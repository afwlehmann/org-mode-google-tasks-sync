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
  (should (eq 'skip
              (org-mode-google-tasks-sync-engine--decide nil nil nil nil))))

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-push ()
  (should (eq 'push
              (org-mode-google-tasks-sync-engine--decide t nil nil nil))))

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-pull ()
  (should (eq 'pull
              (org-mode-google-tasks-sync-engine--decide nil t nil "2026-06-27T10:00:00Z"))))

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-conflict-remote-wins ()
  ;; remote.updated is after local-mtime → remote wins
  (let ((local-mtime (float-time (parse-iso8601-time-string "2026-06-27T10:00:00Z")))
        (remote-updated "2026-06-27T11:00:00Z"))
    (should (eq 'conflict-remote-wins
                (org-mode-google-tasks-sync-engine--decide t t local-mtime remote-updated)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-conflict-local-wins ()
  ;; local-mtime is after remote.updated → local wins
  (let ((local-mtime (float-time (parse-iso8601-time-string "2026-06-27T12:00:00Z")))
        (remote-updated "2026-06-27T11:00:00Z"))
    (should (eq 'conflict-local-wins
                (org-mode-google-tasks-sync-engine--decide t t local-mtime remote-updated)))))

(ert-deftest org-mode-google-tasks-sync-engine-test/decide-both-done-conflict ()
  "Both sides mark the task done, remote newer → conflict-remote-wins.
When the task is completed on both sides, the status field (which is in
the canonical hash) differs from the stored hash on both sides, so both
local-changed and remote-changed are true.  The newer remote timestamp
wins rather than emitting a redundant push that would hit an already-done
remote task."
  (let ((local-mtime (float-time (parse-iso8601-time-string "2026-06-27T10:00:00Z")))
        (remote-updated "2026-06-27T11:00:00Z"))
    (should (eq 'conflict-remote-wins
                (org-mode-google-tasks-sync-engine--decide t t local-mtime remote-updated)))))

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
            ;; Stub out push helpers; they need a real token and network.
            (cl-letf (((symbol-function 'org-mode-google-tasks-sync-engine--push-update)
                       (lambda (&rest _) t))
                      ((symbol-function 'org-mode-google-tasks-sync-engine--push-new)
                       (lambda (&rest _) t)))
              (org-mode-google-tasks-sync-engine--apply
               nil "L" file "Tasks" 'full
               (list remote)
               #'ignore))))
      (with-current-buffer (find-file-noselect file)
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
                    ((symbol-function 'org-mode-google-tasks-sync-engine--push-new)
                     (lambda (&rest _) t)))
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

;;; -- showCompleted pinned in list-tasks query -------------------------------

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

(provide 'org-mode-google-tasks-sync-engine-test)
;;; org-mode-google-tasks-sync-engine-test.el ends here
