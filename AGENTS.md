# AGENTS.md — orientation for AI assistants and contributors

This file gives an AI agent (or new human contributor) what they need to make safe, idiomatic changes to this package without re-deriving the architecture. End-user docs are in `README.md`.

## At a glance

Pure-Elisp two-way sync between org-mode and Google Tasks. Triggered by an Emacs timer + `after-save-hook`. Last-write-wins with conflict quarantine. Auto-delete in both directions. Single Google account, single subtree per list, no `position` sync in v1.

## Use Nix when it's available

If `command -v nix` succeeds, **prefer `nix develop --command ...` for every Emacs invocation** (running tests, byte-compiling, exploring the package in a REPL, anything that needs `plz` or `oauth2`). The dev shell guarantees the deps are on the load-path and avoids touching `test/.elpa/` or the user's `~/.emacs.d`.

Quick reference:

```sh
nix develop --command emacs --batch -l test/run-tests.el -f ert-run-tests-batch-and-exit
nix develop --command emacs --batch -L . -f batch-byte-compile *.el
nix flake check                                            # fully sandboxed CI-equivalent run
nix build .#default                                        # produce the byte-compiled package
```

Fall back to plain `emacs` only when Nix isn't installed — the test helper handles that case by installing deps into `test/.elpa/`.

## Module map

| File | Responsibility |
|---|---|
| `org-mode-google-tasks-sync.el` | Entry point. Autoloads, `defcustom`s, public interactive commands, global minor mode. Has no logic of its own beyond timer/hook plumbing. |
| `org-mode-google-tasks-sync-oauth.el` | Reads/writes `client_id`, `client_secret`, `refresh_token` via `auth-source`. Loopback HTTP server (`make-network-process` with `:host 'local :service t`). Token refresh via the Google token endpoint. |
| `org-mode-google-tasks-sync-api.el` | `plz`-based wrappers for the Tasks API endpoints: `tasks.tasklists.list`, `tasks.tasks.list/get/insert/patch/delete`. Pagination via `nextPageToken`. JSON via native `json-parse-string` / `json-serialize`. |
| `org-mode-google-tasks-sync-org.el` | Reads/writes a Google Task as an org heading. Defines the `org-mode-google-tasks-sync-org-task` struct. Computes the canonical content hash. Pure functions over the buffer at point. No network. |
| `org-mode-google-tasks-sync-engine.el` | Reconciliation.  The 4-cell conflict matrix.  Quarantine buffer.  Log buffer.  State machine (`idle → fetching → applying → pushing → done`).  Post-apply children sort by `:GTASK_POSITION:` / `:GTASK_COMPLETED:` (TODOs by position asc, DONEs by completed desc). |

The entry-point file also hosts buffer-local view/edit features: the
`hide-done-mode` minor mode (invisibility overlays keyed by
`org-mode-google-tasks-sync--hide-done-spec`, hooked to
`org-after-todo-state-change-hook`), the `delete-at-point` /
`show-trash` / `restore-at-point` trio that goes through the trash
buffer (`*org-mode-google-tasks-sync-trash*`, optionally persisted to
`$XDG_DATA_HOME/org-mode-google-tasks-sync/trash.org`), and the
`new-task` convenience prompt.  These call into the engine and API
client but don't change the state machine.

`test/` contains `ert` suites and a `test-helper.el` that installs `plz` + `oauth2` into a project-local `.elpa` so the user's `~/.emacs.d` is never touched.

## Key invariants

These hold throughout the codebase. Violating them produces silent data loss or sync loops, so flag any change that touches them.

1. **The server's `updated` field is authoritative** for "did remote change?" — never compare local wall-clock time to server time. Local clock is only used for the loser-tiebreak in a both-sides-changed conflict.
2. **The canonical content hash includes title, notes, status, due — and nothing else.** Not the GTASK_ID, etag, updated, hash itself, list-id, priority cookie, **position, completed timestamp, links, or webViewLink**.  Position, completed, links, and webViewLink are display metadata; including them would cause Google-side reordering or completion-time bumps to surface as spurious "local changed" detections.  Adding fields to the hash is a breaking change for users with existing data (their stored hashes will mismatch and trigger spurious pushes).
3. **Property drawer values are read by `org-entry-get`, written by `org-entry-put`.** Never `re-search-forward` for `:GTASK_ID:` — that breaks if anyone reformats the drawer.
4. **All HTTP goes through `plz` with `:then`/`:else` callbacks.** Never `accept-process-output` to "wait" — that blocks the UI on the timer tick.
5. **`org-mode-google-tasks-sync-engine--state` must be `'idle` before a tick starts work.** Re-entrant ticks are no-ops; a sync in flight must complete (success or failure) before another can begin.
6. **Priority cookies (`[#A]`/`[#B]`/`[#C]`) are stripped from titles on push and preserved on pull.** `org-mode-google-tasks-sync-org--replace-title` rewrites only the title portion of a headline, keeping the TODO keyword and any priority prefix.
7. **Only direct children of the configured parent heading are synced.** `collect-tasks-under` enforces this. Grandchildren and beyond stay local-only.
8. **Secrets never get written directly to `~/.authinfo.gpg`.** Always go through `auth-source-search :create t` and call the returned `:save-function`. Bypassing this breaks the macOS Keychain / pass backends.

