;;; org-mode-google-tasks-sync-keybinding-test.el --- keybinding tests -*- lexical-binding: t -*-

;;; Commentary:
;; Covers the single command-map keybinding model: the package
;; exposes `org-mode-google-tasks-sync-command-map' and never binds
;; it itself, and the context-sensitive commands (d/h/H/R) silently
;; no-op outside their target buffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-mode-google-tasks-sync)

(defun org-mode-google-tasks-sync-keybinding-test--make-org-file (parent)
  "Create a temp org file containing a single PARENT heading.
Return the absolute file path."
  (let ((file (make-temp-file "gtasks-key-test" nil ".org")))
    (with-temp-file file
      (insert (format "#+TITLE: Test\n\n* %s\n** TODO a task\n" parent)))
    file))

(defun org-mode-google-tasks-sync-keybinding-test--cleanup (file)
  "Delete FILE and kill any visiting buffer."
  (when (and file (file-exists-p file))
    (let ((buf (find-buffer-visiting file)))
      (when buf (kill-buffer buf)))
    (delete-file file)))

(defmacro org-mode-google-tasks-sync-keybinding-test--with-mode (&rest body)
  "Execute BODY with the mode enabled, then disable and clean up.
Saves and restores the global keymap state so tests are isolated."
  (declare (indent 0))
  `(let ((old-mode org-mode-google-tasks-sync-mode))
     (unwind-protect
         (progn
           (org-mode-google-tasks-sync-mode 1)
           ,@body)
       (org-mode-google-tasks-sync-mode -1)
       (setq org-mode-google-tasks-sync-mode old-mode))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/command-map-has-all-commands ()
  "The single command map contains all 12 commands."
  (should (eq (lookup-key org-mode-google-tasks-sync-command-map (kbd "S"))
              #'org-mode-google-tasks-sync-setup))
  (should (eq (lookup-key org-mode-google-tasks-sync-command-map (kbd "s"))
              #'org-mode-google-tasks-sync))
  (should (eq (lookup-key org-mode-google-tasks-sync-command-map (kbd "f"))
              #'org-mode-google-tasks-sync-full-sync))
  (should (eq (lookup-key org-mode-google-tasks-sync-command-map (kbd "n"))
              #'org-mode-google-tasks-sync-new-task))
  (should (eq (lookup-key org-mode-google-tasks-sync-command-map (kbd "j"))
              #'org-mode-google-tasks-sync-jump-to-list))
  (should (eq (lookup-key org-mode-google-tasks-sync-command-map (kbd "l"))
              #'org-mode-google-tasks-sync-show-log))
  (should (eq (lookup-key org-mode-google-tasks-sync-command-map (kbd "c"))
              #'org-mode-google-tasks-sync-show-conflicts))
  (should (eq (lookup-key org-mode-google-tasks-sync-command-map (kbd "r"))
              #'org-mode-google-tasks-sync-show-trash))
  (should (eq (lookup-key org-mode-google-tasks-sync-command-map (kbd "d"))
              #'org-mode-google-tasks-sync-delete-at-point))
  (should (eq (lookup-key org-mode-google-tasks-sync-command-map (kbd "h"))
              #'org-mode-google-tasks-sync-hide-done-mode))
  (should (eq (lookup-key org-mode-google-tasks-sync-command-map (kbd "H"))
              #'org-mode-google-tasks-sync-show-done))
  (should (eq (lookup-key org-mode-google-tasks-sync-command-map (kbd "R"))
              #'org-mode-google-tasks-sync-restore-at-point)))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/enable-does-not-touch-global-map ()
  "Enabling the mode does NOT bind anything in `global-map'."
  (let ((before (lookup-key global-map (kbd "C-c g"))))
    (unwind-protect
        (org-mode-google-tasks-sync-keybinding-test--with-mode
         (should (equal (lookup-key global-map (kbd "C-c g")) before))
         ;; The command map must NOT be at C-c g, and individual commands
         ;; must NOT be reachable.  `lookup-key' returns an integer for a
         ;; partial prefix match, so compare with `eq' against the map.
         (should-not (eq (lookup-key global-map (kbd "C-c g"))
                         org-mode-google-tasks-sync-command-map))
         (should-not (eq (lookup-key global-map (kbd "C-c g s"))
                         #'org-mode-google-tasks-sync))
         (should-not (eq (lookup-key global-map (kbd "C-c g n"))
                         #'org-mode-google-tasks-sync-new-task)))
      ;; ensure clean state
      (when org-mode-google-tasks-sync-mode
        (org-mode-google-tasks-sync-mode -1)))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/disable-does-not-touch-user-binding ()
  "Toggling the mode off does NOT unbind a key the user bound themselves."
  (unwind-protect
      (progn
        (global-set-key (kbd "C-c g") org-mode-google-tasks-sync-command-map)
        (org-mode-google-tasks-sync-keybinding-test--with-mode
         (should (eq (lookup-key global-map (kbd "C-c g"))
                     org-mode-google-tasks-sync-command-map)))
        ;; After the macro's unwind disables the mode, the user binding
        ;; is still there because the mode never owned it.
        (should (eq (lookup-key global-map (kbd "C-c g"))
                    org-mode-google-tasks-sync-command-map)))
    (global-unset-key (kbd "C-c g"))
    (when org-mode-google-tasks-sync-mode
      (org-mode-google-tasks-sync-mode -1))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/no-buffer-or-trash-minor-mode ()
  "The old buffer-mode and trash-mode symbols no longer exist."
  (should-not (boundp 'org-mode-google-tasks-sync-buffer-mode))
  (should-not (boundp 'org-mode-google-tasks-sync-trash-mode))
  (should-not (boundp 'org-mode-google-tasks-sync-buffer-mode-map))
  (should-not (boundp 'org-mode-google-tasks-sync-trash-mode-map)))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/no-prefix-defcustoms ()
  "The old prefix defcustoms no longer exist."
  (should-not (boundp 'org-mode-google-tasks-sync-leader-key))
  (should-not (boundp 'org-mode-google-tasks-sync-key-prefix))
  (should-not (boundp 'org-mode-google-tasks-sync-key-subprefix)))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/delete-at-point-no-op-outside-configured-buffer ()
  "`delete-at-point' silently does nothing in a non-configured org buffer."
  (let ((file (org-mode-google-tasks-sync-keybinding-test--make-org-file "Random")))
    (unwind-protect
        (org-mode-google-tasks-sync-keybinding-test--with-mode
         (with-current-buffer (find-file-noselect file)
           ;; Should not signal an error and should return nil.
           (should-not (org-mode-google-tasks-sync-delete-at-point)))))
    (org-mode-google-tasks-sync-keybinding-test--cleanup file)))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/delete-at-point-no-op-in-non-org-buffer ()
  "`delete-at-point' silently does nothing in a non-org buffer."
  (org-mode-google-tasks-sync-keybinding-test--with-mode
   (with-temp-buffer
     (fundamental-mode)
     (should-not (org-mode-google-tasks-sync-delete-at-point)))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/hide-done-no-op-in-non-org-buffer ()
  "`hide-done-mode' silently does nothing when toggled on in a non-org buffer."
  (org-mode-google-tasks-sync-keybinding-test--with-mode
   (with-temp-buffer
     (fundamental-mode)
     (org-mode-google-tasks-sync-hide-done-mode 1)
     (should-not org-mode-google-tasks-sync-hide-done-mode))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/show-done-no-op-in-non-org-buffer ()
  "`show-done' silently does nothing in a non-org buffer."
  (org-mode-google-tasks-sync-keybinding-test--with-mode
   (with-temp-buffer
     (fundamental-mode)
     (should-not (org-mode-google-tasks-sync-show-done)))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/restore-at-point-no-op-outside-trash-buffer ()
  "`restore-at-point' silently does nothing outside the trash buffer."
  (org-mode-google-tasks-sync-keybinding-test--with-mode
   (with-temp-buffer
     (org-mode)
     (should-not (org-mode-google-tasks-sync-restore-at-point)))))

(provide 'org-mode-google-tasks-sync-keybinding-test)
;;; org-mode-google-tasks-sync-keybinding-test.el ends here
