;;; happy-path-test.el --- Integration tests against a Mockoon mock server -*- lexical-binding: t -*-

;; Copyright (C) 2026 Alexander Lehmann
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Happy-path integration tests that drive the full sync engine against a
;; Mockoon mock server.  The mock serves realistic Google Tasks API responses
;; (see `mockoon-environment.json').  These tests are loaded by
;; `run-integration-tests.el' after the mock server is started.

;;; Code:

(require 'ert)
(require 'org-mode-google-tasks-sync)
(require 'org-mode-google-tasks-sync-api)
(require 'org-mode-google-tasks-sync-oauth)
(require 'org-mode-google-tasks-sync-engine)

(defconst org-mode-google-tasks-sync-integration-test--list-id "MOCK-LIST"
  "Google Tasks list ID served by the Mockoon mock.")

(defun org-mode-google-tasks-sync-integration-test--base-url ()
  "Return the mocked Tasks API base URL."
  (format "http://127.0.0.1:%d/tasks/v1"
          org-mode-google-tasks-sync-integration--mockoon-port))

(defun org-mode-google-tasks-sync-integration-test--fake-token ()
  "Build a token struct that never expires for use against the mock."
  (make-org-mode-google-tasks-sync-api-token
   :access-token "fake-access-token"
   :refresh-token "fake-refresh-token"
   :client-id "fake-client-id"
   :client-secret "fake-client-secret"
   :expires-at (+ (float-time) 3600)))

(defun org-mode-google-tasks-sync-integration-test--pump
    (&optional timeout)
  "Pump the event loop until the engine returns to `idle' or TIMEOUT seconds.
Default timeout is 30 seconds.  `plz' fires callbacks via the Emacs process
event loop; in batch mode nothing pumps it automatically, so we must call
`accept-process-output' repeatedly to let HTTP responses arrive and the
engine's state machine advance through fetching -> applying -> idle."
  (let ((deadline (+ (float-time) (or timeout 30))))
    (while (and (> deadline (float-time))
                (not (eq org-mode-google-tasks-sync-engine--state 'idle)))
      (accept-process-output nil 0.1)))
  (should (eq org-mode-google-tasks-sync-engine--state 'idle)))

(defun org-mode-google-tasks-sync-integration-test--with-org-file
    (org-text &rest body)
  "Run BODY in a temp org file containing ORG-TEXT.
BODY is a list of forms.  The temp file path is bound to `file' via
`cl-macrolet' so tests can pass it to the engine.  Cleans up the file
and buffer on exit."
  (declare (indent 1))
  (let ((file (make-temp-file "orgmode-gtasks-sync-test-" nil ".org"
                              org-text)))
    (unwind-protect
        (progn ,@body)
      (when (get-file-buffer file)
        (with-current-buffer (get-file-buffer file)
          (set-buffer-modified-p nil)
          (kill-buffer)))
      (when (file-exists-p file)
        (delete-file file)))))

(defmacro org-mode-google-tasks-sync-integration-test--setup (org-text &rest body)
  "Set up mocks, create a temp org file with ORG-TEXT, and run BODY.
Restores all overridden variables on exit."
  (declare (indent 1))
  `(let ((org-mode-google-tasks-sync-integration-test--file
          (make-temp-file "orgmode-gtasks-sync-test-" nil ".org" ,org-text))
         (org-mode-google-tasks-sync-integration-test--saved-base-url
          org-mode-google-tasks-sync-api--base-url)
         (org-mode-google-tasks-sync-integration-test--saved-token-url
          org-mode-google-tasks-sync-oauth--token-url)
         (org-mode-google-tasks-sync-integration-test--saved-map
          org-mode-google-tasks-sync-map)
         (org-mode-google-tasks-sync-integration-test--saved-token
          org-mode-google-tasks-sync-engine--token)
         (org-mode-google-tasks-sync-integration-test--saved-state
          org-mode-google-tasks-sync-engine--state)
         (org-mode-google-tasks-sync-integration-test--saved-last-sync
          org-mode-google-tasks-sync-engine--last-sync-time)
         (org-mode-google-tasks-sync-integration-test--saved-keep-done
          (bound-and-true-p org-mode-google-tasks-sync-keep-done-items))
         (org-mode-google-tasks-sync-integration-test--saved-persist-trash
          (bound-and-true-p org-mode-google-tasks-sync-persist-trash)))
     (unwind-protect
         (progn
           (setq org-mode-google-tasks-sync-api--base-url
                 (org-mode-google-tasks-sync-integration-test--base-url))
           (setq org-mode-google-tasks-sync-oauth--token-url
                 org-mode-google-tasks-sync-integration--mockoon-token-url)
           (setq org-mode-google-tasks-sync-engine--token
                 (org-mode-google-tasks-sync-integration-test--fake-token))
           (setq org-mode-google-tasks-sync-engine--state 'idle)
           (setq org-mode-google-tasks-sync-engine--last-sync-time nil)
           (setq org-mode-google-tasks-sync-keep-done-items t)
           (setq org-mode-google-tasks-sync-persist-trash nil)
           (setq org-mode-google-tasks-sync-map
                 (list (cons org-mode-google-tasks-sync-integration-test--list-id
                             (cons org-mode-google-tasks-sync-integration-test--file
                                   "Inbox"))))
           ,@body)
       (setq org-mode-google-tasks-sync-api--base-url
             org-mode-google-tasks-sync-integration-test--saved-base-url)
       (setq org-mode-google-tasks-sync-oauth--token-url
             org-mode-google-tasks-sync-integration-test--saved-token-url)
       (setq org-mode-google-tasks-sync-map
             org-mode-google-tasks-sync-integration-test--saved-map)
       (setq org-mode-google-tasks-sync-engine--token
             org-mode-google-tasks-sync-integration-test--saved-token)
       (setq org-mode-google-tasks-sync-engine--state
             org-mode-google-tasks-sync-integration-test--saved-state)
       (setq org-mode-google-tasks-sync-engine--last-sync-time
             org-mode-google-tasks-sync-integration-test--saved-last-sync)
       (setq org-mode-google-tasks-sync-keep-done-items
             org-mode-google-tasks-sync-integration-test--saved-keep-done)
       (setq org-mode-google-tasks-sync-persist-trash
             org-mode-google-tasks-sync-integration-test--saved-persist-trash)
       (when (get-file-buffer org-mode-google-tasks-sync-integration-test--file)
         (with-current-buffer
             (get-file-buffer org-mode-google-tasks-sync-integration-test--file)
           (set-buffer-modified-p nil)
           (kill-buffer)))
       (when (file-exists-p org-mode-google-tasks-sync-integration-test--file)
         (delete-file org-mode-google-tasks-sync-integration-test--file))
       (when (get-buffer "*org-mode-google-tasks-sync-trash*")
         (kill-buffer "*org-mode-google-tasks-sync-trash*")))))

(ert-deftest org-mode-google-tasks-sync-integration-test/pull-creates-headings ()
  "A full sync against the mock pulls two tasks into an empty org file.
The mock serves `task-001' (Buy milk) and `task-002' (Walk dog), both
with `status=needsAction'.  After the sync, the org file should have
two TODO headings under `* Inbox', each with a `GTASK_ID' property."
  (org-mode-google-tasks-sync-integration-test--setup
      "* Inbox\n"
    (org-mode-google-tasks-sync-engine-run 'full)
    (org-mode-google-tasks-sync-integration-test--pump)
    (with-current-buffer
        (find-file-noselect
         org-mode-google-tasks-sync-integration-test--file)
      (goto-char (point-min))
      (re-search-forward "^\\*+ Inbox$")
      (should (re-search-forward "^\\*\\* TODO Buy milk$" nil t))
      (should (re-search-forward "^\\*\\* TODO Walk dog$" nil t))
      (goto-char (point-min))
      (should (re-search-forward ":GTASK_ID: task-001" nil t))
      (should (re-search-forward ":GTASK_ID: task-002" nil t)))))

(ert-deftest org-mode-google-tasks-sync-integration-test/pull-idempotent ()
  "Running a second full sync immediately after the first is a no-op.
No spurious pushes or deletes should occur.  The headings and their
`GTASK_ID' properties must remain stable."
  (org-mode-google-tasks-sync-integration-test--setup
      "* Inbox\n"
    (org-mode-google-tasks-sync-engine-run 'full)
    (org-mode-google-tasks-sync-integration-test--pump)
    (org-mode-google-tasks-sync-engine-run 'full)
    (org-mode-google-tasks-sync-integration-test--pump)
    (with-current-buffer
        (find-file-noselect
         org-mode-google-tasks-sync-integration-test--file)
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\* TODO Buy milk$" nil t))
      (should (re-search-forward "^\\*\\* TODO Walk dog$" nil t))
      (goto-char (point-min))
      (should (re-search-forward ":GTASK_ID: task-001" nil t))
      (should (re-search-forward ":GTASK_ID: task-002" nil t)))))

(ert-deftest org-mode-google-tasks-sync-integration-test/push-new-task ()
  "A new local heading with no `GTASK_ID' is pushed to the mock server.
After the sync, the heading should have a `GTASK_ID' property starting
with `new-' (the mock's templated ID prefix for inserted tasks)."
  (org-mode-google-tasks-sync-integration-test--setup
      "* Inbox\n** TODO New local task\nSome notes.\n"
    (org-mode-google-tasks-sync-engine-run 'full)
    (org-mode-google-tasks-sync-integration-test--pump)
    (with-current-buffer
        (find-file-noselect
         org-mode-google-tasks-sync-integration-test--file)
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\* TODO New local task$" nil t))
      (should (re-search-forward ":GTASK_ID: new-" nil t)))))

(provide 'happy-path-test)
;;; happy-path-test.el ends here
