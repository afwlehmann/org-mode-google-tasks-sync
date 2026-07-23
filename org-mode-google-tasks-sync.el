;;; org-mode-google-tasks-sync.el --- Two-way sync between org-mode and Google Tasks -*- lexical-binding: t -*-

;; Copyright (C) 2026 Alexander Lehmann
;; SPDX-License-Identifier: MIT

;; Author: Alexander Lehmann <afwlehmann@googlemail.com>
;; Version: 0.3.1
;; Package-Requires: ((emacs "27.1") (plz "0.7") (oauth2 "0.16") (org "9.5"))
;; Keywords: org, calendar, tools

;;; Commentary:

;; Pure Elisp two-way sync between org-mode and Google Tasks.  Syncs while
;; Emacs is open via a timer plus `after-save-hook'.  Last-write-wins with
;; conflict quarantine.  See README.md for setup and usage.

;;; Code:

(require 'cl-lib)
(require 'org-mode-google-tasks-sync-oauth)
(require 'org-mode-google-tasks-sync-api)
(require 'org-mode-google-tasks-sync-org)
(require 'org-mode-google-tasks-sync-engine)

(defgroup org-mode-google-tasks-sync nil
  "Two-way sync between Org mode and Google Tasks."
  :group 'org
  :prefix "org-mode-google-tasks-sync-")

(defcustom org-mode-google-tasks-sync-map nil
  "Alist mapping Google Tasks list IDs to org file + parent heading.
Each entry has the form (LIST-ID . (FILE . PARENT-HEADING)).
Sync touches only direct children under PARENT-HEADING in FILE."
  :type '(alist :key-type string
                :value-type (cons file string))
  :group 'org-mode-google-tasks-sync)

(defcustom org-mode-google-tasks-sync-tick-interval 60
  "Seconds between wake-up checks while `org-mode-google-tasks-sync-mode' is on.
Each tick runs a cheap predicate (no network) that decides whether a
full sync is due — see `org-mode-google-tasks-sync--should-sync-p'.
Lower values make sync more responsive to external file edits; higher
values reduce wake-up overhead."
  :type 'integer
  :group 'org-mode-google-tasks-sync)

(defcustom org-mode-google-tasks-sync-poll-interval 300
  "Maximum seconds between syncs.
Acts as a safety net so Google-side changes get pulled even when no
local file has been modified.  When the tick predicate sees that this
many seconds have passed since the last successful sync, it triggers
one regardless of file mtimes."
  :type 'integer
  :group 'org-mode-google-tasks-sync)

(defcustom org-mode-google-tasks-sync-full-sync-interval 86400
  "Seconds between full reconciliation passes (deletion detection)."
  :type 'integer
  :group 'org-mode-google-tasks-sync)

(defcustom org-mode-google-tasks-sync-log-level 'info
  "Log verbosity for the sync engine.
`info' (default) logs sync actions (pulls, pushes, deletes, conflicts).
`debug' additionally logs per-request diagnostics (body length/bytes,
encoding flags) useful for diagnosing push failures."
  :type '(choice (const :tag "Info" info)
                 (const :tag "Debug" debug))
  :group 'org-mode-google-tasks-sync)

(defvar org-mode-google-tasks-sync--timer nil
  "Timer object for the incremental sync tick.")

(defvar org-mode-google-tasks-sync--full-timer nil
  "Timer object for the periodic full reconciliation pass.")

(defvar org-mode-google-tasks-sync-command-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "S") #'org-mode-google-tasks-sync-setup)
    (define-key m (kbd "s") #'org-mode-google-tasks-sync)
    (define-key m (kbd "f") #'org-mode-google-tasks-sync-full-sync)
    (define-key m (kbd "n") #'org-mode-google-tasks-sync-new-task)
    (define-key m (kbd "d") #'org-mode-google-tasks-sync-delete-at-point)
    (define-key m (kbd "h") #'org-mode-google-tasks-sync-hide-done-mode)
    (define-key m (kbd "H") #'org-mode-google-tasks-sync-show-done)
    (define-key m (kbd "r") #'org-mode-google-tasks-sync-show-trash)
    (define-key m (kbd "R") #'org-mode-google-tasks-sync-restore-at-point)
    (define-key m (kbd "l") #'org-mode-google-tasks-sync-show-log)
    (define-key m (kbd "c") #'org-mode-google-tasks-sync-show-conflicts)
    m)
  "Single-letter keymap for the package's interactive commands.
Bind this map under whatever prefix suits you.  The README's
recommendation is `C-c g' — that prefix is unused by Org mode and
by org-roam (which lives at `C-c n'), so:

  (global-set-key (kbd \"C-c g\") org-mode-google-tasks-sync-command-map)

gives you `C-c g s' for sync, `C-c g n' for new task, `C-c g h' to
toggle hide-DONE, and so on.")

(defcustom org-mode-google-tasks-sync-keep-done-items nil
  "Whether to keep completed (DONE) tasks in the local org buffer.
When nil (the default), tasks marked DONE on the server are removed
from the local buffer after being snapshotted to the trash buffer,
and locally-DONE tasks are pushed to the server as completed then
removed from the local buffer once the server confirms.  Conflicts
always resolve in favor of the remote side.  When non-nil, completed
tasks are synced two-way (the historical behavior).

This is a breaking change: users upgrading from a version that
always kept DONE headings will, after upgrading, see completed tasks
start disappearing from the org buffer.  Set this to non-nil to
restore the prior behavior."
  :type 'boolean
  :group 'org-mode-google-tasks-sync)

(defcustom org-mode-google-tasks-sync-hide-done-by-default nil
  "Whether to auto-enable `org-mode-google-tasks-sync-hide-done-mode'.
When non-nil, opening any file referenced by
`org-mode-google-tasks-sync-map' turns the mode on automatically.
Per-buffer; the minor mode itself is opt-in for other files."
  :type 'boolean
  :group 'org-mode-google-tasks-sync)

(defconst org-mode-google-tasks-sync--hide-done-spec
  'org-mode-google-tasks-sync-hide-done
  "Invisibility-spec symbol used by the hide-DONE minor mode.")

(defun org-mode-google-tasks-sync--done-keyword-p (kw)
  "Return non-nil if KW is a done keyword in the current org buffer."
  (and kw (member kw (or (and (boundp 'org-done-keywords) org-done-keywords)
                         '("DONE")))))

(defun org-mode-google-tasks-sync--apply-done-overlay-at-point ()
  "Cover the heading + subtree at point with an invisibility overlay.
Idempotent — removes any prior hide-done overlay on the same range
before adding."
  (save-excursion
    (org-back-to-heading t)
    (let ((begin (line-beginning-position))
          (end   (save-excursion (org-end-of-subtree t t) (point))))
      (dolist (o (overlays-in begin end))
        (when (eq (overlay-get o 'invisible)
                  org-mode-google-tasks-sync--hide-done-spec)
          (delete-overlay o)))
      (let ((ov (make-overlay begin end)))
        (overlay-put ov 'invisible org-mode-google-tasks-sync--hide-done-spec)
        (overlay-put ov 'evaporate t)))))

(defun org-mode-google-tasks-sync--remove-done-overlay-at-point ()
  "Remove any hide-done overlay covering the heading at point."
  (save-excursion
    (org-back-to-heading t)
    (let ((begin (line-beginning-position))
          (end   (save-excursion (org-end-of-subtree t t) (point))))
      (dolist (o (overlays-in begin end))
        (when (eq (overlay-get o 'invisible)
                  org-mode-google-tasks-sync--hide-done-spec)
          (delete-overlay o))))))

(defun org-mode-google-tasks-sync--apply-done-overlays-in-buffer ()
  "Walk the buffer; apply a hide-done overlay to every DONE-keyword headline."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward org-heading-regexp nil t)
      (when (org-mode-google-tasks-sync--done-keyword-p (org-get-todo-state))
        (org-mode-google-tasks-sync--apply-done-overlay-at-point)))))

(defun org-mode-google-tasks-sync--remove-done-overlays-in-buffer ()
  "Remove every hide-done overlay in the buffer."
  (save-restriction
    (widen)
    (dolist (o (overlays-in (point-min) (point-max)))
      (when (eq (overlay-get o 'invisible)
                org-mode-google-tasks-sync--hide-done-spec)
        (delete-overlay o)))))

(defun org-mode-google-tasks-sync--on-todo-state-change ()
  "Maintain the hide-done overlay when a heading transitions in/out of DONE."
  (when (bound-and-true-p org-mode-google-tasks-sync-hide-done-mode)
    (if (org-mode-google-tasks-sync--done-keyword-p (org-get-todo-state))
        (org-mode-google-tasks-sync--apply-done-overlay-at-point)
      (org-mode-google-tasks-sync--remove-done-overlay-at-point))))

;;;###autoload
(define-minor-mode org-mode-google-tasks-sync-hide-done-mode
  "Hide DONE-keyword headlines and their subtrees in the current buffer.
Uses an invisibility overlay keyed by
`org-mode-google-tasks-sync--hide-done-spec' so other folding (org-fold,
narrow-to-subtree, etc.) is unaffected.

