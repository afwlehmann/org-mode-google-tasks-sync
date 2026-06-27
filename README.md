# org-mode-google-tasks

Pure-Elisp two-way sync between your org-mode files and **Google Tasks**.

- Edit, complete, delete tasks in Emacs and have them flow to Google Tasks.
- Edit them on phone or web, and they flow back into your org files.
- Last-write-wins on conflicts; the losing version is preserved in a quarantine buffer.

This package syncs **Google Tasks only** — not Google Calendar events. If you need calendar event sync, use [`org-gcal.el`](https://github.com/kidd/org-gcal.el).

---

## How it works

- Sync runs **while Emacs is open** — on a timer (default every 5 minutes) and on save of any configured org file.
- No background daemon, no extra runtime — everything lives in Emacs.
- Google Tasks has no push API, so all sync is poll-based.
- State (per-task ID, ETag, server `updated` timestamp, content hash) lives in each heading's `:PROPERTIES:` drawer. There is no external database.
- Secrets (`client_id`, `client_secret`, `refresh_token`) live in `~/.authinfo.gpg` via `auth-source`.

## What is and isn't synced

| Field | Synced? |
|---|---|
| Heading title | ✅ |
| `TODO` / `DONE` keyword | ✅ ↔ `needsAction` / `completed` |
| Body text (notes) | ✅ (verbatim — Google Tasks renders plain text, no Markdown / no org markup) |
| `SCHEDULED:` date | ✅ ↔ Google `due` (date only — **time of day is dropped**) |
| Subtask nesting (one level) | ✅ ↔ Google `parent` |
| `[#A]` / `[#B]` / `[#C]` priority cookies | ❌ Local-only — stripped from title on push, preserved on pull |
| Tag ordering / `position` | ❌ Not synced in v1 |
| Recurring tasks | ❌ Google Tasks API is read-only for recurrence |
| `DEADLINE:` | ❌ Only `SCHEDULED:` maps to Google's `due` |
| Multiple Google accounts | ❌ Single account in v1 |

---

## Prerequisites

- **Emacs 27.1** or later (needs native `json-parse-string`).
- **GPG** installed locally — `brew install gnupg` on macOS, usually preinstalled on Linux.
- **`plz`** and **`oauth2`** Emacs packages (auto-installed by the test infra; you should `M-x package-install` them for end-user use). Both are on GNU ELPA / MELPA.
- A **Google Cloud project** with the **Tasks API enabled** and a **Desktop OAuth client** (see below).

### Google Cloud setup (one-time, ~5 minutes)

1. Go to https://console.cloud.google.com and create a project (or use an existing one).
2. **APIs & Services → Library →** search "Tasks API" → **Enable**.
3. **APIs & Services → OAuth consent screen**:
   - Choose **External** (only valid choice for personal `@gmail.com` accounts).
   - Fill in app name and developer contact email.
   - Save and continue through the scopes / test users screens (no scopes need to be added here; the package requests them dynamically).
   - On the **Audience** tab, add yourself as a **Test user**.
   - **Click "PUBLISH APP"** to move publishing status from Testing to In production. This avoids the 7-day refresh-token expiry that applies in Testing mode. For a single-user personal app you can stay unverified forever — Google's verification requirements only kick in above 100 users.
4. **APIs & Services → Credentials → + Create credentials → OAuth client ID**:
   - Application type: **Desktop app**.
   - Name: anything (e.g. "Emacs org-mode-google-tasks").
   - Click Create.
5. **Save** the resulting `client_id` and `client_secret`. You'll paste them into Emacs in the next section.

---

## Install

Until this package lands on MELPA, clone the repo and `load` it manually:

```elisp
;; in your init.el
(add-to-list 'load-path "~/src/git/org-mode-google-tasks-sync")
(require 'org-mode-google-tasks)
```

Install dependencies from MELPA if you haven't:

```elisp
M-x package-install RET plz RET
M-x package-install RET oauth2 RET
```

---

## Configuration

This section describes **every** user-facing variable and command. All variables live in the `org-mode-google-tasks` customization group; `M-x customize-group RET org-mode-google-tasks RET` works for any of them.

### Step 1 — Store OAuth credentials

Run the interactive configuration command:

```
M-x org-mode-google-tasks-configure
```

You'll be prompted for `client_id` and `client_secret` from the Cloud Console. Both are stored in `~/.authinfo.gpg` via `auth-source` under these entries:

```
machine api.google.com login org-mode-google-tasks-client-id      password <your-id>.apps.googleusercontent.com
machine api.google.com login org-mode-google-tasks-client-secret  password GOCSPX-...
```

You can also write those lines directly into `~/.authinfo.gpg` with any text editor (Emacs will decrypt and re-encrypt transparently via EasyPG).

### Step 2 — Authorize

```
M-x org-mode-google-tasks-authorize
```

This:
1. Reads the credentials you just stored.
2. Spins up a one-shot local HTTP server on `127.0.0.1:<random port>`.
3. Opens your browser to Google's consent screen.
4. After you click "Allow", Google redirects to the local server, the code is exchanged for tokens, and the **refresh token** is appended to `~/.authinfo.gpg`:

   ```
   machine api.google.com login org-mode-google-tasks-refresh-token  password 1//0g...
   ```

The first time you'll see a "Google hasn't verified this app" warning. Click **Advanced → Continue** — this is expected for an unverified single-user app.

### Step 3 — Discover your task lists

```
M-x org-mode-google-tasks-list-discover
```

This fetches your task lists from Google and opens a `*Google Tasks Lists*` buffer showing each list's **ID** and **title**. Copy the IDs you want to sync.

### Step 4 — Configure list → file mapping

```elisp
;; init.el
(setq org-mode-google-tasks-map
      '(("MTYxOTU..."  . ("~/org/work.org"     . "Tasks"))
        ("MTk0NDg..."  . ("~/org/personal.org" . "Inbox"))))
```

Each entry is `(LIST-ID . (FILE . PARENT-HEADING))`:
- `LIST-ID` is the opaque Google Tasks list ID from `list-discover`.
- `FILE` is the absolute or tilde-expanded path to an org file. The file must exist; if the heading doesn't yet, you'll create it manually before the first sync.
- `PARENT-HEADING` is the **exact text** of the heading under which synced tasks live. Sync touches **only direct children** of this heading — anything else in the file is left alone. This lets you put non-synced TODOs in the same file.

Example file:

```org
#+TITLE: Personal

* Inbox
** TODO Buy milk
   :PROPERTIES:
   :GTASK_ID: ...
   :END:
** DONE Renew passport
* Random other stuff (not synced)
** This is fine, it's outside the synced subtree.
```

### Step 5 — Enable the minor mode

```elisp
;; init.el (after the setq above)
(org-mode-google-tasks-mode 1)
```

This installs:
- A periodic timer that calls `org-mode-google-tasks-sync` every `org-mode-google-tasks-poll-interval` seconds.
- A separate timer that calls `org-mode-google-tasks-full-sync` every `org-mode-google-tasks-full-sync-interval` seconds.
- An `after-save-hook` that triggers an incremental sync ~1 second after you save any configured target file.

---

## All configuration variables

| Variable | Default | What it does |
|---|---|---|
| `org-mode-google-tasks-map` | `nil` | Alist of `(LIST-ID . (FILE . PARENT-HEADING))` entries. See above. **Required** for sync to do anything. |
| `org-mode-google-tasks-poll-interval` | `300` | Seconds between incremental sync ticks while the minor mode is on. |
| `org-mode-google-tasks-full-sync-interval` | `86400` (1 day) | Seconds between full reconciliation passes. Full sync drops `updatedMin` and diffs Google's full ID set against local IDs to detect long-tombstoned deletions. |

### What goes where

| Data | Where it lives |
|---|---|
| `client_id`, `client_secret`, `refresh_token` | `~/.authinfo.gpg` via `auth-source` |
| `org-mode-google-tasks-map`, polling intervals | Your `init.el` (or `customize`) |
| Per-task ID, ETag, server `updated`, content hash | `:PROPERTIES:` drawer of each synced heading |
| Per-file last incremental sync timestamp | `#+GTASKS_LAST_SYNC:` keyword at top of file |
| Per-file last full sync timestamp | `#+GTASKS_LAST_FULL_SYNC:` keyword at top of file |
| Action log | `*org-mode-google-tasks-log*` buffer (in-memory; survives until Emacs exits) |
| Conflict quarantine | `*Google Tasks Conflicts*` buffer (in-memory; survives until Emacs exits) |

Heading properties written by the package:

| Property | Purpose |
|---|---|
| `:GTASK_ID:` | The Google Tasks task ID. Absent means the heading hasn't been pushed yet. |
| `:GTASK_LIST:` | The Google Tasks list ID this task belongs to. |
| `:GTASK_UPDATED:` | The `updated` timestamp from Google's last response for this task. Server-authoritative; never compared to local clock. |
| `:GTASK_ETAG:` | The ETag from Google's last response. Sent as `If-Match` on PATCH; on 412 mismatch the task is re-fetched and conflict resolution re-runs. |
| `:GTASK_CONTENT_HASH:` | SHA-1 over a canonical projection of (title, notes, status, due). Stable across whitespace and property-drawer churn. Compared on every tick to detect local edits since the last sync. |

---

## Public commands

| Command | What it does |
|---|---|
| `org-mode-google-tasks-configure` | Prompt for client_id + client_secret; store in auth-source. Idempotent. |
| `org-mode-google-tasks-authorize` | Run the OAuth consent flow; store refresh_token in auth-source. |
| `org-mode-google-tasks-list-discover` | List your Google task lists with their IDs in a buffer. |
| `org-mode-google-tasks-sync` | Run one incremental sync pass right now. |
| `org-mode-google-tasks-full-sync` | Run a full reconciliation now (detects old tombstones). |
| `org-mode-google-tasks-show-log` | Pop to the action log buffer. |
| `org-mode-google-tasks-show-conflicts` | Pop to the conflict quarantine buffer. |
| `org-mode-google-tasks-mode` | Global minor mode. Toggle on to install the sync timer and save hook. |

---

## Conflict and deletion semantics

### Conflict (a task changed on both sides between syncs)

The package computes two booleans per task:
- `local-changed?` — current canonical hash ≠ stored `:GTASK_CONTENT_HASH:`.
- `remote-changed?` — response `updated` ≠ stored `:GTASK_UPDATED:`.

| local-changed? | remote-changed? | Action |
|---|---|---|
| no | no | skip |
| yes | no | push local to Google |
| no | yes | pull Google to local |
| yes | yes | **last-write-wins**: whichever side has a newer timestamp wins. The losing side is appended to the `*Google Tasks Conflicts*` buffer so you can recover the overwritten content. |

### Deletion (auto-delete in both directions, no confirmation)

- **Remote → local**: a `deleted: true` tombstone (returned within Google's ~30-day retention) → the local heading is removed immediately.
- **Remote → local, old tombstones**: a full sync (daily, or `M-x org-mode-google-tasks-full-sync`) fetches the live ID set and removes any locally-stored ID no longer present.
- **Local → remote**: a heading removed from the synced subtree (or archived out of it) is `DELETE`d from Google on the next tick.

Every delete is logged to `*org-mode-google-tasks-log*` with the title and timestamp, so accidental losses are visible.

---

## Troubleshooting

### "Run `M-x org-mode-google-tasks-configure' first"
The package couldn't find your client_id or client_secret in auth-source. Run `M-x org-mode-google-tasks-configure` and check that `~/.authinfo.gpg` decrypts (it should prompt for your GPG passphrase the first time per session).

### Browser shows "Google hasn't verified this app"
Expected for an unverified personal app. Click **Advanced → Continue** to proceed. This warning only appears during the initial consent; subsequent token refreshes are silent.

### Sync seems to do nothing
- Check `org-mode-google-tasks-map` has entries.
- Check the parent heading text **exactly** matches the heading in the file (case-sensitive).
- Pop to `*org-mode-google-tasks-log*` to see what happened during the last tick.

### Refresh token expired / invalid
Run `M-x org-mode-google-tasks-authorize` again. The new refresh_token will overwrite the stale one in auth-source.

### GPG keeps prompting for the passphrase
Configure `gpg-agent` with `pinentry-mac` (or `pinentry-curses` on Linux). The passphrase will be cached for hours and prompts become rare. See https://gnupg.org/documentation/manuals/gnupg/Agent-Configuration.html.

### Port conflict on the OAuth loopback redirect
The loopback server uses a kernel-assigned port (`:service t` in `make-network-process`), so there shouldn't be conflicts. If `M-x org-mode-google-tasks-authorize` fails to bind, restart Emacs.

### Rate limits
Google Tasks API has generous limits (~50k requests/day per project). If you hit a 429, the package backs off exponentially (1s → 60s cap). All rate-limit events are logged.

### How do I revoke / re-authorize?
1. Visit https://myaccount.google.com/permissions, find the app, click "Remove access".
2. Delete the `org-mode-google-tasks-refresh-token` line from `~/.authinfo.gpg`.
3. Run `M-x org-mode-google-tasks-authorize` again to issue a fresh token.

---

## Development

Run the test suite:

```sh
emacs --batch -l test/run-tests.el -f ert-run-tests-batch-and-exit
```

This installs `plz` and `oauth2` into a project-local `test/.elpa` on first run (so your `~/.emacs.d` isn't touched), then runs all `ert` tests.

See `AGENTS.md` for module layout, internal invariants, and conventions.

---

## Scope and limitations

- Single Google account.
- Google Tasks only (no Calendar events).
- Single top-level subtree per list — synced headings must be direct children of the configured `PARENT-HEADING`.
- Subtask nesting limited to one level (Google's data model only supports one).
- Tasks reordered in one side don't reorder the other (no `position` sync in v1).
- `due` is date-only; times of day are dropped on round-trip.
- Recurring tasks: Google Tasks API is read-only for recurrence; not supported here.
- Sync only runs while Emacs is open.
