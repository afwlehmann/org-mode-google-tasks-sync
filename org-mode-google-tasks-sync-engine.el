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

(defconst org-mode-google-tasks-sync-engine--log-buffer-name
  "*org-mode-google-tasks-sync-log*")

(defconst org-mode-google-tasks-sync-engine--conflicts-buffer-name
  "*Google Tasks Conflicts*")

(defcustom org-mode-google-tasks-sync-fetch-timeout 300
  "Seconds after which a sync in flight is considered hung.
When this many seconds pass between entering the `fetching' state
and returning to `idle', the engine forcibly resets state so the
next tick can try again.  Bump this if you have many lists or a
slow network and healthy syncs are being treated as hung."
  :type 'integer
  :group 'org-mode-google-tasks-sync)

(defvar org-mode-google-tasks-sync-engine--state 'idle
  "Current sync state.  One of idle, fetching, applying, pushing.")

(defvar org-mode-google-tasks-sync-engine--timeout-timer nil
  "Timer that resets state if a sync hangs past `org-mode-google-tasks-sync-fetch-timeout'.")

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
  "Append a timestamped line to the log buffer."
  (with-current-buffer (org-mode-google-tasks-sync-engine-log-buffer)
    (goto-char (point-max))
    (insert (format-time-string "[%Y-%m-%d %H:%M:%S] ")
            (apply #'format fmt args)
            "\n")))

(defun org-mode-google-tasks-sync-engine--log-debug (fmt &rest args)
  "Like `--log', but only emits at debug log-level.
Use for per-request diagnostics (body length/bytes, encoding flags)
that would be too noisy at the default `info' level."
  (when (eq (bound-and-true-p org-mode-google-tasks-sync-log-level) 'debug)
    (apply #'org-mode-google-tasks-sync-engine--log fmt args)))

(defun org-mode-google-tasks-sync-engine--remote-task->struct (remote list-id existing-marker)
  "Build a task struct from a REMOTE alist.  Carries EXISTING-MARKER if known."
  (make-org-mode-google-tasks-sync-org-task
   :id        (alist-get 'id remote)
   :list-id   list-id
   :title     (or (alist-get 'title remote) "")
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
   :marker    existing-marker))

(defun org-mode-google-tasks-sync-engine--remote-due (remote)
  "Extract YYYY-MM-DD from the REMOTE task's `due' RFC3339 string."
  (let ((due (alist-get 'due remote)))
    (when (and due (>= (length due) 10))
      (substring due 0 10))))

(defun org-mode-google-tasks-sync-engine--task->api-data (task)
  "Convert a TASK struct to the alist payload for the Tasks API."
  (let ((data `((title . ,(or (org-mode-google-tasks-sync-org-task-title task) ""))
                (notes . ,(or (org-mode-google-tasks-sync-org-task-notes task) ""))
                (status . ,(symbol-name
                            (or (org-mode-google-tasks-sync-org-task-status task)
                                'needsAction))))))
    (when (org-mode-google-tasks-sync-org-task-due task)
      (push (cons 'due (concat (org-mode-google-tasks-sync-org-task-due task)
                               "T00:00:00.000Z"))
            data))
    data))

(defun org-mode-google-tasks-sync-engine--decide (local-changed remote-changed local-mtime remote-updated)
  "Return one of: skip, push, pull, conflict-local-wins, conflict-remote-wins."
  (cond
   ((and (not local-changed) (not remote-changed)) 'skip)
   ((and local-changed (not remote-changed)) 'push)
   ((and (not local-changed) remote-changed) 'pull)
   (t (if (org-mode-google-tasks-sync-engine--remote-newer-p local-mtime remote-updated)
          'conflict-remote-wins
        'conflict-local-wins))))

(defun org-mode-google-tasks-sync-engine--remote-newer-p (local-mtime remote-updated)
  "Return non-nil if REMOTE-UPDATED is after LOCAL-MTIME.
LOCAL-MTIME is float-time; REMOTE-UPDATED is RFC3339 string."
  (let ((remote-ft (org-mode-google-tasks-sync-engine--rfc3339-to-float remote-updated)))
    (and remote-ft (> remote-ft (or local-mtime 0)))))

(defun org-mode-google-tasks-sync-engine--rfc3339-to-float (s)
  "Convert RFC3339 string S to float-time, or nil."
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
  "Return a token, refreshing from auth-source as needed."
  (or org-mode-google-tasks-sync-engine--token
      (setq org-mode-google-tasks-sync-engine--token
            (org-mode-google-tasks-sync-oauth-make-token))))

(defun org-mode-google-tasks-sync-engine-run (mode)
  "Run a sync pass.  MODE is `incremental' or `full'."
  (cond
   ((not (eq org-mode-google-tasks-sync-engine--state 'idle))
    (org-mode-google-tasks-sync-engine--log "Skip tick: sync in flight (state=%s)"
                                       org-mode-google-tasks-sync-engine--state))
   ((not (bound-and-true-p org-mode-google-tasks-sync-map))
    (org-mode-google-tasks-sync-engine--log
     "No lists configured (org-mode-google-tasks-sync-map empty)"))
   (t
    ;; Fetch the token BEFORE transitioning to `fetching'.  This is the
    ;; only synchronous step that can throw (e.g. EasyPG can't find gpg),
    ;; and we don't want a failure here to leave the state machine stuck
    ;; at `fetching' forever — that would make every subsequent tick
    ;; take the `Skip tick: sync in flight' early-return.
    (let ((token (org-mode-google-tasks-sync-engine--token))
          (entries org-mode-google-tasks-sync-map))
      (setq org-mode-google-tasks-sync-engine--state 'fetching)
      (setq org-mode-google-tasks-sync-engine--last-sync-time (float-time))
      (org-mode-google-tasks-sync-engine--arm-timeout)
      ;; We don't log "Begin sync" here — most ticks finish with no actual
      ;; pull/push activity, and a per-cycle "begin"/"complete" pair drowns
      ;; the log.  Per-action lines below (Pushed, Pulled, Deleted, …) are
      ;; the actual signal.
      (org-mode-google-tasks-sync-engine--sync-next entries token mode)))))

(defun org-mode-google-tasks-sync-engine--arm-timeout ()
  "Arm the hung-sync timeout."
  (when org-mode-google-tasks-sync-engine--timeout-timer
    (cancel-timer org-mode-google-tasks-sync-engine--timeout-timer))
  (setq org-mode-google-tasks-sync-engine--timeout-timer
        (run-at-time org-mode-google-tasks-sync-fetch-timeout nil
                     #'org-mode-google-tasks-sync-engine--on-timeout)))

(defun org-mode-google-tasks-sync-engine--cancel-timeout ()
  "Cancel any in-flight hung-sync timer."
  (when org-mode-google-tasks-sync-engine--timeout-timer
    (cancel-timer org-mode-google-tasks-sync-engine--timeout-timer)
    (setq org-mode-google-tasks-sync-engine--timeout-timer nil)))

(defun org-mode-google-tasks-sync-engine--on-timeout ()
  "Called when a sync hangs past `org-mode-google-tasks-sync-fetch-timeout'.
Resets state so the next tick can try again.  Stale plz callbacks
may still fire afterwards; they'll be effectively no-ops on the
state machine because state has already moved back to `idle'."
  (setq org-mode-google-tasks-sync-engine--timeout-timer nil)
  (when (not (eq org-mode-google-tasks-sync-engine--state 'idle))
    (org-mode-google-tasks-sync-engine--log
     "Sync hung past %ss in state=%s; resetting to idle"
     org-mode-google-tasks-sync-fetch-timeout
     org-mode-google-tasks-sync-engine--state)
    (setq org-mode-google-tasks-sync-engine--state 'idle)))

(defun org-mode-google-tasks-sync-engine--sync-next (entries token mode)
  "Drive sync sequentially over ENTRIES."
  (if (null entries)
      (progn
        (setq org-mode-google-tasks-sync-engine--state 'idle)
        ;; Bump last-sync-time AFTER all per-list saves so the tick
        ;; predicate sees mtime <= last-sync-time on the next round
        ;; and doesn't re-fire on our own writes.
        (setq org-mode-google-tasks-sync-engine--last-sync-time (float-time))
        (org-mode-google-tasks-sync-engine--cancel-timeout))
    (let* ((entry (car entries))
           (list-id (car entry))
           (file (car (cdr entry)))
           (parent (cdr (cdr entry))))
      (org-mode-google-tasks-sync-engine--sync-one
       token list-id file parent mode
       (lambda () (org-mode-google-tasks-sync-engine--sync-next (cdr entries) token mode))))))

(defun org-mode-google-tasks-sync-engine--sync-one (token list-id file parent mode done)
  "Sync one list end-to-end, calling DONE when finished."
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
       (org-mode-google-tasks-sync-engine--apply
        token list-id file parent mode remote-tasks done))
     (lambda (err)
       (org-mode-google-tasks-sync-engine--log "Fetch error for list %s: %S" list-id err)
       (funcall done)))))

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

(defun org-mode-google-tasks-sync-engine--apply
    (token list-id file parent mode remote-tasks done)
  "Reconcile REMOTE-TASKS against the local subtree under PARENT in FILE."
  (setq org-mode-google-tasks-sync-engine--state 'applying)
  (with-current-buffer (find-file-noselect file)
    (let* ((local (org-mode-google-tasks-sync-org-collect-tasks-under file parent list-id))
           (local-by-id (make-hash-table :test 'equal))
           (remote-by-id (make-hash-table :test 'equal))
           (parent-marker (org-mode-google-tasks-sync-engine--parent-marker file parent)))
      (dolist (l local)
        (when (org-mode-google-tasks-sync-org-task-id l)
          (puthash (org-mode-google-tasks-sync-org-task-id l) l local-by-id)))
      (dolist (r (append remote-tasks nil))
        (puthash (alist-get 'id r) r remote-by-id))
      (dolist (r (append remote-tasks nil))
        (org-mode-google-tasks-sync-engine--reconcile-one
         token list-id parent-marker r local-by-id))
      (when (eq mode 'full)
        (maphash
         (lambda (id local-task)
           (unless (gethash id remote-by-id)
             (org-mode-google-tasks-sync-engine--delete-local local-task)))
         local-by-id))
      (dolist (l local)
        (unless (org-mode-google-tasks-sync-org-task-id l)
          (org-mode-google-tasks-sync-engine--push-new token list-id l)))
      (org-mode-google-tasks-sync-engine--sort-children parent-marker)
      (org-mode-google-tasks-sync-engine--set-last-sync
       file (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t))
      (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
        (save-buffer))))
  (funcall done))

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
  "Compare two `--task-sort-key' tuples.
TODOs come before DONEs; among TODOs, position ascending; among DONEs,
completed timestamp descending (newest first)."
  (cond
   ((and (not (nth 0 a)) (nth 0 b)) t)
   ((and (nth 0 a) (not (nth 0 b))) nil)
   ((nth 0 a) (string> (nth 2 a) (nth 2 b)))
   (t         (string< (nth 1 a) (nth 1 b)))))

(defun org-mode-google-tasks-sync-engine--sort-children (parent-marker)
  "Sort children of PARENT-MARKER by `--task-sort-key' / `--compare-tasks'.
Returns silently when PARENT-MARKER is nil or points at no heading."
  (when (and parent-marker (marker-buffer parent-marker))
    (save-excursion
      (goto-char parent-marker)
      (when (org-at-heading-p)
        (condition-case err
            (org-sort-entries nil ?f
                              #'org-mode-google-tasks-sync-engine--task-sort-key
                              #'org-mode-google-tasks-sync-engine--compare-tasks)
          (error
           (org-mode-google-tasks-sync-engine--log
            "Sort skipped: %S" err)))))))

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
    (token list-id parent-marker remote local-by-id)
  "Apply the 4-cell matrix to REMOTE against the local task (if any)."
  (let* ((id (alist-get 'id remote))
         (deleted (alist-get 'deleted remote))
         (local (gethash id local-by-id)))
    (cond
     ((eq deleted t)
      (when local (org-mode-google-tasks-sync-engine--delete-local local)))
     ((null local)
      (let* ((task (org-mode-google-tasks-sync-engine--remote-task->struct
                    remote list-id nil)))
        (when parent-marker
          (org-mode-google-tasks-sync-org-insert-task-under parent-marker task)
          (org-mode-google-tasks-sync-engine--log "Pulled new: %s"
                                             (org-mode-google-tasks-sync-org-task-title task)))))
     (t
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
                        (alist-get 'updated remote))))
        (pcase decision
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
           (org-mode-google-tasks-sync-engine--push-update token list-id local))))))))

(defun org-mode-google-tasks-sync-engine--marker-mtime (marker)
  "Return float-time of the file backing MARKER, or nil."
  (let ((buf (marker-buffer marker)))
    (when (and buf (buffer-file-name buf))
      (let ((attrs (file-attributes (buffer-file-name buf))))
        (when attrs (float-time (file-attribute-modification-time attrs)))))))

(defun org-mode-google-tasks-sync-engine--apply-pull (list-id local remote)
  "Apply REMOTE fields onto LOCAL task struct in-buffer."
  (let* ((task (org-mode-google-tasks-sync-engine--remote-task->struct
                remote list-id (org-mode-google-tasks-sync-org-task-marker local))))
    (org-mode-google-tasks-sync-org-write-task task)
    (org-mode-google-tasks-sync-engine--log "Pulled: %s"
                                       (org-mode-google-tasks-sync-org-task-title task))))

(defun org-mode-google-tasks-sync-engine--push-update (token list-id task)
  "PATCH TASK to Google.  Fire-and-forget with logging."
  (org-mode-google-tasks-sync-api-patch-task
   token list-id
   (org-mode-google-tasks-sync-org-task-id task)
   (org-mode-google-tasks-sync-engine--task->api-data task)
   (org-mode-google-tasks-sync-org-task-etag task)
   (lambda (resp)
     (let ((updated (alist-get 'updated resp))
           (etag (alist-get 'etag resp)))
       (setf (org-mode-google-tasks-sync-org-task-updated task) updated)
       (setf (org-mode-google-tasks-sync-org-task-etag task) etag)
       (when (org-mode-google-tasks-sync-org-task-marker task)
         (save-excursion
           (goto-char (org-mode-google-tasks-sync-org-task-marker task))
           (org-mode-google-tasks-sync-org-write-task task))))
     (org-mode-google-tasks-sync-engine--log "Pushed: %s"
                                        (org-mode-google-tasks-sync-org-task-title task)))
   (lambda (err)
     (org-mode-google-tasks-sync-engine--log "Push error: %S (task=%s)"
                                        err
                                        (org-mode-google-tasks-sync-org-task-title task)))))

(defun org-mode-google-tasks-sync-engine--push-new (token list-id task)
  "POST a new TASK to Google."
  (org-mode-google-tasks-sync-api-insert-task
   token list-id
   (org-mode-google-tasks-sync-engine--task->api-data task)
   (lambda (resp)
     (setf (org-mode-google-tasks-sync-org-task-id task) (alist-get 'id resp))
     (setf (org-mode-google-tasks-sync-org-task-updated task) (alist-get 'updated resp))
     (setf (org-mode-google-tasks-sync-org-task-etag task) (alist-get 'etag resp))
     (when (org-mode-google-tasks-sync-org-task-marker task)
       (save-excursion
         (goto-char (org-mode-google-tasks-sync-org-task-marker task))
         (org-mode-google-tasks-sync-org-write-task task)))
     (org-mode-google-tasks-sync-engine--log "Pushed new: %s"
                                        (org-mode-google-tasks-sync-org-task-title task)))
   (lambda (err)
     (org-mode-google-tasks-sync-engine--log "Insert error: %S (task=%s)"
                                        err
                                        (org-mode-google-tasks-sync-org-task-title task)))))

(defun org-mode-google-tasks-sync-engine--delete-local (task)
  "Remove TASK's heading from the buffer."
  (when (org-mode-google-tasks-sync-org-task-marker task)
    (save-excursion
      (goto-char (org-mode-google-tasks-sync-org-task-marker task))
      (org-back-to-heading t)
      (let ((begin (point))
            (end (save-excursion (org-end-of-subtree t t) (point))))
        (delete-region begin end))))
  (org-mode-google-tasks-sync-engine--log "Deleted local: %s"
                                     (org-mode-google-tasks-sync-org-task-title task)))

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
