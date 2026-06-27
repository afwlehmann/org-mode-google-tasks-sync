;;; org-mode-google-tasks-sync-oauth-test.el --- Tests for the OAuth module -*- lexical-binding: t -*-

;;; Commentary:

;; Network-free tests for the OAuth helpers.  Specifically verifies that
;; `--save-secret' restricts writes to `org-mode-google-tasks-sync-oauth-write-target'
;; rather than whichever file happens to be first in `auth-sources'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-mode-google-tasks-sync-oauth)

(ert-deftest org-mode-google-tasks-sync-oauth-test/save-secret-restricts-auth-sources ()
  "Writes go only to the configured write-target, not to other auth-sources."
  (let* ((target "/tmp/org-mode-google-tasks-sync-test-target")
         (org-mode-google-tasks-sync-oauth-write-target target)
         (auth-sources '("/run/secrets/static-creds" "~/.authinfo.gpg" "~/.authinfo"))
         (captured nil))
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest _args)
                 (setq captured auth-sources)
                 (list (list :save-function #'ignore)))))
      (org-mode-google-tasks-sync-oauth--save-secret "test-login" "test-secret")
      (should (equal captured (list target))))))

(ert-deftest org-mode-google-tasks-sync-oauth-test/save-secret-invokes-save-function ()
  "The :save-function returned by auth-source-search must be called."
  (let* ((org-mode-google-tasks-sync-oauth-write-target "/tmp/x")
         (called nil))
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest _args)
                 (list (list :save-function (lambda () (setq called t)))))))
      (org-mode-google-tasks-sync-oauth--save-secret "l" "s")
      (should called))))

(ert-deftest org-mode-google-tasks-sync-oauth-test/write-target-defcustom-defined ()
  "The write-target defcustom exists with a sensible default."
  (should (boundp 'org-mode-google-tasks-sync-oauth-write-target))
  (should (stringp org-mode-google-tasks-sync-oauth-write-target))
  (should (string-match-p "\\.authinfo" org-mode-google-tasks-sync-oauth-write-target)))

(provide 'org-mode-google-tasks-sync-oauth-test)
;;; org-mode-google-tasks-sync-oauth-test.el ends here
