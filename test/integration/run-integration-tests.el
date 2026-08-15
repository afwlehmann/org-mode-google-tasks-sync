;;; run-integration-tests.el --- Entry point for integration ert batch -*- lexical-binding: t -*-

;; Copyright (C) 2026 Alexander Lehmann
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Starts a Mockoon mock server (via npx @mockoon/cli) on a local port,
;; waits for it to be ready, runs the ert integration suite, and kills
;; the server in `unwind-protect' — regardless of pass or fail.
;;
;; Invoked by:
;;   nix develop --command emacs --batch \
;;     -l test/integration/run-integration-tests.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; or the CI equivalent (ubuntu-only).

;;; Code:

(require 'ert)

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (project-root (expand-file-name "../.." here)))
  (add-to-list 'load-path project-root)
  (add-to-list 'load-path (expand-file-name "test" project-root)))

(load (expand-file-name "test-helper.el"
                        (expand-file-name
                         "../"
                         (file-name-directory
                          (or load-file-name buffer-file-name)))))

(defvar org-mode-google-tasks-sync-integration--mockoon-port 3000
  "Port for the Mockoon mock server.")

(defvar org-mode-google-tasks-sync-integration--mockoon-process nil
  "Process object for the Mockoon mock server, or nil when not running.")

(defvar org-mode-google-tasks-sync-integration--mockoon-base-url
  (format "http://127.0.0.1:%d/tasks/v1"
          org-mode-google-tasks-sync-integration--mockoon-port)
  "Base URL for the mocked Google Tasks API.")

(defvar org-mode-google-tasks-sync-integration--mockoon-token-url
  (format "http://127.0.0.1:%d/oauth2/token"
          org-mode-google-tasks-sync-integration--mockoon-port)
  "Mocked OAuth2 token endpoint URL.")

(defun org-mode-google-tasks-sync-integration--mockoon-env ()
  "Return the absolute path to the Mockoon environment JSON file."
  (expand-file-name
   "mockoon-environment.json"
   (file-name-directory (or load-file-name buffer-file-name))))

(defun org-mode-google-tasks-sync-integration--start-mockoon ()
  "Start the Mockoon mock server as an asynchronous subprocess.
Returns the process object on success, signals an error otherwise."
  (let* ((env (org-mode-google-tasks-sync-integration--mockoon-env))
         (port (number-to-string
                org-mode-google-tasks-sync-integration--mockoon-port))
         (proc (make-process
                :name "mockoon"
                :command (list "npx" "--yes" "@mockoon/cli" "start"
                               "--data" env
                               "--port" port
                               "--hostname" "127.0.0.1"
                               "--disable-log-to-file"
                               "--disable-admin-api")
                :connection-type 'pipe
                :stderr (get-buffer-create "*mockoon-stderr*")
                :noquery t)))
    (setq org-mode-google-tasks-sync-integration--mockoon-process proc)
    proc))

(defun org-mode-google-tasks-sync-integration--mockoon-ready-p ()
  "Return non-nil if the Mockoon server is responding to requests."
  (condition-case nil
      (let ((url-show-to-url nil))
        (with-current-buffer
            (url-retrieve-synchronously
             (format "http://127.0.0.1:%d/tasks/v1/users/@me/lists"
                     org-mode-google-tasks-sync-integration--mockoon-port)
             nil t 5)
          t))
    (error nil)))

(defun org-mode-google-tasks-sync-integration--wait-for-mockoon
    (&optional timeout)
  "Poll until Mockoon responds or TIMEOUT seconds elapse (default 30).
Signals an error if the server does not become ready in time."
  (let ((deadline (+ (float-time) (or timeout 30))))
    (while (and (> deadline (float-time))
                (not (org-mode-google-tasks-sync-integration--mockoon-ready-p)))
      (sit-for 0.5))
    (unless (org-mode-google-tasks-sync-integration--mockoon-ready-p)
      (error "Mockoon did not start within %d seconds"
             (or timeout 30)))))

(defun org-mode-google-tasks-sync-integration--stop-mockoon ()
  "Kill the Mockoon mock server process if it is running."
  (when (and org-mode-google-tasks-sync-integration--mockoon-process
             (process-live-p
              org-mode-google-tasks-sync-integration--mockoon-process))
    (delete-process org-mode-google-tasks-sync-integration--mockoon-process))
  (setq org-mode-google-tasks-sync-integration--mockoon-process nil))

(defun org-mode-google-tasks-sync-integration--run ()
  "Start Mockoon, run the ert suite, and stop Mockoon."
  (org-mode-google-tasks-sync-integration--start-mockoon)
  (unwind-protect
      (progn
        (org-mode-google-tasks-sync-integration--wait-for-mockoon)
        (let ((here (file-name-directory (or load-file-name buffer-file-name))))
          (load (expand-file-name "happy-path-test.el" here)))
        (ert-run-tests-batch-and-exit))
    (org-mode-google-tasks-sync-integration--stop-mockoon)))

(org-mode-google-tasks-sync-integration--run)

(provide 'run-integration-tests)
;;; run-integration-tests.el ends here
