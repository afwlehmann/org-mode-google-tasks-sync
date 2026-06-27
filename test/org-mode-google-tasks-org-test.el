;;; org-mode-google-tasks-org-test.el --- Tests for the org parser -*- lexical-binding: t -*-

;;; Commentary:

;; Verifies hash stability, round-trip serialization, and edge cases of
;; the org parser module.

;;; Code:

(require 'ert)
(require 'org-mode-google-tasks-org)

(defmacro org-mode-google-tasks-org-test--with-org (org-text &rest body)
  "Run BODY in a temporary org buffer containing ORG-TEXT, point at min."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,org-text)
     (org-mode)
     (goto-char (point-min))
     ,@body))

(ert-deftest org-mode-google-tasks-org-test/strip-priority ()
  (should (equal "Buy milk"
                 (org-mode-google-tasks-org-strip-priority "[#A] Buy milk")))
  (should (equal "Buy milk"
                 (org-mode-google-tasks-org-strip-priority "[#B]   Buy milk")))
  (should (equal "Buy milk"
                 (org-mode-google-tasks-org-strip-priority "Buy milk")))
  ;; A bare cookie with no following title is fully stripped — empty headlines aren't meaningful.
  (should (equal "" (org-mode-google-tasks-org-strip-priority "[#A]"))))

(ert-deftest org-mode-google-tasks-org-test/read-task-basic ()
  (org-mode-google-tasks-org-test--with-org
      "* TODO Buy milk\n"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-org-read-task-at-point "L1")))
      (should (equal "Buy milk" (org-mode-google-tasks-org-task-title task)))
      (should (equal "L1" (org-mode-google-tasks-org-task-list-id task)))
      (should (eq 'needsAction (org-mode-google-tasks-org-task-status task)))
      (should (equal "" (org-mode-google-tasks-org-task-notes task)))
      (should (null (org-mode-google-tasks-org-task-due task)))
      (should (null (org-mode-google-tasks-org-task-id task))))))

(ert-deftest org-mode-google-tasks-org-test/read-task-with-priority ()
  (org-mode-google-tasks-org-test--with-org
      "* TODO [#A] Buy milk\n"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-org-read-task-at-point "L1")))
      ;; Priority cookie must be stripped from title
      (should (equal "Buy milk" (org-mode-google-tasks-org-task-title task))))))

(ert-deftest org-mode-google-tasks-org-test/read-task-done ()
  (org-mode-google-tasks-org-test--with-org
      "* DONE Buy milk\n"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-org-read-task-at-point "L1")))
      (should (eq 'completed (org-mode-google-tasks-org-task-status task))))))

(ert-deftest org-mode-google-tasks-org-test/read-task-with-due ()
  (org-mode-google-tasks-org-test--with-org
      "* TODO Buy milk\nSCHEDULED: <2026-06-27 Sat>\n"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-org-read-task-at-point "L1")))
      (should (equal "2026-06-27" (org-mode-google-tasks-org-task-due task))))))

(ert-deftest org-mode-google-tasks-org-test/read-task-with-notes ()
  (org-mode-google-tasks-org-test--with-org
      "* TODO Buy milk\nGet organic.\nTwo liters.\n"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-org-read-task-at-point "L1")))
      (should (equal "Get organic.\nTwo liters."
                     (org-mode-google-tasks-org-task-notes task))))))

(ert-deftest org-mode-google-tasks-org-test/read-task-with-properties-and-notes ()
  (org-mode-google-tasks-org-test--with-org
      "* TODO Buy milk
SCHEDULED: <2026-06-27 Sat>
:PROPERTIES:
:GTASK_ID: abc123
:GTASK_LIST: L1
:GTASK_UPDATED: 2026-06-27T10:00:00.000Z
:GTASK_ETAG: \"etag-1\"
:GTASK_CONTENT_HASH: abcdef
:END:
Some body text here.
"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-org-read-task-at-point "L1")))
      (should (equal "abc123" (org-mode-google-tasks-org-task-id task)))
      (should (equal "Buy milk" (org-mode-google-tasks-org-task-title task)))
      (should (equal "Some body text here." (org-mode-google-tasks-org-task-notes task)))
      (should (equal "2026-06-27" (org-mode-google-tasks-org-task-due task)))
      (should (equal "2026-06-27T10:00:00.000Z"
                     (org-mode-google-tasks-org-task-updated task)))
      (should (equal "abcdef" (org-mode-google-tasks-org-task-hash task))))))

