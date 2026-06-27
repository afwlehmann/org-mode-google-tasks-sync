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

(defcustom org-mode-google-tasks-sync-poll-interval 300
  "Seconds between background sync ticks while `org-mode-google-tasks-sync-mode' is on."
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

(defun org-mode-google-tasks-sync--after-save-hook ()
  "If the saved file is a configured sync target, schedule a sync soon."
  (when (and org-mode-google-tasks-sync-map
             (org-mode-google-tasks-sync--file-is-target-p (buffer-file-name)))
    (run-at-time 1 nil #'org-mode-google-tasks-sync)))

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

(defun org-mode-google-tasks-sync--enable ()
  "Install timers and hooks."
  (when org-mode-google-tasks-sync--timer
    (cancel-timer org-mode-google-tasks-sync--timer))
  (when org-mode-google-tasks-sync--full-timer
    (cancel-timer org-mode-google-tasks-sync--full-timer))
  (setq org-mode-google-tasks-sync--timer
        (run-at-time org-mode-google-tasks-sync-poll-interval
                     org-mode-google-tasks-sync-poll-interval
                     #'org-mode-google-tasks-sync))
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
