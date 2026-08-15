[![CI](https://github.com/afwlehmann/org-mode-google-tasks-sync/actions/workflows/ci.yml/badge.svg)](https://github.com/afwlehmann/org-mode-google-tasks-sync/actions/workflows/ci.yml)

# org-mode-google-tasks-sync

Pure-Elisp two-way sync between your org-mode files and **Google Tasks**.

- Edit, complete, delete tasks in Emacs and have them flow to Google Tasks.
- Edit them on phone or web, and they flow back into your org files.
- Last-write-wins on conflicts; the losing version is preserved in a quarantine buffer.

This package syncs **Google Tasks only** — not Google Calendar events.

---

## How it works

- Sync runs **while Emacs is open** — on a timer (default every 5 minutes) and on save of any configured org file.
- No background daemon, no extra runtime — everything lives in Emacs.
- Google Tasks has no push API, so all sync is poll-based.
- State (per-task ID, ETag, server `updated` timestamp, content hash) lives in each heading's `:PROPERTIES:` drawer. There is no external database.
- Secrets are accessed exclusively through Emacs's `auth-source`.  By default all three (`client_id`, `client_secret`, `refresh_token`) live in `~/.authinfo.gpg`.  When the Home Manager bridge is used instead, all three live in a single chmod-0600 netrc file under `$XDG_DATA_HOME` — `~/.authinfo.gpg` is never touched by this package.

## What is and isn't synced

| Field | Synced? |
|---|---|
| Heading title | ✅ |
| `TODO` / `DONE` keyword | ✅ ↔ `needsAction` / `completed` — configurable via `org-mode-google-tasks-sync-keep-done-items` (see [DONE handling](#done-handling)) |
| Body text (notes) | ✅ (verbatim — Google Tasks renders plain text, no Markdown / no org markup) |
| `SCHEDULED:` date | ✅ ↔ Google `due` (date only — **time of day is dropped**) |
| Subtask nesting (two levels) | ✅ ↔ Google `parent` — top-level tasks and one level of subtasks. Reparenting conflicts resolved remote-wins. |
| `[#A]` / `[#B]` / `[#C]` priority cookies | ❌ Local-only — stripped from title on push, preserved on pull |
| Org tags (`:tag1:` `:tag2:`) | ✅ Encoded as trailing `@` hashtags in the pushed title (e.g. `Buy milk @errands @work`), decoded back into org tags on pull. Sorted; whitespace-containing tags are silently dropped. |
| Tag ordering / `position` | ✅ Via org's `M-↑`/`M-↓`/`M-←`/`M-→` keys (server-first, no race), or manual cut/paste (detected at next tick) |
| Links / attachments (`links[]`, `webViewLink`) | 📖 Read-only display — populated by Gmail/Keep/Chat/Docs; stored as `:GTASK_LINKS:` / `:GTASK_WEB_LINK:` properties.  Not pushable via the API. |
| Starred | ❌ No `starred` field in the Tasks API v1 |
| Recurring tasks | ❌ Google Tasks API is read-only for recurrence |
| `DEADLINE:` | ❌ Only `SCHEDULED:` maps to Google's `due` |
| Hidden tasks (`hidden=true`) | 🗑️ Treated as deleted — removed locally with trash snapshot. See [Hidden tasks](#hidden-tasks). |

### Sync scope

```org
* Tasks                       ← sync starts here
** TODO Buy milk              synced
*** TODO Buy oat milk         synced (subtask)
**** Weird depth              NOT synced — too deep

* Other section               ← sync stops here
** TODO totally unrelated     NOT synced
```

Sync visits the subtree under the configured `PARENT-HEADING` only, up
to two levels deep (top-level tasks plus one level of subtasks).  The
first heading at the parent's own level — or shallower — ends the
region; anything after is ignored.  Unrelated sections in the same file
are never touched.

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
   - Name: anything (e.g. "Emacs org-mode-google-tasks-sync").
   - Click Create.
5. **Save** the resulting `client_id` and `client_secret`. You'll paste them into Emacs in the next section.

---

## Install

1. Install dependencies from MELPA:

   ```
   M-x package-install RET plz RET
   M-x package-install RET oauth2 RET
   ```

2. Clone this repo and add it to your `load-path`:

   ```elisp
   (add-to-list 'load-path "/path/to/org-mode-google-tasks-sync")
   (require 'org-mode-google-tasks-sync)
   ```

(Nix users: the repo also ships a flake with an overlay and a Home Manager module — see [Nix integration](#nix-integration) below.)

---

## Configuration

This section describes **every** user-facing variable and command. All variables live in the `org-mode-google-tasks-sync` customization group; `M-x customize-group RET org-mode-google-tasks-sync RET` works for any of them.

### Step 1 — One-time interactive setup

```
M-x org-mode-google-tasks-sync-setup
```

This single command:
1. Prompts for `client_id` and `client_secret` (from the Cloud Console). Stores them in `~/.authinfo.gpg` via `auth-source`.
2. Spins up a loopback HTTP server, opens your browser to Google's consent screen, captures the redirect, and writes the resulting `refresh_token` to `~/.authinfo.gpg`.
3. Opens a `*Google Tasks Lists*` buffer with your list IDs so you can copy the ones you want into the map below.

Two things to expect:

- A "Google hasn't verified this app" warning during the browser step — click **Advanced → Continue**. Expected for an unverified personal app.
- A GPG passphrase prompt the first time Emacs reads/writes `~/.authinfo.gpg` in this session.

Each phase is also available individually for re-runs:
`M-x org-mode-google-tasks-sync-configure`, `…-authorize`, `…-list-discover`.

### Step 2 — Configure list → file mapping

```elisp
;; init.el
(setq org-mode-google-tasks-sync-map
      '(("MTYxOTU..."  . ("~/org/work.org"     . "Tasks"))
        ("MTk0NDg..."  . ("~/org/personal.org" . "Inbox"))))
```

Each entry is `(LIST-ID . (FILE . PARENT-HEADING))`:
- `LIST-ID` is the opaque Google Tasks list ID from `list-discover`.
- `FILE` is the absolute or tilde-expanded path to an org file. The file must exist; if the heading doesn't yet, you'll create it manually before the first sync.
- `PARENT-HEADING` is the **exact text** of the heading under which synced tasks live. Sync touches **only direct children** of this heading — anything else in the file is left alone. This lets you put non-synced TODOs in the same file.

**The match is literal.** In the org buffer, write the heading as stars + one space + the exact `PARENT-HEADING` text, nothing else:

| In the buffer | With `PARENT-HEADING` of `"Tasks"` |
|---|---|
| `* Tasks` | ✅ matches |
| `* Tasks :work:` | ❌ no match (tags make the raw text `"Tasks :work:"`) |
| `* TODO Tasks` | ❌ no match (TODO keyword is part of the raw text) |
| `*  Tasks` (double space) | ❌ no match |
| ❌ not present at all | 🔧 engine auto-creates `* Tasks` at end-of-file on first sync |

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

### Step 3 — Enable the minor mode

```elisp
;; init.el (after the setq above)
(org-mode-google-tasks-sync-mode 1)
```

This installs:
- A periodic timer that calls `org-mode-google-tasks-sync` every `org-mode-google-tasks-sync-poll-interval` seconds.
- A separate timer that calls `org-mode-google-tasks-sync-full-sync` every `org-mode-google-tasks-sync-full-sync-interval` seconds.
- An `after-save-hook` that triggers an incremental sync ~1 second after you save any configured target file.

---

## All configuration variables

| Variable | Default | What it does |
|---|---|---|
| `org-mode-google-tasks-sync-map` | `nil` | Alist of `(LIST-ID . (FILE . PARENT-HEADING))` entries. See above. **Required** for sync to do anything. |
| `org-mode-google-tasks-sync-poll-interval` | `300` | Seconds between incremental sync ticks while the minor mode is on. |
| `org-mode-google-tasks-sync-full-sync-interval` | `86400` (1 day) | Seconds between full reconciliation passes. Full sync drops `updatedMin` and diffs Google's full ID set against local IDs to detect long-tombstoned deletions. |
| `org-mode-google-tasks-sync-debug-jump-always-prompt` | `nil` | Debug flag. When non-nil, `org-mode-google-tasks-sync-jump-to-list` always prompts even with a single reachable list. Set at runtime with `setq`. |

### What goes where

| Data | Where it lives |
|---|---|
| `client_id`, `client_secret`, `refresh_token` | `~/.authinfo.gpg` via `auth-source` |
| `org-mode-google-tasks-sync-map`, polling intervals | Your `init.el` (or `customize`) |
| Per-task ID, ETag, server `updated`, content hash | `:PROPERTIES:` drawer of each synced heading |
| Per-file last incremental sync timestamp | `#+GTASKS_LAST_SYNC:` keyword at top of file |
| Per-file last full sync timestamp | `#+GTASKS_LAST_FULL_SYNC:` keyword at top of file |
| Action log | `*org-mode-google-tasks-sync-log*` buffer (in-memory; survives until Emacs exits) |
| Conflict quarantine | `*Google Tasks Conflicts*` buffer (in-memory; survives until Emacs exits) |

Heading properties written by the package:

| Property | Purpose |
|---|---|
| `:GTASK_ID:` | The Google Tasks task ID. Absent means the heading hasn't been pushed yet. |
| `:GTASK_LIST:` | The Google Tasks list ID this task belongs to. |
| `:GTASK_UPDATED:` | The `updated` timestamp from Google's last response for this task. Server-authoritative; never compared to local clock. |
| `:GTASK_ETAG:` | The ETag from Google's last response. Sent as `If-Match` on PATCH; on 412 mismatch the task is re-fetched and conflict resolution re-runs. |
| `:GTASK_CONTENT_HASH:` | SHA-1 over a canonical projection of (title, notes, status, due). Stable across whitespace and property-drawer churn. Compared on every tick to detect local edits since the last sync. |
| `:GTASK_PARENT_ID:` | Server `parent` task ID at last sync. Compared against the parent ID inferred from the current heading hierarchy to distinguish a local reparent (they differ, push direction) from a remote one (they match, apply direction). Absent for top-level tasks; not in the hash. |
| `:GTASK_POSITION:` | Server `position` lexicographic-rank string. Used for sorting; not in the hash. |
| `:GTASK_COMPLETED:` | Server `completed` RFC3339 timestamp. Sort key for DONE tasks; not in the hash. |
| `:GTASK_LINKS:` | Server `links[]` array, JSON-encoded. Read-only display metadata populated by Gmail/Keep/Chat/Docs. Not in the hash; not pushable. |
| `:GTASK_WEB_LINK:` | Server `webViewLink` URL to the task in Google's web UI. Read-only display metadata; not in the hash; not pushable. |

---

## Public commands

| Command | What it does |
|---|---|
| `org-mode-google-tasks-sync-configure` | Prompt for client_id + client_secret; store in auth-source. Idempotent. |
| `org-mode-google-tasks-sync-authorize` | Run the OAuth consent flow; store refresh_token in auth-source. |
| `org-mode-google-tasks-sync-list-discover` | List your Google task lists with their IDs in a buffer. |
| `org-mode-google-tasks-sync` | Run one incremental sync pass right now. |
| `org-mode-google-tasks-sync-full-sync` | Run a full reconciliation now (detects old tombstones). |
| `org-mode-google-tasks-sync-show-log` | Pop to the action log buffer. |
| `org-mode-google-tasks-sync-show-conflicts` | Pop to the conflict quarantine buffer. |
| `org-mode-google-tasks-sync-jump-to-list` | Jump to a configured Google Tasks list from anywhere. With one reachable list, goes directly; with more, prompts with fuzzy completion. |
| `org-mode-google-tasks-sync-mode` | Global minor mode. Toggle on to install the sync timer and save hook. |

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
- **Remote → local, old tombstones**: a full sync (daily, or `M-x org-mode-google-tasks-sync-full-sync`) fetches the live ID set and removes any locally-stored ID no longer present.
- **Local → remote**: a heading removed from the synced subtree (or archived out of it) is `DELETE`d from Google on the next tick.

Every delete is logged to `*org-mode-google-tasks-sync-log*` with the title and timestamp, so accidental losses are visible.

---

Run into trouble?  See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — covers `(epg-error "no usable configuration" OpenPGP)`, sync-runs-but-nothing-changes, and refresh-token revocation.

---

## Suggested key bindings

The package does **not** install keybindings itself — it only ships the `org-mode-google-tasks-sync-command-map` keymap.  Bind it under a prefix in your `init.el`, guarded by `with-eval-after-load` so the keymap variable is non-nil at bind time:

```elisp
(with-eval-after-load 'org-mode-google-tasks-sync
  (global-set-key (kbd "C-c g") org-mode-google-tasks-sync-command-map))
```

The `with-eval-after-load` guard matters: without it, the keymap is still `nil` if your init runs the `global-set-key` before the package is loaded (common with `use-package :defer t` or when the line sits ahead of the `require`).  `C-c g` then silently binds to nothing — `M-x org-mode-google-tasks-sync` still works (the commands are autoloaded) but the keys are dead.  If your `C-c g …` chords don't respond, check `C-h v org-mode-google-tasks-sync-command-map RET` — `nil` means the package isn't loaded yet.

`C-c g …` doesn't conflict with stock org-mode (which uses `C-c C-…`, `C-c a`, `C-c c`, `C-c l`, `C-c '` etc.) or with [org-roam](https://www.orgroam.com/) (whose prefix is `C-c n …`).

| Key | Command |
|---|---|
| `C-c g S` | `org-mode-google-tasks-sync-setup` (one-time configure + authorize) |
| `C-c g s` | `org-mode-google-tasks-sync` (incremental sync now) |
| `C-c g f` | `org-mode-google-tasks-sync-full-sync` |
| `C-c g n` | `org-mode-google-tasks-sync-new-task` |
| `C-c g d` | `org-mode-google-tasks-sync-delete-at-point` |
| `C-c g h` | toggle `org-mode-google-tasks-sync-hide-done-mode` |
| `C-c g H` | `org-mode-google-tasks-sync-show-done` |
| `C-c g r` | `org-mode-google-tasks-sync-show-trash` |
| `C-c g R` | `org-mode-google-tasks-sync-restore-at-point` (inside trash buffer) |
| `C-c g l` | `org-mode-google-tasks-sync-show-log` |
| `C-c g c` | `org-mode-google-tasks-sync-show-conflicts` |
| `C-c g j` | `org-mode-google-tasks-sync-jump-to-list` |

Use a different prefix if `C-c g` clashes with something in your own config — the keymap is independent of the prefix you choose.

---

## Display, ordering, and editing

The engine pulls everything from Google (including DONE tasks) into the synced subtree.  A few helpers keep the view manageable and the edits explicit.

### Sort order

After each sync the children of the parent heading are sorted to match Google's web UI:

- **TODO entries first**, by Google's `position` field (ascending — the lexicographic-rank string the API maintains for in-list ordering).
- **DONE entries after**, by `completed` timestamp (descending — most-recently-completed first).

`:GTASK_POSITION:` and `:GTASK_COMPLETED:` are stored on each synced heading.  Headings you create manually under the parent are pushed on the next sync; Google assigns a `position`, which is written to the property drawer before the sort runs — so the heading lands in its server-assigned position on the same tick.  If a position is ever missing (e.g. a push error), the heading sorts to the end of the TODO section rather than the front.

### Reorder and reparent with org's own keys

When `org-mode-google-tasks-sync-mode` is enabled, org's built-in subtree-move and promote/demote keys are advised so they push to Google via `tasks.move`:

| Key | Org command | Synced action |
|---|---|---|
| `M-↑` | `org-move-subtree-up` | Reorder among siblings (same parent) |
| `M-↓` | `org-move-subtree-down` | Reorder among siblings (same parent) |
| `M-←` | `org-do-promote` | Subtask → top-level (`parent=nil`) |
| `M-→` | `org-do-demote` | Top-level → subtask (of preceding sibling) |
| `M-S-←` | `org-promote-subtree` | **Refused** on synced headings |
| `M-S-→` | `org-demote-subtree` | **Refused** on synced headings |

All advised operations are **server-first**: the heading doesn't move locally until Google confirms the new position, which eliminates the race with the post-apply sort step.  You'll see a brief "Moving…" message while the API call is in flight.

Non-synced headings pass through to org's original behavior with zero change.

**Manual cut/paste reorders**: if you cut a heading and paste it elsewhere (instead of using `M-↑`/`M-↓`/`M-←`/`M-→`), the engine detects the reorder at the next tick by comparing the buffer's physical sibling order against the order implied by stored `:GTASK_POSITION:` values.  It then fires `tasks.move` for every synced sibling to push your intended order to the server.  This runs *before* the sort step, so the buffer converges to your manual reorder.

**Demote guard:** demoting a top-level task that itself has subtask headings is refused — the subtasks would fall to level N+3 (outside the 2-level sync window) and stop syncing.  Move or delete the subtasks first.

### Hide DONE tasks

`M-x org-mode-google-tasks-sync-hide-done-mode` is a buffer-local minor mode that hides every DONE-keyword headline (and its subtree) via invisibility overlays.  Toggle on/off interactively, or auto-enable for target files:

```elisp
(setq org-mode-google-tasks-sync-hide-done-by-default t)
```

In the Home Manager module, `hideDoneByDefault = true;` sets the defcustom for you.

To **un-DONE an accidentally completed task**:
1. `M-x org-mode-google-tasks-sync-show-done` (or toggle the mode off).
2. Navigate to the task.
3. `C-c C-t` — back to TODO.  The hook removes the overlay automatically.
4. Re-enable the mode if needed.

### Create a new task

Add a `* TODO` heading anywhere under the configured parent and save:

```org
* Inbox
** TODO Buy milk
```

After-save-hook schedules a sync ~1 s later.  The engine sees the heading has no `:GTASK_ID:`, POSTs it to Google, writes `:GTASK_ID:`, `:GTASK_UPDATED:`, `:GTASK_ETAG:`, and `:GTASK_POSITION:` back into the property drawer.

For a guided prompt: `M-x org-mode-google-tasks-sync-new-task` — asks for a title, then uses org's calendar pop-up (`org-read-date`) to collect an optional scheduled date.  Press `C-g` at the date prompt for "no scheduled date".  Inserts the heading under the parent (or `completing-read` across multiple configured lists) and saves.

### Delete a task once and for all

`M-x org-mode-google-tasks-sync-delete-at-point` on a synced heading:

1. Asks `Delete task "Buy milk" from Google? (yes/no)`.
2. On `yes`: calls `tasks.tasks.delete`, snapshots the task into `*org-mode-google-tasks-sync-trash*`, removes the heading + subtree locally, logs `Deleted: <title>`.
3. Engine-side deletions in response to remote tombstones also drop into the same trash buffer.

### Undo a deletion

`M-x org-mode-google-tasks-sync-show-trash` opens the trash buffer.  Point on the deleted heading you want back, then `M-x org-mode-google-tasks-sync-restore-at-point`.

Caveats:

- **Deleted tasks** (`:GTASK_REMOVAL_REASON: deleted`): the original task is gone server-side.  Restoration creates a **fresh** task with the same title, notes, status, and due date, then calls `tasks.move` to restore the original relative position (best-effort).  A new `:GTASK_ID:` is assigned by Google; the original ID is preserved in the trash entry under `:GTASK_ID_ORIG:` for human reference only.
- **Done-removed tasks** (`:GTASK_REMOVAL_REASON: done-removed`): the task still exists on the server as completed.  Restoration **reopens** the original task (patches `status=needsAction`) and re-inserts the local heading with the original `:GTASK_ID:`, `:GTASK_UPDATED:`, `:GTASK_ETAG:`, and `:GTASK_POSITION:` — no duplicate is created, and the task appears at its original relative position.
- The trash buffer is persisted to `$XDG_DATA_HOME/org-mode-google-tasks-sync/trash.org` by default; toggle via `org-mode-google-tasks-sync-persist-trash`.
- The buffer never auto-purges.  Clean it yourself when you trust the deletions.

### DONE handling

By default (`org-mode-google-tasks-sync-keep-done-items` = nil), completed tasks are **removed from the local buffer** instead of kept as DONE headings:

- **Server-side completion**: when Google marks a task DONE, the local heading is removed (snapshotted to trash as `done-removed`, restorable via `restore-at-point` which reopens the original task).
- **Local completion**: when you mark a task DONE locally, the engine pushes `status=completed` to Google, then removes the local heading (also snapshotted as `done-removed`).
- **Conflicts**: remote always wins — if both sides changed, the local version is quarantined to `*Google Tasks Conflicts*` before removal.

To restore the historical two-way DONE sync behavior (completed tasks stay in the buffer as DONE headings):

```elisp
(setq org-mode-google-tasks-sync-keep-done-items t)
```

This is a **breaking change**: users upgrading from a version that always kept DONE headings will, after upgrading, see completed tasks start disappearing from the org buffer.  Set the defcustom to `t` to restore the prior behavior.

### Hidden tasks

Google Tasks' web UI has a **"Clear completed tasks"** action that marks completed tasks as `hidden=true` on the server.  These tasks are not deleted — they remain on the server but are invisible in the web UI.  This package treats `hidden=true` tasks as **deleted**:

- Hidden tasks are filtered out of the remote set *before* reconciliation — they are never pulled or pushed.
- Any local heading whose `:GTASK_ID:` matches a hidden task is removed via `--delete-local` with reason `hidden-archived` (trash-snapshotted).
- This runs in both `incremental` and `full` sync modes.
- **Restoring** a `hidden-archived` task creates a **fresh** task (new `:GTASK_ID:`), because the original is unreachable via the API.

This is independent of `org-mode-google-tasks-sync-keep-done-items`: `hidden` is server-side archival; `keep-done-items` is a local display preference.

---

## Troubleshooting

### Transient HTTP errors and rate limits

Every request (list, insert, patch, delete, move) is retried automatically
on transient failures: HTTP **429 / 500 / 502 / 503 / 504**, and curl-level
transport errors (DNS / connection / timeout / SSL handshake / empty reply /
recv failure). Retry uses exponential backoff with full jitter (uniform in
[0.5 s, 2 s] after the first failure, [0.5 s, 4 s] after the second) and
honors `Retry-After` up to a 60-second cap. Worst
case, three attempts are made before the request surfaces to `*org-mode-google-tasks-sync-log*` as an error — so a single busy Google's rate-limit response doesn't kill a tick.

Non-transient errors (400/404/412 handled differently, auth failures) are
never retried: they'd just burn attempts.

### HTTP 412 — ETag conflict on a push

When your local edit and someone else's edit collide on the server's ETag,
the sync PATCH returns 412. The API layer **does not blind-retry** — it fetches the live task and applies remote-wins: if your local version differs from the fetched copy, that losing side is quarantined to `*Google Tasks Conflicts*` first; the fresh copy is written in-place; a `ETag conflict resolved (remote-wins)` line lands in the log.  Config-permanent 412s (e.g. corrupted `:GTASK_ETAG:` on the heading) recur at every tick — re-push with stale metadata is impossible, so the fix is to pull first (`M-x org-mode-google-tasks-sync-full-sync`).

### The log buffer

Every pull, push, delete, conflict, retry, and error is logged to
`*org-mode-google-tasks-sync-log*`. The first thing to check when a sync
appears to misbehave. With `org-mode-google-tasks-sync-log-level` at
`'debug`, JSON serialization details and extra API diagnostics are
included.

### Duplicate subtasks after upgrade

Versions before 0.5.5 had a bug where a parent task's `notes` slot
included its children's heading text, causing the canonical hash to
change whenever a subtask changed and the push callback to re-insert
the child text as new headings — doubling subtasks on every sync.
Upgrading to 0.5.5 fixes the root cause and the next sync
deduplicates any existing copies automatically (duplicates at any
level — top-level tasks and subtasks — are removed and snapshotted to
the trash buffer for manual recovery if needed).

### Freshly-pushed subtasks sorting to the wrong position

Versions before 0.5.6 had a bug where `--finalize-push-new` discarded
the server-assigned `position` from the `tasks.insert` response — only
`id`, `updated`, and `etag` were copied. The heading got its
`:GTASK_ID:` but no `:GTASK_POSITION:`, so `--sort-children` sorted it
to the front of its siblings (empty string sorts before any real
position), making it appear to "disappear." On the next sync a pull
would eventually write the position and the heading would "reappear."
Upgrading to 0.5.6 fixes the root cause; existing positionless headings
are repaired on the next pull.

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
- Reordering via org's `M-↑`/`M-↓`/`M-←`/`M-→` keys pushes to Google immediately (server-first).  Manual cut/paste reorders are detected at the next tick.
- `due` is date-only; times of day are dropped on round-trip.
- Recurring tasks: Google Tasks API is read-only for recurrence; not supported here.
- Sync only runs while Emacs is open.
