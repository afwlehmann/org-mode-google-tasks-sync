;;; test-helper.el --- Test bootstrap -*- lexical-binding: t -*-

;;; Commentary:

;; Sets up a project-local elpa under test/.elpa and ensures plz + oauth2 are
;; installed.  Loaded by run-tests.el before any ert files.

;;; Code:

(require 'package)

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (project-root (expand-file-name ".." here))
       (local-elpa (expand-file-name ".elpa" here)))
  (setq package-user-dir local-elpa)
  (unless (file-directory-p local-elpa)
    (make-directory local-elpa t))
  (setq package-archives
        '(("gnu"   . "https://elpa.gnu.org/packages/")
          ("melpa" . "https://melpa.org/packages/")))
  (package-initialize)
  (dolist (pkg '(plz oauth2))
    (unless (package-installed-p pkg)
      (unless (assq pkg package-archive-contents)
        (package-refresh-contents))
      (package-install pkg)))
  (add-to-list 'load-path project-root)
  (add-to-list 'load-path here))

(provide 'test-helper)
;;; test-helper.el ends here
