;;; org-mode-google-tasks-sync-engine-test.el --- Tests for the sync engine -*- lexical-binding: t -*-

;;; Commentary:

;; Covers the 4-cell conflict matrix, remote/local struct conversion, and the
;; API data payload shape.  Network calls are not exercised here.

;;; Code:

(require 'ert)
(require 'parse-time)
(require 'org-mode-google-tasks-sync-engine)

;;; -- The 4-cell conflict matrix --------------------------------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-skip ()
  (let ((org-mode-google-tasks-sync-keep-done-items t))
    (should (eq 'skip
                (org-mode-google-tasks-sync-engine--decide nil nil nil nil)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-push ()
  (let ((org-mode-google-tasks-sync-keep-done-items t))
    (should (eq 'push
                (org-mode-google-tasks-sync-engine--decide t nil nil nil)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-pull ()
  (let ((org-mode-google-tasks-sync-keep-done-items t))
    (should (eq 'pull
                (org-mode-google-tasks-sync-engine--decide
                 nil t nil "2026-06-27T10:00:00Z")))))

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-conflict-remote-wins ()
  ;; remote.updated is after local-mtime → remote wins
  (let ((org-mode-google-tasks-sync-keep-done-items t)
        (local-mtime (float-time (parse-iso8601-time-string "2026-06-27T10:00:00Z")))
        (remote-updated "2026-06-27T11:00:00Z"))
    (should (eq 'conflict-remote-wins
                (org-mode-google-tasks-sync-engine--decide
                 t t local-mtime remote-updated)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-conflict-local-wins ()
  ;; local-mtime is after remote.updated → local wins
  (let ((org-mode-google-tasks-sync-keep-done-items t)
        (local-mtime (float-time (parse-iso8601-time-string "2026-06-27T12:00:00Z")))
        (remote-updated "2026-06-27T11:00:00Z"))
    (should (eq 'conflict-local-wins
                (org-mode-google-tasks-sync-engine--decide
                 t t local-mtime remote-updated)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-both-done-conflict ()
  "Both sides mark the task done, remote newer → conflict-remote-wins.
When the task is completed on both sides, the status field (which is in
the canonical hash) differs from the stored hash on both sides, so both
local-changed and remote-changed are true.  The newer remote timestamp
wins rather than emitting a redundant push that would hit an already-done
remote task."
  (let ((org-mode-google-tasks-sync-keep-done-items t)
        (local-mtime (float-time (parse-iso8601-time-string "2026-06-27T10:00:00Z")))
        (remote-updated "2026-06-27T11:00:00Z"))
    (should (eq 'conflict-remote-wins
                (org-mode-google-tasks-sync-engine--decide
                 t t local-mtime remote-updated)))))

;;; -- DONE-handling fast paths (keep-done-items = nil) -----------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-done-remove-when-remote-completed ()
  "When keep-done-items is nil and remote is completed, the decision is
`done-remove-local' regardless of local-changed/remote-changed —
remote always wins for DONE removal."
  (let ((org-mode-google-tasks-sync-keep-done-items nil))
    (should (eq 'done-remove-local
                (org-mode-google-tasks-sync-engine--decide
                 nil nil nil nil nil 'completed)))
    ;; Even on a both-changed conflict.
    (should (eq 'done-remove-local
                (org-mode-google-tasks-sync-engine--decide
                 t t 1700000000.0 "2026-06-27T11:00:00Z" nil 'completed)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-done-push-when-local-completed ()
  "When keep-done-items is nil and local is completed (but remote is not),
the decision is `done-push-then-remove'."
  (let ((org-mode-google-tasks-sync-keep-done-items nil))
    (should (eq 'done-push-then-remove
                (org-mode-google-tasks-sync-engine--decide
                 nil nil nil nil 'completed nil)))
    ;; Remote also changed (e.g. a content edit) — local-done still wins
    ;; the fast path because remote-status is not 'completed.
    (should (eq 'done-push-then-remove
                (org-mode-google-tasks-sync-engine--decide
                 t t 1700000000.0 "2026-06-27T11:00:00Z" 'completed nil)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-done-remote-wins-over-local ()
  "When both sides are completed and keep-done-items is nil, remote-done
takes precedence (done-remove-local) — the task is removed locally
without a redundant push."
  (let ((org-mode-google-tasks-sync-keep-done-items nil))
    (should (eq 'done-remove-local
                (org-mode-google-tasks-sync-engine--decide
                 t t 1700000000.0 "2026-06-27T11:00:00Z"
                 'completed 'completed)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-done-skip-when-keep-on ()
  "When keep-done-items is t, the DONE fast paths don't fire and the
normal 4-cell matrix applies."
  (let ((org-mode-google-tasks-sync-keep-done-items t))
    (should (eq 'skip
                (org-mode-google-tasks-sync-engine--decide
                 nil nil nil nil 'completed 'completed)))))

;;; -- RFC3339 parsing -------------------------------------------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/rfc3339-roundtrip ()
  (let* ((s "2026-06-27T10:00:00Z")
         (f (org-mode-google-tasks-sync-engine--rfc3339-to-float s)))
    (should (numberp f))
    (should (> f 1700000000))))

(ert-deftest org-mode-google-tasks-sync-engine-test/rfc3339-nil-on-garbage ()
  (should (null (org-mode-google-tasks-sync-engine--rfc3339-to-float nil)))
  (should (null (org-mode-google-tasks-sync-engine--rfc3339-to-float ""))))

;;; -- Remote → struct conversion --------------------------------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/remote->struct-basic ()
  (let* ((remote '((id . "abc")
                   (title . "Buy milk")
                   (notes . "Two liters")
                   (status . "needsAction")
                   (due . "2026-06-27T00:00:00.000Z")
                   (updated . "2026-06-27T10:00:00.000Z")
                   (etag . "\"etag-1\"")))
         (task (org-mode-google-tasks-sync-engine--remote-task->struct remote "L1" nil)))
    (should (equal "abc" (org-mode-google-tasks-sync-org-task-id task)))
    (should (equal "L1"  (org-mode-google-tasks-sync-org-task-list-id task)))
    (should (equal "Buy milk" (org-mode-google-tasks-sync-org-task-title task)))
    (should (equal "Two liters" (org-mode-google-tasks-sync-org-task-notes task)))
    (should (eq 'needsAction (org-mode-google-tasks-sync-org-task-status task)))
    (should (equal "2026-06-27" (org-mode-google-tasks-sync-org-task-due task)))
    (should (equal "\"etag-1\"" (org-mode-google-tasks-sync-org-task-etag task)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/remote->struct-completed-status ()
  (let* ((remote '((id . "x") (title . "Done") (status . "completed")))
         (task (org-mode-google-tasks-sync-engine--remote-task->struct remote "L1" nil)))
    (should (eq 'completed (org-mode-google-tasks-sync-org-task-status task)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/remote->struct-no-due ()
  (let* ((remote '((id . "x") (title . "Y") (status . "needsAction")))
         (task (org-mode-google-tasks-sync-engine--remote-task->struct remote "L1" nil)))
    (should (null (org-mode-google-tasks-sync-org-task-due task)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/remote->struct-extracts-links ()
  "`--remote-task->struct' picks up `links' and `webViewLink' from the remote response.
The `links' array is JSON-serialized for storage in the property drawer;
`webViewLink' is stored as a plain string.  Both are read-only display
metadata — never in the canonical hash, never in the push payload."
  (let* ((remote `((id . "abc")
                   (title . "Task with links")
                   (status . "needsAction")
                   (links . [((type . "email")
                              (description . "Related email")
                              (link . "https://mail.google.com/foo"))])
                   (webViewLink . "https://tasks.googleapis.com/tasks/v1/abc")))
         (task (org-mode-google-tasks-sync-engine--remote-task->struct remote "L" nil)))
    (should (org-mode-google-tasks-sync-org-task-links task))
    (should (string-match-p "Related email" (org-mode-google-tasks-sync-org-task-links task)))
    (should (string-match-p "https://mail.google.com/foo"
                            (org-mode-google-tasks-sync-org-task-links task)))
    (should (equal "https://tasks.googleapis.com/tasks/v1/abc"
                   (org-mode-google-tasks-sync-org-task-web-view-link task)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/remote->struct-no-links ()
  "When the remote response has no `links' or `webViewLink', the struct slots are nil."
  (let* ((remote '((id . "x") (title . "Plain") (status . "needsAction")))
         (task (org-mode-google-tasks-sync-engine--remote-task->struct remote "L" nil)))
    (should (null (org-mode-google-tasks-sync-org-task-links task)))
    (should (null (org-mode-google-tasks-sync-org-task-web-view-link task)))))

;;; -- Struct → API payload ---------------------------------------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/task->api-data-basic ()
  (let* ((task (make-org-mode-google-tasks-sync-org-task
                :title "Buy milk" :notes "Two liters"
                :status 'needsAction :due "2026-06-27"))
         (data (org-mode-google-tasks-sync-engine--task->api-data task)))
    (should (equal "Buy milk" (alist-get 'title data)))
    (should (equal "Two liters" (alist-get 'notes data)))
    (should (equal "needsAction" (alist-get 'status data)))
    (should (equal "2026-06-27T00:00:00.000Z" (alist-get 'due data)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/task->api-data-no-due ()
  (let* ((task (make-org-mode-google-tasks-sync-org-task
                :title "Buy milk" :status 'needsAction))
         (data (org-mode-google-tasks-sync-engine--task->api-data task)))
    (should-not (assoc 'due data))))

(ert-deftest org-mode-google-tasks-sync-engine-test/task->api-data-completed ()
  (let* ((task (make-org-mode-google-tasks-sync-org-task
                 :title "Buy milk" :status 'completed))
          (data (org-mode-google-tasks-sync-engine--task->api-data task)))
    (should (equal "completed" (alist-get 'status data)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/task->api-data-omits-links ()
  "Links and webViewLink are read-only; the push payload never includes them."
  (let* ((task (make-org-mode-google-tasks-sync-org-task
                :title "Buy milk" :status 'needsAction
                :links "[{\"type\":\"email\"}]"
                :web-view-link "https://tasks.googleapis.com/abc"))
         (data (org-mode-google-tasks-sync-engine--task->api-data task)))
    (should-not (assoc 'links data))
    (should-not (assoc 'webViewLink data))))

;;; -- Non-ASCII encoding ------------------------------------------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/task->api-data-non-ascii-title ()
  "Non-ASCII characters in the title survive the struct→alist conversion."
  (let* ((task (make-org-mode-google-tasks-sync-org-task
                :title "Wöchentliche · Überprüfung"
                :status 'needsAction))
         (data (org-mode-google-tasks-sync-engine--task->api-data task)))
    (should (equal "Wöchentliche · Überprüfung" (alist-get 'title data)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/task->api-data-non-ascii-notes ()
  "Non-ASCII characters in notes survive even when the title is pure ASCII.
Covers the case where only the body (not the title) carries non-ASCII —
the original symptom for tasks like \"PayPal\" and \"FAZID Banner Epic\"."
  (let* ((task (make-org-mode-google-tasks-sync-org-task
                :title "PayPal"
                :notes "Zahlung über Fußweg"
                :status 'needsAction))
         (data (org-mode-google-tasks-sync-engine--task->api-data task)))
    (should (equal "PayPal" (alist-get 'title data)))
    (should (equal "Zahlung über Fußweg" (alist-get 'notes data)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/serialize-json-returns-unibyte ()
  "The serialized JSON body is a unibyte string: length == string-bytes.
This is the invariant curl's CURLOPT_POSTFIELDSIZE requires; violating it
surfaces as CURLE_FAILED_INIT (2) on any body with non-ASCII code points."
  (let* ((data `((title . "Wöchentliche · Überprüfung")
                 (notes . "Zahlung über Fußweg")
                 (status . "needsAction")))
         (body (org-mode-google-tasks-sync-api--serialize-json data)))
    (should (stringp body))
    (should (eq (length body) (string-bytes body)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/serialize-json-preserves-non-ascii-codepoints ()
  "Non-ASCII codepoints survive a serialize → parse round-trip."
  (let* ((data `((title . "Wöchentliche · Überprüfung")
                 (notes . "Zahlung über Fußweg")
                 (status . "needsAction")))
         (body (org-mode-google-tasks-sync-api--serialize-json data))
         (back (json-parse-string body
                                  :object-type 'alist
                                  :null-object nil
                                  :false-object :false)))
    (should (equal "Wöchentliche · Überprüfung" (alist-get 'title back)))
    (should (equal "Zahlung über Fußweg" (alist-get 'notes back)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/run-keeps-state-idle-on-token-error ()
  "If `engine--token' throws, `engine-run' must leave `--state' alone.
Regression for the deadlock where a GPG-not-found error left the
state machine stuck at `fetching', causing every subsequent tick to
take the `Skip tick: sync in flight' early-return until Emacs restart."
  (let ((org-mode-google-tasks-sync-engine--state 'idle)
        (org-mode-google-tasks-sync-map '(("L" . ("/tmp/x.org" . "h")))))
    (cl-letf (((symbol-function 'org-mode-google-tasks-sync-engine--token)
               (lambda () (signal 'error '("simulated GPG failure")))))
      (should-error (org-mode-google-tasks-sync-engine-run 'incremental))
      (should (eq org-mode-google-tasks-sync-engine--state 'idle)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/token-returns-cached-when-not-expired ()
  "A cached token whose `expires-at' is in the future is returned as-is.
`oauth-make-token' must not be called."
  (let ((org-mode-google-tasks-sync-engine--token
         (make-org-mode-google-tasks-sync-api-token
          :access-token "cached"
          :expires-at (+ (float-time) 3600))))
    (cl-letf (((symbol-function 'org-mode-google-tasks-sync-oauth-make-token)
               (lambda () (error "oauth-make-token should not be called"))))
      (let ((tok (org-mode-google-tasks-sync-engine--token)))
        (should (equal "cached"
                       (org-mode-google-tasks-sync-api-token-access-token tok)))
        (should (eq tok org-mode-google-tasks-sync-engine--token))))))

(ert-deftest org-mode-google-tasks-sync-engine-test/token-refreshes-when-expired ()
  "A cached token past its `expires-at' is replaced by a fresh one."
  (let ((org-mode-google-tasks-sync-engine--token
         (make-org-mode-google-tasks-sync-api-token
          :access-token "stale"
          :expires-at (1- (float-time)))))
    (cl-letf (((symbol-function 'org-mode-google-tasks-sync-oauth-make-token)
               (lambda ()
                 (make-org-mode-google-tasks-sync-api-token
                  :access-token "fresh"
                  :expires-at (+ (float-time) 3600)))))
      (let ((tok (org-mode-google-tasks-sync-engine--token)))
        (should (equal "fresh"
                       (org-mode-google-tasks-sync-api-token-access-token tok)))
        (should (eq tok org-mode-google-tasks-sync-engine--token))))))

(ert-deftest org-mode-google-tasks-sync-engine-test/token-refreshes-when-expires-at-nil ()
  "A cached token with nil `expires-at' is treated as expired and refreshed."
  (let ((org-mode-google-tasks-sync-engine--token
         (make-org-mode-google-tasks-sync-api-token
          :access-token "unknown-expiry")))
    (cl-letf (((symbol-function 'org-mode-google-tasks-sync-oauth-make-token)
               (lambda ()
                 (make-org-mode-google-tasks-sync-api-token
                  :access-token "fresh"
                  :expires-at (+ (float-time) 3600)))))
      (let ((tok (org-mode-google-tasks-sync-engine--token)))
        (should (equal "fresh"
                       (org-mode-google-tasks-sync-api-token-access-token tok)))
        (should (eq tok org-mode-google-tasks-sync-engine--token))))))

(ert-deftest org-mode-google-tasks-sync-engine-test/timeout-resets-stuck-state ()
  "When the timeout timer fires while state is not idle, it resets to idle."
  (let ((org-mode-google-tasks-sync-engine--state 'fetching))
    (org-mode-google-tasks-sync-engine--on-timeout)
    (should (eq org-mode-google-tasks-sync-engine--state 'idle))))

(ert-deftest org-mode-google-tasks-sync-engine-test/timeout-noop-when-idle ()
  "If the sync completed before the timeout fires, the timer is a no-op."
  (let ((org-mode-google-tasks-sync-engine--state 'idle))
    (org-mode-google-tasks-sync-engine--on-timeout)
    (should (eq org-mode-google-tasks-sync-engine--state 'idle))))

(ert-deftest org-mode-google-tasks-sync-engine-test/cancel-timeout-clears-timer ()
  "Cancelling the timeout clears the timer slot."
  (let ((org-mode-google-tasks-sync-engine--timeout-timer
         (run-at-time 1000 nil #'ignore)))
    (unwind-protect
        (progn
          (org-mode-google-tasks-sync-engine--cancel-timeout)
          (should (null org-mode-google-tasks-sync-engine--timeout-timer)))
      (when org-mode-google-tasks-sync-engine--timeout-timer
        (cancel-timer org-mode-google-tasks-sync-engine--timeout-timer)))))

(require 'org-mode-google-tasks-sync)

(ert-deftest org-mode-google-tasks-sync-engine-test/after-save-hook-respects-inhibit ()
  "After-save-hook is a no-op while the engine is saving its own write."
  (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t)
        (org-mode-google-tasks-sync-map
         '(("L" . ("/tmp/gtasks-after-save-test.org" . "Inbox"))))
        (scheduled nil))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest args) (setq scheduled args))))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/gtasks-after-save-test.org")
        (org-mode-google-tasks-sync--after-save-hook)
        (should-not scheduled)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/after-save-hook-fires-when-not-inhibited ()
  "After-save-hook schedules a sync when not inhibited and the file is a target."
  (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks nil)
        (org-mode-google-tasks-sync-map
         '(("L" . ("/tmp/gtasks-after-save-test.org" . "Inbox"))))
        (scheduled nil))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest args) (setq scheduled args))))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/gtasks-after-save-test.org")
        (org-mode-google-tasks-sync--after-save-hook)
        (should scheduled)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/parent-marker-auto-creates ()
  "When the parent heading is absent, the helper creates it and returns a marker."
  (let ((file (make-temp-file "gtasks-parent-test" nil ".org")))
    (unwind-protect
        (let ((marker (org-mode-google-tasks-sync-engine--parent-marker file "Inbox")))
          (should marker)
          (with-current-buffer (find-file-noselect file)
            (goto-char (point-min))
            (should (re-search-forward "^\\* Inbox$" nil t))
            (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
              (set-buffer-modified-p nil))
            (kill-buffer)))
      (delete-file file))))

(ert-deftest org-mode-google-tasks-sync-engine-test/parent-marker-finds-existing ()
  "When the parent heading already exists, the helper returns its marker without duplicating it."
  (let ((file (make-temp-file "gtasks-parent-existing" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+TITLE: Tasks\n\n* Inbox\n** TODO Some pre-existing task\n"))
          (let ((marker (org-mode-google-tasks-sync-engine--parent-marker file "Inbox")))
            (should marker)
            (with-current-buffer (find-file-noselect file)
              (goto-char (point-min))
              ;; Exactly one "* Inbox" line — no duplicate created.
              (should (re-search-forward "^\\* Inbox$" nil t))
              (should-not (re-search-forward "^\\* Inbox$" nil t))
              (kill-buffer))))
      (delete-file file))))

;;; Sort + position round-trip

(ert-deftest org-mode-google-tasks-sync-engine-test/remote->struct-extracts-position-and-completed ()
  "`--remote-task->struct' picks up the new `position' and `completed' fields."
  (let* ((remote '((id . "abc") (title . "X") (status . "completed")
                   (position . "00000000000000000010")
                   (completed . "2026-06-27T10:00:00.000Z")))
         (task (org-mode-google-tasks-sync-engine--remote-task->struct
                remote "L" nil)))
    (should (equal "00000000000000000010"
                   (org-mode-google-tasks-sync-org-task-position task)))
    (should (equal "2026-06-27T10:00:00.000Z"
                   (org-mode-google-tasks-sync-org-task-completed task)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/compare-tasks-orders-todo-before-done ()
  (should (org-mode-google-tasks-sync-engine--compare-tasks
           (list nil "01" "")
           (list t   "00" "2026-06-27T10:00:00Z")))
  (should-not (org-mode-google-tasks-sync-engine--compare-tasks
               (list t   "00" "2026-06-27T10:00:00Z")
               (list nil "01" ""))))

(ert-deftest org-mode-google-tasks-sync-engine-test/compare-tasks-todo-by-position-asc ()
  (should (org-mode-google-tasks-sync-engine--compare-tasks
           (list nil "00" "")
           (list nil "10" "")))
  (should-not (org-mode-google-tasks-sync-engine--compare-tasks
               (list nil "10" "")
               (list nil "00" ""))))

(ert-deftest org-mode-google-tasks-sync-engine-test/compare-tasks-done-by-completed-desc ()
  (should (org-mode-google-tasks-sync-engine--compare-tasks
           (list t "" "2026-06-27T12:00:00Z")     ; newer
           (list t "" "2026-06-27T08:00:00Z")))   ; older
  (should-not (org-mode-google-tasks-sync-engine--compare-tasks
               (list t "" "2026-06-27T08:00:00Z")
               (list t "" "2026-06-27T12:00:00Z"))))

;;; -- Full-sync deletion sweep ------------------------------------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/sweep-deletes-absent-ids ()
  "Full-sync sweep removes local tasks whose IDs are absent from the remote set."
  (let ((file (make-temp-file "gtasks-sweep-absent" nil ".org")))
    (unwind-protect
        (progn
          (when (get-buffer "*org-mode-google-tasks-sync-trash*")
            (kill-buffer "*org-mode-google-tasks-sync-trash*"))
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO Keep me\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: keep\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"
                    "** TODO Delete me\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: drop\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"))
          (let* ((remote `((id . "keep")
                           (title . "Keep me")
                           (status . "needsAction")
                           (updated . "2026-01-01T00:00:00.000Z"))))
            (cl-letf (((symbol-function 'org-mode-google-tasks-sync-engine--push-update)
                       (lambda (&rest _) t))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--push-new-queue)
                       (lambda (_token _list-id _tasks _file done)
                         (funcall done)))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--resolve-reorder-drift)
                       (lambda (_token _list-id _pairs _file done)
                         (funcall done)))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--repair-position-ties)
                       (lambda (_token _list-id _parent _file done)
                         (funcall done))))
              (org-mode-google-tasks-sync-engine--apply
               nil "L" file "Tasks" 'full
               (list remote)
               #'ignore))))
      (with-current-buffer (find-file-noselect file)
        (widen)
        (goto-char (point-min))
        (should (re-search-forward "Keep me" nil t))
        (should-not (re-search-forward "Delete me" nil t))
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (set-buffer-modified-p nil))
        (kill-buffer))
      (delete-file file))))

(ert-deftest org-mode-google-tasks-sync-engine-test/sweep-snapshots-to-trash ()
  "Engine-side deletion (sweep) snapshots the task to the trash buffer.
Regression for the README/implementation mismatch: README claims
engine deletions are recoverable, but the code never snapshotted."
  (let ((file (make-temp-file "gtasks-sweep-trash" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO Delete me\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: drop\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"))
          (cl-letf (((symbol-function 'org-mode-google-tasks-sync-engine--push-update)
                     (lambda (&rest _) t))
                    ((symbol-function 'org-mode-google-tasks-sync-engine--push-new-queue)
                     (lambda (_token _list-id _tasks _file done)
                       (funcall done))))
            (org-mode-google-tasks-sync-engine--apply
             nil "L" file "Tasks" 'full nil #'ignore)))
      (with-current-buffer (get-buffer-create
                            "*org-mode-google-tasks-sync-trash*")
        (goto-char (point-min))
        (should (re-search-forward "Delete me" nil t)))
      (with-current-buffer (find-file-noselect file)
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (set-buffer-modified-p nil))
        (kill-buffer))
      (delete-file file)
      (when (get-buffer "*org-mode-google-tasks-sync-trash*")
        (kill-buffer "*org-mode-google-tasks-sync-trash*")))))

;;; -- duplicate GTASK_ID dedup -------------------------------------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/dedup-duplicate-ids-at-any-level ()
  "`--apply' removes duplicate local headings that share the same
GTASK_ID, at any level (top-level tasks and subtasks alike).  Runs
in both `incremental' and `full' modes — mirrors the hidden-task
removal precedent (data-integrity fixes run regardless of mode).
The last heading per ID wins; earlier shadows are deleted with a
trash snapshot.  Regression for the pre-0.5.5 subtask-doubling bug
where `--headline-body' leaked child heading text into the parent's
notes, causing the push callback to re-insert children as new
headings on every sync."
  (let ((file (make-temp-file "gtasks-dedup" nil ".org")))
    (unwind-protect
        (progn
          (when (get-buffer "*org-mode-google-tasks-sync-trash*")
            (kill-buffer "*org-mode-google-tasks-sync-trash*"))
          (with-temp-file file
            (insert "* Tasks\n"
                    ;; Two top-level headings sharing GTASK_ID "dup-top".
                    "** TODO Top A\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: dup-top\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"
                    "** TODO Top B (duplicate of A)\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: dup-top\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"
                    ;; A parent with two subtask headings sharing GTASK_ID "dup-sub".
                    "** TODO Parent\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: parent-1\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"
                    "*** TODO Sub A\n"
                    "    :PROPERTIES:\n"
                    "    :GTASK_ID: dup-sub\n"
                    "    :GTASK_LIST: L\n"
                    "    :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "    :GTASK_CONTENT_HASH: x\n"
                    "    :END:\n"
                    "*** TODO Sub B (duplicate of Sub A)\n"
                    "    :PROPERTIES:\n"
                    "    :GTASK_ID: dup-sub\n"
                    "    :GTASK_LIST: L\n"
                    "    :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "    :GTASK_CONTENT_HASH: x\n"
                    "    :END:\n"))
          (let* ((remote `(((id . "dup-top")
                            (title . "Top B (duplicate of A)")
                            (status . "needsAction")
                            (updated . "2026-01-01T00:00:00.000Z"))
                           ((id . "parent-1")
                            (title . "Parent")
                            (status . "needsAction")
                            (updated . "2026-01-01T00:00:00.000Z"))
                           ((id . "dup-sub")
                            (title . "Sub B (duplicate of Sub A)")
                            (status . "needsAction")
                            (parent . "parent-1")
                            (updated . "2026-01-01T00:00:00.000Z")))))
            (cl-letf (((symbol-function 'org-mode-google-tasks-sync-engine--push-update)
                       (lambda (&rest _) t))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--push-new-queue)
                        (lambda (_token _list-id _tasks _file done)
                          (funcall done)))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--resolve-reorder-drift)
                        (lambda (_token _list-id _pairs _file done)
                          (funcall done)))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--repair-position-ties)
                        (lambda (_token _list-id _parent _file done)
                          (funcall done))))
              ;; Incremental mode: dedup must run even when the IDs are
              ;; present in the remote response.
              (org-mode-google-tasks-sync-engine--apply
               nil "L" file "Tasks" 'incremental
               remote
               #'ignore)))
          (with-current-buffer (find-file-noselect file)
            (widen)
            (goto-char (point-min))
            ;; Exactly one heading per GTASK_ID survives.
            (should (re-search-forward "Top B" nil t))
            (should-not (re-search-forward "Top A$" nil t))
            (should (re-search-forward "Sub B" nil t))
            (should-not (re-search-forward "Sub A$" nil t))
            ;; Duplicates were snapshotted to trash.
            (with-current-buffer (get-buffer-create
                                  "*org-mode-google-tasks-sync-trash*")
              (goto-char (point-min))
              (should (re-search-forward "Top A" nil t))
              (should (re-search-forward "Sub A" nil t)))
            (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
              (set-buffer-modified-p nil))
            (kill-buffer)))
      (delete-file file)
      (when (get-buffer "*org-mode-google-tasks-sync-trash*")
        (kill-buffer "*org-mode-google-tasks-sync-trash*")))))

;;; -- showCompleted pinned in list-tasks query -------------------------------

;;; -- hidden tasks are filtered and removed locally --------------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/hidden-task-removed-locally ()
  "A remote task with `hidden=true' is filtered from the live remote
set and any matching local heading is removed via `--delete-local'
with reason `hidden-archived'.  Runs in incremental mode too (not
gated on `full' like the absent-id sweep)."
  (let ((file (make-temp-file "gtasks-hidden-remove" nil ".org")))
    (unwind-protect
        (progn
          (when (get-buffer "*org-mode-google-tasks-sync-trash*")
            (kill-buffer "*org-mode-google-tasks-sync-trash*"))
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO Visible\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: vis\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"
                    "** TODO Cleared\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: clr\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"))
          (let ((remote `(((id . "vis")
                           (title . "Visible")
                           (status . "needsAction")
                           (updated . "2026-01-01T00:00:00.000Z"))
                          ((id . "clr")
                           (title . "Cleared")
                           (status . "completed")
                           (hidden . t)
                           (updated . "2026-01-01T00:00:00.000Z")))))
            (cl-letf (((symbol-function 'org-mode-google-tasks-sync-engine--push-update)
                       (lambda (&rest _) t))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--push-new-queue)
                       (lambda (_token _list-id _tasks _file done)
                         (funcall done)))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--resolve-reorder-drift)
                       (lambda (_token _list-id _pairs _file done)
                         (funcall done)))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--repair-position-ties)
                       (lambda (_token _list-id _parent _file done)
                         (funcall done))))
              (org-mode-google-tasks-sync-engine--apply
               nil "L" file "Tasks" 'incremental remote #'ignore))))
      (with-current-buffer (find-file-noselect file)
        (widen)
        (goto-char (point-min))
        (should (re-search-forward "Visible" nil t))
        (should-not (re-search-forward "Cleared" nil t))
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (set-buffer-modified-p nil))
        (kill-buffer))
      ;; Trash snapshot carries the hidden-archived reason.
      (with-current-buffer (get-buffer-create
                            "*org-mode-google-tasks-sync-trash*")
        (goto-char (point-min))
        (should (re-search-forward "Cleared" nil t))
        (should (re-search-forward "hidden-archived" nil t)))
      (delete-file file)
      (when (get-buffer "*org-mode-google-tasks-sync-trash*")
        (kill-buffer "*org-mode-google-tasks-sync-trash*")))))

(ert-deftest org-mode-google-tasks-sync-engine-test/hidden-task-not-pulled-into-buffer ()
  "A remote task with `hidden=true' that has NO local heading is not
inserted — the hidden filter drops it before the pull pass."
  (let ((file (make-temp-file "gtasks-hidden-nopull" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n"))
          (let ((remote `(((id . "clr")
                           (title . "Cleared")
                           (status . "completed")
                           (hidden . t)
                           (updated . "2026-01-01T00:00:00.000Z")))))
            (cl-letf (((symbol-function 'org-mode-google-tasks-sync-engine--push-update)
                       (lambda (&rest _) t))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--push-new-queue)
                       (lambda (_token _list-id _tasks _file done)
                         (funcall done)))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--resolve-reorder-drift)
                       (lambda (_token _list-id _pairs _file done)
                         (funcall done)))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--repair-position-ties)
                       (lambda (_token _list-id _parent _file done)
                         (funcall done))))
              (org-mode-google-tasks-sync-engine--apply
               nil "L" file "Tasks" 'incremental remote #'ignore))))
      (with-current-buffer (find-file-noselect file)
        (widen)
        (goto-char (point-min))
        (should-not (re-search-forward "Cleared" nil t))
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (set-buffer-modified-p nil))
        (kill-buffer))
      (delete-file file))))

;;; -- showCompleted pinned in list-tasks query (cont.) -----------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/list-tasks-pins-showCompleted ()
  "The list-tasks API call must pin showCompleted=true.
Without it, Google may omit completed tasks from a complete response,
and the full-sync deletion sweep would then nuke every local DONE
heading — the 'items vanish on full sync' bug."
  (let (captured-url)
    (cl-letf (((symbol-function 'plz)
               (lambda (_method url &rest keys)
                 (setq captured-url url)
                 (funcall (plist-get keys :then)
                          '((items . nil) (nextPageToken . nil))))))
      (org-mode-google-tasks-sync-api-list-tasks
       (make-org-mode-google-tasks-sync-api-token
        :access-token "fake")
       "LIST-ID" nil #'ignore #'ignore))
    (should captured-url)
    (should (string-match-p "showCompleted=true" captured-url))))

;;; -- move-task query string (previous param for sibling reordering) --------

(ert-deftest org-mode-google-tasks-sync-engine-test/move-task-omits-previous-when-nil ()
  "`api-move-task' omits the `previous' query param when nil.
Backward compatibility for the reparenting call site which passes
only `new-parent-id'."
  (let (captured-url)
    (cl-letf (((symbol-function 'plz)
               (lambda (_method url &rest keys)
                 (setq captured-url url)
                 (funcall (plist-get keys :then) '((id . "t"))))))
      (org-mode-google-tasks-sync-api-move-task
       (make-org-mode-google-tasks-sync-api-token
        :access-token "fake")
       "LIST" "TASK" #'ignore #'ignore "PARENT" nil))
    (should captured-url)
    (should (string-match-p "parent=PARENT" captured-url))
    (should-not (string-match-p "previous=" captured-url))))

(ert-deftest org-mode-google-tasks-sync-engine-test/move-task-includes-previous-when-given ()
  "`api-move-task' includes `previous' in the query string when given.
This is the sibling-reorder path: same parent (or nil), insert after
PREVIOUS."
  (let (captured-url)
    (cl-letf (((symbol-function 'plz)
               (lambda (_method url &rest keys)
                 (setq captured-url url)
                 (funcall (plist-get keys :then) '((id . "t"))))))
      (org-mode-google-tasks-sync-api-move-task
       (make-org-mode-google-tasks-sync-api-token
        :access-token "fake")
       "LIST" "TASK" #'ignore #'ignore "PARENT" "PREV"))
    (should captured-url)
    (should (string-match-p "parent=PARENT" captured-url))
    (should (string-match-p "previous=PREV" captured-url))))

(ert-deftest org-mode-google-tasks-sync-engine-test/move-task-bare-url-when-no-params ()
  "`api-move-task' produces a bare URL (no query) when both params are nil."
  (let (captured-url)
    (cl-letf (((symbol-function 'plz)
               (lambda (_method url &rest keys)
                 (setq captured-url url)
                 (funcall (plist-get keys :then) '((id . "t"))))))
      (org-mode-google-tasks-sync-api-move-task
       (make-org-mode-google-tasks-sync-api-token
        :access-token "fake")
       "LIST" "TASK" #'ignore #'ignore nil nil))
    (should captured-url)
    (should-not (string-match-p "?" captured-url))))

;;; -- write-task-if-marker-matches guard -------------------------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/write-task-if-marker-matches-writes-when-title-matches ()
  "When the marker still points at a heading with the same title, the write runs."
  (let ((file (make-temp-file "gtasks-marker-match" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n** TODO Foo\n"))
          (with-current-buffer (find-file-noselect file)
            (save-excursion
              (goto-char (point-min))
              (re-search-forward "^\\*\\* ")
              (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L")))
                (setf (org-mode-google-tasks-sync-org-task-id task) "new-id")
                (should (org-mode-google-tasks-sync-engine--write-task-if-marker-matches task)))
              (should (equal "new-id" (org-entry-get nil "GTASK_ID")))))
          (with-current-buffer (find-file-noselect file)
            (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
              (set-buffer-modified-p nil))
            (kill-buffer)))
      (delete-file file))))

(ert-deftest org-mode-google-tasks-sync-engine-test/write-task-if-marker-matches-skips-when-title-mismatches ()
  "When the marker points at a heading with a DIFFERENT title, the write is skipped.
Regression for the buffer-clobber bug: a deferred async callback
\(e.g. push-new's :then) whose marker got orphaned by a prior
sort/sweep must NOT clobber the wrong heading."
  (let ((file (make-temp-file "gtasks-marker-mismatch" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n** TODO Wrong heading\n"))
          (with-current-buffer (find-file-noselect file)
            (save-excursion
              (goto-char (point-min))
              (re-search-forward "^\\*\\* ")
              (let ((task (make-org-mode-google-tasks-sync-org-task
                           :title "Foo"
                           :id "new-id"
                           :marker (point-marker))))
                (should-not (org-mode-google-tasks-sync-engine--write-task-if-marker-matches task)))
              ;; The wrong heading must not have gained a GTASK_ID.
              (should (null (org-entry-get nil "GTASK_ID")))))
          (with-current-buffer (find-file-noselect file)
            (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
              (set-buffer-modified-p nil))
            (kill-buffer)))
      (delete-file file))))

;;; -- push-new passes previous param for position preservation ---------------

(ert-deftest org-mode-google-tasks-sync-engine-test/push-new-passes-previous-when-has-preceding-sibling ()
  "`--push-new' passes `previous' = the preceding synced sibling's :GTASK_ID:
so Google appends the task at the same position the user placed it locally.
Without `previous', Google inserts at the top of the list and the next
tick's sort pulls the task away from its intended place."
  (let ((file (make-temp-file "gtasks-push-prev" nil ".org"))
        captured-query-args)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO A\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: a-id\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"
                    "** TODO Foo\n"))
          (cl-letf (((symbol-function 'org-mode-google-tasks-sync-api-insert-task)
                     (lambda (_token _list-id _data then _else query-args)
                       (setq captured-query-args query-args)
                       (funcall then '((id . "new") (updated . "u") (etag . "e"))))))
            (with-current-buffer (find-file-noselect file)
              (save-excursion
                (goto-char (point-min))
                (re-search-forward "^\\*\\* TODO Foo")
                (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L")))
                  (org-mode-google-tasks-sync-engine--push-new
                   nil "L" task file))))))
      (should (assoc "previous" captured-query-args))
      (should (equal "a-id" (cdr (assoc "previous" captured-query-args))))
      (with-current-buffer (find-file-noselect file)
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (set-buffer-modified-p nil))
        (kill-buffer))
      (delete-file file))))

(ert-deftest org-mode-google-tasks-sync-engine-test/push-new-omits-previous-when-first-sibling ()
  "`--push-new' omits `previous' when the task is the first sibling
\(no preceding synced heading)."
  (let ((file (make-temp-file "gtasks-push-no-prev" nil ".org"))
        captured-query-args)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n** TODO Foo\n"))
          (cl-letf (((symbol-function 'org-mode-google-tasks-sync-api-insert-task)
                     (lambda (_token _list-id _data then _else query-args)
                       (setq captured-query-args query-args)
                       (funcall then '((id . "new") (updated . "u") (etag . "e"))))))
            (with-current-buffer (find-file-noselect file)
              (save-excursion
                (goto-char (point-min))
                (re-search-forward "^\\*\\* ")
                (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L")))
                  (org-mode-google-tasks-sync-engine--push-new
                   nil "L" task file))))))
      (should-not (assoc "previous" captured-query-args))
      (with-current-buffer (find-file-noselect file)
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (set-buffer-modified-p nil))
        (kill-buffer))
      (delete-file file))))

;;; -- --prev-synced-sibling-id positions on the task's marker -----------------

(ert-deftest org-mode-google-tasks-sync-engine-test/prev-synced-sibling-id-positions-on-marker ()
  "`--prev-synced-sibling-id' must navigate to TASK's marker before
searching backward for a sibling.  Without the `goto-char', it reads
at whatever point happens to be current — returning a stale or
wrong sibling's ID when called from `--push-new' during `--apply'
\(where point wanders across headings)."
  (let ((file (make-temp-file "gtasks-prev-marker" nil ".org"))
        captured-query-args)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO A\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: a-id\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"
                    "** TODO Foo\n"))
          (cl-letf (((symbol-function 'org-mode-google-tasks-sync-api-insert-task)
                     (lambda (_token _list-id _data then _else query-args)
                       (setq captured-query-args query-args)
                       (funcall then '((id . "new") (updated . "u") (etag . "e"))))))
            (with-current-buffer (find-file-noselect file)
              (save-excursion
                (goto-char (point-min))
                (re-search-forward "^\\*\\* TODO Foo")
                (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L")))
                  ;; Move point far away from Foo — onto A's heading.
                  ;; Without the marker goto-char, the backward search
                  ;; starts here and finds no preceding sibling of A,
                  ;; so `previous' would be nil.
                  (goto-char (point-min))
                  (re-search-forward "^\\*\\* TODO A")
                  (org-mode-google-tasks-sync-engine--push-new
                   nil "L" task file))))))
      (should (assoc "previous" captured-query-args))
      (should (equal "a-id" (cdr (assoc "previous" captured-query-args))))
      (with-current-buffer (find-file-noselect file)
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (set-buffer-modified-p nil))
        (kill-buffer))
      (delete-file file))))

;;; -- push-new serialization: parent-id resolved at fire time -----------------

(ert-deftest org-mode-google-tasks-sync-engine-test/resolve-parent-id-reads-from-buffer ()
  "`--resolve-parent-id' re-reads the parent heading's :GTASK_ID:
from the buffer at fire time, not from the struct's `parent-id'
slot.  When the parent was itself a new task pushed moments earlier
in the same tick (its GTASK_ID written by the async callback), the
struct's slot is nil but the buffer has the value.  This is the
core fix for children of unsynced parents being pushed as top-level."
  (let ((file (make-temp-file "gtasks-resolve-parent" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO Parent\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: parent-fresh-id\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"
                    "*** TODO Child\n"))
          (with-current-buffer (find-file-noselect file)
            (save-excursion
              (goto-char (point-min))
              (re-search-forward "^\\*\\*\\* TODO Child")
              (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L")))
                ;; parent-id slot is nil (parent had no GTASK_ID at
                ;; collect time — simulate by clearing it).
                (setf (org-mode-google-tasks-sync-org-task-parent-id task) nil)
                (should (equal "parent-fresh-id"
                               (org-mode-google-tasks-sync-engine--resolve-parent-id task)))))))
      (with-current-buffer (find-file-noselect file)
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (set-buffer-modified-p nil))
        (kill-buffer))
      (delete-file file))))

(ert-deftest org-mode-google-tasks-sync-engine-test/push-new-queue-serializes-inserts ()
  "`--push-new-queue' pushes tasks one at a time, each waiting for
the previous insert's :then to complete.  This ensures the
`previous' param for task N+1 reflects task N's freshly-written
GTASK_ID, not a stale nil.  The test verifies serialization by
capturing insert call order and confirming each call sees the
prior task's ID in the buffer."
  (let ((file (make-temp-file "gtasks-push-queue" nil ".org"))
        insert-order)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO First\n"
                    "** TODO Second\n"))
          (cl-letf (((symbol-function 'org-mode-google-tasks-sync-api-insert-task)
                     (lambda (_token _list-id _data then _else query-args)
                       (let ((prev (cdr (assoc "previous" query-args))))
                         (push prev insert-order)
                         (funcall then '((id . "gen-id")
                                         (updated . "u")
                                         (etag . "e")))))))
            (with-current-buffer (find-file-noselect file)
              (let (tasks)
                (save-excursion
                  (goto-char (point-min))
                  (re-search-forward "^\\*\\* TODO First")
                  (push (org-mode-google-tasks-sync-org-read-task-at-point "L") tasks)
                  (re-search-forward "^\\*\\* TODO Second")
                  (push (org-mode-google-tasks-sync-org-read-task-at-point "L") tasks))
                (org-mode-google-tasks-sync-engine--push-new-queue
                 nil "L" (nreverse tasks) file #'ignore)))))
      ;; First insert has no previous; second has "gen-id" (written
      ;; by the first insert's :then callback).
      (should (equal '(nil "gen-id") (nreverse insert-order)))
      (with-current-buffer (find-file-noselect file)
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (set-buffer-modified-p nil))
        (kill-buffer))
      (delete-file file))))

(ert-deftest org-mode-google-tasks-sync-engine-test/push-new-queue-empty-calls-done ()
  "An empty queue immediately calls DONE without firing any inserts."
  (let ((called-done nil))
    (cl-letf (((symbol-function 'org-mode-google-tasks-sync-api-insert-task)
               (lambda (&rest _) (error "Should not be called"))))
      (org-mode-google-tasks-sync-engine--push-new-queue
       nil "L" nil "/dev/null" (lambda () (setq called-done t))))
    (should called-done)))

;;; -- position-tie repair -----------------------------------------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/repair-ties-fires-move-for-duplicates ()
  "`--repair-position-ties' fires `tasks.move' with `previous=<first-id>'
for the second of two adjacent siblings that share the same
:GTASK_POSITION: string.  Without this, the stable sort produces
an unstable order (ties preserved in whatever order the buffer
happens to be in)."
  (let ((file (make-temp-file "gtasks-tie-repair" nil ".org"))
        captured-moves)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO A\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: id-a\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_POSITION: 00000000000000000000\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"
                    "** TODO B\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: id-b\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_POSITION: 00000000000000000000\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"))
          (cl-letf (((symbol-function 'org-mode-google-tasks-sync-api-move-task)
                     (lambda (_token _list-id task-id then _else new-parent previous-id)
                       (push (cons task-id previous-id) captured-moves)
                       (funcall then '((position . "00000000000000000001"))))))
            (with-current-buffer (find-file-noselect file)
              (let ((parent-marker (save-excursion
                                      (goto-char (point-min))
                                      (re-search-forward "^\\* Tasks")
                                      (point-marker))))
                (org-mode-google-tasks-sync-engine--repair-position-ties
                 nil "L" parent-marker file #'ignore)))))
      (should (= 1 (length captured-moves)))
      (should (equal "id-b" (caar captured-moves)))
      (should (equal "id-a" (cdar captured-moves)))
      (with-current-buffer (find-file-noselect file)
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (set-buffer-modified-p nil))
        (kill-buffer))
      (delete-file file))))

(ert-deftest org-mode-google-tasks-sync-engine-test/repair-ties-noop-when-unique ()
  "`--repair-position-ties' fires no moves when all positions are unique."
  (let ((file (make-temp-file "gtasks-tie-unique" nil ".org"))
        (move-count 0))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO A\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: id-a\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_POSITION: 00000000000000000001\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"
                    "** TODO B\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: id-b\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_POSITION: 00000000000000000002\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"))
          (cl-letf (((symbol-function 'org-mode-google-tasks-sync-api-move-task)
                     (lambda (&rest _)
                       (setq move-count (1+ move-count))
                       (error "should not be called"))))
            (with-current-buffer (find-file-noselect file)
              (let ((parent-marker (save-excursion
                                      (goto-char (point-min))
                                      (re-search-forward "^\\* Tasks")
                                      (point-marker))))
                (org-mode-google-tasks-sync-engine--repair-position-ties
                 nil "L" parent-marker file #'ignore)))))
      (should (eq 0 move-count))
      (with-current-buffer (find-file-noselect file)
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (set-buffer-modified-p nil))
        (kill-buffer))
      (delete-file file))))

;;; -- reorder drift detection (B1) -------------------------------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/detect-reorder-drift-fires-moves ()
  "`--detect-reorder-drift' returns move pairs when the buffer order
differs from the position-sorted order.  This is the manual
cut/paste path: the user moved a heading, the positions haven't
changed, and the engine pushes the new order to the server."
  (let ((file (make-temp-file "gtasks-drift" nil ".org"))
        captured-moves)
    (unwind-protect
        (progn
          ;; Buffer order: B (pos 2), A (pos 1) — user swapped them.
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO B\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: id-b\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_POSITION: 00000000000000000002\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"
                    "** TODO A\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: id-a\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_POSITION: 00000000000000000001\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"))
          (with-current-buffer (find-file-noselect file)
            (let* ((parent-marker (save-excursion
                                    (goto-char (point-min))
                                    (re-search-forward "^\\* Tasks")
                                    (point-marker)))
                   (snapshot (org-mode-google-tasks-sync-engine--snapshot-sibling-order
                              parent-marker))
                   (drift (org-mode-google-tasks-sync-engine--detect-reorder-drift
                           snapshot)))
              (cl-letf (((symbol-function 'org-mode-google-tasks-sync-api-move-task)
                         (lambda (_token _list-id task-id then _else _parent previous-id)
                           (push (cons task-id previous-id) captured-moves)
                           (funcall then '((position . "00000000000000000003"))))))
                 (org-mode-google-tasks-sync-engine--resolve-reorder-drift
                  nil "L" drift file #'ignore)))))
      ;; Buffer order is B, A.  Sorted order is A, B.  They differ, so
      ;; every task gets a move with its buffer predecessor:
      ;; B -> previous=nil (first), A -> previous=id-b (second).
      ;; The mock uses push, so captured-moves is in reverse order:
      ;; first element is the LAST move fired (A), second is the first (B).
      (should (= 2 (length captured-moves)))
      (should (equal "id-a" (caar captured-moves)))
      (should (equal "id-b" (cdar captured-moves)))
      (should (equal "id-b" (car (cadr captured-moves))))
      (should (null (cdr (cadr captured-moves))))
      (with-current-buffer (find-file-noselect file)
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (set-buffer-modified-p nil))
        (kill-buffer))
      (delete-file file))))

(ert-deftest org-mode-google-tasks-sync-engine-test/detect-reorder-drift-noop-when-aligned ()
  "`--detect-reorder-drift' returns nil when buffer order matches
position-sorted order — no moves are fired."
  (let ((file (make-temp-file "gtasks-no-drift" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO A\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: id-a\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_POSITION: 00000000000000000001\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"
                    "** TODO B\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: id-b\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_POSITION: 00000000000000000002\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"))
          (with-current-buffer (find-file-noselect file)
            (let* ((parent-marker (save-excursion
                                    (goto-char (point-min))
                                    (re-search-forward "^\\* Tasks")
                                    (point-marker)))
                   (snapshot (org-mode-google-tasks-sync-engine--snapshot-sibling-order
                              parent-marker))
                   (drift (org-mode-google-tasks-sync-engine--detect-reorder-drift
                           snapshot)))
              (should (null drift)))))
      (with-current-buffer (find-file-noselect file)
        (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
          (set-buffer-modified-p nil))
        (kill-buffer))
      (delete-file file))))

;;; -- sort resilience: #+ keywords before first heading ---------------------

(ert-deftest org-mode-google-tasks-sync-engine-test/sort-children-does-not-error-with-keywords-before-first-heading ()
  "`--sort-children' must not raise when the buffer begins with #+
keyword lines (e.g. #+TITLE:, #+GTASKS_LAST_SYNC:).  Regression for
the bug where `org-sort-entries' left point at `point-min' (inside
the keyword lines, before the first `*' heading) and the subsequent
`org-back-to-heading t' raised `user-error \"Before first headline
at position 1\"', aborting the sync and leaving the state machine
stuck at `applying'."
  (let ((file (make-temp-file "gtasks-sort-keywords" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+TITLE: Tasks\n"
                    "#+GTASKS_LAST_SYNC: 2026-01-01T00:00:00.000Z\n\n"
                    "* Tasks\n"
                    "** TODO B\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: b\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_POSITION: 00000000000000000002\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"
                    "** TODO A\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: a\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z\n"
                    "   :GTASK_POSITION: 00000000000000000001\n"
                    "   :GTASK_CONTENT_HASH: x\n"
                    "   :END:\n"))
          ;; Drive through --apply with mode='full and mocked push fns
          ;; so the sort-children step runs against a buffer whose
          ;; children are in reverse position order.
          (let* ((remote `(((id . "a")
                            (title . "A")
                            (status . "needsAction")
                            (updated . "2026-01-01T00:00:00.000Z")
                            (position . "00000000000000000001"))
                           ((id . "b")
                            (title . "B")
                            (status . "needsAction")
                            (updated . "2026-01-01T00:00:00.000Z")
                            (position . "00000000000000000002")))))
            (cl-letf (((symbol-function 'org-mode-google-tasks-sync-engine--push-update)
                       (lambda (&rest _) t))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--push-new-queue)
                       (lambda (_token _list-id _tasks _file done)
                         (funcall done)))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--resolve-reorder-drift)
                       (lambda (_token _list-id _pairs _file done)
                         (funcall done)))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--repair-position-ties)
                       (lambda (_token _list-id _parent _file done)
                         (funcall done))))
              ;; Must not raise.
              (org-mode-google-tasks-sync-engine--apply
               nil "L" file "Tasks" 'full
               remote
               #'ignore)))
          (with-current-buffer (find-file-noselect file)
            (widen)
            (goto-char (point-min))
            ;; Children are now sorted by position ascending: A before B.
            (should (re-search-forward "^\\*\\* TODO A" nil t))
            (should (re-search-forward "^\\*\\* TODO B" nil t))
            (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
              (set-buffer-modified-p nil))
            (kill-buffer)))
      (delete-file file))))

(ert-deftest org-mode-google-tasks-sync-engine-test/sync-one-calls-done-when-apply-throws ()
  "`--sync-one' must call DONE even when `--apply' throws, so the
state machine is never left waiting on a sync that already failed.
Defense in depth against any future bug in `--apply' locking out
the sync — `--sync-next' relies on DONE being called to advance to
the next entry or return to `idle'."
  (let ((file (make-temp-file "gtasks-apply-throw" nil ".org"))
        (done-called nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+TITLE: Tasks\n\n* Tasks\n"))
          (cl-letf (((symbol-function 'org-mode-google-tasks-sync-api-list-tasks)
                     (lambda (_token _list-id _args then _else)
                       (funcall then '())))
                    ((symbol-function 'org-mode-google-tasks-sync-engine--apply)
                     (lambda (&rest _)
                       (signal 'user-error "simulated apply failure"))))
            (org-mode-google-tasks-sync-engine--sync-one
             nil "L" file "Tasks" 'full
             (lambda () (setq done-called t))))
          (should done-called)
          (with-current-buffer (find-file-noselect file)
            (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
              (set-buffer-modified-p nil))
            (kill-buffer)))
      (delete-file file))))

;;; -- async-callback buffer safety -------------------------------------------
;;
;; plz invokes `:then' callbacks with the curl process buffer as
;; `current-buffer' (a `fundamental-mode' buffer named
;; ` *plz-request-curl*...').  Functions that mutate org headings from
;; these callbacks must switch to the org buffer via the marker, not
;; rely on the caller's `current-buffer'.  These tests simulate that
;; scenario by making a non-org temp buffer current before calling the
;; fixed functions.

(ert-deftest org-mode-google-tasks-sync-engine-test/delete-local-writes-org-buffer-not-current-when-called-from-non-org-buffer ()
  "`--delete-local' must delete the heading in the marker's buffer,
not in `current-buffer' (which may be a plz curl buffer when called
from an async `:then' callback)."
  (let ((file (make-temp-file "gtasks-delete-local-cb" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO Foo\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: foo-id\n"
                    "   :GTASK_LIST: L\n"
                    "   :END:\n"))
          (let (org-marker)
            (with-current-buffer (find-file-noselect file)
              (save-excursion
                (goto-char (point-min))
                (re-search-forward "^\\*\\* ")
                (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L")))
                  (setq org-marker (org-mode-google-tasks-sync-org-task-marker task))
                  ;; Simulate a plz :then callback: switch to a
                  ;; fundamental-mode temp buffer before calling.
                  (with-temp-buffer
                    (should (eq (current-buffer) (get-buffer (buffer-name))))
                    (should-not (derived-mode-p 'org-mode))
                    (org-mode-google-tasks-sync-engine--delete-local task file)))))
            (with-current-buffer (find-file-noselect file)
              (save-excursion
                (goto-char (point-min))
                (should-not (re-search-forward "^\\*\\* TODO Foo" nil t)))
              (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
                (set-buffer-modified-p nil))
              (kill-buffer))))
      (delete-file file))))

(ert-deftest org-mode-google-tasks-sync-engine-test/write-move-result-writes-to-file-not-current-when-called-from-non-org-buffer ()
  "`--write-move-result' must write the position into the org FILE,
not into `current-buffer' (which may be a plz curl buffer when called
from a drift/tie-repair `:then' callback).  FILE is now threaded
through explicitly."
  (let ((file (make-temp-file "gtasks-move-result-cb" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO Foo\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: foo-id\n"
                    "   :GTASK_LIST: L\n"
                    "   :GTASK_POSITION: 00000000000000000000\n"
                    "   :END:\n"))
          ;; Simulate a plz :then callback: switch to a non-org temp
          ;; buffer before calling.  Pass FILE explicitly.
          (with-temp-buffer
            (should-not (derived-mode-p 'org-mode))
            (org-mode-google-tasks-sync-engine--write-move-result
             "foo-id"
             '((position . "00000000000000000042"))
             file))
          (with-current-buffer (find-file-noselect file)
            (save-excursion
              (goto-char (point-min))
              (re-search-forward "^\\*\\* ")
              (should (equal "00000000000000000042"
                             (org-entry-get nil "GTASK_POSITION"))))
            (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
              (set-buffer-modified-p nil))
            (kill-buffer)))
      (delete-file file))))

(ert-deftest org-mode-google-tasks-sync-engine-test/write-task-if-marker-matches-skips-when-marker-has-no-buffer ()
  "When the marker has no live buffer, `--write-task-if-marker-matches'
must NOT fall through to writing at point in the current (possibly
plz) buffer.  It should log and return nil."
  (let ((org-buf (generate-new-buffer " *org-marker-test*")))
    (unwind-protect
        (progn
          (with-current-buffer org-buf
            (org-mode)
            (insert "* Tasks\n** TODO Foo\n")
            (goto-char (point-min))
            (re-search-forward "^\\*\\* ")
            (let ((task (make-org-mode-google-tasks-sync-org-task
                         :title "Foo"
                         :id "foo-id"
                         :marker (point-marker))))
              (kill-buffer org-buf)
              (with-temp-buffer
                (should-not (derived-mode-p 'org-mode))
                (should-not
                 (org-mode-google-tasks-sync-engine--write-task-if-marker-matches task)))))
      (when (buffer-live-p org-buf)
        (kill-buffer org-buf))))))

(ert-deftest org-mode-google-tasks-sync-engine-test/update-heading-server-state-writes-org-buffer-not-current-when-called-from-non-org-buffer ()
  "`--update-heading-server-state' must write properties into the
marker's buffer, not into `current-buffer' (which may be a plz curl
buffer when called from `--apply-server-move's `:then' callback)."
  (let ((file (make-temp-file "gtasks-update-heading-cb" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Tasks\n"
                    "** TODO Foo\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: foo-id\n"
                    "   :GTASK_LIST: L\n"
                    "   :END:\n"))
          (let (heading-marker)
            (with-current-buffer (find-file-noselect file)
              (save-excursion
                (goto-char (point-min))
                (re-search-forward "^\\*\\* ")
                (setq heading-marker (point-marker)))
              ;; Simulate a plz :then callback: switch to a
              ;; fundamental-mode temp buffer before calling.
              (with-temp-buffer
                (should-not (derived-mode-p 'org-mode))
                (org-mode-google-tasks-sync--update-heading-server-state
                 "2026-08-07T12:00:00.000Z"
                 "\"new-etag\""
                 "00000000000000000042"
                 heading-marker)))
            (with-current-buffer (find-file-noselect file)
              (save-excursion
                (goto-char (point-min))
                (re-search-forward "^\\*\\* ")
                (should (equal "2026-08-07T12:00:00.000Z"
                               (org-entry-get nil "GTASK_UPDATED")))
                (should (equal "\"new-etag\""
                               (org-entry-get nil "GTASK_ETAG")))
                (should (equal "00000000000000000042"
                               (org-entry-get nil "GTASK_POSITION"))))
              (let ((org-mode-google-tasks-sync-engine--inhibit-save-hooks t))
                (set-buffer-modified-p nil))
              (kill-buffer))))
      (delete-file file))))

(provide 'org-mode-google-tasks-sync-engine-test)
;;; org-mode-google-tasks-sync-engine-test.el ends here
