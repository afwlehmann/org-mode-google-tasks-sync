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
| `TODO` / `DONE` keyword | ✅ ↔ `needsAction` / `completed` |
| Body text (notes) | ✅ (verbatim — Google Tasks renders plain text, no Markdown / no org markup) |
| `SCHEDULED:` date | ✅ ↔ Google `due` (date only — **time of day is dropped**) |
| Subtask nesting (one level) | ✅ ↔ Google `parent` |
| `[#A]` / `[#B]` / `[#C]` priority cookies | ❌ Local-only — stripped from title on push, preserved on pull |
| Tag ordering / `position` | ❌ Not synced in v1 |
| Recurring tasks | ❌ Google Tasks API is read-only for recurrence |
| `DEADLINE:` | ❌ Only `SCHEDULED:` maps to Google's `due` |

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

## Nix integration

The repo ships a flake with three outputs:

- `overlays.default` — adds `org-mode-google-tasks-sync` to `pkgs.emacsPackages`.
- `homeManagerModules.default` — Home Manager module that installs the package and writes the Emacs config.
- `packages.<system>.default` — the byte-compiled package, if you'd rather wire it up manually.

### Minimal Home Manager setup

```nix
# your flake.nix
inputs.org-mode-google-tasks-sync = {
  url = "github:afwlehmann/org-mode-google-tasks-sync";
  inputs.nixpkgs.follows = "nixpkgs";
};

# your home.nix
{ config, inputs, ... }: {
  nixpkgs.overlays = [ inputs.org-mode-google-tasks-sync.overlays.default ];
  imports = [ inputs.org-mode-google-tasks-sync.homeManagerModules.default ];

  programs.org-mode-google-tasks-sync = {
    enable = true;
    map = {
      "MTYxOTU..." = {
        file = "${config.home.homeDirectory}/org/personal.org";
        parentHeading = "Inbox";
      };
    };
  };
}
```

After `home-manager switch`, run `M-x org-mode-google-tasks-sync-setup` once (same as the non-Nix flow) — all three secrets end up in `~/.authinfo.gpg` via auth-source.

#### One-rebuild bootstrap from the shell

To go from zero to a single `home-manager switch`, do the OAuth dance **before** any HM rebuild, then drop everything into your declarative config. The repo ships a self-contained bootstrap that fetches the code via Nix — no clone required:

```sh
curl -fsSL https://raw.githubusercontent.com/afwlehmann/org-mode-google-tasks-sync/main/bootstrap.sh | sh
```

Or, equivalently:

```sh
nix run github:afwlehmann/org-mode-google-tasks-sync#bootstrap
```

The helper prompts for `client_id` and `client_secret` (paste them from the Cloud Console), opens your browser to the consent screen, and after you click **Allow**, prints to stdout:

```
--- Bootstrap complete ---
client_id=1234567890-abcdef.apps.googleusercontent.com
client_secret=<the value you just entered>
refresh_token=1//0gAbcDef...

--- Google Tasks lists (use these IDs in `map') ---
MTYxOTU...   Personal
MTk0NDg...   Work
```

The bootstrap writes `client_id`, `client_secret`, and `refresh_token` to `~/.authinfo.gpg` along the way (the standard Emacs auth-source location).  You can stop here: copy the list IDs into your HM `map`, set `clientId`/`clientSecretFile`/`gpgRecipient`, and `home-manager switch` once.  Emacs's `auth-sources` walks both the HM-managed XDG file (for client_id/client_secret) and `~/.authinfo.gpg` (for the refresh_token), so everything resolves on the first rebuild.

```nix
sops.secrets.org-mode-google-tasks-sync-client-secret.sopsFile = ./secrets.yaml;