## The 4-cell conflict matrix (the heart of the engine)

Per task, compute:

```
local-changed?  = (canonical-hash(local-task) ≠ stored :GTASK_CONTENT_HASH:)
remote-changed? = (response.updated         ≠ stored :GTASK_UPDATED:)
```

| local-changed? | remote-changed? | Decision |
|---|---|---|
| no | no | `skip` |
| yes | no | `push` |
| no | yes | `pull` |
| yes | yes | `conflict-remote-wins` if `remote.updated > local-mtime`, else `conflict-local-wins`; copy losing side to `*Google Tasks Conflicts*` |

Pure function: `org-mode-google-tasks-sync-engine--decide`. Don't make this stateful — it's fully covered by `ert` and reasoning about it depends on functional purity.

## State machine

```
              .--- on `--sync-next` reaches end ---.
              v                                    |
  +---------+      +----------+      +-----------+ |
  |  idle   |----->| fetching |----->| applying  |-+
  +---------+      +----------+      +-----------+
       ^                                  |
       |                                  v
       +------ on error ------ +----------+
                               | pushing  |
                               +----------+
```

`fetching` is per-list (async `plz`); `applying` is buffer-local reconciliation; `pushing` happens inline within `--reconcile-one` and `--apply` (fire-and-forget with logging). Re-entrant ticks are dropped while state ≠ idle.

## Running tests

**If Nix is available** (check with `command -v nix`), prefer the dev shell for any Emacs invocation — tests, byte-compile, interactive REPL, anything. The dev shell provides Emacs with `plz` and `oauth2` already on the load-path, so nothing gets installed into the user's environment and nothing gets written to `test/.elpa/`.

```sh
nix develop --command emacs --batch -l test/run-tests.el -f ert-run-tests-batch-and-exit
```

For a fully sandboxed run (slower; builds a fresh derivation each time):

```sh
nix flake check
```

**If Nix is not available**, fall back to plain Emacs:

```sh
emacs --batch -l test/run-tests.el -f ert-run-tests-batch-and-exit
```

On first plain-Emacs run this installs `plz` and `oauth2` into `test/.elpa/`; subsequent runs are fast. `test-helper.el` detects the situation automatically — if the deps are already on the load-path (as inside `nix develop`), it skips the install.

Test files:
- `test/org-mode-google-tasks-sync-org-test.el` — parser, hash stability, round-trip serialization.
- `test/org-mode-google-tasks-sync-engine-test.el` — 4-cell conflict matrix, RFC3339 parsing, remote↔struct conversion, API payload shape.

There are intentionally no tests that hit the real Google API — those would be flaky and require credentials. Integration testing is manual; see the README troubleshooting section and the verification plan in the original design doc at `~/.claude/plans/i-need-tooling-to-dapper-moonbeam.md`.

## Linting and formatting

All Emacs Lisp source files must pass **byte-compile** (zero warnings) and **checkdoc** (zero warnings) checks. A combined lint script is at `hooks/lint.el`:

```sh
nix develop --command emacs --batch -L . -l hooks/lint.el -f org-mode-google-tasks-sync-lint
```

Without Nix:

```sh
emacs --batch -L . -l hooks/lint.el -f org-mode-google-tasks-sync-lint
```

Exits non-zero if any warning is found. The script lints the five package source files (not test files).

### Git hooks (via git-hooks.nix)

