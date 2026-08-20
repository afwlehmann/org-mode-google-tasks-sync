;;; org-mode-google-tasks-sync-engine.el --- Sync state machine -*- lexical-binding: t -*-

;; Copyright (C) 2026 Alexander Lehmann
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The reconciliation engine.  Runs the 4-cell conflict matrix per task
;; (local-changed? × remote-changed?), quarantines losers, applies deletions
;; in both directions, and logs every action to the log buffer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'parse-time)
(require 'org-mode-google-tasks-sync-api)
(require 'org-mode-google-tasks-sync-org)
(require 'org-mode-google-tasks-sync-oauth)

(declare-function org-save-outline-visibility "org-macs" (use-markers &rest body))

(defvar org-mode-google-tasks-sync-map nil
  "Alist mapping Google Tasks list IDs to org file + parent heading.
Defined in `org-mode-google-tasks-sync.el'; declared here so the
engine can reference it without a circular require.")

(defvar org-mode-google-tasks-sync-log-level nil
  "Log verbosity for the sync engine.
Defined in `org-mode-google-tasks-sync.el'; declared here so the
engine can reference it without a circular require.")

(defvar org-mode-google-tasks-sync-keep-done-items nil
  "Whether to keep DONE tasks in the local buffer.
Defined in `org-mode-google-tasks-sync.el'; declared here so the
engine can reference it without a circular require.")

(defconst org-mode-google-tasks-sync-engine--log-buffer-name
  "*org-mode-google-tasks-sync-log*")

(defconst org-mode-google-tasks-sync-engine--conflicts-buffer-name
  "*Google Tasks Conflicts*")

(defcustom org-mode-google-tasks-sync-fetch-timeout 300
  "Seconds after which a sync item is considered hung.
When this many seconds pass between an item starting and finishing,
the worker forcibly drops it so the next item can run.  Bump this if
you have many lists or a slow network and healthy syncs are being
treated as hung."
  :type 'integer
  :group 'org-mode-google-tasks-sync)

(defcustom org-mode-google-tasks-sync-action-timeout 30
  "Seconds after which a `move' or `delete' item is considered hung.
Shorter than `org-mode-google-tasks-sync-fetch-timeout' because
interactive actions should feel snappy; a stalled move/delete is
almost certainly a network problem, not a large workload."
  :type 'integer
  :group 'org-mode-google-tasks-sync)

(defcustom org-mode-google-tasks-sync-sort-time-budget 5
  "Wall-clock budget in seconds for the post-apply children sort.
The sort path is synchronous CPU-bound work and historically hung
Emacs at the \"Sorting entries...\" message when a cycle formed.
When the budget is exceeded the sort is aborted: a `display-warning'
*error* is raised with diagnostic context, the remaining sorts are
skipped, but the sync item still stamps, saves, and completes so the
worker advances instead of parking forever.  Bump this if you have a
genuinely large list (thousands of tasks) and the tripwire fires on
healthy sorts."
  :type 'integer
  :group 'org-mode-google-tasks-sync)

(defvar org-mode-google-tasks-sync-engine--state 'idle
  "Derived view of the worker state, kept for log/test compatibility.
One of `idle', `fetching', `applying'.  The action queue
\(`--queue' / `--running') is the source of truth; this variable
mirrors it so existing tests and log lines keep working.  `idle'
means no item is running and the queue is empty.")

(defvar org-mode-google-tasks-sync-engine--timeout-timer nil
  "Timer that drops the running item if it hangs past its budget.")

(defvar org-mode-google-tasks-sync-engine--last-sync-time nil
  "`float-time' of the last sync that reached `idle' again.
The tick predicate compares each target file's mtime against this; a
freshly-saved file by the engine itself doesn't re-trigger the next
tick because we bump this both when entering `fetching' and when
returning to `idle'.")

(defvar org-mode-google-tasks-sync-engine--inhibit-save-hooks nil
  "Bound to non-nil while the engine writes to a synced file.
The entry-point's `after-save-hook' checks this and skips its work
when set, so the engine's own buffer save doesn't kick off another
sync in 1 second (which would itself save, which would trigger
the hook again — a 1-Hz loop).")

(defvar org-mode-google-tasks-sync-engine--queue nil
  "Pending action items, priority-ordered FIFO within a class.
Each item is a list: (TYPE KEY PAYLOAD HANDLER STARTED-AT).  TYPE is
one of `move', `delete', `incremental-sync', `full-sync'.  KEY is
the dedup key (task-id for `move'/`delete', the symbol otherwise).
HANDLER is a function of one arg DONE-CALLBACK.  STARTED-AT is set
when the worker picks the item up, nil while queued.")

(defvar org-mode-google-tasks-sync-engine--running nil
  "The item currently being processed by the worker, or nil.
An empty `--queue' plus this being nil means the worker is idle.")

(defvar org-mode-google-tasks-sync-engine--worker-scheduled nil
  "Non-nil while a `worker-step' is pending via `run-at-time'.
Prevents double-scheduling when several items enqueue in the same
event-loop tick.")

(defvar org-mode-google-tasks-sync-engine--sort-needed nil
  "Alist (LIST-ID . t) of lists whose next sync tail must sort.
Set by the four position-writing producers (pull write,
`--finalize-push-new', `--write-move-result', drift/tie callbacks)
during a pass so `--finalize-apply' can skip the sort on no-op ticks.
Cleared at the start of each sync item for the lists it owns.")

(defvar org-mode-google-tasks-sync-engine--pass-count 0
  "Monotonic counter of sync passes started this session.
Used by the sort tripwire's diagnostic dump to indicate whether
sorts fire every pass (a convergence-failure smell).")

(put 'org-mode-google-tasks-sync-engine--queue 'safe-local-variable t)

(define-error 'org-mode-google-tasks-sync-sort-timeout
  "Sort exceeded `org-mode-google-tasks-sync-sort-time-budget'.
Raised inside `--with-sort-budget' to abort a hanging children sort
without wedging the worker.  Caught by `--finalize-apply' which logs
and skips the remaining sorts.")

(defun org-mode-google-tasks-sync-engine-log-buffer ()
  "Return (creating if needed) the log buffer."
  (get-buffer-create org-mode-google-tasks-sync-engine--log-buffer-name))

(defun org-mode-google-tasks-sync-engine-conflicts-buffer ()
  "Return (creating if needed) the conflict quarantine buffer."
  (let ((buf (get-buffer-create org-mode-google-tasks-sync-engine--conflicts-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'org-mode)
        (org-mode)))
    buf))

(defun org-mode-google-tasks-sync-engine--log (fmt &rest args)
  "Append a timestamped line to the log buffer.
FMT is a `format' spec string; ARGS are its arguments."
  (with-current-buffer (org-mode-google-tasks-sync-engine-log-buffer)
    (goto-char (point-max))
    (insert (format-time-string "[%Y-%m-%d %H:%M:%S] ")
            (apply #'format fmt args)
            "\n")))

(defun org-mode-google-tasks-sync-engine--log-debug (fmt &rest args)
  "Like `--log', but only emits at debug log-level.
FMT is a `format' spec string; ARGS are its arguments.
Use for per-request diagnostics (body length/bytes, encoding flags)
that would be too noisy at the default `info' level."
  (when (eq (bound-and-true-p org-mode-google-tasks-sync-log-level) 'debug)
    (apply #'org-mode-google-tasks-sync-engine--log fmt args)))

(defun org-mode-google-tasks-sync-engine--remote-task->struct (remote list-id existing-marker)
  "Build a task struct from a REMOTE alist in LIST-ID.
Carries EXISTING-MARKER if known.  Trailing `@' hashtags in the
remote `title' are decoded into the struct's `tags' slot and stripped
from the title — see `org-mode-google-tasks-sync-org-title-decode-tags'."
  (let* ((links-raw (alist-get 'links remote))
         (links-json (when links-raw
                       (json-serialize links-raw
                                       :null-object nil
                                       :false-object :false)))
         (decoded (org-mode-google-tasks-sync-org-title-decode-tags
                   (or (alist-get 'title remote) ""))))
    (make-org-mode-google-tasks-sync-org-task
     :id        (alist-get 'id remote)
     :list-id   list-id
     :title     (car decoded)
     :notes     (or (alist-get 'notes remote) "")
     :status    (if (equal (alist-get 'status remote) "completed")
                    'completed 'needsAction)
     :due       (org-mode-google-tasks-sync-engine--remote-due remote)
     :parent-id (alist-get 'parent remote)
     :updated   (alist-get 'updated remote)
     :etag      (alist-get 'etag remote)
     :hash      nil
     :position  (alist-get 'position remote)
     :completed (alist-get 'completed remote)
     :links     links-json
     :web-view-link (alist-get 'webViewLink remote)
     :tags      (cdr decoded)
     :marker    existing-marker)))

(defun org-mode-google-tasks-sync-engine--remote-due (remote)
  "Extract YYYY-MM-DD from the REMOTE task's `due' RFC3339 string."
  (let ((due (alist-get 'due remote)))
    (when (and due (>= (length due) 10))
      (substring due 0 10))))

(defun org-mode-google-tasks-sync-engine--task->api-data (task)
  "Convert a TASK struct to the alist payload for the Tasks API.
TASK's tags are encoded into the pushed `title' as trailing `@' hashtags
\(sorted, whitespace-free tags only); on pull the hashes are stripped
and turned back into org tags.  Users of the Google Tasks web UI see
the hashtags at the end of the title."
  (let ((data `((title . ,(org-mode-google-tasks-sync-org-title-encode-tags
                           (org-mode-google-tasks-sync-org-task-title task)
                           (org-mode-google-tasks-sync-org-task-tags task)))
                (notes . ,(or (org-mode-google-tasks-sync-org-task-notes task) ""))
                (status . ,(symbol-name
                            (or (org-mode-google-tasks-sync-org-task-status task)
                                'needsAction))))))
    (when (org-mode-google-tasks-sync-org-task-due task)
      (push (cons 'due (concat (org-mode-google-tasks-sync-org-task-due task)
                               "T00:00:00.000Z"))
            data))
    data))

(defun org-mode-google-tasks-sync-engine--keep-done-p ()
  "Return non-nil when DONE tasks should be kept in both buffers.
Reads `org-mode-google-tasks-sync-keep-done-items' (defined in the
entry-point file).  Returns nil when the variable is unbound so
`--decide' stays pure and testable in isolation."
  (and (boundp 'org-mode-google-tasks-sync-keep-done-items)
       org-mode-google-tasks-sync-keep-done-items))

(defun org-mode-google-tasks-sync-engine--remote-completed-p (remote)
  "Return non-nil if REMOTE alist indicates the task is completed."
  (equal (alist-get 'status remote) "completed"))

(defun org-mode-google-tasks-sync-engine--local-completed-p (local)
  "Return non-nil if LOCAL struct indicates the task is completed."
  (eq (org-mode-google-tasks-sync-org-task-status local) 'completed))

(defun org-mode-google-tasks-sync-engine--decide
    (local-changed remote-changed local-mtime remote-updated
     &optional local-status remote-status)
  "Return the sync decision for one task.
One of: skip, push, pull, conflict-local-wins,
conflict-remote-wins, done-remove-local, done-push-then-remove.
LOCAL-CHANGED and REMOTE-CHANGED are booleans.  LOCAL-MTIME is
`float-time'; REMOTE-UPDATED is an RFC3339 string.  Optional
LOCAL-STATUS and REMOTE-STATUS are the task status symbols and
are only consulted when `org-mode-google-tasks-sync-keep-done-items'
is nil — the DONE fast paths run before the 4-cell conflict matrix
so remote-completed always wins (with local quarantine if the
local side had pending edits)."
  (cond
   ((and (not (org-mode-google-tasks-sync-engine--keep-done-p))
         (eq remote-status 'completed))
    'done-remove-local)
   ((and (not (org-mode-google-tasks-sync-engine--keep-done-p))
         (eq local-status 'completed))
    'done-push-then-remove)
   ((and (not local-changed) (not remote-changed)) 'skip)
   ((and local-changed (not remote-changed)) 'push)
   ((and (not local-changed) remote-changed) 'pull)
   (t (if (org-mode-google-tasks-sync-engine--remote-newer-p local-mtime remote-updated)
          'conflict-remote-wins
        'conflict-local-wins))))

(defun org-mode-google-tasks-sync-engine--remote-newer-p (local-mtime remote-updated)
  "Return non-nil if REMOTE-UPDATED is after LOCAL-MTIME.
LOCAL-MTIME is `float-time'; REMOTE-UPDATED is an RFC3339 string."
  (let ((remote-ft (org-mode-google-tasks-sync-engine--rfc3339-to-float remote-updated)))
    (and remote-ft (> remote-ft (or local-mtime 0)))))

(defun org-mode-google-tasks-sync-engine--rfc3339-to-float (s)
  "Convert RFC3339 string S to `float-time', or nil."
  (when (and s (stringp s))
    (condition-case nil
        (float-time (parse-iso8601-time-string s))
      (error nil))))

(defun org-mode-google-tasks-sync-engine--quarantine (label task)
  "Append a snapshot of TASK (with LABEL) to the conflict buffer."
  (with-current-buffer (org-mode-google-tasks-sync-engine-conflicts-buffer)
    (goto-char (point-max))
    (insert (format "* CONFLICT %s — %s\n  :PROPERTIES:\n  :SAVED_AT: %s\n  :GTASK_ID: %s\n  :END:\n%s\n"
                    label
                    (or (org-mode-google-tasks-sync-org-task-title task) "")
                    (format-time-string "%Y-%m-%dT%H:%M:%S")
                    (or (org-mode-google-tasks-sync-org-task-id task) "<unsynced>")
                    (or (org-mode-google-tasks-sync-org-task-notes task) "")))))

(defvar org-mode-google-tasks-sync-engine--token nil
  "Cached API token for the current Emacs session.")

(defun org-mode-google-tasks-sync-engine--token ()
  "Return a non-expired API token, refreshing when necessary.
The cached token's `expires-at' (set 60s before the real expiry by
`oauth--refresh-access-token') is checked on every call; a token
past its expiry is replaced by a fresh one from auth-source."
  (let ((cached org-mode-google-tasks-sync-engine--token))
    (when (and cached
               (let ((exp (org-mode-google-tasks-sync-api-token-expires-at cached)))
                 (or (null exp) (<= exp (float-time)))))
      (setq org-mode-google-tasks-sync-engine--token nil)
      (setq cached nil))
    (or cached
        (setq org-mode-google-tasks-sync-engine--token
              (org-mode-google-tasks-sync-oauth-make-token)))))

(defun org-mode-google-tasks-sync-engine-run (mode)
  "Enqueue a sync pass.  MODE is `incremental' or `full'.
The pass runs on the action queue once the worker drains any
higher-priority (interactive) items ahead of it.  Returns
immediately; coalesces with an already-pending or running sync of
the same MODE so repeated ticks/after-save triggers don't pile up."
  (unless (bound-and-true-p org-mode-google-tasks-sync-map)
    (org-mode-google-tasks-sync-engine--log
     "No lists configured (org-mode-google-tasks-sync-map empty)")
    (cl-return-from org-mode-google-tasks-sync-engine-run))
  (let ((type (if (eq mode 'full) 'full-sync 'incremental-sync)))
    (org-mode-google-tasks-sync-engine--enqueue
     type type
     (lambda (done)
       (org-mode-google-tasks-sync-engine--run-sync-pass mode done))
     (if (eq type 'full-sync)
         org-mode-google-tasks-sync-fetch-timeout
       org-mode-google-tasks-sync-fetch-timeout))))

(defun org-mode-google-tasks-sync-engine--run-sync-pass (mode done)
  "Run one sync pass of MODE, calling DONE when the pass finishes.
Fetches the token before transitioning to `fetching' so a token
error (e.g. EasyPG can't find gpg) doesn't leave the worker stuck;
instead the item completes with state left at `idle'."
  (condition-case err
      (let ((token (org-mode-google-tasks-sync-engine--token)))
        (setq org-mode-google-tasks-sync-engine--state 'fetching)
        (setq org-mode-google-tasks-sync-engine--last-sync-time (float-time))
        (setq org-mode-google-tasks-sync-engine--pass-count
              (1+ org-mode-google-tasks-sync-engine--pass-count))
        (org-mode-google-tasks-sync-engine--log-debug
         "PASS #%d begin (%s) for %d lists"
         org-mode-google-tasks-sync-engine--pass-count
         mode (length org-mode-google-tasks-sync-map))
        ;; Reset the sort-needed flags for the lists this pass owns so
        ;; the gating decision reflects this pass's writes, not a
        ;; previous pass's leftovers.
        (dolist (entry org-mode-google-tasks-sync-map)
          (org-mode-google-tasks-sync-engine--sort-needed-clear (car entry)))
        (org-mode-google-tasks-sync-engine--sync-next
         org-mode-google-tasks-sync-map token mode done))
    (error
     (org-mode-google-tasks-sync-engine--log
      "Sync pass failed before fetch: %S" err)
     (setq org-mode-google-tasks-sync-engine--state 'idle)
     (funcall done))))

(defun org-mode-google-tasks-sync-engine--arm-timeout (budget)
  "Arm the hung-item timeout to fire after BUDGET seconds."
  (when org-mode-google-tasks-sync-engine--timeout-timer
    (cancel-timer org-mode-google-tasks-sync-engine--timeout-timer))
  (setq org-mode-google-tasks-sync-engine--timeout-timer
        (run-at-time budget nil
                     #'org-mode-google-tasks-sync-engine--on-timeout)))

(defun org-mode-google-tasks-sync-engine--cancel-timeout ()
  "Cancel any in-flight hung-item timer."
  (when org-mode-google-tasks-sync-engine--timeout-timer
    (cancel-timer org-mode-google-tasks-sync-engine--timeout-timer)
    (setq org-mode-google-tasks-sync-engine--timeout-timer nil)))

(defun org-mode-google-tasks-sync-engine--on-timeout ()
  "Called when the running item exceeds its budget.
Drops the item so the worker advances.  Stale plz callbacks may
still fire afterwards; they're effectively no-ops because the
worker has already moved on."
  (setq org-mode-google-tasks-sync-engine--timeout-timer nil)
  (when org-mode-google-tasks-sync-engine--running
    (let* ((item org-mode-google-tasks-sync-engine--running)
           (type (car item))
           (key (cadr item))
           (started (car (cddddr item)))
           (elapsed (if started (- (float-time) started) 0)))
      (org-mode-google-tasks-sync-engine--log
       "TIMEOUT %s (elapsed=%ds, key=%S)"
       (if (memq type '(incremental-sync full-sync)) "sync" type)
       (round elapsed) key)
      ;; Drop the item and step the worker.  Keep `--state' sane for
      ;; a sync item that died mid-pass.
      (when (memq type '(incremental-sync full-sync))
        (setq org-mode-google-tasks-sync-engine--state 'idle))
      (setq org-mode-google-tasks-sync-engine--running nil)
      (org-mode-google-tasks-sync-engine--worker-step))))

(defun org-mode-google-tasks-sync-engine--sync-next (entries token mode done)
  "Drive sync sequentially over ENTRIES using TOKEN in MODE.
Calls DONE when all entries have finished (success or failure)."
  (if (null entries)
      (progn
        (setq org-mode-google-tasks-sync-engine--state 'idle)
        ;; Bump last-sync-time AFTER all per-list saves so the tick
        ;; predicate sees mtime <= last-sync-time on the next round
        ;; and doesn't re-fire on our own writes.
        (setq org-mode-google-tasks-sync-engine--last-sync-time (float-time))
        (funcall done))
    (let* ((entry (car entries))
           (list-id (car entry))
           (file (car (cdr entry)))
           (parent (cdr (cdr entry))))
      (org-mode-google-tasks-sync-engine--sync-one
       token list-id file parent mode
       (lambda () (org-mode-google-tasks-sync-engine--sync-next
              (cdr entries) token mode done))))))

(defun org-mode-google-tasks-sync-engine--sync-one (token list-id file parent mode done)
  "Sync one list end-to-end using TOKEN in LIST-ID from FILE.
PARENT is the heading under which tasks live.
MODE is `incremental' or `full'.  Calls DONE when finished."
  (let* ((parent-exists-p
          (with-current-buffer (find-file-noselect file)
            (save-excursion
              (goto-char (point-min))
              (re-search-forward
               (format "^\\*+ %s$" (regexp-quote parent)) nil t))))
         ;; Drop `updatedMin' when the parent heading is missing.  If a prior
         ;; sync wrote `#+GTASKS_LAST_SYNC' to the file but had nowhere to
         ;; insert the pulled tasks (e.g. parent absent), that stale timestamp
         ;; would otherwise make every subsequent incremental sync ask Google
         ;; for "changes since then" and get nothing — exactly the case where
         ;; the user sees a populated keyword but no tasks.  Treating the
         ;; "no parent" branch as a full sync recovers automatically.
         (args (if (or (eq mode 'full) (not parent-exists-p))
                   '()
                 (let ((since (org-mode-google-tasks-sync-engine--last-sync file)))
                   (when since `(("updatedMin" . ,since)))))))
    (org-mode-google-tasks-sync-api-list-tasks
     token list-id args
      (lambda (remote-tasks)
        (condition-case err
            (org-mode-google-tasks-sync-engine--apply
             token list-id file parent mode remote-tasks done)
          (error
           (org-mode-google-tasks-sync-engine--log
            "Apply failed for list %s: %S" list-id err)
           (funcall done))))
      (lambda (err)
        (org-mode-google-tasks-sync-engine--log "Fetch error for list %s: %S" list-id err)
        (funcall done)))))

;;; -- action queue & worker ---------------------------------------------------
;;
;; A single main-thread worker processes one action at a time: an
;; interactive `move'/`delete' or a background `incremental-sync'/
;; `full-sync' pass.  Items are deduplicated by their KEY (task-id for
;; move/delete, the type symbol for syncs), with a newer move of the
;; same task replacing an already-queued one.  The worker is lazily
;; scheduled via `run-at-time 0' on first enqueue and dies when the
;; queue drains; exactly one worker instance exists at any time by
;; construction (Emacs is single-threaded and `--worker-scheduled'
;; guards double-scheduling).
;;
;; This serializes the previously ad-hoc fire-and-forget paths: the
;; post-apply `--sort-children' inside a sync can no longer race with
;; an interactive `tasks.move' advice, because moves run as their own
;; items ahead of (or after) any running sync.  Repeated tick/after-save
;; triggers collapse into one pending sync item rather than being
;; dropped (the old drop-on-busy tick gate) or piling up.

(defconst org-mode-google-tasks-sync-engine--item-priorities
  '((move             . 1)
    (delete           . 1)
    (incremental-sync . 2)
    (full-sync        . 3))
  "Priority class per item TYPE, lower number = higher priority.
Interactive items (move/delete) jump the queue ahead of background
syncs so a user keystroke isn't blocked behind a 300-item full sync.
Priority only orders the pending queue; a running item is never
preempted (it has its own per-item timeout instead).")

(defun org-mode-google-tasks-sync-engine--item-priority (type)
  "Return the priority class number for item TYPE."
  (or (alist-get type org-mode-google-tasks-sync-engine--item-priorities)
      99))

(defun org-mode-google-tasks-sync-engine--enqueue (type key handler &optional timeout)
  "Add an action item (TYPE KEY HANDLER) to the queue, then pump the worker.
KEY is the dedup key.  HANDLER takes one arg, a DONE callback.
TIMEOUT, when given, overrides the type default budget for the
hung-item timer.  Dedup semantics:
- For `move': a queued `move' with the same KEY is replaced by the
  new one (the user kept pressing M-<down>; only the latest target
  matters and params are recomputed at run time anyway).
- For `delete': items with the same KEY are not coalesced (a second
  delete of an already-queued task is dropped as a no-op).
- For sync types: a queued or running item of the same type is
  merged — repeated triggers don't pile up."
  (let ((existing (org-mode-google-tasks-sync-engine--find-item type key)))
    (cond
     ;; Running sync of the same type: merge (the running pass already
     ;; covers whatever the new trigger wants).
     ((and existing (eq existing 'running))
      (org-mode-google-tasks-sync-engine--log-debug
       "MERGED %s key=%S (already running)" type key))
     ;; Queued item with the same key.
     (existing
      (if (eq type 'move)
          (progn
            (org-mode-google-tasks-sync-engine--replace-item type key handler)
            (org-mode-google-tasks-sync-engine--log-debug
             "REPLACE move key=%S (newer request)" key))
        (org-mode-google-tasks-sync-engine--log-debug
         "MERGED %s key=%S (already queued)" type key)))
     (t
      (let ((item (list type key handler timeout nil)))
        (setq org-mode-google-tasks-sync-engine--queue
              (org-mode-google-tasks-sync-engine--insert-ordered item))
        (org-mode-google-tasks-sync-engine--log-debug
         "ENQUEUE %s key=%S (queue-depth=%d)"
         type key (length org-mode-google-tasks-sync-engine--queue)))))
    (org-mode-google-tasks-sync-engine--schedule-worker)))

(defun org-mode-google-tasks-sync-engine--find-item (type key)
  "Return `running' if a matching item of TYPE is running, the queued item, or nil.
A move matches only against other moves; sync types match only
their own type.  KEY is compared with `equal'."
  (let ((running org-mode-google-tasks-sync-engine--running))
    (cond
     ((and running (eq (car running) type)
           (equal (cadr running) key))
      'running)
     (t
      (cl-find-if
       (lambda (item)
         (and (eq (car item) type) (equal (cadr item) key)))
       org-mode-google-tasks-sync-engine--queue)))))

(defun org-mode-google-tasks-sync-engine--replace-item (type key handler)
  "Replace a queued item of TYPE/KEY with HANDLER (used for newer move requests)."
  (setq org-mode-google-tasks-sync-engine--queue
        (cl-mapcar
         (lambda (item)
           (if (and (eq (car item) type) (equal (cadr item) key))
               (list type key handler (cadddr item) nil)
             item))
         org-mode-google-tasks-sync-engine--queue)))

(defun org-mode-google-tasks-sync-engine--insert-ordered (item)
  "Return a new queue with ITEM inserted at its priority slot (FIFO within class).
Lower priority number = higher priority; a higher-priority item jumps
ahead of lower-priority items already queued, but equal-priority
items keep FIFO order (a move enqueued after another move of a
different task runs after it, not before)."
  (let ((p (org-mode-google-tasks-sync-engine--item-priority (car item))))
    (if (or (null org-mode-google-tasks-sync-engine--queue)
            (< p (org-mode-google-tasks-sync-engine--item-priority
                  (caar org-mode-google-tasks-sync-engine--queue))))
        (cons item org-mode-google-tasks-sync-engine--queue)
      ;; Stable insert: keep existing order, append after all
      ;; strictly-higher-priority items already queued (equal priority
      ;; stays FIFO).
      (let ((tail org-mode-google-tasks-sync-engine--queue)
            (acc nil))
        ;; Walk past strictly-higher-priority (lower number) AND
        ;; equal-priority items so equal-priority inserts stay FIFO.
        (while (and tail
                    (<= (org-mode-google-tasks-sync-engine--item-priority (caar tail))
                        p))
          (push (car tail) acc)
          (setq tail (cdr tail)))
        (nconc (nreverse acc) (list item) tail)))))

(defun org-mode-google-tasks-sync-engine--schedule-worker ()
  "Run the worker once on the next event-loop tick when idle."
  (unless (or org-mode-google-tasks-sync-engine--running
              org-mode-google-tasks-sync-engine--worker-scheduled)
    (setq org-mode-google-tasks-sync-engine--worker-scheduled t)
    (run-at-time 0 nil #'org-mode-google-tasks-sync-engine--worker-step)))

(defun org-mode-google-tasks-sync-engine--worker-step ()
  "Pop the next queue item and run it, or go idle when the queue is empty."
  (setq org-mode-google-tasks-sync-engine--worker-scheduled nil)
  (if org-mode-google-tasks-sync-engine--running
      ;; A timeout already advanced the worker; re-scheduling while
      ;; the previous item is still in flight is a no-op.
      nil
    (if (null org-mode-google-tasks-sync-engine--queue)
        (setq org-mode-google-tasks-sync-engine--state 'idle)
      (let ((item (pop org-mode-google-tasks-sync-engine--queue)))
        (setf (nthcdr 4 item) (list (float-time)))
        (setq org-mode-google-tasks-sync-engine--running item)
        (let* ((type (car item))
               (handler (caddr item))
               (timeout (or (cadddr item)
                            (if (memq type '(incremental-sync full-sync))
                                org-mode-google-tasks-sync-fetch-timeout
                              org-mode-google-tasks-sync-action-timeout)))
               (done
                (lambda ()
                  (org-mode-google-tasks-sync-engine--item-done item))))
          (org-mode-google-tasks-sync-engine--log-debug
           "START %s key=%S" type (cadr item))
          (org-mode-google-tasks-sync-engine--arm-timeout timeout)
          (condition-case err
              (funcall handler done)
            (error
             (org-mode-google-tasks-sync-engine--log
              "Item handler threw before completing: %s %S" type err)
             (funcall done))))))))

(defun org-mode-google-tasks-sync-engine--item-done (item)
  "Mark ITEM finished and step the worker to the next pending item."
  (when (eq item org-mode-google-tasks-sync-engine--running)
    (org-mode-google-tasks-sync-engine--log-debug
     "DONE %s key=%S" (car item) (cadr item))
    (setq org-mode-google-tasks-sync-engine--running nil)
    (org-mode-google-tasks-sync-engine--cancel-timeout)
    (when (memq (car item) '(incremental-sync full-sync))
      (setq org-mode-google-tasks-sync-engine--state 'idle))
    (org-mode-google-tasks-sync-engine--worker-step)))

(defun org-mode-google-tasks-sync-engine--queue-reset ()
  "Drop the queue and running item.  Use from test code and `--disable'."
  (setq org-mode-google-tasks-sync-engine--queue nil
        org-mode-google-tasks-sync-engine--running nil
        org-mode-google-tasks-sync-engine--worker-scheduled nil
        org-mode-google-tasks-sync-engine--state 'idle))

(defun org-mode-google-tasks-sync-engine--queue-pending-p (type)
  "Return non-nil if a TYPE item is queued or running."
  (or (and org-mode-google-tasks-sync-engine--running
           (eq (car org-mode-google-tasks-sync-engine--running) type))
      (cl-some (lambda (item) (eq (car item) type))
               org-mode-google-tasks-sync-engine--queue)))

;;; -- sort-needed gating ------------------------------------------------------

(defun org-mode-google-tasks-sync-engine--sort-needed-mark (list-id)
  "Record that LIST-ID's next sync tail must sort.
Called by the position-writing producers (pull write,
`--finalize-push-new', `--write-move-result', drift/tie callbacks)
during a pass so `--finalize-apply' can skip the sort on no-op ticks."
  (when list-id
    (setf (alist-get list-id org-mode-google-tasks-sync-engine--sort-needed)
          t)))

(defun org-mode-google-tasks-sync-engine--sort-needed-p (list-id)
  "Return non-nil when LIST-ID was marked for sorting this pass."
  (and list-id (cdr (assoc list-id org-mode-google-tasks-sync-engine--sort-needed))))

(defun org-mode-google-tasks-sync-engine--sort-needed-clear (list-id)
  "Clear the sort-needed flag for LIST-ID."
  (setq org-mode-google-tasks-sync-engine--sort-needed
        (assoc-delete-all list-id org-mode-google-tasks-sync-engine--sort-needed)))

(defun org-mode-google-tasks-sync-engine--last-sync (file)
  "Read the #+GTASKS_LAST_SYNC keyword from FILE, or nil."
  (when (file-exists-p file)
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "^#\\+GTASKS_LAST_SYNC: \\(.*\\)$" nil t)
          (match-string 1))))))

(defun org-mode-google-tasks-sync-engine--set-last-sync (file ts)
  "Set #+GTASKS_LAST_SYNC to TS in FILE."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char (point-min))
      (if (re-search-forward "^#\\+GTASKS_LAST_SYNC: .*$" nil t)
          (replace-match (concat "#+GTASKS_LAST_SYNC: " ts))
        (insert "#+GTASKS_LAST_SYNC: " ts "\n")))))

(defun org-mode-google-tasks-sync-engine--finalize-apply
    (token list-id parent-marker file drift-pairs done)
  "Resolve reorder drift, repair ties, sort, stamp, save, call DONE.
TOKEN authenticates moves.  LIST-ID is the Google Tasks list.
PARENT-MARKER locates the subtree.  FILE is the org source file.
DRIFT-PAIRS is the list from `--detect-reorder-drift' (snapshot
taken at tick start, before pulls rewrote positions).  DONE is
called when all post-push work is finished.  Reorder drift is
resolved first (pushing the user's manual reorder to the server),
then tie repair, then sort — so the sort converges to the user's
intended order.  The sort/save/stamp tail runs inside
`with-current-buffer' on FILE so it targets the org buffer even
when the caller is a plz `:then' callback whose `current-buffer'
is the curl process buffer.  The sort+save is wrapped in
`org-save-outline-visibility' so the user's fold state survives
`org-sort-entries' and other org operations in the write path."
  (org-mode-google-tasks-sync-engine--resolve-reorder-drift
   token list-id drift-pairs file
   (lambda ()
     (org-mode-google-tasks-sync-engine--repair-position-ties
      token list-id parent-marker file
      (lambda ()
        (with-current-buffer (find-file-noselect file)
          (org-save-outline-visibility nil
            ;; Gated sort: skip the synchronous sort path on no-op
            ;; ticks (the four position-writing producers didn't fire
            ;; this pass).  Shrinks the exposure window for a hang and
            ;; saves CPU on quiet ticks.
            (when (org-mode-google-tasks-sync-engine--sort-needed-p list-id)
              (org-mode-google-tasks-sync-engine--sort-with-budget
               parent-marker list-id file))
            (org-mode-google-tasks-sync-engine--set-last-sync
             file (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t))
            (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
               (save-buffer)))
           (funcall done)))))))

(defun org-mode-google-tasks-sync-engine--collect-content-dupes (local-tasks)
  "Return the shadowed headings from LOCAL-TASKS grouped by canonical hash.
LOCAL-TASKS is the list collected by `--apply' (all synced headings
up to 2 levels deep).  Headings without a GTASK_ID are skipped
\(they're new-task headings the push path owns).  The canonical
hash is *computed* from the task struct (title, notes, status,
due) via `org-mode-google-tasks-sync-org-canonical-hash', not
read from the stored :GTASK_CONTENT_HASH: property — the
property may be stale or a placeholder, and deduping on a stale
value would remove genuinely different headings that happen to
share a stored hash.  For each content-hash group with more than
one member, the keeper is the member with the newest
:GTASK_UPDATED: (last heading in buffer order wins ties,
mirroring `puthash' semantics in the ID-dedup); all other
members are returned as shadows for the caller to delete.
Returns a fresh list; does not mutate LOCAL-TASKS."
  (let ((groups (make-hash-table :test 'equal)))
    (dolist (task local-tasks)
      (when (org-mode-google-tasks-sync-org-task-id task)
        (let ((hash (org-mode-google-tasks-sync-org-canonical-hash task)))
          (push task (gethash hash groups nil)))))
    (let (shadows)
      (maphash
       (lambda (_hash members)
         (when (cdr members)
           ;; `members' is in reverse buffer order (we pushed).  Pick
           ;; the keeper: newest by :GTASK_UPDATED:, ties broken by
           ;; last-in-buffer (the head of `members').  The rest are
           ;; shadows.
           (let* ((winner (car members))
                  (winner-updated (org-mode-google-tasks-sync-org-task-updated winner)))
             (dolist (m (cdr members))
               (let ((mu (org-mode-google-tasks-sync-org-task-updated m)))
                 (when (and mu winner-updated (string> mu winner-updated))
                   (setq winner m
                         winner-updated mu))))
             (dolist (m members)
               (unless (eq m winner)
                 (push m shadows))))))
       groups)
      shadows)))

(defun org-mode-google-tasks-sync-engine--apply
    (token list-id file parent mode remote-tasks done)
  "Reconcile REMOTE-TASKS against the local subtree under PARENT in FILE.
Uses TOKEN for pushes.  LIST-ID is the Google Tasks list.
MODE is `incremental' or `full'.  Calls DONE when finished.

Remote tasks are processed in two passes: top-level tasks first
\(no `parent' field), then subtasks (has `parent').  This ensures
parent headings exist locally before children are inserted under
them.  In `full' mode, any local task whose ID is absent from the
remote response is deleted via `--delete-local', which snapshots it
to the trash buffer (recoverable via
`org-mode-google-tasks-sync-restore-at-point') before removing the
heading.  FILE is threaded through to `--reconcile-one' and the
sweep so both deletion paths can snapshot.

Tasks with `hidden=true' (cleared server-side via the Google Tasks
UI's \"Clear completed tasks\") are filtered out of the live remote
set before reconciliation — they are never pulled, pushed, or
sorted.  Any local heading whose GTASK_ID matches a hidden task is
removed via `--delete-local' with reason `hidden-archived'
\(snapshotted to trash; restoring creates a fresh task because the
original is unreachable on the server).  This runs in both
`incremental' and `full' modes — unlike the full-sync sweep, which
only fires in `full' mode.

Duplicate GTASK_IDs (multiple local headings sharing the same ID)
are also removed in both modes: all but the last heading per ID are
deleted via `--delete-local' with reason `duplicate' (snapshotted to
trash).  This auto-heals the duplication caused by the pre-0.5.5
`--headline-body' bug where parent notes leaked child heading text
into the push callback, and guards against any future regression."
  (setq org-mode-google-tasks-sync-engine--state 'applying)
  (with-current-buffer (find-file-noselect file)
    (let* ((local (org-mode-google-tasks-sync-org-collect-tasks-under file parent list-id))
           (local-by-id (make-hash-table :test 'equal))
           (remote-by-id (make-hash-table :test 'equal))
           (parent-marker (org-mode-google-tasks-sync-engine--parent-marker file parent))
           (remote-list (append remote-tasks nil))
           (visible (cl-remove-if (lambda (r) (eq (alist-get 'hidden r) t)) remote-list))
           (hidden-ids (delq nil
                             (mapcar (lambda (r) (when (eq (alist-get 'hidden r) t)
                                                   (alist-get 'id r)))
                                     remote-list)))
           (top-level (cl-remove-if (lambda (r) (alist-get 'parent r)) visible))
           (subtasks (cl-remove-if-not (lambda (r) (alist-get 'parent r)) visible))
           (new-tasks nil)
           (dupes nil)
           (drift-snapshot (org-mode-google-tasks-sync-engine--snapshot-sibling-order
                            parent-marker)))
      (dolist (l local)
        (when (org-mode-google-tasks-sync-org-task-id l)
          (let ((id (org-mode-google-tasks-sync-org-task-id l)))
            (when (gethash id local-by-id)
              (push (gethash id local-by-id) dupes))
            (puthash id l local-by-id))))
      (dolist (r visible)
        (puthash (alist-get 'id r) r remote-by-id))
      ;; Hidden-task removal: runs in both incremental and full modes.
      ;; A local heading whose server-side twin has been cleared
      ;; (hidden=true) is removed locally with a trash snapshot so
      ;; `restore-at-point' can recreate it as a fresh task.
      (when hidden-ids
        (dolist (id hidden-ids)
          (let ((local-task (gethash id local-by-id)))
            (when local-task
              (org-mode-google-tasks-sync-engine--delete-local
               local-task file 'hidden-archived)
              (org-mode-google-tasks-sync-engine--log
               "Removed local (hidden server-side): %s"
               (org-mode-google-tasks-sync-org-task-title local-task))))))
      ;; Duplicate-ID removal: runs in both incremental and full modes.
      ;; `puthash' above silently overwrites earlier headings with the
      ;; same GTASK_ID, leaving the shadowed copies invisible to
      ;; reconciliation.  Without this pass they would survive every
      ;; tick and accumulate (the pre-0.5.5 `--headline-body' bug
      ;; doubled subtasks on every sync).  The last heading per ID wins
      ;; (it's the one in `local-by-id'); all earlier shadows are
      ;; deleted with a trash snapshot so recovery is possible.  Covers
      ;; duplicates at any level — top-level tasks and subtasks alike —
      ;; because `local' contains all collected headings up to 2 levels
      ;; deep.
      (when dupes
        (dolist (dupe dupes)
          (org-mode-google-tasks-sync-engine--delete-local dupe file 'duplicate)
          (org-mode-google-tasks-sync-engine--log
           "Removed duplicate local (same GTASK_ID): %s"
           (org-mode-google-tasks-sync-org-task-title dupe))))
      ;; Duplicate-content removal: runs in both incremental and full
      ;; modes.  Two local headings with different GTASK_IDs but
      ;; identical canonical content (title, notes, status, due) are
      ;; server-side duplicates the engine can't otherwise distinguish
      ;; — each pulls/pushes independently and they feed back into each
      ;; other every tick.  Reduce each content-hash group to the
      ;; newest by :GTASK_UPDATED: (last heading in buffer order wins
      ;; ties, mirroring `puthash' semantics in the ID-dedup above);
      ;; older shadows are trash-snapshotted via `--delete-local' with
      ;; reason `duplicate-content' so `restore-at-point' can recreate
      ;; them as fresh tasks.  Only synced headings (those with a
      ;; GTASK_ID and a stored hash) participate; new-task headings
      ;; without an ID are left for the push path.  Covers duplicates
      ;; at any level — top-level tasks and subtasks alike — because
      ;; `local' contains all collected headings up to 2 levels deep.
      (let ((content-dupes
              (org-mode-google-tasks-sync-engine--collect-content-dupes local)))
        (dolist (dupe content-dupes)
          (org-mode-google-tasks-sync-engine--delete-local dupe file 'duplicate-content)
          (org-mode-google-tasks-sync-engine--log
           "Removed duplicate local (same content, different GTASK_ID): %s"
           (org-mode-google-tasks-sync-org-task-title dupe))))
      ;; Pass 1: top-level tasks (no parent).
      (dolist (r top-level)
        (org-mode-google-tasks-sync-engine--reconcile-one
         token list-id parent-marker r local-by-id file))
      ;; Pass 2: subtasks (has parent) — parent headings now exist.
      (dolist (r subtasks)
        (org-mode-google-tasks-sync-engine--reconcile-one
         token list-id parent-marker r local-by-id file))
      (when (eq mode 'full)
        (maphash
         (lambda (id local-task)
           (unless (gethash id remote-by-id)
             (org-mode-google-tasks-sync-engine--delete-local local-task file)))
         local-by-id))
      (dolist (l local)
        (unless (org-mode-google-tasks-sync-org-task-id l)
          (push l new-tasks))
        (org-mode-google-tasks-sync-engine--log-debug
         "Queued new task for push: %s"
         (org-mode-google-tasks-sync-org-task-title l)))
       (org-mode-google-tasks-sync-engine--push-new-queue
        token list-id (nreverse new-tasks) file
        (lambda ()
          (org-mode-google-tasks-sync-engine--finalize-apply
           token list-id parent-marker file
           (org-mode-google-tasks-sync-engine--detect-reorder-drift drift-snapshot)
           done))))))

(defun org-mode-google-tasks-sync-engine--task-sort-key ()
  "Return the sort key for the current heading.
Tuple: (done? position-string completed-string).  Used together with
`--compare-tasks'."
  (require 'org)
  (list (and (org-get-todo-state)
             (member (org-get-todo-state) org-done-keywords))
        (or (org-entry-get nil "GTASK_POSITION") "")
        (or (org-entry-get nil "GTASK_COMPLETED") "")))

(defun org-mode-google-tasks-sync-engine--compare-tasks (a b)
  "Compare two `--task-sort-key' tuples A and B.
TODOs come before DONEs; among TODOs, position ascending; among DONEs,
completed timestamp descending (newest first).  A missing position
\(empty string) sorts last among TODOs so that positionless headings
\(e.g. a freshly-pushed task whose position write was skipped) stay
at the end of the sibling list rather than jumping to the front."
  (cond
   ((and (not (nth 0 a)) (nth 0 b)) t)
   ((and (nth 0 a) (not (nth 0 b))) nil)
   ((nth 0 a) (string> (nth 2 a) (nth 2 b)))
   (t
    (let ((pa (nth 1 a))
          (pb (nth 1 b)))
      (cond
       ((and (string= pa "") (not (string= pb ""))) nil)
       ((and (not (string= pa "")) (string= pb "")) t)
       (t (string< pa pb)))))))

(defun org-mode-google-tasks-sync-engine--sort-children (parent-marker)
  "Sort children of PARENT-MARKER by `--task-sort-key' / `--compare-tasks'.
Sorts direct children, then recurses into each child's subtree so
subtasks are also ordered.  Returns silently when PARENT-MARKER is
nil or points at no heading."
  (when (and parent-marker (marker-buffer parent-marker))
    (with-current-buffer (marker-buffer parent-marker)
      (save-excursion
        (goto-char parent-marker)
        (when (org-at-heading-p)
          (org-mode-google-tasks-sync-engine--sort-subtree-at-point))))))

(defvar org-mode-google-tasks-sync-engine--sort-deadline nil
  "Wall-clock deadline for the current sort, or nil when no budget is set.
Bound by `--sort-with-budget' and checked at each recursion level of
`--sort-subtree-at-point'.  Buffer-local so concurrent syncs of
different files don't share a deadline.")

(defun org-mode-google-tasks-sync-engine--sort-with-budget (parent-marker list-id file)
  "Run `--sort-children' under a wall-clock budget, aborting on timeout.
PARENT-MARKER locates the subtree to sort.  LIST-ID and FILE appear
in the diagnostic `display-warning' when the budget is exceeded.
The sort is wrapped so a hanging sort (the cycle that historically
froze Emacs at \"Sorting entries...\") aborts cleanly: the warning
surfaces, the remaining sorts are skipped, but the sync item still
stamps, saves, and completes — the worker advances instead of
parking forever."
  (let ((org-mode-google-tasks-sync-engine--sort-deadline
         (+ (float-time) org-mode-google-tasks-sync-sort-time-budget)))
    (condition-case _err
        (org-mode-google-tasks-sync-engine--sort-children parent-marker)
      (org-mode-google-tasks-sync-sort-timeout
       ;; The recursion-entry check already raised the
       ;; `display-warning'; here we just ensure the sync tail
       ;; continues (stamp, save) so the worker advances.
       (org-mode-google-tasks-sync-engine--log
        "Sort aborted after exceeding %ds budget for list %S file %S (set `org-mode-google-tasks-sync-sort-time-budget' to raise it)"
        org-mode-google-tasks-sync-sort-time-budget list-id file)))))

(defun org-mode-google-tasks-sync-engine--sort-tripwire-here
    (title id where &optional start file list-id)
  "Emit the always-on `display-warning' for a sort trip, plus a log line.
TITLE and ID identify the heading the sort stalled at (or nil).
WHERE is a short label for which check fired.  START, FILE and
LIST-ID, when given, add elapsed time and file/list context to the
diagnostic.  The warning is `:error' severity so it can't be missed
mid-hang and carries the cycle-indicator context the user needs to
debug the root cause."
  (let* ((elapsed (if start (- (float-time) start) 0))
         (budget org-mode-google-tasks-sync-sort-time-budget)
         (running org-mode-google-tasks-sync-engine--running)
         (queue (mapcar (lambda (i) (list (car i) (cadr i)))
                        org-mode-google-tasks-sync-engine--queue))
         (pass org-mode-google-tasks-sync-engine--pass-count)
         (msg
          (format-message
           (concat "Sort exceeded the %ds budget (set "
                   "`org-mode-google-tasks-sync-sort-time-budget' to raise it).\n"
                   "  stalled at: %S  (GTASK_ID=%S)\n"
                   "  check: %S\n"
                   "  elapsed: %ds\n"
                   "  file: %S\n  list-id: %S\n"
                   "  pass: #%d\n"
                   "  running item: %S\n"
                   "  pending queue: %S\n\n"
                   "Likely causes:\n"
                   "  - a position-repair / drift-resolution cycle "
                   "(check the log for repeated `tasks.move' lines)\n"
                   "  - a content-hash flap pulling the same task every "
                   "pass (check the log for repeated `Pulled')\n"
                   "  - a genuinely large list (raise the budget)\n\n"
                   "The remaining sorts were skipped; the sync still "
                   "saved and completed.  See *org-mode-google-tasks-sync-log* "
                   "(set `org-mode-google-tasks-sync-log-level' to `debug' "
                   "for queue chatter).")
           budget
           (or title "<unknown>") (or id "<none>")
           where elapsed
           (or file "<unknown>") (or list-id "<unknown>")
           pass
           (and running (list (car running) (cadr running)))
           queue)))
    (display-warning 'org-mode-google-tasks-sync-sort msg :error)
    (org-mode-google-tasks-sync-engine--log "SORT ABORTED: %s" msg)))

(defun org-mode-google-tasks-sync-engine--collect-tie-pairs (parent-marker)
  "Return (ID . PREV-ID) pairs for synced siblings with duplicate positions.
Walks direct synced children of PARENT-MARKER in buffer order, then
recurses one level into each synced child's subtree — matching the
2-level sync depth of `collect-tasks-under'.  When two adjacent
siblings share the same :GTASK_POSITION:, the second one needs a
`tasks.move' with `previous=<first-id>' to get a unique position.
Returns nil when all positions are unique."
  (when (and parent-marker (marker-buffer parent-marker))
    (with-current-buffer (marker-buffer parent-marker)
      (save-excursion
        (goto-char parent-marker)
        (org-back-to-heading t)
        (let (pairs)
          ;; Direct children of the configured parent (top-level tasks).
          (when-let ((level-pairs
                      (org-mode-google-tasks-sync-engine--collect-tie-pairs-one-level)))
            (setq pairs (nconc pairs (nreverse level-pairs))))
          ;; One level of subtasks under each synced top-level task.
          (dolist (child-marker
                   (org-mode-google-tasks-sync-engine--child-markers))
            (save-excursion
              (goto-char child-marker)
              (when-let ((level-pairs
                          (org-mode-google-tasks-sync-engine--collect-tie-pairs-one-level)))
                (setq pairs (nconc pairs (nreverse level-pairs))))))
          pairs)))))

(defun org-mode-google-tasks-sync-engine--collect-tie-pairs-one-level ()
  "Return (ID FIRST-DUP-ID . PRE-PAIR-ID) triples for duplicate positions.
Walks the direct synced children of the heading at point.  When two
adjacent synced siblings share the same :GTASK_POSITION:, the second
needs a `tasks.move' with `previous=<first-id>'.  In a 3+-way tie
\(A,B,C all sharing a position), every sibling past the first uses
the *first* of the run as FIRST-DUP-ID so Google moves it past the
stable anchor rather than past a sibling that is itself being
repaired this pass.  PRE-PAIR-ID is the synced sibling immediately
before the duplicate run (nil when the run starts at the front of
the list); it is the fallback `previous' used when Google returns
the same position for the first move (which happens when the task
is already placed right after FIRST-DUP-ID).  Returns nil when all
positions are unique or there are no synced children."
  (let ((parent-level (org-current-level))
        (pairs nil)
        (prev-id nil)
        (prev-pos nil)
        (run-start-id nil)
        (pre-pair-id nil))
    (save-excursion
      (when (org-goto-first-child)
        (while (and (not (eobp))
                    (= (org-current-level) (1+ parent-level)))
          (let ((id (org-entry-get nil org-mode-google-tasks-sync-org--prop-id))
                (pos (org-entry-get nil org-mode-google-tasks-sync-org--prop-position)))
            (if (and id pos prev-pos (equal pos prev-pos))
                ;; Continuing a duplicate run (2nd, 3rd, ... sibling
                ;; with the same position).  Anchor against the
                ;; *first* sibling of the run so a 3+-way tie
                ;; converges instead of moving each sibling past the
                ;; one before it (which would re-tie them).
                (when (and id prev-id)
                  (push (list id (or run-start-id prev-id) pre-pair-id) pairs))
              ;; Position changed (or first sibling) — start a new
              ;; potential run.  run-start-id remembers the first
              ;; sibling of the current run; pre-pair-id remembers
              ;; the synced sibling before the run started.
              (setq run-start-id id)
              (when (and prev-id prev-pos (not (equal pos prev-pos)))
                (setq pre-pair-id prev-id)))
            (setq prev-id id
                  prev-pos pos))
          (unless (org-get-next-sibling)
            (goto-char (point-max))))))
    pairs))

(defun org-mode-google-tasks-sync-engine--repair-position-ties
    (token list-id parent-marker file done)
  "Fire `tasks.move' for siblings with duplicate :GTASK_POSITION: values.
TOKEN authenticates the calls.  LIST-ID is the Google Tasks list.
PARENT-MARKER locates the subtree.  FILE is the source org file,
threaded to `--write-move-result' so the position write targets the
org buffer even when the callback fires in a plz curl buffer.  DONE
is called when all tie repairs have completed (or immediately when
there are no ties).  Each move response writes the fresh position
into the heading's property, ensuring the subsequent `--sort-children'
produces a stable order.  When Google returns the same position for
a move (the task was already placed there), `--repair-tie-queue'
retries once with a different `previous' anchor so Google is forced
to assign a genuinely new position."
  (let ((pairs (org-mode-google-tasks-sync-engine--collect-tie-pairs parent-marker)))
    (if (null pairs)
        (funcall done)
      (org-mode-google-tasks-sync-engine--repair-tie-queue
       token list-id pairs file done))))

(defun org-mode-google-tasks-sync-engine--repair-tie-queue
    (token list-id pairs file done)
  "Process PAIRS serially, calling DONE when the queue is empty.
TOKEN authenticates each move.  LIST-ID is the Google Tasks list.
FILE is the source org file, threaded to `--write-move-result'.
Each pair is (ID FIRST-DUP-ID . PRE-PAIR-ID); the first move calls
`tasks.move' with `previous=FIRST-DUP-ID' to give ID a unique
position after FIRST-DUP-ID.  When Google returns the same position
string (which happens when ID is already placed right after
FIRST-DUP-ID), retry once with `previous=PRE-PAIR-ID' — or with
`previous' omitted (move to the front of the list) when PRE-PAIR-ID
is nil.  If the retry also returns the same position, log and
advance: the stable sort keeps the duplicates adjacent so no
reordering flap ensues."
  (if (null pairs)
      (funcall done)
    (let* ((pair (car pairs))
           (task-id (car pair))
           (first-dup-id (cadr pair))
           (pre-pair-id (caddr pair)))
      (org-mode-google-tasks-sync-engine--repair-tie-move
       token list-id task-id first-dup-id pre-pair-id file
       (lambda ()
         (org-mode-google-tasks-sync-engine--repair-tie-queue
          token list-id (cdr pairs) file done))))))

(defun org-mode-google-tasks-sync-engine--repair-tie-move
    (token list-id task-id first-dup-id pre-pair-id file done)
  "Fire one `tasks.move' for TASK-ID, retrying once on a no-op move.
TOKEN authenticates the call.  LIST-ID is the Google Tasks list.
TASK-ID is the heading being repaired.  FIRST-DUP-ID is the sibling
the task is currently tied with (the first `previous' candidate).
PRE-PAIR-ID is the synced sibling before the duplicate pair (the
fallback `previous' when the first move is a no-op); nil means the
pair is at the front of the list, so the retry moves TASK-ID to the
front.  FILE is the source org file, threaded to
`--write-move-result'.  DONE is called when this pair's repair
finishes (regardless of outcome)."
  (let ((current-pos
         (org-mode-google-tasks-sync-engine--position-for-id task-id file)))
    (org-mode-google-tasks-sync-api-move-task
     token list-id task-id
     (lambda (resp)
       (let ((new-pos (alist-get 'position resp)))
         (if (and current-pos new-pos (string= new-pos current-pos))
             ;; Google returned the same position — the task was
             ;; already placed there.  Retry once with the fallback
             ;; anchor so Google is forced to compute a fresh
             ;; position.  When PRE-PAIR-ID is nil, omit `previous'
             ;; entirely (move to front).
              (org-mode-google-tasks-sync-api-move-task
               token list-id task-id
               (lambda (resp2)
                 (let ((new-pos2 (alist-get 'position resp2)))
                   (if (and new-pos2 current-pos
                            (string= new-pos2 current-pos))
                       (org-mode-google-tasks-sync-engine--log
                        "Tie repair stuck: tasks.move returned the same \
position (%s) for task %s after retry; leaving duplicate in place"
                        new-pos2 task-id)
                     (org-mode-google-tasks-sync-engine--write-move-result
                      task-id resp2 file)))
                 (funcall done))
              (lambda (err)
                (org-mode-google-tasks-sync-engine--log
                 "Tie repair retry move error: %S (task=%s)" err task-id)
                (funcall done))
              nil pre-pair-id)
           ;; Position genuinely changed — write it and advance.
           (org-mode-google-tasks-sync-engine--write-move-result
            task-id resp file)
           (funcall done))))
     (lambda (err)
       (org-mode-google-tasks-sync-engine--log
        "Tie repair move error: %S (task=%s)" err task-id)
       (funcall done))
     nil first-dup-id)))

(defun org-mode-google-tasks-sync-engine--position-for-id (task-id file)
  "Return the current :GTASK_POSITION: of the heading with :GTASK_ID: TASK-ID.
FILE is the source org file (the search happens in that buffer).
Returns nil when the heading can't be found or has no position."
  (when (and task-id file)
    (let ((marker (org-mode-google-tasks-sync-org-find-marker-by-gtask-id
                   file task-id)))
      (when (and marker (marker-buffer marker))
        (with-current-buffer (marker-buffer marker)
          (save-excursion
            (goto-char marker)
            (org-back-to-heading t)
            (org-entry-get nil org-mode-google-tasks-sync-org--prop-position)))))))

(defun org-mode-google-tasks-sync-engine--write-move-result (task-id resp &optional file)
  "Write the position from a move RESP into the heading with :GTASK_ID: TASK-ID.
Called after `tasks.move' returns a fresh position for a tie-repair
or drift-resolution move.  Searches the org buffer for the heading by
GTASK_ID.  FILE is the source org file; when given, the search happens
in that buffer (via `find-file-noselect') so this works even when the
caller's `current-buffer' is a plz curl buffer.  Falls back to
`(buffer-file-name)' for legacy callers."
  (let ((position (alist-get 'position resp))
        (search-file (or file (buffer-file-name))))
    (when (and position search-file)
      (let ((marker (org-mode-google-tasks-sync-org-find-marker-by-gtask-id
                     search-file task-id)))
        (when (and marker (marker-buffer marker))
          (with-current-buffer (marker-buffer marker)
            (save-excursion
              (goto-char marker)
              (org-back-to-heading t)
              (org-entry-put nil org-mode-google-tasks-sync-org--prop-position
                             position)))
          ;; Position changed this pass → the sync tail must sort.
          (org-mode-google-tasks-sync-engine--sort-needed-mark
           (org-mode-google-tasks-sync-engine--list-id-for-file search-file)))))))

(defun org-mode-google-tasks-sync-engine--list-id-for-file (file)
  "Return the list-id whose `--map' entry matches FILE, or nil."
  (let ((abs (and file (file-truename file))))
    (cl-some
     (lambda (entry)
       (when (and abs (string= abs (file-truename (car (cdr entry)))))
         (car entry)))
     org-mode-google-tasks-sync-map)))

;;; -- reorder drift detection (B1) -------------------------------------------
;;
;; Detects manual cut/paste reorders by comparing the buffer's physical
;; sibling order against the order implied by stored :GTASK_POSITION:
;; values.  The snapshot is taken at tick START (before pulls rewrite
;; position properties), so server-driven reorders (pulls) are not
;; mistaken for user-driven ones.  After reconciliation, drifted tasks
;; are pushed to the server via `tasks.move' with `previous=<buffer
;; predecessor>', reconstructing the user's intended order server-side.

(defun org-mode-google-tasks-sync-engine--snapshot-sibling-order (parent-marker)
  "Return a list of (BUFFER-IDS . SORTED-IDS) snapshots for synced children.
One snapshot per parent heading whose direct children include at
least one synced task, walked to the same 2-level depth as
`org-mode-google-tasks-sync-org-collect-tasks-under' so manual
cut/paste reorders are detected at both the top-level and subtask
levels.  Each snapshot's BUFFER-IDS is the list of GTASK_IDs of the
parent's synced direct children in physical buffer order;
SORTED-IDS is the same list stably sorted by :GTASK_POSITION:.
When the two lists differ for any parent, a manual reorder has
occurred at that level.  Returns nil when PARENT-MARKER is invalid."
  (if (not (and parent-marker (marker-buffer parent-marker)))
      nil
    (with-current-buffer (marker-buffer parent-marker)
      (save-excursion
        (goto-char parent-marker)
        (org-back-to-heading t)
        (let (snapshots)
          ;; Direct children of the configured parent (top-level tasks),
          ;; then one level of subtasks under each — matching the 2-level
          ;; sync depth of `collect-tasks-under'.
          (when-let ((snap (org-mode-google-tasks-sync-engine--snapshot-one-level)))
            (push snap snapshots))
          (dolist (child-marker
                   (org-mode-google-tasks-sync-engine--child-markers))
            (save-excursion
              (goto-char child-marker)
              (when-let ((snap (org-mode-google-tasks-sync-engine--snapshot-one-level)))
                (push snap snapshots))))
          (nreverse snapshots))))))

(defun org-mode-google-tasks-sync-engine--snapshot-one-level ()
  "Return (BUFFER-IDS . SORTED-IDS) for synced direct children at point.
Walks the direct synced children of the heading at point.  Returns
nil when the heading has no synced children."
  (let ((parent-level (org-current-level))
        (entries nil))
    (save-excursion
      (when (org-goto-first-child)
        (while (and (not (eobp))
                    (= (org-current-level) (1+ parent-level)))
          (let ((id (org-entry-get nil org-mode-google-tasks-sync-org--prop-id))
                (pos (org-entry-get nil org-mode-google-tasks-sync-org--prop-position)))
            (when id
              (push (cons id (or pos "")) entries)))
          (unless (org-get-next-sibling)
            (goto-char (point-max))))))
    (when entries
      (let* ((rev (reverse entries))
             (buffer-ids (mapcar #'car rev))
             (sorted-ids (mapcar #'car
                                 (sort (copy-sequence rev)
                                       (lambda (a b)
                                         (string< (cdr a) (cdr b)))))))
        (cons buffer-ids sorted-ids)))))

(defun org-mode-google-tasks-sync-engine--child-markers ()
  "Return markers for the direct child headings of the heading at point.
Each marker is a sticky `point-marker' so it stays valid across the
sibling walk.  The walk uses `org-get-next-sibling' so a child's
own subtree is never mistaken for a direct child."
  (let ((parent-level (org-current-level))
        (markers nil))
    (save-excursion
      (when (org-goto-first-child)
        (while (and (not (eobp))
                    (= (org-current-level) (1+ parent-level)))
          (push (org-mode-google-tasks-sync-org--sticky-marker) markers)
          (unless (org-get-next-sibling)
            (goto-char (point-max))))))
    (nreverse markers)))

(defun org-mode-google-tasks-sync-engine--detect-reorder-drift (snapshots)
  "Return a list of (ID . PREV-ID) move pairs for drifted siblings.
SNAPSHOTS is the list of (BUFFER-IDS . SORTED-IDS) from
`--snapshot-sibling-order', one per parent level (top-level tasks
and subtasks).  For each snapshot where the two lists differ, a
pair is emitted for every task in buffer order whose actual buffer
predecessor differs from what the sorted order would place before
it.  Each pair is (ID . PREV-ID) where PREV-ID is the synced
sibling immediately before ID in buffer order (nil for the first
sibling at that level).  Returns nil when no level has drift."
  (let (all-pairs)
    (dolist (snapshot snapshots)
      (let ((buffer-ids (car snapshot))
            (sorted-ids (cdr snapshot)))
        (unless (equal buffer-ids sorted-ids)
          (let ((prev-id nil))
            (dolist (id buffer-ids)
              (push (cons id prev-id) all-pairs)
              (setq prev-id id))))))
    (nreverse all-pairs)))

(defun org-mode-google-tasks-sync-engine--resolve-reorder-drift
    (token list-id drift-pairs file done)
  "Fire `tasks.move' for each pair in DRIFT-PAIRS, serially.
TOKEN authenticates.  LIST-ID is the Google Tasks list.  FILE is the
source org file, threaded to `--write-move-result' so the position
write targets the org buffer even when the callback fires in a plz
curl buffer.  DONE is called when all moves complete (or immediately
when no drift).  Each pair is (ID . PREV-ID); the move sets
`previous=PREV-ID' so Google places ID right after PREV-ID,
reconstructing the buffer order on the server."
  (if (null drift-pairs)
      (funcall done)
    (let* ((pair (car drift-pairs))
           (task-id (car pair))
           (prev-id (cdr pair)))
      (org-mode-google-tasks-sync-api-move-task
       token list-id task-id
       (lambda (resp)
         (org-mode-google-tasks-sync-engine--write-move-result task-id resp file)
         (org-mode-google-tasks-sync-engine--resolve-reorder-drift
          token list-id (cdr drift-pairs) file done))
       (lambda (err)
         (org-mode-google-tasks-sync-engine--log
          "Reorder drift move error: %S (task=%s)" err task-id)
         (org-mode-google-tasks-sync-engine--resolve-reorder-drift
          token list-id (cdr drift-pairs) file done))
       nil prev-id))))

(defun org-mode-google-tasks-sync-engine--back-to-heading-safe ()
  "Move point to the nearest heading, never raising a user-error.
`org-back-to-heading' raises `user-error' when point is before the
first headline (e.g. at `point-min' after `org-sort-entries' on a
buffer that begins with #+ keyword lines); that error aborts the
sync and leaves the state machine stuck at `applying'.  This
wrapper falls back to a forward search in that case.  Returns
non-nil when point ended on a heading, nil otherwise."
  (cond
   ((org-at-heading-p) t)
   ((org-before-first-heading-p)
    (when (re-search-forward "^\\*+ " nil t)
      (beginning-of-line)
      t))
   (t
    (condition-case nil
        (progn (org-back-to-heading t) t)
      (error nil)))))

(defun org-mode-google-tasks-sync-engine--sort-subtree-at-point ()
  "Sort the children of the heading at point, then recurse into each child.
Children are sorted by `--task-sort-key' / `--compare-tasks'."
  ;; Sort tripwire: when `--sort-deadline' is set (we're inside
  ;; `--sort-with-budget'), bail out before doing more work once the
  ;; budget is exceeded.  The check is cheap and runs at each recursion
  ;; level so a hung sort aborts in O(1) extra time, not after the
  ;; current subtree finishes.
  (when (and org-mode-google-tasks-sync-engine--sort-deadline
             (> (float-time) org-mode-google-tasks-sync-engine--sort-deadline))
    (let ((here-title
           (condition-case nil
               (or (org-element-property :raw-value (org-element-at-point))
                   "<no heading>")
             (error "<no heading>")))
          (here-id (condition-case nil (org-entry-get nil "GTASK_ID")
                     (error nil))))
      (org-mode-google-tasks-sync-engine--sort-tripwire-here
       here-title here-id "recursion entry")
      (signal 'org-mode-google-tasks-sync-sort-timeout
              (list here-title here-id))))
  (condition-case err
      (progn
        (org-sort-entries nil ?f
                          #'org-mode-google-tasks-sync-engine--task-sort-key
                          #'org-mode-google-tasks-sync-engine--compare-tasks)
        ;; Recurse into each direct child.  `org-sort-entries' can leave
        ;; point at `point-min' (e.g. when the buffer begins with #+
        ;; keyword lines); `org-back-to-heading' would raise a user-error
        ;; from there, aborting the sync and leaving the state machine
        ;; stuck at `applying'.  Relocate via `--back-to-heading-safe'
        ;; and bail out cleanly if no heading is found.
        (save-excursion
          (when (org-mode-google-tasks-sync-engine--back-to-heading-safe)
            (when (org-at-heading-p)
              (let ((parent-level (org-current-level)))
                (forward-line 1)
                (while (and (not (eobp))
                            (looking-at "^\\*+ ")
                            (= (org-current-level) (1+ parent-level)))
                  (org-mode-google-tasks-sync-engine--sort-subtree-at-point)
                  (when (org-mode-google-tasks-sync-engine--back-to-heading-safe)
                    (forward-line 1))))))))
    (org-mode-google-tasks-sync-sort-timeout
     ;; The recursion-entry check already raised the
     ;; `display-warning'; swallow here so the recursion unwinds
     ;; cleanly and the sync tail continues.
     nil)
    (error
     (org-mode-google-tasks-sync-engine--log
      "Sort skipped: %S" err))))

(defun org-mode-google-tasks-sync-engine--parent-marker (file parent)
  "Return marker of PARENT heading in FILE, creating the heading if absent.
Without the auto-create, the engine would silently skip every
pulled task because there's nowhere to insert it — the file would
end up containing only the `#+GTASKS_LAST_SYNC' keyword and the
user would see no tasks despite a successful sync."
  (with-current-buffer (find-file-noselect file)
    (or (save-excursion
          (goto-char (point-min))
          (when (re-search-forward (format "^\\*+ %s$" (regexp-quote parent)) nil t)
            (point-marker)))
        (save-excursion
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert (format "* %s" parent))
          (let ((mk (point-marker)))
            (insert "\n")
            (org-mode-google-tasks-sync-engine--log
             "Created parent heading %S in %s" parent file)
            mk)))))

(defun org-mode-google-tasks-sync-engine--reconcile-one
    (token list-id parent-marker remote local-by-id file)
  "Apply the 4-cell matrix to REMOTE against the local task (if any).
Uses TOKEN for pushes.  LIST-ID is the Google Tasks list.
PARENT-MARKER is the org heading under which top-level tasks live.
LOCAL-BY-ID is a hash table of local tasks keyed by ID.
FILE is the source file, passed to `--delete-local' for trash snapshots.

When REMOTE has a `parent' field, the task is a subtask: it is
inserted under the local heading whose :GTASK_ID: matches the
remote `parent', not under PARENT-MARKER."
  (let* ((id (alist-get 'id remote))
         (deleted (alist-get 'deleted remote))
         (remote-parent (alist-get 'parent remote))
         (local (gethash id local-by-id)))
    (cond
     ((eq deleted t)
      (when local (org-mode-google-tasks-sync-engine--delete-local local file)))
      ((null local)
       (unless (and (not (org-mode-google-tasks-sync-engine--keep-done-p))
                    (org-mode-google-tasks-sync-engine--remote-completed-p remote))
          (let* ((task (org-mode-google-tasks-sync-engine--remote-task->struct
                        remote list-id nil)))
            ;; For subtasks, insert under the parent task's heading, not
            ;; the configured parent heading.  Look up by :GTASK_ID:.
            ;; If the parent can't be found locally (e.g. it was deleted
            ;; on this side but the child survived remotely), insert the
            ;; orphan at top level and warn rather than silently dropping
            ;; it.
            (let* ((found-parent
                    (and remote-parent
                         (or (when (gethash remote-parent local-by-id)
                               (org-mode-google-tasks-sync-org-task-marker
                                (gethash remote-parent local-by-id)))
                             (org-mode-google-tasks-sync-org-find-marker-by-gtask-id
                              file remote-parent))))
                   (insert-marker (or found-parent parent-marker)))
              (when (and remote-parent (not found-parent))
                (org-mode-google-tasks-sync-engine--log
                 "WARN: orphan subtask %s (parent %s not found locally); inserted at top level"
                 (org-mode-google-tasks-sync-org-task-title task)
                 remote-parent)
                (display-warning 'org-mode-google-tasks-sync
                                 (format "Orphan subtask %S inserted at top level (parent not found)"
                                         (org-mode-google-tasks-sync-org-task-title task))
                                 :warning))
              (when insert-marker
                (org-mode-google-tasks-sync-org-insert-task-under insert-marker task)
                (org-mode-google-tasks-sync-engine--log "Pulled new: %s"
                                                    (org-mode-google-tasks-sync-org-task-title task)))))))
     (t
      (progn
        (let* ((local-parent (org-mode-google-tasks-sync-org-task-parent-id local))
               (stored-parent
                (org-mode-google-tasks-sync-org-stored-parent-id local))
               (parent-changed (not (equal remote-parent local-parent)))
               (local-moved (not (equal stored-parent local-parent))))
         (when parent-changed
           ;; Reparenting detected.  Who moved?  Compare the current
           ;; hierarchy-derived parent against the stored
           ;; :GTASK_PARENT_ID: from the last sync:
           ;; - Equal: the user didn't move it locally; remote wins.
           ;; - Different: the user reparented locally; push unless the
           ;;   remote also moved and is newer.
           (let* ((remote-changed (not (equal
                                        (alist-get 'updated remote)
                                        (org-mode-google-tasks-sync-org-task-updated local))))
                  (local-mtime (and (org-mode-google-tasks-sync-org-task-marker local)
                                    (org-mode-google-tasks-sync-engine--marker-mtime
                                     (org-mode-google-tasks-sync-org-task-marker local))))
                  (remote-newer (org-mode-google-tasks-sync-engine--remote-newer-p
                                 local-mtime (alist-get 'updated remote))))
             (cond
              ((not local-moved)
               ;; Local hierarchy untouched since last sync: remote wins.
               (org-mode-google-tasks-sync-engine--move-local-heading
                local remote-parent file)
               (org-mode-google-tasks-sync-engine--log
                "Reparented (remote): %s -> parent=%s"
                (org-mode-google-tasks-sync-org-task-title local)
                (or remote-parent "<top-level>")))
              ((and remote-changed remote-newer)
               ;; Both moved, remote newer: remote wins.
               (org-mode-google-tasks-sync-engine--move-local-heading
                local remote-parent file)
               (org-mode-google-tasks-sync-engine--log
                "Reparented (remote, conflict): %s -> parent=%s"
                (org-mode-google-tasks-sync-org-task-title local)
                (or remote-parent "<top-level>")))
               (t
                ;; Local moved (and remote didn't, or local is newer):
                ;; push to Google via tasks.move.  Pass local-parent as
                ;; :new-parent-id (not :previous-id, which is for sibling
                ;; reordering, not reparenting).
                (org-mode-google-tasks-sync-api-move-task
                 token list-id id
                  (lambda (resp)
                    (setf (org-mode-google-tasks-sync-org-task-updated local)
                          (alist-get 'updated resp))
                    ;; Bring the stored :GTASK_PARENT_ID: in line with
                    ;; the heading's (already moved) position.
                    (let ((m (org-mode-google-tasks-sync-org-task-marker local)))
                      (when (and m (marker-buffer m))
                        (with-current-buffer (marker-buffer m)
                          (save-excursion
                            (goto-char m)
                            (org-mode-google-tasks-sync-org-write-parent-id-at-point
                             local-parent)))))
                    (org-mode-google-tasks-sync-engine--log
                     "Reparented (local push): %s -> parent=%s"
                     (org-mode-google-tasks-sync-org-task-title local)
                     (or local-parent "<top-level>")))
                 (lambda (err)
                   (org-mode-google-tasks-sync-engine--log
                    "Reparent push error: %S (task=%s)"
                    err (org-mode-google-tasks-sync-org-task-title local)))
                 local-parent nil))))))
      (let* ((local-changed (not (equal
                                  (org-mode-google-tasks-sync-org-canonical-hash local)
                                  (org-mode-google-tasks-sync-org-task-hash local))))
             (remote-changed (not (equal
                                   (alist-get 'updated remote)
                                   (org-mode-google-tasks-sync-org-task-updated local))))
             (decision (org-mode-google-tasks-sync-engine--decide
                        local-changed remote-changed
                        (and (org-mode-google-tasks-sync-org-task-marker local)
                             (org-mode-google-tasks-sync-engine--marker-mtime
                              (org-mode-google-tasks-sync-org-task-marker local)))
                        (alist-get 'updated remote)
                        (org-mode-google-tasks-sync-org-task-status local)
                        (if (equal (alist-get 'status remote) "completed")
                            'completed 'needsAction))))
        (pcase decision
          ('done-remove-local
           (when local-changed
             (org-mode-google-tasks-sync-engine--quarantine "local-overwritten-done" local))
           (org-mode-google-tasks-sync-engine--remove-done-local local file))
          ('done-push-then-remove
           (org-mode-google-tasks-sync-engine--push-and-remove-on-done
            token list-id local file))
          ('skip nil)
          ('push (org-mode-google-tasks-sync-engine--push-update token list-id local))
          ('pull (org-mode-google-tasks-sync-engine--apply-pull list-id local remote))
          ('conflict-remote-wins
           (org-mode-google-tasks-sync-engine--quarantine "local-overwritten" local)
           (org-mode-google-tasks-sync-engine--apply-pull list-id local remote))
          ('conflict-local-wins
           (org-mode-google-tasks-sync-engine--quarantine
            "remote-overwritten"
            (org-mode-google-tasks-sync-engine--remote-task->struct remote list-id nil))
           (org-mode-google-tasks-sync-engine--push-update token list-id local)))))))))

(defun org-mode-google-tasks-sync-engine--marker-mtime (marker)
  "Return `float-time' of the file backing MARKER, or nil."
  (let ((buf (marker-buffer marker)))
    (when (and buf (buffer-file-name buf))
      (let ((attrs (file-attributes (buffer-file-name buf))))
        (when attrs (float-time (file-attribute-modification-time attrs)))))))

(defun org-mode-google-tasks-sync-engine--move-local-heading (task new-parent-id file)
  "Move TASK's org heading under the heading with :GTASK_ID: NEW-PARENT-ID.
When NEW-PARENT-ID is nil, move to top level (under the configured
parent heading).  FILE is the source file, used to find the new
parent's heading marker."
  (when (org-mode-google-tasks-sync-org-task-marker task)
    (let ((dest-marker
           (if new-parent-id
               (org-mode-google-tasks-sync-org-find-marker-by-gtask-id file new-parent-id)
             (org-mode-google-tasks-sync-engine--parent-marker file
              (or (cdr (assoc (org-mode-google-tasks-sync-org-task-list-id task)
                              org-mode-google-tasks-sync-map
                              ;; fall back to first entry's parent
                              ))
                  (cdar org-mode-google-tasks-sync-map))))))
      (when dest-marker
        (with-current-buffer (marker-buffer (org-mode-google-tasks-sync-org-task-marker task))
          (save-excursion
            (goto-char (org-mode-google-tasks-sync-org-task-marker task))
            (org-back-to-heading t)
            (let* ((begin (point))
                   (end (save-excursion (org-end-of-subtree t t) (point)))
                   (subtree-text (buffer-substring begin end))
                   (old-level (org-current-level)))
              (delete-region begin end)
              (with-current-buffer (marker-buffer dest-marker)
                (save-excursion
                  (goto-char dest-marker)
                  (org-back-to-heading t)
                  (let ((new-level (1+ (org-current-level))))
                    (org-end-of-subtree t t)
                    (unless (bolp) (insert "\n"))
                    (let* ((adjusted
                            (org-mode-google-tasks-sync-engine--adjust-heading-level
                             subtree-text old-level new-level))
                           (insert-point (point)))
                      (insert adjusted)
                      ;; Persist :GTASK_PARENT_ID: on the freshly moved
                      ;; heading so the next tick sees its hierarchy as
                      ;; matching the last-synced state.
                      (save-excursion
                         (goto-char insert-point)
                         (org-mode-google-tasks-sync-org-write-parent-id-at-point
                          new-parent-id)))))))))))))

(defun org-mode-google-tasks-sync-engine--adjust-heading-level (text old-level new-level)
  "Adjust the heading level stars in TEXT from OLD-LEVEL to NEW-LEVEL."
  (let ((diff (- new-level old-level)))
    (if (= diff 0)
        text
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (while (re-search-forward "^\\(\\*+\\) " nil t)
          (let ((stars (match-string 1)))
            (replace-match
             (concat (make-string (max 1 (+ (length stars) diff)) ?*) " ")
             nil t)))
        (buffer-string)))))

(defun org-mode-google-tasks-sync-engine--apply-pull (list-id local remote)
  "Apply REMOTE fields onto LOCAL task struct in LIST-ID in-buffer."
  (let* ((task (org-mode-google-tasks-sync-engine--remote-task->struct
                 remote list-id (org-mode-google-tasks-sync-org-task-marker local))))
    (org-mode-google-tasks-sync-org-write-task task)
    (org-mode-google-tasks-sync-engine--log "Pulled: %s"
                                       (org-mode-google-tasks-sync-org-task-title task))))

(defun org-mode-google-tasks-sync-engine--finalize-push-etag-conflict
    (on-failure token list-id task error &optional on-success)
  "Resolve a 412 ETag conflict on pushing TASK via remote-wins semantics.

TOKEN authenticates the refetch; LIST-ID identifies the list.  Called
by the API retry layer after a PATCH whose If-Match header no longer
matches the server (someone else mutated the task since our last
pull).  Refetches TASK via `tasks.get'; quarantines the local content
when it differs from the fetched fresh copy (the loser in the
conflict); writes the fetched copy to the buffer; then calls
ON-SUCCESS — the push is finalized, but with the server's version of
the data.  On fetch failure, logs and calls ON-FAILURE with ERROR
\(the original 412 plz error), so the sync pipeline continues the
same way an un-retryable push would."
  (declare (indent 1))
  (org-mode-google-tasks-sync-api-get-task
   token list-id (org-mode-google-tasks-sync-org-task-id task)
   (lambda (fresh)
     (let ((local-differs
            (not (equal
                  (org-mode-google-tasks-sync-org-canonical-hash
                   (org-mode-google-tasks-sync-engine--remote-task->struct
                    fresh list-id nil))
                  (org-mode-google-tasks-sync-org-canonical-hash task)))))
       (when local-differs
         (org-mode-google-tasks-sync-engine--quarantine
          "local-overwritten-after-412" task))
        (org-mode-google-tasks-sync-engine--write-task-if-marker-matches
         (org-mode-google-tasks-sync-engine--remote-task->struct
          fresh list-id
          (org-mode-google-tasks-sync-org-task-marker task)))
       (org-mode-google-tasks-sync-engine--log
        "ETag conflict resolved (remote-wins): %s"
        (org-mode-google-tasks-sync-org-task-title task))
       (when on-success (funcall on-success fresh))))
   (lambda (fetch-err)
     (org-mode-google-tasks-sync-engine--log
      "412 finalization GET failed (%S); original push error: %S"
      fetch-err error)
     (when on-failure (funcall on-failure error)))))

(defun org-mode-google-tasks-sync-engine--push-update (token list-id task &optional on-success)
  "Push TASK to Google in LIST-ID using TOKEN.  Fire-and-forget with logging.
When ON-SUCCESS is non-nil it is called with the response alist after
the push succeeds and the local heading has been updated — used by
the DONE-push-then-remove path to remove the heading once the server
confirms the completion."
  (let ((on-failure
         (lambda (err)
           (org-mode-google-tasks-sync-engine--log "Push error: %S (task=%s)"
                                              err
                                              (org-mode-google-tasks-sync-org-task-title task)))))
    (org-mode-google-tasks-sync-api-patch-task
     token list-id
     (org-mode-google-tasks-sync-org-task-id task)
     (cons (cons 'id (org-mode-google-tasks-sync-org-task-id task))
           (org-mode-google-tasks-sync-engine--task->api-data task))
     (org-mode-google-tasks-sync-org-task-etag task)
      (lambda (resp)
        (let ((updated (alist-get 'updated resp))
              (etag (alist-get 'etag resp)))
          (setf (org-mode-google-tasks-sync-org-task-updated task) updated)
          (setf (org-mode-google-tasks-sync-org-task-etag task) etag)
          (when (org-mode-google-tasks-sync-org-task-marker task)
            (org-mode-google-tasks-sync-engine--write-task-if-marker-matches task)))
        (org-mode-google-tasks-sync-engine--log "Pushed: %s"
                                           (org-mode-google-tasks-sync-org-task-title task))
        (when on-success (funcall on-success resp)))
      on-failure
      ;; On 412: refetch the live task and finalize remote-wins; do NOT
      ;; blind-retry the stale PUT.  The lambda is the API-side on-412
      ;; hook, called with the 412 plz-error; the closure binds the
      ;; engine-level context (--finalize's on-failure).
      (lambda (err)
        (org-mode-google-tasks-sync-engine--finalize-push-etag-conflict
         on-failure token list-id task err on-success)))))

(defun org-mode-google-tasks-sync-engine--write-task-if-marker-matches (task)
  "Write TASK to its marker, but only if the marker still points at TASK's heading.
Async callbacks (`--push-new', `--push-update', the 412 finalizer) fire
after the engine has potentially mutated the buffer (sort, sweep,
inserts); a stale marker can land on the wrong heading and clobber it.
Verifies the heading at the marker has the same title as TASK before
writing.  On mismatch or when the marker has no live buffer: log a
warning and skip the write — the next tick's reconciliation will fix
the buffer naturally.  Returns non-nil when the write ran."
  (let ((m (org-mode-google-tasks-sync-org-task-marker task))
        (title (org-mode-google-tasks-sync-org-task-title task)))
    (if (and m (marker-buffer m))
        (with-current-buffer (marker-buffer m)
          (save-excursion
            (goto-char m)
            (org-back-to-heading t)
            (let ((actual (org-element-property
                           :raw-value (org-element-at-point))))
              (if (equal actual title)
                   (progn
                     (org-mode-google-tasks-sync-org-write-task task)
                     ;; A pull/push wrote the heading (incl. position),
                     ;; so the sync tail must sort this pass.
                     (org-mode-google-tasks-sync-engine--sort-needed-mark
                      (org-mode-google-tasks-sync-org-task-list-id task))
                     t)
                 (org-mode-google-tasks-sync-engine--log
                  "WARN: marker detached for %S; heading at marker is %S; skipping in-place write"
                  title actual)
                 nil))))
      (org-mode-google-tasks-sync-engine--log
       "WARN: no live marker for %S; skipping in-place write"
       title)
      nil)))

(defun org-mode-google-tasks-sync-engine--push-new
    (token list-id task &optional file on-success)
  "POST a new TASK to Google in LIST-ID using TOKEN.
When FILE is given and TASK has a `parent-id', pass it as the `parent'
query param to `tasks.insert' so Google knows the nesting.  Also
passes `previous' (the :GTASK_ID: of the nearest preceding synced
sibling) so Google appends the task after it — matching the local
buffer order.  Without `previous', Google inserts new tasks at the
top of the list, and the next tick's `--sort-children' would pull
the task away from where the user placed it.

When ON-SUCCESS is non-nil it is called with the response alist
after the local heading has been updated — used by the serialized
push queue to fire the next pending insert."
  (let* ((parent-id (org-mode-google-tasks-sync-engine--resolve-parent-id task))
         (previous-id (when file
                        (org-mode-google-tasks-sync-engine--prev-synced-sibling-id task)))
         (insert-args
          (delq nil
                (append (when parent-id `(("parent" . ,parent-id)))
                        (when previous-id `(("previous" . ,previous-id)))))))
    (org-mode-google-tasks-sync-api-insert-task
     token list-id
     (org-mode-google-tasks-sync-engine--task->api-data task)
     (lambda (resp)
       (org-mode-google-tasks-sync-engine--finalize-push-new task resp)
       (when on-success (funcall on-success resp)))
     (lambda (err)
       (org-mode-google-tasks-sync-engine--log "Insert error: %S (task=%s)"
                                          err
                                          (org-mode-google-tasks-sync-org-task-title task))
       ;; Advance the serialized push queue even on insert failure.
       ;; Without this, `--push-new-queue' would stall on the first
       ;; error: `done' (and therefore `--finalize-apply' → drift →
       ;; tie repair → sort → save) would never run, leaving the
       ;; buffer un-repaired and un-saved.  The failed task stays
       ;; without a :GTASK_ID: and will be re-queued on the next
       ;; tick (it's still in the local set with no ID).
       (when on-success (funcall on-success nil)))
     insert-args)))

(defun org-mode-google-tasks-sync-engine--resolve-parent-id (task)
  "Return TASK's parent-id, re-read from the buffer at fire time.
When the struct's `parent-id' is already set (parent was synced
before collection), use it.  Otherwise, look up the parent heading's
:GTASK_ID: from the buffer — this catches the case where the parent
was itself a new task pushed earlier in the same tick (its GTASK_ID
was written by the async callback between collect-time and now).
Returns nil for top-level tasks."
  (or (org-mode-google-tasks-sync-org-task-parent-id task)
      (let ((m (org-mode-google-tasks-sync-org-task-marker task)))
        (when (and m (marker-buffer m))
          (with-current-buffer (marker-buffer m)
            (save-excursion
              (goto-char m)
              (org-mode-google-tasks-sync-org--parent-id-at-point)))))))

(defun org-mode-google-tasks-sync-engine--finalize-push-new (task resp)
  "Write the server-assigned fields from RESP into TASK and its heading.
Updates the struct's id, updated, etag, position, completed, links,
and web-view-link slots, then writes the full task to the buffer via
`--write-task-if-marker-matches'.  Copying `position' from the
response is essential: without it, `--sort-children' sees an empty
position string and sorts the freshly-pushed heading to the front
of its siblings — the user perceives the heading as having
disappeared."
  (let ((links-raw (alist-get 'links resp)))
    (setf (org-mode-google-tasks-sync-org-task-id task) (alist-get 'id resp))
    (setf (org-mode-google-tasks-sync-org-task-updated task) (alist-get 'updated resp))
    (setf (org-mode-google-tasks-sync-org-task-etag task) (alist-get 'etag resp))
    (setf (org-mode-google-tasks-sync-org-task-position task) (alist-get 'position resp))
    (setf (org-mode-google-tasks-sync-org-task-completed task) (alist-get 'completed resp))
    (setf (org-mode-google-tasks-sync-org-task-links task)
          (when links-raw
            (json-serialize links-raw :null-object nil :false-object :false)))
    (setf (org-mode-google-tasks-sync-org-task-web-view-link task)
          (alist-get 'webViewLink resp)))
  (when (org-mode-google-tasks-sync-org-task-marker task)
    (org-mode-google-tasks-sync-engine--write-task-if-marker-matches task))
  (org-mode-google-tasks-sync-engine--log "Pushed new: %s"
                                     (org-mode-google-tasks-sync-org-task-title task)))

(defun org-mode-google-tasks-sync-engine--push-new-queue
    (token list-id tasks file done)
  "Push TASKS to Google serially, firing DONE when the queue is empty.
TOKEN authenticates each insert.  LIST-ID is the Google Tasks list.
Each task is pushed via `--push-new'; the next task fires only after
the previous insert's :then callback completes and writes the
GTASK_ID into the buffer.  This ensures children of a newly-pushed
parent see the parent's GTASK_ID when `--resolve-parent-id' reads
the buffer, and that `previous' reflects the just-written sibling.
FILE is the source org file.  DONE is called when the queue drains."
  (if (null tasks)
      (funcall done)
    (org-mode-google-tasks-sync-engine--push-new
     token list-id (car tasks) file
     (lambda (_resp)
       (org-mode-google-tasks-sync-engine--push-new-queue
        token list-id (cdr tasks) file done)))))

(defun org-mode-google-tasks-sync-engine--prev-synced-sibling-id (task)
  "Return the :GTASK_ID: of the nearest preceding synced sibling of TASK.
Nil when TASK is the first sibling (or when its marker is invalid).
Used by `--push-new' to pass `previous' to `tasks.insert' so Google
appends the task at the same position the user placed it locally."
  (let ((m (org-mode-google-tasks-sync-org-task-marker task)))
    (when (and m (marker-buffer m))
      (with-current-buffer (marker-buffer m)
        (save-excursion
          (goto-char m)
          (org-mode-google-tasks-sync-org--prev-sibling-id-at-point))))))

(defun org-mode-google-tasks-sync-engine--delete-local (task &optional source-file reason)
  "Remove TASK's heading from the buffer.
Snapshots TASK to the trash buffer when SOURCE-FILE is given, so
engine-side deletions (tombstones and the full-sync sweep) are
recoverable via `org-mode-google-tasks-sync-restore-at-point' —
matching what the README documents.  Interactive deletions go
through `org-mode-google-tasks-sync-delete-at-point', which
snapshots separately and leaves SOURCE-FILE nil here.
Optional REASON is `deleted' or `done-removed' (default `deleted');
it threads through to `--snapshot-to-trash' so `restore-at-point'
knows whether to reopen the original task (done-removed) or
create a fresh one (deleted)."
  (when (and source-file (fboundp 'org-mode-google-tasks-sync--snapshot-to-trash))
    (condition-case err
        (org-mode-google-tasks-sync--snapshot-to-trash task source-file reason)
      (error
       (org-mode-google-tasks-sync-engine--log
        "Trash snapshot failed (task=%s): %S"
        (org-mode-google-tasks-sync-org-task-title task) err))))
  (when (org-mode-google-tasks-sync-org-task-marker task)
    (let ((m (org-mode-google-tasks-sync-org-task-marker task)))
      (if (and m (marker-buffer m))
          (with-current-buffer (marker-buffer m)
            (save-excursion
              (goto-char m)
              (org-back-to-heading t)
              (let ((begin (point))
                    (end (save-excursion (org-end-of-subtree t t) (point))))
                (delete-region begin end))))
        (org-mode-google-tasks-sync-engine--log
         "WARN: delete-local marker has no buffer for %S; skipping in-place deletion"
         (org-mode-google-tasks-sync-org-task-title task)))))
  (org-mode-google-tasks-sync-engine--log "Deleted local: %s"
                                     (org-mode-google-tasks-sync-org-task-title task)))

(defun org-mode-google-tasks-sync-engine--remove-done-local (task file)
  "Remove the DONE TASK from the buffer and snapshot to trash as done-removed.
FILE is the source org file (used for the trash :SOURCE_FILE:).
Delegates to `--delete-local' with REASON `done-removed' so
`restore-at-point' knows the task still exists server-side and can
reopen it rather than creating a duplicate."
  (org-mode-google-tasks-sync-engine--delete-local task file 'done-removed))

(defun org-mode-google-tasks-sync-engine--push-and-remove-on-done
    (token list-id local file)
  "Push LOCAL (completed) to Google via TOKEN, then remove from the buffer.
LIST-ID is the Google Tasks list.  The removal happens in the
success callback, only after the server returns the completed task.
On error the local heading is left in place and logged.  Uses FILE
for the trash snapshot."
  (org-mode-google-tasks-sync-engine--push-update
   token list-id local
   (lambda (_resp)
     (org-mode-google-tasks-sync-engine--remove-done-local local file))))

(defun org-mode-google-tasks-sync-engine-discover-lists ()
  "Fetch and print available task lists."
  (let ((token (org-mode-google-tasks-sync-engine--token)))
    (org-mode-google-tasks-sync-api-list-tasklists
     token
     (lambda (lists)
       (with-current-buffer (get-buffer-create "*Google Tasks Lists*")
         (erase-buffer)
         (insert "Google Tasks lists for this account:\n\n")
         (dolist (l (append lists nil))
           (insert (format "  %s  %s\n"
                           (alist-get 'id l) (alist-get 'title l))))
         (insert
          "\nAdd entries to your `org-mode-google-tasks-sync-map' like:\n\n"
          "(setq org-mode-google-tasks-sync-map\n"
          "      '((\"<list-id>\" . (\"~/org/tasks.org\" . \"Tasks\"))))\n")
         (pop-to-buffer (current-buffer))))
     (lambda (err)
       (message "Could not fetch lists: %S" err)))))

;;;###autoload
(defun org-mode-google-tasks-sync-engine-discover-lists-batch ()
  "Print task lists to stdout as `ID<TAB>TITLE' lines.
Designed for `emacs --batch'.  Requires a refresh token already stored
in auth-source (run `M-x org-mode-google-tasks-sync-authorize'
interactively at least once first).  Performs the HTTPS call
synchronously so the output is complete before Emacs exits."
  (let* ((token (org-mode-google-tasks-sync-engine--token))
         (body (plz 'get
                 (concat org-mode-google-tasks-sync-api--base-url
                         "/users/@me/lists")
                 :headers (org-mode-google-tasks-sync-api--auth-header token)
                 :as 'string))
         (lists (alist-get 'items
                           (org-mode-google-tasks-sync-api--parse-json body))))
    (dolist (l (append lists nil))
      (princ (format "%s\t%s\n"
                     (alist-get 'id l)
                     (alist-get 'title l))))))

(provide 'org-mode-google-tasks-sync-engine)
;;; org-mode-google-tasks-sync-engine.el ends here
