;;; org-mode-google-tasks-sync-jump-test.el --- jump-to-list tests -*- lexical-binding: t -*-

;;; Commentary:
;; Covers `org-mode-google-tasks-sync-jump-to-list': auto-jump on a
;; single reachable entry, fuzzy `completing-read' prompt otherwise,
;; filtering of broken map entries (missing file or absent parent
;; heading), and the `user-error' when no entry is reachable.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-mode-google-tasks-sync)

(defconst org-mode-google-tasks-sync-jump-test--heading-regexp
  "^\\*+ %s$"
  "Format string for a parent heading line used in the test fixtures.")

(defun org-mode-google-tasks-sync-jump-test--make-file (parent)
  "Create a temp org file containing a single PARENT heading.
Return the absolute file path."
  (let ((file (make-temp-file "gtasks-jump-test" nil ".org")))
    (with-temp-file file
      (insert (format "#+TITLE: Test\n\n* %s\n** TODO a task\n" parent)))
    file))

(defun org-mode-google-tasks-sync-jump-test--cleanup (file)
  "Delete FILE and kill any visiting buffer."
  (when (and file (file-exists-p file))
    (let ((buf (find-buffer-visiting file)))
      (when buf (kill-buffer buf)))
    (delete-file file)))

(defun org-mode-google-tasks-sync-jump-test--cleanup-all (files)
  "Clean up every path in FILES."
  (dolist (f files)
    (org-mode-google-tasks-sync-jump-test--cleanup f)))

(ert-deftest org-mode-google-tasks-sync-jump-test/single-entry-auto-jumps ()
  "With one reachable entry and flag nil, jump directly without prompting."
  (let ((file (org-mode-google-tasks-sync-jump-test--make-file "Inbox"))
        (org-mode-google-tasks-sync-map nil)
        (org-mode-google-tasks-sync-debug-jump-always-prompt nil)
        (prompted nil))
    (unwind-protect
        (progn
          (setq org-mode-google-tasks-sync-map
                `(("LIST1" . (,file . "Inbox"))))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _)
                       (setq prompted t)
                       (error "completing-read should not be called"))))
            (org-mode-google-tasks-sync-jump-to-list)
            (should-not prompted)
            (with-current-buffer (find-file-noselect file)
              (save-excursion
                (goto-char (point-min))
                (should (re-search-forward
                         (format org-mode-google-tasks-sync-jump-test--heading-regexp
                                 "Inbox")
                         nil t)))
              (kill-buffer))))
      (org-mode-google-tasks-sync-jump-test--cleanup-all (list file)))))

(ert-deftest org-mode-google-tasks-sync-jump-test/single-entry-prompts-when-flag-set ()
  "With one reachable entry and flag non-nil, the prompt is shown."
  (let ((file (org-mode-google-tasks-sync-jump-test--make-file "Inbox"))
        (org-mode-google-tasks-sync-map nil)
        (org-mode-google-tasks-sync-debug-jump-always-prompt t)
        (styles-seen nil)
        (prompted nil))
    (unwind-protect
        (progn
          (setq org-mode-google-tasks-sync-map
                `(("LIST1" . (,file . "Inbox"))))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt collection &rest _args)
                       (setq prompted t)
                       (setq styles-seen completion-styles)
                       (car collection))))
            (org-mode-google-tasks-sync-jump-to-list)
            (should prompted)
            (should (memq 'flex styles-seen))))
      (org-mode-google-tasks-sync-jump-test--cleanup-all (list file)))))

(ert-deftest org-mode-google-tasks-sync-jump-test/multiple-entries-prompt ()
  "With two reachable entries, the prompt is shown regardless of flag."
  (let ((file-a (org-mode-google-tasks-sync-jump-test--make-file "Work"))
        (file-b (org-mode-google-tasks-sync-jump-test--make-file "Home"))
        (org-mode-google-tasks-sync-map nil)
        (org-mode-google-tasks-sync-debug-jump-always-prompt nil)
        (prompted nil))
    (unwind-protect
        (progn
          (setq org-mode-google-tasks-sync-map
                `(("L1" . (,file-a . "Work"))
                  ("L2" . (,file-b . "Home"))))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt collection &rest _args)
                       (setq prompted t)
                       (car collection))))
            (org-mode-google-tasks-sync-jump-to-list)
            (should prompted)))
      (org-mode-google-tasks-sync-jump-test--cleanup-all
       (list file-a file-b)))))