To bring a task back from DONE to TODO when you've hit
\\<org-mode-map>\\[org-todo] by mistake, run
`M-x org-mode-google-tasks-sync-show-done', navigate to the task,
\\[org-todo] again, then turn this mode back on."
  :lighter " GTasks-Hide"
  :group 'org-mode-google-tasks-sync
  (if org-mode-google-tasks-sync-hide-done-mode
      (progn
        (add-to-invisibility-spec org-mode-google-tasks-sync--hide-done-spec)
        (org-mode-google-tasks-sync--apply-done-overlays-in-buffer)
        (add-hook 'org-after-todo-state-change-hook
                  #'org-mode-google-tasks-sync--on-todo-state-change
                  nil t))
    (remove-hook 'org-after-todo-state-change-hook
                 #'org-mode-google-tasks-sync--on-todo-state-change
                 t)
    (org-mode-google-tasks-sync--remove-done-overlays-in-buffer)
    (remove-from-invisibility-spec org-mode-google-tasks-sync--hide-done-spec)))

;;;###autoload
(defun org-mode-google-tasks-sync-show-done ()
  "Temporarily reveal DONE tasks by turning off the hide-done minor mode.
Convenience wrapper — equivalent to
`(org-mode-google-tasks-sync-hide-done-mode -1)' from a key binding."
  (interactive)
  (org-mode-google-tasks-sync-hide-done-mode -1))

