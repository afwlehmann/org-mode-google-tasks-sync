;;; test-helper.el --- Test bootstrap -*- lexical-binding: t -*-

;;; Commentary:

;; Sets up a project-local elpa under test/.elpa and ensures plz + oauth2 are
;; installed.  Loaded by run-tests.el before any ert files.

;;; Code:

(require 'package)

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (project-root (expand-file-name ".." here)))
  (add-to-list 'load-path project-root)
  (add-to-list 'load-path here)
  ;; If plz and oauth2 are already on the load-path (e.g. via Nix
  ;; emacsWithPackages, or already installed in ~/.emacs.d), use them.
  ;; Otherwise install them into a project-local elpa so we don't touch the
  ;; user's emacs profile.
  (unless (and (locate-library "plz") (locate-library "oauth2"))
    (let ((local-elpa (expand-file-name ".elpa" here)))
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
          (package-install pkg))))))

(provide 'test-helper)
;;; test-helper.el ends here
