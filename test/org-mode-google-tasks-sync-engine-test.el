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

(provide 'org-mode-google-tasks-sync-engine-test)
;;; org-mode-google-tasks-sync-engine-test.el ends here