(defun org-mode-google-tasks-sync--maybe-enable-hide-done ()
  "Auto-enable hide-done in a buffer if the file is a configured target.
Used as a `find-file-hook' when
`org-mode-google-tasks-sync-hide-done-by-default' is non-nil."
  (when (and org-mode-google-tasks-sync-hide-done-by-default
             (derived-mode-p 'org-mode)
             (org-mode-google-tasks-sync--file-is-target-p (buffer-file-name)))
    (org-mode-google-tasks-sync-hide-done-mode 1)))

(add-hook 'find-file-hook #'org-mode-google-tasks-sync--maybe-enable-hide-done)

(defconst org-mode-google-tasks-sync--trash-buffer-name
  "*org-mode-google-tasks-sync-trash*")

(defcustom org-mode-google-tasks-sync-persist-trash t
  "When non-nil, persist the deletion trash buffer to disk.
File path is `$XDG_DATA_HOME/org-mode-google-tasks-sync/trash.org'.
Survives Emacs restarts so accidental deletions remain recoverable
across sessions."
  :type 'boolean
  :group 'org-mode-google-tasks-sync)

(defun org-mode-google-tasks-sync--trash-file ()
  "Return the on-disk path of the deletion trash, or nil if disabled."
  (when org-mode-google-tasks-sync-persist-trash
    (expand-file-name
     "org-mode-google-tasks-sync/trash.org"
     (or (getenv "XDG_DATA_HOME")
         (expand-file-name "~/.local/share")))))

(defun org-mode-google-tasks-sync--trash-buffer ()
  "Return the trash buffer, creating + loading from disk if needed."
  (let ((buf (get-buffer org-mode-google-tasks-sync--trash-buffer-name)))
    (or buf
        (let ((b (get-buffer-create org-mode-google-tasks-sync--trash-buffer-name))
              (path (org-mode-google-tasks-sync--trash-file)))
          (with-current-buffer b
            (org-mode)
            (when (and path (file-exists-p path))
              (insert-file-contents path))
            (setq-local org-mode-google-tasks-sync--trash-source-path path))
          b))))

(defun org-mode-google-tasks-sync--trash-persist ()
  "If trash persistence is enabled, write the trash buffer to disk."
  (let ((path (org-mode-google-tasks-sync--trash-file)))
    (when path
      (make-directory (file-name-directory path) t)
      (with-current-buffer (org-mode-google-tasks-sync--trash-buffer)
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (write-region (point-min) (point-max) path nil 'quiet))))))

(defun org-mode-google-tasks-sync--snapshot-to-trash (task source-file &optional reason)
  "Append a snapshot of TASK to the trash buffer.  SOURCE-FILE is where it lived.
Optional REASON is the symbol `deleted' (server-side delete) or
`done-removed' (completed on server, removed locally because
`org-mode-google-tasks-sync-keep-done-items' is nil).  Defaults to
`deleted'.  The reason drives which restore path `restore-at-point'
takes: a `done-removed' task still exists server-side as completed,
so restoring reopens it (patch status=needsAction) rather than
creating a fresh task."
  (let* ((rem (or reason 'deleted))
         (marker (org-mode-google-tasks-sync-org-task-marker task))
         (parent-id (when (and marker (marker-buffer marker))
                      (with-current-buffer (marker-buffer marker)
                        (save-excursion
                          (goto-char marker)
                          (org-mode-google-tasks-sync-org--parent-id-at-point)))))
         (prev-sibling-id (when (and marker (marker-buffer marker))
                            (with-current-buffer (marker-buffer marker)
                              (save-excursion
                                (goto-char marker)
                                (org-mode-google-tasks-sync-org--prev-sibling-id-at-point))))))
    (with-current-buffer (org-mode-google-tasks-sync--trash-buffer)
      (goto-char (point-min))
      (insert
       (format
        "* %s\n  :PROPERTIES:\n  :DELETED_AT: %s\n  :SOURCE_FILE: %s\n  :GTASK_LIST: %s\n  :GTASK_ID_ORIG: %s\n  :GTASK_ID: %s\n  :GTASK_STATUS: %s\n  :GTASK_REMOVAL_REASON: %s\n%s%s%s%s  :END:\n%s\n\n"
        (or (org-mode-google-tasks-sync-org-task-title task) "<no title>")
        (format-time-string "%Y-%m-%dT%H:%M:%S")
        (or source-file "")
        (or (org-mode-google-tasks-sync-org-task-list-id task) "")
        (or (org-mode-google-tasks-sync-org-task-id task) "")
        (or (org-mode-google-tasks-sync-org-task-id task) "")
        (symbol-name (or (org-mode-google-tasks-sync-org-task-status task)
                         'needsAction))
        (symbol-name rem)
        (if (org-mode-google-tasks-sync-org-task-due task)
            (format "  :GTASK_DUE: %s\n"
                    (org-mode-google-tasks-sync-org-task-due task))
          "")
        (if (org-mode-google-tasks-sync-org-task-completed task)
            (format "  :GTASK_COMPLETED: %s\n"
                    (org-mode-google-tasks-sync-org-task-completed task))
          "")
        (if (org-mode-google-tasks-sync-org-task-position task)
            (format "  :GTASK_POSITION: %s\n"
                    (org-mode-google-tasks-sync-org-task-position task))
          "")
        (cond
         ((eq rem 'done-removed)
          (concat
           (when (org-mode-google-tasks-sync-org-task-updated task)
             (format "  :GTASK_UPDATED: %s\n"
                     (org-mode-google-tasks-sync-org-task-updated task)))
           (when (org-mode-google-tasks-sync-org-task-etag task)
             (format "  :GTASK_ETAG: %s\n"
                     (org-mode-google-tasks-sync-org-task-etag task)))))
         (t (concat
             (when parent-id
               (format "  :GTASK_PARENT_ID: %s\n" parent-id))
             (when prev-sibling-id
               (format "  :GTASK_PREV_SIBLING: %s\n" prev-sibling-id)))))
        (or (org-mode-google-tasks-sync-org-task-notes task) "")))
      (org-mode-google-tasks-sync--trash-persist))))

;;;###autoload
(defun org-mode-google-tasks-sync-delete-at-point ()
  "Delete the task at point on Google and locally.
Prompts for confirmation.  The deleted task is snapshotted into
`*org-mode-google-tasks-sync-trash*' so a misclick is recoverable via
`org-mode-google-tasks-sync-restore-at-point' (run from inside that
buffer).  Local deletion happens only after Google confirms."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (let* ((list-id-prop (org-entry-get nil "GTASK_LIST" t))
         (task (org-mode-google-tasks-sync-org-read-task-at-point list-id-prop))
         (id (org-mode-google-tasks-sync-org-task-id task))
         (list-id (org-mode-google-tasks-sync-org-task-list-id task))
         (title (org-mode-google-tasks-sync-org-task-title task))
         (source-file (buffer-file-name)))
    (cond
     ((not id)
      (user-error "Heading has no :GTASK_ID:; not a synced task"))
     ((not list-id)
      (user-error "Heading is missing :GTASK_LIST: — can't tell which list to delete from"))
     ((not (yes-or-no-p (format "Delete task %S from Google? " title)))
      (message "Deletion cancelled."))
     (t
      (let ((token (org-mode-google-tasks-sync-engine--token))
            (start (save-excursion (org-back-to-heading t) (point)))
            (end   (save-excursion (org-end-of-subtree t t) (point))))
        (org-mode-google-tasks-sync-api-delete-task
         token list-id id
         (lambda (_)
           (org-mode-google-tasks-sync--snapshot-to-trash task source-file)
           (with-current-buffer (find-file-noselect source-file)
             (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
               (delete-region start end)
               (save-buffer)))
           (org-mode-google-tasks-sync-engine--log "Deleted: %s" title)
           (message "Deleted %S; snapshot in *…-trash*" title))
         (lambda (err)
           (org-mode-google-tasks-sync-engine--log
            "Delete error for %S: %S" title err)
           (message "Delete failed: %S" err))))))))

;;;###autoload
(defun org-mode-google-tasks-sync-show-trash ()
  "Pop to the deletion trash buffer."
  (interactive)
  (pop-to-buffer (org-mode-google-tasks-sync--trash-buffer)))

;;;###autoload
(defun org-mode-google-tasks-sync-new-task (title &optional due list-id)
  "Insert a new `* TODO TITLE' under the configured parent and save.
With one list configured the target is unambiguous; with multiple
lists a `completing-read' prompt picks one.  Optional DUE is a
YYYY-MM-DD string applied as SCHEDULED.  Optional LIST-ID selects
the target list explicitly.  The `after-save-hook'
triggers a sync ~1 s later, which POSTs the task to Google.

Interactively, DUE is collected via `org-read-date' (the org calendar
pop-up); pressing `C-g' at the prompt means \"no scheduled date\"."
  (interactive
   (let* ((title (read-string "New task title: "))
          (list-id
           (cond
            ((null org-mode-google-tasks-sync-map)
             (user-error "`org-mode-google-tasks-sync-map' is empty — set it first"))
            ((= 1 (length org-mode-google-tasks-sync-map))
             (caar org-mode-google-tasks-sync-map))
            (t (completing-read
                "List: "
                (mapcar #'car org-mode-google-tasks-sync-map)
                nil t)))))
     (list title nil list-id)))
  (let* ((entry (cl-find-if (lambda (e) (string= (car e) list-id))
                            org-mode-google-tasks-sync-map))
         (file (car (cdr entry)))
         (parent (cdr (cdr entry)))
         (parent-marker (org-mode-google-tasks-sync-engine--parent-marker file parent)))
    (unless parent-marker
      (user-error "Could not locate parent heading %S in %s" parent file))
    (with-current-buffer (marker-buffer parent-marker)
      ;; Collect DUE via `org-read-date' here (not in `interactive') so
      ;; the calendar pop-up runs in an org buffer — `org-read-date'
      ;; expects org-mode to be active.  C-g means "no scheduled date".
      (let ((due (or due
                     (condition-case nil
                         (let ((d (org-read-date
                                   nil nil "Scheduled date (C-g for none): ")))
                           (and (not (string-empty-p d)) d))
                       (quit nil)))))
        (save-excursion
          (goto-char parent-marker)
          (org-end-of-subtree t)
          (unless (bolp) (insert "\n"))
          (insert (format "** TODO %s\n" title))
          (when due
            (org-back-to-heading t)
            (org-schedule nil due)))
        (save-buffer)))
    (message "Inserted %S; will sync to Google within ~1 s." title)))

;;;###autoload
(defun org-mode-google-tasks-sync-restore-at-point ()
  "Restore the task at point in the trash buffer.
Two paths depending on :GTASK_REMOVAL_REASON:

- `deleted' (task gone server-side): creates a fresh task on Google,
  inserts the resulting heading under the configured parent in the
  original source file, then calls `tasks.move' with the stored
  parent/previous IDs to restore the original relative position
  \(best-effort — falls back to appending on failure).

- `done-removed' (task still exists server-side as completed):
  reopens the original task (patch status=needsAction) and
  re-inserts the local heading with the original :GTASK_ID:,
  :GTASK_UPDATED:, :GTASK_ETAG:, and :GTASK_POSITION:.  No
  duplicate is created.

In both cases the trash entry is removed after success."
  (interactive)
  (unless (equal (buffer-name) org-mode-google-tasks-sync--trash-buffer-name)
    (user-error "Run this from inside the trash buffer"))
  (save-excursion
    (org-back-to-heading t)
    (let* ((element (org-element-at-point))
           (title (org-element-property :raw-value element))
           (list-id (org-entry-get nil "GTASK_LIST"))
           (status-str (or (org-entry-get nil "GTASK_STATUS") "needsAction"))
           (due (org-entry-get nil "GTASK_DUE"))
           (source-file (org-entry-get nil "SOURCE_FILE"))
           (notes (org-mode-google-tasks-sync-org--headline-body element))
           (reason-str (or (org-entry-get nil "GTASK_REMOVAL_REASON") "deleted"))
           (reason (intern reason-str))
           (orig-id (org-entry-get nil "GTASK_ID"))
           (orig-updated (org-entry-get nil "GTASK_UPDATED"))
           (orig-etag (org-entry-get nil "GTASK_ETAG"))
           (orig-position (org-entry-get nil "GTASK_POSITION"))
           (orig-parent-id (org-entry-get nil "GTASK_PARENT_ID"))
           (orig-prev-sibling (org-entry-get nil "GTASK_PREV_SIBLING"))
           (entry (cl-find-if (lambda (e) (string= (car e) list-id))
                              org-mode-google-tasks-sync-map))
           (parent (and entry (cdr (cdr entry)))))
      (unless (and list-id source-file parent)
        (user-error
         "Missing :GTASK_LIST: / :SOURCE_FILE: in trash entry, or list not in config-map"))
      (let ((token (org-mode-google-tasks-sync-engine--token)))
        (if (eq reason 'done-removed)
            (org-mode-google-tasks-sync--restore-done-removed
             token list-id title notes due
             orig-id orig-updated orig-etag orig-position
             source-file parent)
          (org-mode-google-tasks-sync--restore-deleted
           token list-id title notes due status-str
           orig-parent-id orig-prev-sibling
           source-file parent))))))

(defun org-mode-google-tasks-sync--restore-done-removed
    (token list-id title notes due
     orig-id orig-updated orig-etag orig-position
     source-file parent)
  "Reopen a done-removed task by patching status=needsAction.
TOKEN/LIST-ID/TITLE/NOTES/DUE describe the task.  ORIG-ID/
ORIG-UPDATED/ORIG-ETAG/ORIG-POSITION are the server-side state
captured at removal time so the re-inserted heading matches what
the server still holds.  SOURCE-FILE/PARENT locate the org target."
  (unless orig-id
    (user-error
      "Trash entry is missing :GTASK_ID:; cannot reopen the original task"))
  (let ((patch-data `((id . ,orig-id)
                      (title . ,title)
                      (notes . ,(or notes ""))
                      (status . "needsAction")
                      ,@(when due `((due . ,(concat due "T00:00:00.000Z")))))))
    (org-mode-google-tasks-sync-api-patch-task
     token list-id orig-id patch-data orig-etag
     (lambda (resp)
       (let* ((updated (or (alist-get 'updated resp) orig-updated))
              (etag (or (alist-get 'etag resp) orig-etag))
              (position (or (alist-get 'position resp) orig-position))
              (task (make-org-mode-google-tasks-sync-org-task
                     :id orig-id
                     :list-id list-id
                     :title title
                     :notes (or notes "")
                     :status 'needsAction
                     :due due
                     :parent-id nil
                     :updated updated
                     :etag etag
                     :hash nil
                     :position position
                     :completed nil
                     :links nil
                     :web-view-link nil
                     :marker nil))
              (parent-marker
               (org-mode-google-tasks-sync-engine--parent-marker
                source-file parent)))
         (when parent-marker
           (with-current-buffer (marker-buffer parent-marker)
             (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
               (org-mode-google-tasks-sync-org-insert-task-under
                parent-marker task)
               (save-buffer))))
         (org-mode-google-tasks-sync--remove-trash-entry-at-point)
         (org-mode-google-tasks-sync-engine--log "Restored (reopened): %s" title)
         (message "Reopened %S in %s" title source-file)))
     (lambda (err)
       (message "Restore (reopen) failed: %S" err)))))

(defun org-mode-google-tasks-sync--restore-deleted
    (token list-id title notes due status-str
     orig-parent-id orig-prev-sibling
     source-file parent)
  "Create a fresh task to replace a deleted one, then move to original position.
TOKEN/LIST-ID/TITLE/NOTES/DUE/STATUS-STR describe the task to create.
ORIG-PARENT-ID/ORIG-PREV-SIBLING are the position hints captured at
deletion time, passed to `tasks.move' as :parent/:previous to restore
the original relative position.  SOURCE-FILE/PARENT locate the org
target."
  (let ((data `((title . ,title)
                (notes . ,(or notes ""))
                (status . ,status-str)
                ,@(when due `((due . ,(concat due "T00:00:00.000Z")))))))
    (org-mode-google-tasks-sync-api-insert-task
     token list-id data
     (lambda (resp)
       (let* ((new-task
               (org-mode-google-tasks-sync-engine--remote-task->struct
                resp list-id nil))
              (new-id (alist-get 'id resp))
              (parent-marker
               (org-mode-google-tasks-sync-engine--parent-marker
                source-file parent)))
         (when parent-marker
           (with-current-buffer (marker-buffer parent-marker)
             (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
               (org-mode-google-tasks-sync-org-insert-task-under
                parent-marker new-task)
               (save-buffer))))
         ;; Best-effort restore of original relative position.
         (when (or orig-parent-id orig-prev-sibling)
           (org-mode-google-tasks-sync-api-move-task
            token list-id new-id
            (lambda (_)
              (org-mode-google-tasks-sync-engine--log
               "Restored position for: %s" title))
            (lambda (err)
              (org-mode-google-tasks-sync-engine--log
               "Position restore failed (task=%s): %S" title err))
            orig-parent-id orig-prev-sibling))
         (org-mode-google-tasks-sync--remove-trash-entry-at-point)
         (org-mode-google-tasks-sync-engine--log "Restored: %s" title)
         (message "Restored %S to %s" title source-file)))
     (lambda (err)
       (message "Restore failed: %S" err)))))

(defun org-mode-google-tasks-sync--remove-trash-entry-at-point ()
  "Delete the trash entry heading at point and persist the trash buffer."
  (with-current-buffer (org-mode-google-tasks-sync--trash-buffer)
    (let ((begin (save-excursion (org-back-to-heading t) (point)))
          (end   (save-excursion (org-end-of-subtree t t) (point))))
      (delete-region begin end)))
  (org-mode-google-tasks-sync--trash-persist))


;;;###autoload
(defun org-mode-google-tasks-sync-setup ()
  "One-shot interactive setup — the single command most users want.
Prompts for `client_id' and `client_secret', runs the OAuth consent
flow, and then opens a buffer listing your Google Tasks list IDs so
you can populate `org-mode-google-tasks-sync-map'.

The individual steps are still exposed as
`org-mode-google-tasks-sync-configure', `-authorize', and
`-list-discover' for re-running phases on their own (e.g.
re-authorizing after a token revocation)."
  (interactive)
  (org-mode-google-tasks-sync-oauth-configure)
  (org-mode-google-tasks-sync-oauth-authorize
   #'org-mode-google-tasks-sync-engine-discover-lists))

;;;###autoload
(defun org-mode-google-tasks-sync-configure ()
  "Interactively store client_id and client_secret in `auth-source'."
  (interactive)
  (org-mode-google-tasks-sync-oauth-configure))

;;;###autoload
(defun org-mode-google-tasks-sync-authorize ()
  "Run the OAuth flow and persist the refresh token."
  (interactive)
  (org-mode-google-tasks-sync-oauth-authorize))

;;;###autoload
(defun org-mode-google-tasks-sync-list-discover ()
  "Fetch task lists from Google and offer to populate the map.
Populates `org-mode-google-tasks-sync-map'."
  (interactive)
  (org-mode-google-tasks-sync-engine-discover-lists))

;;;###autoload
(defun org-mode-google-tasks-sync ()
  "Run one incremental sync pass for every configured list."
  (interactive)
  (org-mode-google-tasks-sync-engine-run 'incremental))

;;;###autoload
(defun org-mode-google-tasks-sync-full-sync ()
  "Run a full reconciliation pass: detect long-tombstoned deletions."
  (interactive)
  (org-mode-google-tasks-sync-engine-run 'full))

;;;###autoload
(defun org-mode-google-tasks-sync-show-log ()
  "Pop to the sync log buffer."
  (interactive)
  (pop-to-buffer (org-mode-google-tasks-sync-engine-log-buffer)))

;;;###autoload
(defun org-mode-google-tasks-sync-show-conflicts ()
  "Pop to the conflict quarantine buffer."
  (interactive)
  (pop-to-buffer (org-mode-google-tasks-sync-engine-conflicts-buffer)))

(defun org-mode-google-tasks-sync--detect-hm-bridge ()
  "Point writes at the HM bridge's XDG files when they exist.
The Home Manager module materializes
`$XDG_DATA_HOME/org-mode-google-tasks-sync/static-creds.authinfo.gpg' on
activation.  If that file is present the bootstrap is running in an
HM-managed environment, so secrets it writes (notably the refresh
token) should land alongside the HM-managed file rather than in
`~/.authinfo.gpg' where the user's interactive Emacs won't read them
first.  No-op when the file is absent."
  (let* ((xdg (or (getenv "XDG_DATA_HOME")
                  (expand-file-name "~/.local/share")))
         (dir (expand-file-name "org-mode-google-tasks-sync" xdg))
         (static-creds (expand-file-name "static-creds.authinfo.gpg" dir))
         (dynamic-creds (expand-file-name "dynamic-creds.authinfo.gpg" dir)))
    (when (file-exists-p static-creds)
      (require 'auth-source)
      (add-to-list 'auth-sources static-creds)
      (add-to-list 'auth-sources dynamic-creds)
      (setq org-mode-google-tasks-sync-oauth-write-target dynamic-creds)
      (message "Home Manager bridge detected; writing to %s" dynamic-creds))))

;;;###autoload
(defun org-mode-google-tasks-sync-bootstrap ()
  "End-to-end bootstrap.  Designed for `emacs --batch'.

Reuses `org-mode-google-tasks-sync-configure' (prompts for client_id
and client_secret, stores them in auth-source) and `-authorize' (runs
the OAuth dance, saves the refresh token), then prints `refresh_token'
and your list IDs to stdout for use in a SOPS/Home-Manager config.

Typical invocation:

  nix run github:afwlehmann/org-mode-google-tasks-sync#bootstrap

By default the result lands in `~/.authinfo.gpg' (so a non-Nix user
can stop here).  If the Home Manager bridge has already been activated
on this machine (detected by the presence of
`$XDG_DATA_HOME/org-mode-google-tasks-sync/static-creds.authinfo.gpg'),
the bootstrap instead writes to that directory's
`dynamic-creds.authinfo.gpg' so the secrets land where the
HM-configured Emacs is going to look for them.  The values are also
echoed to stdout for Nix users who'd rather copy them into SOPS.
Exits non-zero on timeout (5 minutes)."
  (org-mode-google-tasks-sync--detect-hm-bridge)
  (let ((done nil))
    (call-interactively #'org-mode-google-tasks-sync-configure)
    (org-mode-google-tasks-sync-oauth-authorize
     (lambda () (setq done t)))
    (let ((deadline (+ (float-time) 300)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 1)))
    (unless done
      (message "Timed out waiting for OAuth callback.")
      (kill-emacs 1)))
  (princ "\n--- Bootstrap complete ---\n")
  (princ "Copy these into SOPS (or your secret manager) if you want a declarative Home Manager setup:\n\n")
  (princ (format "client_id=%s\n"
                 (org-mode-google-tasks-sync-oauth--read-secret
                  org-mode-google-tasks-sync-oauth--login-client-id)))
  (princ (format "client_secret=<the value you just entered>\n"))
  (princ (format "refresh_token=%s\n"
                 (org-mode-google-tasks-sync-oauth--read-secret
                  org-mode-google-tasks-sync-oauth--login-refresh-token)))
  (princ "\n--- Google Tasks lists (use these IDs in `map') ---\n")
  (org-mode-google-tasks-sync-engine-discover-lists-batch))

(defun org-mode-google-tasks-sync--after-save-hook ()
  "If the saved file is a configured sync target, schedule a sync soon.
Bails out when `org-mode-google-tasks-sync-engine--inhibit-save-hooks'
is bound (the engine is saving the file itself), otherwise the
engine's own write would re-trigger the sync chain on every save."
  (unless org-mode-google-tasks-sync-engine--inhibit-save-hooks
    (when (and org-mode-google-tasks-sync-map
               (org-mode-google-tasks-sync--file-is-target-p (buffer-file-name)))
      (run-at-time 1 nil #'org-mode-google-tasks-sync))))

(defun org-mode-google-tasks-sync--file-is-target-p (file)
  "Return non-nil if FILE is a target in `org-mode-google-tasks-sync-map'."
  (and file
       (let ((abs (file-truename file)))
         (cl-some (lambda (entry)
                    (string= abs (file-truename (car (cdr entry)))))
                  org-mode-google-tasks-sync-map))))


;;; Reordering and reparenting via org's own keys
;;
;; `M-<up>'    org-move-subtree-up   — reorder among siblings (same parent)
;; `M-<down>'  org-move-subtree-down — reorder among siblings (same parent)
;; `M-<left>'  org-do-promote        — subtask → top-level (parent=nil)
;; `M-<right>' org-do-demote         — top-level → subtask (of preceding sibling)
;; `M-S-<left>'  org-promote-subtree — REFUSED on synced headings
;; `M-S-<right>' org-demote-subtree  — REFUSED on synced headings
;;
;; All advised operations are server-first: the heading doesn't move
;; locally until Google confirms the new position, which eliminates the
;; race with the post-apply `--sort-children' step (it re-sorts by the
;; stale :GTASK_POSITION: until the callback updates it).

(declare-function org-mode-google-tasks-sync--last-child-id "org-mode-google-tasks-sync.el" (parent-marker))
(declare-function org-mode-google-tasks-sync--compute-demote-params "org-mode-google-tasks-sync.el" ())
(declare-function org-mode-google-tasks-sync--update-heading-server-state "org-mode-google-tasks-sync.el" (updated etag position))
(declare-function org-mode-google-tasks-sync--apply-server-move "org-mode-google-tasks-sync.el" (token list-id task-id new-parent-id previous-id title &optional post-move-fn))
(declare-function org-mode-google-tasks-sync--advised-move "org-mode-google-tasks-sync.el" (orig-fn direction))
(declare-function org-mode-google-tasks-sync--advised-promote "org-mode-google-tasks-sync.el" (orig-fn))
(declare-function org-mode-google-tasks-sync--advised-demote "org-mode-google-tasks-sync.el" (orig-fn))
(declare-function org-mode-google-tasks-sync--refuse-subtree-op "org-mode-google-tasks-sync.el" (orig-fn))

(defun org-mode-google-tasks-sync--synced-task-at-point-p ()
  "Return non-nil if the heading at point is a synced Google Task."
  (and (derived-mode-p 'org-mode)
       (org-at-heading-p)
       (org-entry-get nil "GTASK_ID")
       (org-entry-get nil "GTASK_LIST" t)))

(defun org-mode-google-tasks-sync--sibling-ids ()
  "Return a list of (MARKER . GTASK_ID) for direct siblings of heading at point.
Includes the heading at point itself, in buffer order.  Siblings
without :GTASK_ID: are skipped (they're local-only)."
  (save-excursion
    (org-back-to-heading t)
    (let* ((level (org-current-level))
           (siblings '()))
      ;; Walk backward to collect siblings before point.
      (save-excursion
        (while (and (not (bobp))
                    (re-search-backward "^\\*+ " nil t))
          (when (= (org-current-level) level)
            (push (cons (point-marker)
                        (org-entry-get nil "GTASK_ID"))
                  siblings))))
      ;; Walk forward from point to collect siblings after point.
      (save-excursion
        (forward-line 1)
        (while (and (not (eobp))
                    (looking-at "^\\*+ ")
                    (<= (org-current-level) level))
          (when (= (org-current-level) level)
            (push (cons (point-marker)
                        (org-entry-get nil "GTASK_ID"))
                  siblings))
          (forward-line 1)))
      (nreverse siblings))))

(defun org-mode-google-tasks-sync--prev-sibling-id (sibs current-marker)
  "Return the :GTASK_ID: of the sibling immediately before CURRENT-MARKER.
SIBS is the list from `--sibling-ids'.  Nil if CURRENT-MARKER is
the first sibling (or the only one)."
  (let ((prev nil))
    (cl-some (lambda (cell)
               (if (equal (marker-position (car cell))
                          (marker-position current-marker))
                   (cdr prev)
                 (setq prev cell)
                 nil))
             sibs)))

(defun org-mode-google-tasks-sync--compute-move-params (direction)
  "Compute (NEW-PARENT-ID . PREVIOUS-ID) for a sibling move in DIRECTION.
DIRECTION is `up or `down.  Returns nil when the move is not
possible (heading is already at the edge)."
  (save-excursion
    (org-back-to-heading t)
    (let* ((current-marker (point-marker))
           (parent-id (org-mode-google-tasks-sync-org--parent-id-at-point))
           (sibs (org-mode-google-tasks-sync--sibling-ids))
           (current-pos (marker-position current-marker))
           (idx (cl-position current-pos sibs
                             :test (lambda (a b)
                                     (equal a (marker-position (car b)))))))
       (cond
        ((null idx) nil)
        ((and (eq direction 'up) (<= idx 0))
         (user-error "Cannot move further up"))
        ((and (eq direction 'down) (>= idx (1- (length sibs))))
         (user-error "Cannot move further down"))
        ((eq direction 'up)
         ;; Move to position of sibling two-before current (or first).
         ;; previous-id = the sibling that will precede us after the move.
         (let* ((target-idx (max 0 (1- idx)))
                (prev-sib (and (> target-idx 0)
                               (with-no-warnings
                                 (nth (1- target-idx) sibs)))))
           (cons parent-id (cdr-safe prev-sib))))
        (t ;; direction 'down
         ;; After moving down, the sibling that was immediately after us
         ;; becomes our predecessor.
         (let ((after-sib (with-no-warnings (nth (1+ idx) sibs))))
           (cons parent-id (cdr-safe after-sib)))))))

(defun org-mode-google-tasks-sync--last-child-id (parent-marker)
  "Return the :GTASK_ID: of the last direct child heading under PARENT-MARKER.
Nil if the parent has no synced children."
  (save-excursion
    (goto-char parent-marker)
    (org-back-to-heading t)
    (let ((parent-level (org-current-level))
          (last-id nil))
      (save-excursion
        (org-forward-heading-same-level 1)
        (when (> (org-current-level) parent-level)
          ;; We entered the subtree — walk to the last direct child.
          (while (and (not (eobp))
                      (looking-at "^\\*+ ")
                      (> (org-current-level) parent-level))
            (when (= (org-current-level) (1+ parent-level))
              (let ((id (org-entry-get nil "GTASK_ID")))
                (when id (setq last-id id))))
            (forward-line 1))))
      last-id)))

(defun org-mode-google-tasks-sync--compute-demote-params ()
  "Compute (NEW-PARENT-ID . PREVIOUS-ID) for a demote of the heading at point.
The heading becomes a subtask of the preceding top-level sibling,
appended as its last child.  Refuses if the heading has subtasks
\(they'd fall to level N+3 and stop syncing)."
  (save-excursion
    (org-back-to-heading t)
    (let ((current-marker (point-marker))
          (level (org-current-level)))
      ;; Refuse if the task has child headings.
      (save-excursion
        (forward-line 1)
        (when (and (not (eobp))
                   (looking-at "^\\*+ ")
                   (> (org-current-level) level))
          (user-error
            "Cannot demote: task has subtasks; move or delete them first")))
      (let* ((sibs (org-mode-google-tasks-sync--sibling-ids))
             (idx (cl-position (marker-position current-marker) sibs
                               :test (lambda (a b)
                                       (equal a (marker-position (car b)))))))
        (when (or (null idx) (<= idx 0))
          (user-error "Cannot demote: no preceding sibling to nest under"))
        (let* ((prev-sib (with-no-warnings (nth (1- idx) sibs)))
               (new-parent-id (cdr-safe prev-sib))
               (last-child-id
                (when new-parent-id
                  (org-mode-google-tasks-sync--last-child-id
                   (car prev-sib)))))
          (cons new-parent-id last-child-id))))))

(defun org-mode-google-tasks-sync--update-heading-server-state
    (updated etag position)
  "Write UPDATED/ETAG/POSITION onto the heading at point."
  (save-excursion
    (org-back-to-heading t)
    (when (and updated (fboundp 'org-entry-put))
      (org-entry-put nil "GTASK_UPDATED" updated))
    (when (and etag (fboundp 'org-entry-put))
      (org-entry-put nil "GTASK_ETAG" etag))
    (when (and position (fboundp 'org-entry-put))
      (org-entry-put nil "GTASK_POSITION" position))))

(defun org-mode-google-tasks-sync--apply-server-move
    (token list-id task-id new-parent-id previous-id title
     &optional post-move-fn)
  "Call `tasks.move' and log; on success call POST-MOVE-FN with the response.
TOKEN authenticates the call.  LIST-ID is the Google Tasks list.
TASK-ID identifies the task.  NEW-PARENT-ID and PREVIOUS-ID are the
move params (either may be nil).  TITLE is for logging."
  (org-mode-google-tasks-sync-api-move-task
   token list-id task-id
     (lambda (resp)
       (let ((updated (alist-get 'updated resp))
             (etag (alist-get 'etag resp))
             (position (alist-get 'position resp)))
         ;; Update the heading's server-state properties.
         (org-mode-google-tasks-sync--update-heading-server-state
          updated etag position)
         (when post-move-fn (funcall post-move-fn resp))
       (org-mode-google-tasks-sync-engine--log
        "Moved (local push): %s" title)
       (message "Moved %S" title)))
   (lambda (err)
     (org-mode-google-tasks-sync-engine--log
      "Move error: %S (task=%s)" err title)
     (message "Move failed: %S" err))
   new-parent-id previous-id))

(defun org-mode-google-tasks-sync--advised-move (orig-fn direction)
  "Advice wrapper for `org-move-subtree-up' / `org-move-subtree-down'.
ORIG-FN is the original function; DIRECTION is `up or `down.
Performs a server-first move: calls `tasks.move' and only runs
ORIG-FN after the server confirms, so the post-apply sort step
can't undo the local reorder."
  (if (not (org-mode-google-tasks-sync--synced-task-at-point-p))
      (funcall orig-fn)
    (let* ((list-id (org-entry-get nil "GTASK_LIST" t))
           (task-id (org-entry-get nil "GTASK_ID"))
           (title (or (org-element-property
                       :raw-value (org-element-at-point)) ""))
           (params (org-mode-google-tasks-sync--compute-move-params direction))
           (token (org-mode-google-tasks-sync-engine--token))
           (marker (point-marker)))
      (when params
        (message "Moving…")
        (org-mode-google-tasks-sync--apply-server-move
         token list-id task-id
         (car params) (cdr params) title
         (lambda (_resp)
           (with-current-buffer (marker-buffer marker)
             (save-excursion
               (goto-char marker)
               (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
                 (funcall orig-fn)
                 (save-buffer))))))))))

(defun org-mode-google-tasks-sync--advised-promote (orig-fn)
  "Advice wrapper for `org-do-promote'.
ORIG-FN is the original `org-do-promote'.  Promotes a subtask to
top-level: parent=nil, previous=former parent."
  (if (not (org-mode-google-tasks-sync--synced-task-at-point-p))
      (funcall orig-fn)
    (save-excursion
      (org-back-to-heading t)
      (let* ((parent-id (org-mode-google-tasks-sync-org--parent-id-at-point)))
        (unless parent-id
          (user-error "Heading is already top-level"))
        (let* ((list-id (org-entry-get nil "GTASK_LIST" t))
               (task-id (org-entry-get nil "GTASK_ID"))
               (title (or (org-element-property
                           :raw-value (org-element-at-point)) ""))
               (token (org-mode-google-tasks-sync-engine--token))
               (marker (point-marker)))
          (message "Promoting…")
          (org-mode-google-tasks-sync--apply-server-move
           token list-id task-id
           nil parent-id title
           (lambda (_resp)
             (with-current-buffer (marker-buffer marker)
               (save-excursion
                 (goto-char marker)
                 (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
                   (funcall orig-fn)
                   (save-buffer)))))))))))

(defun org-mode-google-tasks-sync--advised-demote (orig-fn)
  "Advice wrapper for `org-do-demote'.
ORIG-FN is the original `org-do-demote'.  Demotes a top-level task
to subtask: parent=preceding sibling, previous=last existing child
of that sibling."
  (if (not (org-mode-google-tasks-sync--synced-task-at-point-p))
      (funcall orig-fn)
    (let* ((list-id (org-entry-get nil "GTASK_LIST" t))
           (task-id (org-entry-get nil "GTASK_ID"))
           (title (or (org-element-property
                       :raw-value (org-element-at-point)) ""))
           (params (org-mode-google-tasks-sync--compute-demote-params))
           (token (org-mode-google-tasks-sync-engine--token))
           (marker (point-marker)))
      (when params
        (message "Demoting…")
        (org-mode-google-tasks-sync--apply-server-move
         token list-id task-id
         (car params) (cdr params) title
         (lambda (_resp)
           (with-current-buffer (marker-buffer marker)
             (save-excursion
               (goto-char marker)
               (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
                 (funcall orig-fn)
                 (save-buffer))))))))))

(defun org-mode-google-tasks-sync--refuse-subtree-op (orig-fn)
  "Advice wrapper that refuses subtree-wide promote/demote on synced headings.
ORIG-FN is the original function.  Subtree variants
\(`org-promote-subtree' / `org-demote-subtree') would reparent a
whole subtree including synced subtasks, which is too messy to map
to `tasks.move' cleanly.  Refuses with a clear message."
  (if (not (org-mode-google-tasks-sync--synced-task-at-point-p))
      (funcall orig-fn)
    (user-error
      "Subtree-wide promote/demote is not supported on synced tasks; use `C-c C-^' (org-move-subtree-up) / `C-c C-_' (org-move-subtree-down) on the parent instead"))))

(defun org-mode-google-tasks-sync--advice-move-up (orig-fn &rest _)
  "Advice for `org-move-subtree-up'.  ORIG-FN is the original."
  (org-mode-google-tasks-sync--advised-move orig-fn 'up))

(defun org-mode-google-tasks-sync--advice-move-down (orig-fn &rest _)
  "Advice for `org-move-subtree-down'.  ORIG-FN is the original."
  (org-mode-google-tasks-sync--advised-move orig-fn 'down))

(defun org-mode-google-tasks-sync--advice-promote (orig-fn &rest _)
  "Advice for `org-do-promote'.  ORIG-FN is the original."
  (org-mode-google-tasks-sync--advised-promote orig-fn))

(defun org-mode-google-tasks-sync--advice-demote (orig-fn &rest _)
  "Advice for `org-do-demote'.  ORIG-FN is the original."
  (org-mode-google-tasks-sync--advised-demote orig-fn))

(defun org-mode-google-tasks-sync--advice-refuse-promote (orig-fn &rest _)
  "Advice refusing `org-promote-subtree' on synced headings.  ORIG-FN is original."
  (org-mode-google-tasks-sync--refuse-subtree-op orig-fn))

(defun org-mode-google-tasks-sync--advice-refuse-demote (orig-fn &rest _)
  "Advice refusing `org-demote-subtree' on synced headings.  ORIG-FN is original."
  (org-mode-google-tasks-sync--refuse-subtree-op orig-fn))

(defun org-mode-google-tasks-sync--install-move-advice ()
  "Install `:around' advice on org's move/promote/demote functions."
  (advice-add 'org-move-subtree-up :around
              #'org-mode-google-tasks-sync--advice-move-up)
  (advice-add 'org-move-subtree-down :around
              #'org-mode-google-tasks-sync--advice-move-down)
  (advice-add 'org-do-promote :around
              #'org-mode-google-tasks-sync--advice-promote)
  (advice-add 'org-do-demote :around
              #'org-mode-google-tasks-sync--advice-demote)
  (advice-add 'org-promote-subtree :around
              #'org-mode-google-tasks-sync--advice-refuse-promote)
  (advice-add 'org-demote-subtree :around
              #'org-mode-google-tasks-sync--advice-refuse-demote))

(defun org-mode-google-tasks-sync--uninstall-move-advice ()
  "Remove the `:around' advice installed by `--install-move-advice'."
  (advice-remove 'org-move-subtree-up
                 #'org-mode-google-tasks-sync--advice-move-up)
  (advice-remove 'org-move-subtree-down
                 #'org-mode-google-tasks-sync--advice-move-down)
  (advice-remove 'org-do-promote
                 #'org-mode-google-tasks-sync--advice-promote)
  (advice-remove 'org-do-demote
                 #'org-mode-google-tasks-sync--advice-demote)
  (advice-remove 'org-promote-subtree
                 #'org-mode-google-tasks-sync--advice-refuse-promote)
  (advice-remove 'org-demote-subtree
                 #'org-mode-google-tasks-sync--advice-refuse-demote))

;;;###autoload
(define-minor-mode org-mode-google-tasks-sync-mode
  "Global minor mode that keeps org files synced with Google Tasks."
  :global t
  :lighter " GTasks"
  :group 'org-mode-google-tasks-sync
  (if org-mode-google-tasks-sync-mode
      (org-mode-google-tasks-sync--enable)
    (org-mode-google-tasks-sync--disable)))

(defun org-mode-google-tasks-sync--any-file-modified-p ()
  "Return non-nil if any configured org file's mtime is newer than the last sync.
Returns t when no sync has happened yet this session, which makes the
first tick fire a sync (so the user sees a sync within
`org-mode-google-tasks-sync-tick-interval' seconds of starting Emacs)."
  (or (null org-mode-google-tasks-sync-engine--last-sync-time)
      (cl-some
       (lambda (entry)
         (let* ((file (car (cdr entry)))
                (attrs (and file (file-exists-p file) (file-attributes file))))
           (when attrs
             (> (float-time (file-attribute-modification-time attrs))
                org-mode-google-tasks-sync-engine--last-sync-time))))
       org-mode-google-tasks-sync-map)))

(defun org-mode-google-tasks-sync--should-sync-p ()
  "Return non-nil if the tick should kick off a sync.
True when: no sync has happened yet, or a configured file has been
modified since the last sync, or the safety-net interval has elapsed."
  (or (null org-mode-google-tasks-sync-engine--last-sync-time)
      (org-mode-google-tasks-sync--any-file-modified-p)
      (> (- (float-time) org-mode-google-tasks-sync-engine--last-sync-time)
         org-mode-google-tasks-sync-poll-interval)))

(defun org-mode-google-tasks-sync--tick ()
  "Wake-up handler: sync iff the predicate indicates we should.
Errors during the sync are caught and routed to the log buffer so a
misconfigured environment (e.g. unavailable GPG) doesn't spam
*Messages* every `tick-interval' seconds.  The user is expected to
look at *org-mode-google-tasks-sync-log* for diagnostic output."
  (when (org-mode-google-tasks-sync--should-sync-p)
    (condition-case err
        (org-mode-google-tasks-sync)
      (error
       (org-mode-google-tasks-sync-engine--log "Tick failed: %S" err)))))

(defun org-mode-google-tasks-sync--enable ()
  "Install timers, hooks, and move/promote/demote advice."
  (when org-mode-google-tasks-sync--timer
    (cancel-timer org-mode-google-tasks-sync--timer))
  (when org-mode-google-tasks-sync--full-timer
    (cancel-timer org-mode-google-tasks-sync--full-timer))
  (setq org-mode-google-tasks-sync-engine--last-sync-time nil)
  ;; First tick fires 1 s after enable so the user gets an immediate sync
  ;; on Emacs start; subsequent ticks fire every `tick-interval'.
  (setq org-mode-google-tasks-sync--timer
        (run-at-time 1 org-mode-google-tasks-sync-tick-interval
                     #'org-mode-google-tasks-sync--tick))
  (setq org-mode-google-tasks-sync--full-timer
        (run-at-time org-mode-google-tasks-sync-full-sync-interval
                     org-mode-google-tasks-sync-full-sync-interval
                     #'org-mode-google-tasks-sync-full-sync))
  (add-hook 'after-save-hook #'org-mode-google-tasks-sync--after-save-hook)
  (org-mode-google-tasks-sync--install-move-advice))

(defun org-mode-google-tasks-sync--disable ()
  "Tear down timers, hooks, and move/promote/demote advice."
  (when org-mode-google-tasks-sync--timer
    (cancel-timer org-mode-google-tasks-sync--timer)
    (setq org-mode-google-tasks-sync--timer nil))
  (when org-mode-google-tasks-sync--full-timer
    (cancel-timer org-mode-google-tasks-sync--full-timer)
    (setq org-mode-google-tasks-sync--full-timer nil))
  (remove-hook 'after-save-hook #'org-mode-google-tasks-sync--after-save-hook)
  (org-mode-google-tasks-sync--uninstall-move-advice))

(provide 'org-mode-google-tasks-sync)
;;; org-mode-google-tasks-sync.el ends here
