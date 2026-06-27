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

(defvar org-mode-google-tasks-sync-engine--state 'idle
  "Current sync state.  One of idle, fetching, applying, pushing.")

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
    (setq org-mode-google-tasks-sync-engine--state 'fetching)
    (org-mode-google-tasks-sync-engine--log "Begin %s sync" mode)
    (let ((token (org-mode-google-tasks-sync-engine--token))
          (entries org-mode-google-tasks-sync-map))
      (org-mode-google-tasks-sync-engine--sync-next entries token mode)))))

(defun org-mode-google-tasks-sync-engine--sync-next (entries token mode)
  "Drive sync sequentially over ENTRIES."
  (if (null entries)
      (progn
        (setq org-mode-google-tasks-sync-engine--state 'idle)
        (org-mode-google-tasks-sync-engine--log "Sync complete"))
    (let* ((entry (car entries))
           (list-id (car entry))
           (file (car (cdr entry)))
           (parent (cdr (cdr entry))))
      (org-mode-google-tasks-sync-engine--sync-one
       token list-id file parent mode
       (lambda () (org-mode-google-tasks-sync-engine--sync-next (cdr entries) token mode))))))

(defun org-mode-google-tasks-sync-engine--sync-one (token list-id file parent mode done)
  "Sync one list end-to-end, calling DONE when finished."
  (let ((args (if (eq mode 'full) '()
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
      (org-mode-google-tasks-sync-engine--set-last-sync
       file (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t))
      (save-buffer)))
  (funcall done))

(defun org-mode-google-tasks-sync-engine--parent-marker (file parent)
  "Return marker of PARENT heading in FILE."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward (format "^\\*+ %s" (regexp-quote parent)) nil t)
        (point-marker)))))

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

(provide 'org-mode-google-tasks-sync-engine)
;;; org-mode-google-tasks-sync-engine.el ends here
