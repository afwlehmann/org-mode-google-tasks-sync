;;; org-mode-google-tasks-sync.el --- Two-way sync between org-mode and Google Tasks -*- lexical-binding: t -*-

;; Copyright (C) 2026 Alexander Lehmann
;; SPDX-License-Identifier: MIT

;; Author: Alexander Lehmann <afwlehmann@googlemail.com>
;; Version: 0.1.0
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
  "Two-way sync between org-mode and Google Tasks."
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
recommendation is `C-c g' — that prefix is unused by org-mode and
by org-roam (which lives at `C-c n'), so:

  (global-set-key (kbd \"C-c g\") org-mode-google-tasks-sync-command-map)

gives you `C-c g s' for sync, `C-c g n' for new task, `C-c g h' to
toggle hide-DONE, and so on.")

(defcustom org-mode-google-tasks-sync-hide-done-by-default nil
  "Whether to auto-enable `org-mode-google-tasks-sync-hide-done-mode' on target files.
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

To bring a task back from DONE to TODO when you've hit `C-c C-t' by
mistake, run `M-x org-mode-google-tasks-sync-show-done', navigate to
the task, `C-c C-t' again, then turn this mode back on."
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

(defun org-mode-google-tasks-sync--snapshot-to-trash (task source-file)
  "Append a snapshot of TASK to the trash buffer.  SOURCE-FILE is where it lived."
  (with-current-buffer (org-mode-google-tasks-sync--trash-buffer)
    (goto-char (point-min))
    (insert
     (format
      "* %s\n  :PROPERTIES:\n  :DELETED_AT: %s\n  :SOURCE_FILE: %s\n  :GTASK_LIST: %s\n  :GTASK_ID_ORIG: %s\n  :GTASK_STATUS: %s\n%s%s  :END:\n%s\n\n"
      (or (org-mode-google-tasks-sync-org-task-title task) "<no title>")
      (format-time-string "%Y-%m-%dT%H:%M:%S")
      (or source-file "")
      (or (org-mode-google-tasks-sync-org-task-list-id task) "")
      (or (org-mode-google-tasks-sync-org-task-id task) "")
      (symbol-name (or (org-mode-google-tasks-sync-org-task-status task)
                       'needsAction))
      (if (org-mode-google-tasks-sync-org-task-due task)
          (format "  :GTASK_DUE: %s\n"
                  (org-mode-google-tasks-sync-org-task-due task))
        "")
      (if (org-mode-google-tasks-sync-org-task-completed task)
          (format "  :GTASK_COMPLETED: %s\n"
                  (org-mode-google-tasks-sync-org-task-completed task))
        "")
      (or (org-mode-google-tasks-sync-org-task-notes task) "")))
    (org-mode-google-tasks-sync--trash-persist)))

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
lists a completing-read prompt picks one.  Optional DUE is a
YYYY-MM-DD string applied as SCHEDULED.  The after-save-hook
triggers a sync ~1 s later, which POSTs the task to Google."
  (interactive
   (let* ((title (read-string "New task title: "))
          (due (let ((s (read-string "Due date (YYYY-MM-DD, blank for none): ")))
                 (and (not (string-empty-p s)) s)))
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
     (list title due list-id)))
  (let* ((entry (cl-find-if (lambda (e) (string= (car e) list-id))
                            org-mode-google-tasks-sync-map))
         (file (car (cdr entry)))
         (parent (cdr (cdr entry)))
         (parent-marker (org-mode-google-tasks-sync-engine--parent-marker file parent)))
    (unless parent-marker
      (user-error "Could not locate parent heading %S in %s" parent file))
    (with-current-buffer (marker-buffer parent-marker)
      (save-excursion
        (goto-char parent-marker)
        (org-end-of-subtree t)
        (unless (bolp) (insert "\n"))
        (insert (format "** TODO %s\n" title))
        (when due
          (org-back-to-heading t)
          (org-schedule nil due)))
      (save-buffer))
    (message "Inserted %S; will sync to Google within ~1 s." title)))

;;;###autoload
(defun org-mode-google-tasks-sync-restore-at-point ()
  "Restore the deleted task at point in the trash buffer.
Creates a fresh task on Google (the original is gone server-side),
inserts the resulting heading under the configured parent in the
original source file, and removes the entry from the trash buffer.

Note: the new task gets a fresh `:GTASK_ID:'; the original ID and
position are lost.  Only title, notes, status, due, and list-id
survive."
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
           (entry (cl-find-if (lambda (e) (string= (car e) list-id))
                              org-mode-google-tasks-sync-map))
           (parent (and entry (cdr (cdr entry)))))
      (unless (and list-id source-file parent)
        (user-error "Missing :GTASK_LIST: / :SOURCE_FILE: in trash entry, or list not in config-map"))
      (let* ((token (org-mode-google-tasks-sync-engine--token))
             (data `((title . ,title)
                     (notes . ,(or notes ""))
                     (status . ,status-str)
                     ,@(when due `((due . ,(concat due "T00:00:00.000Z")))))))
        (org-mode-google-tasks-sync-api-insert-task
         token list-id data
         (lambda (resp)
           (let* ((new-task
                   (org-mode-google-tasks-sync-engine--remote-task->struct
                    resp list-id nil))
                  (parent-marker
                   (org-mode-google-tasks-sync-engine--parent-marker
                    source-file parent)))
             (when parent-marker
               (with-current-buffer (marker-buffer parent-marker)
                 (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
                   (org-mode-google-tasks-sync-org-insert-task-under
                    parent-marker new-task)
                   (save-buffer))))
             ;; Remove from trash.
             (let ((begin (save-excursion (org-back-to-heading t) (point)))
                   (end   (save-excursion (org-end-of-subtree t t) (point))))
               (delete-region begin end))
             (org-mode-google-tasks-sync--trash-persist)
             (org-mode-google-tasks-sync-engine--log "Restored: %s" title)
             (message "Restored %S to %s" title source-file)))
         (lambda (err)
           (message "Restore failed: %S" err)))))))


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
  "Fetch task lists from Google and offer to populate `org-mode-google-tasks-sync-map'."
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
  "Return non-nil if FILE is the target of any entry in `org-mode-google-tasks-sync-map'."
  (and file
       (let ((abs (file-truename file)))
         (cl-some (lambda (entry)
                    (string= abs (file-truename (car (cdr entry)))))
                  org-mode-google-tasks-sync-map))))

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
  "Wake-up handler: sync iff the predicate says we should.
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
  "Install timers and hooks."
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
  (add-hook 'after-save-hook #'org-mode-google-tasks-sync--after-save-hook))

(defun org-mode-google-tasks-sync--disable ()
  "Tear down timers and hooks."
  (when org-mode-google-tasks-sync--timer
    (cancel-timer org-mode-google-tasks-sync--timer)
    (setq org-mode-google-tasks-sync--timer nil))
  (when org-mode-google-tasks-sync--full-timer
    (cancel-timer org-mode-google-tasks-sync--full-timer)
    (setq org-mode-google-tasks-sync--full-timer nil))
  (remove-hook 'after-save-hook #'org-mode-google-tasks-sync--after-save-hook))

(provide 'org-mode-google-tasks-sync)
;;; org-mode-google-tasks-sync.el ends here
