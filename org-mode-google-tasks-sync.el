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
