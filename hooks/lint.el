;;; lint.el --- Run checkdoc + byte-compile checks on all package files -*- lexical-binding: t -*-

;; Run via:
;;   nix develop --command emacs --batch -L . -l hooks/lint.el -f org-mode-google-tasks-sync-lint
;; Or without Nix:
;;   emacs --batch -L . -l hooks/lint.el -f org-mode-google-tasks-sync-lint
;;
;; Exits non-zero if any warning is found.  Used by the pre-commit hook.

;;; Code:

(require 'bytecomp)
(require 'checkdoc)

(defconst org-mode-google-tasks-sync-lint--files
  '("org-mode-google-tasks-sync.el"
    "org-mode-google-tasks-sync-api.el"
    "org-mode-google-tasks-sync-engine.el"
    "org-mode-google-tasks-sync-oauth.el"
    "org-mode-google-tasks-sync-org.el")
  "Package source files to lint.")

(defvar org-mode-google-tasks-sync-lint--errors nil
  "Accumulated error/warning messages.")

(defun org-mode-google-tasks-sync-lint--capture-messages (file fn)
  "Call FN and capture any messages for FILE.
Returns a list of message strings."
  (let ((messages nil)
        (orig-message (symbol-function 'message)))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (let ((msg (apply #'format fmt args)))
                   (unless (or (string-empty-p msg)
                               (string-prefix-p "Loading" msg))
                     (push msg messages))
                   (funcall orig-message fmt args)))))
      (funcall fn))
    (nreverse messages)))

(defun org-mode-google-tasks-sync-lint--checkdoc-file (file)
  "Run checkdoc on FILE and collect warnings."
  (let ((checkdoc-autofix-flag nil))
    (let ((msgs (org-mode-google-tasks-sync-lint--capture-messages
                 file
                 (lambda () (checkdoc-file file)))))
      (dolist (msg msgs)
        (when (string-match-p "Warning" msg)
          (push (format "checkdoc %s: %s" file msg)
                org-mode-google-tasks-sync-lint--errors))))))

(defun org-mode-google-tasks-sync-lint--byte-compile-file (file)
  "Byte-compile FILE and collect warnings."
  (let ((byte-compile-warnings t)
        (msgs (org-mode-google-tasks-sync-lint--capture-messages
               file
               (lambda () (byte-compile-file file)))))
    (dolist (msg msgs)
      (when (string-match-p "[Ww]arning" msg)
        (push (format "byte-compile %s: %s" file msg)
              org-mode-google-tasks-sync-lint--errors)))))

(defun org-mode-google-tasks-sync-lint ()
  "Run all lint checks.  Exit non-zero on failure."
  (let ((default-directory
         (or (and load-file-name
                  (file-name-directory load-file-name)
                  (expand-file-name ".." (file-name-directory load-file-name)))
             default-directory)))
    (dolist (file org-mode-google-tasks-sync-lint--files)
      (org-mode-google-tasks-sync-lint--checkdoc-file file)
      (org-mode-google-tasks-sync-lint--byte-compile-file file))
    (if org-mode-google-tasks-sync-lint--errors
        (progn
          (message "LINT FAILED — %d warning(s):"
                   (length org-mode-google-tasks-sync-lint--errors))
          (dolist (err (nreverse org-mode-google-tasks-sync-lint--errors))
            (message "  %s" err))
          (kill-emacs 1))
      (message "LINT OK — all %d files clean"
               (length org-mode-google-tasks-sync-lint--files))
      (kill-emacs 0))))

(provide 'org-mode-google-tasks-sync-lint)
;;; lint.el ends here