(ert-deftest org-mode-google-tasks-sync-jump-test/skips-missing-file ()
  "An entry whose file does not exist is filtered out."
  (let ((file (org-mode-google-tasks-sync-jump-test--make-file "Real"))
        (org-mode-google-tasks-sync-map nil)
        (org-mode-google-tasks-sync-debug-jump-always-prompt nil)
        (prompted nil))
    (unwind-protect
        (progn
          (setq org-mode-google-tasks-sync-map
                `(("BROKEN" . ("/nonexistent/nope.org" . "Ghost"))
                  ("REAL"   . (,file . "Real"))))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _)
                       (setq prompted t)
                       (error "should auto-jump to the one real entry"))))
            (org-mode-google-tasks-sync-jump-to-list)
            (should-not prompted)))
      (org-mode-google-tasks-sync-jump-test--cleanup-all (list file)))))

(ert-deftest org-mode-google-tasks-sync-jump-test/skips-missing-heading ()
  "An entry whose parent heading is absent is filtered out."
  (let ((file (org-mode-google-tasks-sync-jump-test--make-file "Real"))
        (org-mode-google-tasks-sync-map nil)
        (org-mode-google-tasks-sync-debug-jump-always-prompt nil)
        (prompted nil))
    (unwind-protect
        (progn
          ;; file-b exists but contains no "Ghost" heading
          (let ((file-b (make-temp-file "gtasks-jump-noheading" nil ".org")))
            (with-temp-file file-b (insert "#+TITLE: Empty\n"))
            (setq org-mode-google-tasks-sync-map
                  `(("NOHEADING" . (,file-b . "Ghost"))
                    ("REAL"      . (,file . "Real"))))
            (unwind-protect
                (cl-letf (((symbol-function 'completing-read)
                           (lambda (&rest _)
                             (setq prompted t)
                             (error "should auto-jump to the one real entry"))))
                  (org-mode-google-tasks-sync-jump-to-list)
                  (should-not prompted))
              (org-mode-google-tasks-sync-jump-test--cleanup-all (list file-b)))))
      (org-mode-google-tasks-sync-jump-test--cleanup-all (list file)))))

(ert-deftest org-mode-google-tasks-sync-jump-test/zero-valid-errors ()
  "When no entries are reachable, signal `user-error'."
  (let ((org-mode-google-tasks-sync-map
         '(("X" . ("/nonexistent/nope.org" . "Ghost"))))
        (org-mode-google-tasks-sync-debug-jump-always-prompt nil))
    (should-error (org-mode-google-tasks-sync-jump-to-list)
                  :type 'user-error)))

(ert-deftest org-mode-google-tasks-sync-jump-test/navigates-to-heading ()
  "After jumping, point is on the chosen parent heading line."
  (let ((file (org-mode-google-tasks-sync-jump-test--make-file "Inbox"))
        (org-mode-google-tasks-sync-map nil)
        (org-mode-google-tasks-sync-debug-jump-always-prompt nil))
    (unwind-protect
        (progn
          (setq org-mode-google-tasks-sync-map
                `(("LIST1" . (,file . "Inbox"))))
          (org-mode-google-tasks-sync-jump-to-list)
          (should (derived-mode-p 'org-mode))
          (save-excursion
            (org-back-to-heading t)
            (should (looking-at
                     (format org-mode-google-tasks-sync-jump-test--heading-regexp
                             "Inbox"))))
          (kill-buffer))
      (org-mode-google-tasks-sync-jump-test--cleanup-all (list file)))))

(provide 'org-mode-google-tasks-sync-jump-test)
;;; org-mode-google-tasks-sync-jump-test.el ends here