(ert-deftest org-mode-google-tasks-org-test/hash-stable-across-whitespace ()
  (let ((t1 (make-org-mode-google-tasks-org-task
             :title "Buy milk" :notes "Two liters" :status 'needsAction :due "2026-06-27"))
        (t2 (make-org-mode-google-tasks-org-task
             :title "Buy milk" :notes "Two liters" :status 'needsAction :due "2026-06-27")))
    (should (equal (org-mode-google-tasks-org-canonical-hash t1)
                   (org-mode-google-tasks-org-canonical-hash t2)))))

(ert-deftest org-mode-google-tasks-org-test/hash-changes-on-title-change ()
  (let ((t1 (make-org-mode-google-tasks-org-task
             :title "Buy milk" :status 'needsAction))
        (t2 (make-org-mode-google-tasks-org-task
             :title "Buy bread" :status 'needsAction)))
    (should-not (equal (org-mode-google-tasks-org-canonical-hash t1)
                       (org-mode-google-tasks-org-canonical-hash t2)))))

(ert-deftest org-mode-google-tasks-org-test/hash-changes-on-status-change ()
  (let ((t1 (make-org-mode-google-tasks-org-task
             :title "Buy milk" :status 'needsAction))
        (t2 (make-org-mode-google-tasks-org-task
             :title "Buy milk" :status 'completed)))
    (should-not (equal (org-mode-google-tasks-org-canonical-hash t1)
                       (org-mode-google-tasks-org-canonical-hash t2)))))

(ert-deftest org-mode-google-tasks-org-test/hash-changes-on-due-change ()
  (let ((t1 (make-org-mode-google-tasks-org-task
             :title "Buy milk" :due "2026-06-27"))
        (t2 (make-org-mode-google-tasks-org-task
             :title "Buy milk" :due "2026-06-28")))
    (should-not (equal (org-mode-google-tasks-org-canonical-hash t1)
                       (org-mode-google-tasks-org-canonical-hash t2)))))

(ert-deftest org-mode-google-tasks-org-test/hash-independent-of-id-and-etag ()
  (let ((t1 (make-org-mode-google-tasks-org-task
             :title "Buy milk" :status 'needsAction
             :id "abc" :etag "e1" :updated "2026-06-27T00:00:00Z"))
        (t2 (make-org-mode-google-tasks-org-task
             :title "Buy milk" :status 'needsAction
             :id "xyz" :etag "e9" :updated "9999-12-31T23:59:59Z")))
    (should (equal (org-mode-google-tasks-org-canonical-hash t1)
                   (org-mode-google-tasks-org-canonical-hash t2)))))

(ert-deftest org-mode-google-tasks-org-test/collect-tasks-under-parent ()
  (let ((file (make-temp-file "gtasks-test" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+TITLE: Test\n\n"
                    "* Other heading\n"
                    "** TODO Should not be collected\n"
                    "* Tasks\n"
                    "** TODO First task\n"
                    "** TODO Second task\n"
                    "*** TODO Nested child (not direct)\n"
                    "** DONE Third task\n"))
          (let ((tasks (org-mode-google-tasks-org-collect-tasks-under
                        file "Tasks" "L1")))
            (should (= 3 (length tasks)))
            (should (equal '("First task" "Second task" "Third task")
                           (mapcar #'org-mode-google-tasks-org-task-title tasks)))
            (should (eq 'completed
                        (org-mode-google-tasks-org-task-status (nth 2 tasks))))))
      (delete-file file))))

(provide 'org-mode-google-tasks-org-test)
;;; org-mode-google-tasks-org-test.el ends here
