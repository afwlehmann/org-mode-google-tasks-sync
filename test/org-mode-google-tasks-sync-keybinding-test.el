;;; org-mode-google-tasks-sync-keybinding-test.el --- prefix keybinding tests -*- lexical-binding: t -*-

;;; Commentary:
;; Covers the configurable prefix keybinding system: three defcustoms
;; (`leader-key', `key-prefix', `key-subprefix'), auto-rebind via `:set',
;; save/restore of the previous binding on enable/disable, and the
;; buffer-local minor modes for configured org buffers and the trash
;; buffer.

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
Saves and restores the defcustom values and the global keymap
state so tests are isolated."
  (declare (indent 0))
  `(let ((old-leader org-mode-google-tasks-sync-leader-key)
         (old-prefix org-mode-google-tasks-sync-key-prefix)
         (old-subprefix org-mode-google-tasks-sync-key-subprefix)
         (old-mode org-mode-google-tasks-sync-mode))
     (unwind-protect
         (progn
           (setq org-mode-google-tasks-sync-leader-key "C-c"
                 org-mode-google-tasks-sync-key-prefix "g"
                 org-mode-google-tasks-sync-key-subprefix nil)
           (org-mode-google-tasks-sync-mode 1)
           ,@body)
       (org-mode-google-tasks-sync-mode -1)
       (setq org-mode-google-tasks-sync-leader-key old-leader
             org-mode-google-tasks-sync-key-prefix old-prefix
             org-mode-google-tasks-sync-key-subprefix old-subprefix
             org-mode-google-tasks-sync-mode old-mode))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/global-bound-on-enable ()
  "Enabling the mode binds the command map at the default prefix."
  (org-mode-google-tasks-sync-keybinding-test--with-mode
   (should (eq (lookup-key global-map (kbd "C-c g"))
               org-mode-google-tasks-sync-command-map))
   (should (eq (lookup-key global-map (kbd "C-c g s"))
               #'org-mode-google-tasks-sync))
   (should (eq (lookup-key global-map (kbd "C-c g n"))
               #'org-mode-google-tasks-sync-new-task))
   (should (eq (lookup-key global-map (kbd "C-c g j"))
               #'org-mode-google-tasks-sync-jump-to-list))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/global-unbound-on-disable ()
  "Disabling the mode restores the previous binding at the prefix."
  (org-mode-google-tasks-sync-keybinding-test--with-mode
   (should (eq (lookup-key global-map (kbd "C-c g"))
               org-mode-google-tasks-sync-command-map)))
  (should-not (lookup-key global-map (kbd "C-c g"))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/save-restore-existing-binding ()
  "Enabling saves a pre-existing binding; disabling restores it."
  (let ((existing (lambda () (interactive) (message "other"))))
    (unwind-protect
        (progn
          (global-set-key (kbd "C-c g") existing)
          (org-mode-google-tasks-sync-mode 1)
          (should (eq (lookup-key global-map (kbd "C-c g"))
                      org-mode-google-tasks-sync-command-map))
          (org-mode-google-tasks-sync-mode -1)
          (should (eq (lookup-key global-map (kbd "C-c g")) existing)))
      (global-unset-key (kbd "C-c g"))
      (when org-mode-google-tasks-sync-mode
        (org-mode-google-tasks-sync-mode -1)))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/subprefix-binding ()
  "With a subprefix, commands bind at the deeper prefix."
  (let ((org-mode-google-tasks-sync-leader-key "C-c")
        (org-mode-google-tasks-sync-key-prefix "g")
        (org-mode-google-tasks-sync-key-subprefix "t"))
    (unwind-protect
        (progn
          (org-mode-google-tasks-sync-mode 1)
          (should (eq (lookup-key global-map (kbd "C-c g t"))
                      org-mode-google-tasks-sync-command-map))
          (should (eq (lookup-key global-map (kbd "C-c g t s"))
                      #'org-mode-google-tasks-sync))
          (should (eq (lookup-key global-map (kbd "C-c g t n"))
                      #'org-mode-google-tasks-sync-new-task)))
      (org-mode-google-tasks-sync-mode -1))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/rebind-on-prefix-change ()
  "Changing `key-prefix' via `:set' rebinds immediately."
  (org-mode-google-tasks-sync-keybinding-test--with-mode
   (should (eq (lookup-key global-map (kbd "C-c g"))
               org-mode-google-tasks-sync-command-map))
   (org-mode-google-tasks-sync--set-and-rebind
    'org-mode-google-tasks-sync-key-prefix "t")
   (should (eq (lookup-key global-map (kbd "C-c t"))
               org-mode-google-tasks-sync-command-map))
   (should (eq (lookup-key global-map (kbd "C-c t s"))
               #'org-mode-google-tasks-sync))
   (should-not (lookup-key global-map (kbd "C-c g")))
   (org-mode-google-tasks-sync--set-and-rebind
    'org-mode-google-tasks-sync-key-prefix "g")))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/rebind-on-leader-change ()
  "Changing `leader-key' via `:set' rebinds immediately."
  (org-mode-google-tasks-sync-keybinding-test--with-mode
   (should (eq (lookup-key global-map (kbd "C-c g"))
               org-mode-google-tasks-sync-command-map))
   (org-mode-google-tasks-sync--set-and-rebind
    'org-mode-google-tasks-sync-leader-key "C-x")
   (should (eq (lookup-key global-map (kbd "C-x g"))
               org-mode-google-tasks-sync-command-map))
   (should (eq (lookup-key global-map (kbd "C-x g s"))
               #'org-mode-google-tasks-sync))
   (should-not (lookup-key global-map (kbd "C-c g")))
   (org-mode-google-tasks-sync--set-and-rebind
    'org-mode-google-tasks-sync-leader-key "C-c")))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/buffer-mode-not-in-non-configured-buffer ()
  "The buffer-local minor mode is NOT enabled in a non-configured org buffer."
  (let ((file (org-mode-google-tasks-sync-keybinding-test--make-org-file "Random")))
    (unwind-protect
        (org-mode-google-tasks-sync-keybinding-test--with-mode
         (with-current-buffer (find-file-noselect file)
           (should-not org-mode-google-tasks-sync-buffer-mode)))
      (org-mode-google-tasks-sync-keybinding-test--cleanup file))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/buffer-mode-in-configured-buffer ()
  "The buffer-local minor mode IS enabled in a configured org buffer."
  (let ((file (org-mode-google-tasks-sync-keybinding-test--make-org-file "Inbox")))
    (unwind-protect
        (let ((org-mode-google-tasks-sync-map
               `(("LIST1" . (,file . "Inbox")))))
          (org-mode-google-tasks-sync-keybinding-test--with-mode
           (with-current-buffer (find-file-noselect file)
             (should org-mode-google-tasks-sync-buffer-mode)
             (should (eq (lookup-key org-mode-google-tasks-sync-buffer-mode-map
                                     (kbd "C-c g"))
                         org-mode-google-tasks-sync-buffer-map))
             (should (eq (lookup-key org-mode-google-tasks-sync-buffer-map
                                     (kbd "d"))
                         #'org-mode-google-tasks-sync-delete-at-point))
             (should (eq (lookup-key global-map (kbd "C-c g s"))
                         #'org-mode-google-tasks-sync)))))
      (org-mode-google-tasks-sync-keybinding-test--cleanup file))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/trash-mode-in-trash-buffer ()
  "The trash minor mode is enabled in the trash buffer."
  (let ((org-mode-google-tasks-sync-persist-trash nil))
    (unwind-protect
        (org-mode-google-tasks-sync-keybinding-test--with-mode
         (let ((trash-buf (org-mode-google-tasks-sync--trash-buffer)))
           (with-current-buffer trash-buf
             (should org-mode-google-tasks-sync-trash-mode)
             (should (eq (lookup-key org-mode-google-tasks-sync-trash-mode-map
                                     (kbd "C-c g"))
                         org-mode-google-tasks-sync-trash-map))
             (should (eq (lookup-key org-mode-google-tasks-sync-trash-map
                                     (kbd "R"))
                         #'org-mode-google-tasks-sync-restore-at-point)))))
      (when (get-buffer org-mode-google-tasks-sync--trash-buffer-name)
        (kill-buffer org-mode-google-tasks-sync--trash-buffer-name)))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/no-buffer-keys-in-non-configured-buffer ()
  "Buffer-local keys (d/h/H) are not bound in a non-configured org buffer."
  (let ((file (org-mode-google-tasks-sync-keybinding-test--make-org-file "Random")))
    (unwind-protect
        (org-mode-google-tasks-sync-keybinding-test--with-mode
         (with-current-buffer (find-file-noselect file)
           (should-not (lookup-key global-map (kbd "C-c g d")))))
      (org-mode-google-tasks-sync-keybinding-test--cleanup file))))

(ert-deftest org-mode-google-tasks-sync-keybinding-test/buffer-mode-disabled-on-mode-off ()
  "Disabling the global mode disables the buffer-local mode too."
  (let ((file (org-mode-google-tasks-sync-keybinding-test--make-org-file "Inbox")))
    (unwind-protect
        (let ((org-mode-google-tasks-sync-map
               `(("LIST1" . (,file . "Inbox")))))
          (org-mode-google-tasks-sync-keybinding-test--with-mode
           (with-current-buffer (find-file-noselect file)
             (should org-mode-google-tasks-sync-buffer-mode)))
          (with-current-buffer (find-file-noselect file)
            (should-not org-mode-google-tasks-sync-buffer-mode)))
      (org-mode-google-tasks-sync-keybinding-test--cleanup file))))

(provide 'org-mode-google-tasks-sync-keybinding-test)
;;; org-mode-google-tasks-sync-keybinding-test.el ends here