Pre-commit and commit-msg hooks are managed by [git-hooks.nix](https://github.com/cachix/git-hooks.nix). Entering the dev shell auto-installs them — no manual `cp` to `.git/hooks/` needed:

```sh
nix develop   # hooks are installed automatically
```

Hooks configured (see `flake.nix`):
- **convco** (commit-msg) — enforces Conventional Commits.
- **emacs-lint-checks** (pre-commit) — runs `hooks/lint.el` + the full ert test suite when `.el` files are staged.
- **nixfmt-classic** (pre-commit) — formats `.nix` files.

Run all hooks manually: `nix develop -c pre-commit run --all-files`

Bypass with `git commit --no-verify`.

### Docstring conventions

checkdoc enforces standard Emacs Lisp docstring conventions. Key rules:
- **Argument names in UPPERCASE** in docstrings (`TOKEN`, not `token`; `LIST-ID`, not `list-id`).
- **Lisp symbols in backquotes** (`` `float-time' ``, not bare `float-time`).
- **First line is a complete sentence** ending with a period.
- **Imperative mood** ("Return", not "Returns").
- **Lines under 80 characters** (byte-compile enforces this).
- **No unescaped single quotes** — use `` `symbol' `` or `\='symbol\='`.

## Conventions

- **No exceptions across module boundaries.** Each public function either returns a value or invokes a callback. Errors from `plz` go through the `:else` callback.
- **Property keys are uppercase with `GTASK_` prefix** (`GTASK_ID`, `GTASK_UPDATED`, `GTASK_ETAG`, `GTASK_CONTENT_HASH`, `GTASK_LIST`, `GTASK_POSITION`, `GTASK_COMPLETED`, `GTASK_LINKS`, `GTASK_WEB_LINK`).  Defined as `defconst`s at the top of `org-mode-google-tasks-sync-org.el`.  Only the first five are sync-state; `GTASK_POSITION` and `GTASK_COMPLETED` are display metadata used by the children sort step in `--apply`; `GTASK_LINKS` and `GTASK_WEB_LINK` are read-only display metadata populated by Google (Gmail/Keep/Chat/Docs) — never in the hash, never in the push payload.
- **Auth-source `login` discriminators are full prefix** (`org-mode-google-tasks-sync-client-id`, etc.) so multiple Google-API-using packages can coexist in the same `~/.authinfo.gpg`.
- **Modules talk through value types, not buffer state.** The engine never reads other modules' internal state directly; it calls accessor functions. The struct `org-mode-google-tasks-sync-org-task` is the contract between `*-org.el` and `*-engine.el`.
- **Log liberally to the action log.** Every push, pull, delete, conflict, and error gets a line in `*org-mode-google-tasks-sync-log*`. Users debug from there.
- **No `accept-process-output` in tick path.** `plz` callbacks only. The one exception is `oauth-make-token`, where a synchronous refresh is acceptable because it's outside the tick and rare.

## How to add a new synced field end-to-end

Example: suppose Google adds a `priority` field to the Tasks API. To wire it in:

1. **Struct**: add a slot to `org-mode-google-tasks-sync-org-task` (`cl-defstruct` in `org-mode-google-tasks-sync-org.el`).
2. **Read from org**: extend `org-mode-google-tasks-sync-org-read-task-at-point` to populate the new slot from the heading.
3. **Write to org**: extend `org-mode-google-tasks-sync-org-write-task` to render the new slot into the heading.
4. **Canonical hash**: add the new value to the projection in `org-mode-google-tasks-sync-org-canonical-hash` (this changes the hash for existing data — bump a version constant if you want to handle migration gracefully).
5. **Remote → struct**: extend `org-mode-google-tasks-sync-engine--remote-task->struct` to read the field from the API response.
6. **Struct → API payload**: extend `org-mode-google-tasks-sync-engine--task->api-data` to emit the field on push.
7. **Tests**: add `ert` cases in both `org-test.el` (parser round-trip, hash sensitivity) and `engine-test.el` (struct conversion, API payload).
8. **Schema mapping table**: update README.md's "What is and isn't synced" table.

## What NOT to do

- **Don't add an external database.** State lives in the org file and `~/.authinfo.gpg`; if you find yourself wanting a sqlite, you've taken a wrong turn.
- **Don't add a confirmation prompt for deletes.** The user explicitly chose auto-delete with logging.
- **Don't introduce a new HTTP library.** `plz` is the choice.
- **Don't sync more than one level of subtask nesting.** Google Tasks doesn't support it; emitting deeper nesting silently is misleading.
- **Don't try to sync `position`.** v2 work; needs `tasks.move` calls and a tiebreak rule for ordering conflicts. Not in v1 scope.
- **Don't add a verification flow for Google's "unverified app" warning.** Personal-use apps stay unverified by design.
- **Don't read from `~/.authinfo.gpg` directly.** Always via `auth-source-search`.