programs.org-mode-google-tasks-sync = {
  enable = true;
  clientId         = "1234567890-abcdef.apps.googleusercontent.com";
  clientSecretFile = config.sops.secrets.org-mode-google-tasks-sync-client-secret.path;
  gpgRecipient     = "alex@example.com";
  map = {
    "MTYxOTU..." = { file = "${config.home.homeDirectory}/org/personal.org"; parentHeading = "Inbox"; };
    "MTk0NDg..." = { file = "${config.home.homeDirectory}/org/work.org";     parentHeading = "Tasks"; };
  };
};
```

Single `home-manager switch`.  Subsequent `M-x org-mode-google-tasks-sync-authorize` (after a future revocation) writes the new refresh token to the HM-managed `dynamic-creds.authinfo.gpg`; the bootstrap-time copy in `~/.authinfo.gpg` becomes a fallback but doesn't interfere because `auth-sources` walks in order and the dynamic file is first.

#### Fetching list IDs only

If you already have a refresh token stored, you can re-fetch list IDs at any time:

```sh
nix develop --command emacs --batch \
  -l org-mode-google-tasks-sync.el \
  -f org-mode-google-tasks-sync-engine-discover-lists-batch
```

Useful when you create new Google Tasks lists and want to extend your `map` without re-running the full bootstrap.

### Declarative credentials (sops-nix, agenix, …)

Set `clientId`, `clientSecretFile`, and `gpgRecipient` to materialize a pair of GPG-encrypted auth-source files under `$XDG_DATA_HOME/org-mode-google-tasks-sync/` at activation time. HM writes `static-creds.authinfo.gpg` from scratch on every rebuild (encrypt-only, no gpg-agent dependency at activation), and Emacs writes the refresh token to `dynamic-creds.authinfo.gpg`. A pinned `.dir-locals.el` keeps EasyPG from prompting for the recipient. `~/.authinfo.gpg` is never touched.

SOPS example:

```nix
sops.secrets.org-mode-google-tasks-sync-client-secret.sopsFile = ./secrets.yaml;

programs.org-mode-google-tasks-sync = {
  enable = true;
  clientId         = "1234567890-abcdef.apps.googleusercontent.com";
  clientSecretFile = config.sops.secrets.org-mode-google-tasks-sync-client-secret.path;
  gpgRecipient     = "alex@example.com";
  map = { /* ... */ };
};
```

`secrets.yaml` (SOPS-encrypted) holds just the secret value:

```yaml
org-mode-google-tasks-sync-client-secret: GOCSPX-xxxxxxxxxxxxxxxxxxxx
```

Then `M-x org-mode-google-tasks-sync-authorize` once (no `-configure` needed). For agenix or NixOS keys, point `clientSecretFile` at their runtime path the same way.

### All module options

| Option | Type | Default | Purpose |
|---|---|---|---|
| `enable` | bool | `false` | Master switch. |
| `package` | package | `pkgs.emacsPackages.org-mode-google-tasks-sync` | Override to pin or fork. |
| `clientId` | nullable string | `null` | OAuth client ID (set together with the next two for the declarative bridge). |
| `clientSecretFile` | nullable path | `null` | Runtime path to a file containing the client secret. |
| `gpgRecipient` | nullable string | `null` | GPG key id/email used to encrypt the XDG credentials files. |
| `map` | attrset of `{ file, parentHeading }` | `{}` | List ID → org file + parent heading. |
| `tickInterval` | positive int | `30` | Seconds between cheap wake-up checks.  Each tick checks file mtimes and only syncs when something changed.  Determines how quickly external edits show up in Google. |
| `pollInterval` | positive int | `300` | Maximum seconds between syncs — safety net so Google-side changes get pulled even when nothing local has changed. |
| `fullSyncInterval` | positive int | `86400` | Seconds between full reconciliations. |
| `autoEnableMode` | bool | `true` | Auto-start `org-mode-google-tasks-sync-mode`. |
| `extraConfig` | lines | `""` | Extra Elisp appended to the generated config. |

### Without Home Manager

If you assemble your Emacs differently, apply the overlay and pull the package out yourself:

```nix
nixpkgs.overlays = [ inputs.org-mode-google-tasks-sync.overlays.default ];
programs.emacs.extraPackages = epkgs: [ epkgs.org-mode-google-tasks-sync ];
```

Or try it directly: `nix run github:afwlehmann/org-mode-google-tasks-sync#emacs`.

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
