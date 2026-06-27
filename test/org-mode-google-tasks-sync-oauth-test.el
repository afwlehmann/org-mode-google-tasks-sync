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

(ert-deftest org-mode-google-tasks-sync-oauth-test/gen-state-base64-encodes-cleanly ()
  "--gen-state must not crash on bytes >= 128.

The implementation builds a unibyte buffer of 16 random bytes and
base64-encodes it.  An earlier version used `string' instead of
`unibyte-string', which interpreted bytes >= 128 as Unicode code
points and made `base64-encode-string' signal
\"Multibyte character in data for base64 encoding\" — breaking the
bootstrap flow on its very first call.  This test exercises the path
many times to be confident we hit the >= 128 range."
  (dotimes (_ 50)
    (let ((state (org-mode-google-tasks-sync-oauth--gen-state)))
      (should (stringp state))
      (should (> (length state) 0))
      (should (string-match-p "\\`[A-Za-z0-9+/=]+\\'" state)))))

(require 'org-mode-google-tasks-sync)

(ert-deftest org-mode-google-tasks-sync-oauth-test/detect-hm-bridge-finds-xdg ()
  "When the HM-managed static-creds file exists, writes pivot to the XDG dynamic-creds path."
  (let* ((tmp-xdg (make-temp-file "gtasks-xdg" t))
         (pkg-dir (expand-file-name "org-mode-google-tasks-sync" tmp-xdg))
         (static-creds (expand-file-name "static-creds.authinfo.gpg" pkg-dir))
         (dynamic-creds (expand-file-name "dynamic-creds.authinfo.gpg" pkg-dir))
         (process-environment (cons (format "XDG_DATA_HOME=%s" tmp-xdg) process-environment))
         (auth-sources '("~/.authinfo.gpg"))
         (org-mode-google-tasks-sync-oauth-write-target "/tmp/should-be-replaced"))
    (unwind-protect
        (progn
          (make-directory pkg-dir t)
          ;; Bypass EasyPG: we only need a placeholder file at this path so
          ;; the detector finds it.  The .gpg extension would otherwise
          ;; trigger gpg-encryption inside a sandbox that has no GPG.
          (let ((file-name-handler-alist nil))
            (with-temp-file static-creds (insert "placeholder")))
          (org-mode-google-tasks-sync--detect-hm-bridge)
          (should (member static-creds auth-sources))
          (should (member dynamic-creds auth-sources))
          (should (equal org-mode-google-tasks-sync-oauth-write-target dynamic-creds)))
      (delete-directory tmp-xdg t))))

(ert-deftest org-mode-google-tasks-sync-oauth-test/detect-hm-bridge-noop-without-xdg ()
  "When the HM-managed static-creds file is absent, the helper changes nothing."
  (let* ((tmp-xdg (make-temp-file "gtasks-xdg" t))
         (process-environment (cons (format "XDG_DATA_HOME=%s" tmp-xdg) process-environment))
         (auth-sources '("~/.authinfo.gpg"))
         (original "/tmp/keep-me")
         (org-mode-google-tasks-sync-oauth-write-target original))
    (unwind-protect
        (progn
          (org-mode-google-tasks-sync--detect-hm-bridge)
          (should (equal org-mode-google-tasks-sync-oauth-write-target original))
          (should (equal auth-sources '("~/.authinfo.gpg"))))
      (delete-directory tmp-xdg t))))

(provide 'org-mode-google-tasks-sync-oauth-test)
;;; org-mode-google-tasks-sync-oauth-test.el ends here
