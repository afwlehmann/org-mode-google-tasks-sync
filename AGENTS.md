# AGENTS.md — orientation for AI assistants and contributors

This file gives an AI agent (or new human contributor) what they need to make safe, idiomatic changes to this package without re-deriving the architecture. End-user docs are in `README.md`.

## At a glance

Pure-Elisp two-way sync between org-mode and Google Tasks. Triggered by an Emacs timer + `after-save-hook`. Last-write-wins with conflict quarantine. Auto-delete in both directions. Single Google account, single subtree per list, no `position` sync in v1.

## Module map

| File | Responsibility |
|---|---|
| `org-mode-google-tasks.el` | Entry point. Autoloads, `defcustom`s, public interactive commands, global minor mode. Has no logic of its own beyond timer/hook plumbing. |
| `org-mode-google-tasks-oauth.el` | Reads/writes `client_id`, `client_secret`, `refresh_token` via `auth-source`. Loopback HTTP server (`make-network-process` with `:host 'local :service t`). Token refresh via the Google token endpoint. |
| `org-mode-google-tasks-api.el` | `plz`-based wrappers for the Tasks API endpoints: `tasks.tasklists.list`, `tasks.tasks.list/get/insert/patch/delete`. Pagination via `nextPageToken`. JSON via native `json-parse-string` / `json-serialize`. |
| `org-mode-google-tasks-org.el` | Reads/writes a Google Task as an org heading. Defines the `org-mode-google-tasks-org-task` struct. Computes the canonical content hash. Pure functions over the buffer at point. No network. |
| `org-mode-google-tasks-engine.el` | Reconciliation. The 4-cell conflict matrix. Quarantine buffer. Log buffer. State machine (`idle → fetching → applying → pushing → done`). |

`test/` contains `ert` suites and a `test-helper.el` that installs `plz` + `oauth2` into a project-local `.elpa` so the user's `~/.emacs.d` is never touched.

## Key invariants

These hold throughout the codebase. Violating them produces silent data loss or sync loops, so flag any change that touches them.

1. **The server's `updated` field is authoritative** for "did remote change?" — never compare local wall-clock time to server time. Local clock is only used for the loser-tiebreak in a both-sides-changed conflict.
2. **The canonical content hash includes title, notes, status, due — and nothing else.** Not the GTASK_ID, etag, updated, hash itself, list-id, or priority cookie. Adding fields to the hash is a breaking change for users with existing data (their stored hashes will mismatch and trigger spurious pushes).
3. **Property drawer values are read by `org-entry-get`, written by `org-entry-put`.** Never `re-search-forward` for `:GTASK_ID:` — that breaks if anyone reformats the drawer.
4. **All HTTP goes through `plz` with `:then`/`:else` callbacks.** Never `accept-process-output` to "wait" — that blocks the UI on the timer tick.
5. **`org-mode-google-tasks-engine--state` must be `'idle` before a tick starts work.** Re-entrant ticks are no-ops; a sync in flight must complete (success or failure) before another can begin.
6. **Priority cookies (`[#A]`/`[#B]`/`[#C]`) are stripped from titles on push and preserved on pull.** `org-mode-google-tasks-org--replace-title` rewrites only the title portion of a headline, keeping the TODO keyword and any priority prefix.
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

Pure function: `org-mode-google-tasks-engine--decide`. Don't make this stateful — it's fully covered by `ert` and reasoning about it depends on functional purity.

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

```sh
emacs --batch -l test/run-tests.el -f ert-run-tests-batch-and-exit
```

On first run this installs `plz` and `oauth2` into `test/.elpa/`. Subsequent runs are fast.

Test files:
- `test/org-mode-google-tasks-org-test.el` — parser, hash stability, round-trip serialization.
- `test/org-mode-google-tasks-engine-test.el` — 4-cell conflict matrix, RFC3339 parsing, remote↔struct conversion, API payload shape.

There are intentionally no tests that hit the real Google API — those would be flaky and require credentials. Integration testing is manual; see the README troubleshooting section and the verification plan in the original design doc at `~/.claude/plans/i-need-tooling-to-dapper-moonbeam.md`.

## Conventions

- **No exceptions across module boundaries.** Each public function either returns a value or invokes a callback. Errors from `plz` go through the `:else` callback.
- **Property keys are uppercase with `GTASK_` prefix** (`GTASK_ID`, `GTASK_UPDATED`, `GTASK_ETAG`, `GTASK_CONTENT_HASH`, `GTASK_LIST`). Defined as `defconst`s at the top of `org-mode-google-tasks-org.el`.
- **Auth-source `login` discriminators are full prefix** (`org-mode-google-tasks-client-id`, etc.) so multiple Google-API-using packages can coexist in the same `~/.authinfo.gpg`.
- **Modules talk through value types, not buffer state.** The engine never reads other modules' internal state directly; it calls accessor functions. The struct `org-mode-google-tasks-org-task` is the contract between `*-org.el` and `*-engine.el`.
- **Log liberally to the action log.** Every push, pull, delete, conflict, and error gets a line in `*org-mode-google-tasks-log*`. Users debug from there.
- **No `accept-process-output` in tick path.** `plz` callbacks only. The one exception is `oauth-make-token`, where a synchronous refresh is acceptable because it's outside the tick and rare.

## How to add a new synced field end-to-end

Example: suppose Google adds a `priority` field to the Tasks API. To wire it in:

1. **Struct**: add a slot to `org-mode-google-tasks-org-task` (`cl-defstruct` in `org-mode-google-tasks-org.el`).
2. **Read from org**: extend `org-mode-google-tasks-org-read-task-at-point` to populate the new slot from the heading.
3. **Write to org**: extend `org-mode-google-tasks-org-write-task` to render the new slot into the heading.
4. **Canonical hash**: add the new value to the projection in `org-mode-google-tasks-org-canonical-hash` (this changes the hash for existing data — bump a version constant if you want to handle migration gracefully).
5. **Remote → struct**: extend `org-mode-google-tasks-engine--remote-task->struct` to read the field from the API response.
6. **Struct → API payload**: extend `org-mode-google-tasks-engine--task->api-data` to emit the field on push.
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
