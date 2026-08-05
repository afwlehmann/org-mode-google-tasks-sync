;;; org-mode-google-tasks-sync-org-test.el --- Tests for the org parser -*- lexical-binding: t -*-

;;; Commentary:

;; Verifies hash stability, round-trip serialization, and edge cases of
;; the org parser module.

;;; Code:

(require 'ert)
(require 'org-mode-google-tasks-sync-org)

(defmacro org-mode-google-tasks-sync-org-test--with-org (org-text &rest body)
  "Run BODY in a temporary org buffer containing ORG-TEXT, point at min."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,org-text)
     (org-mode)
     (goto-char (point-min))
     ,@body))

(ert-deftest org-mode-google-tasks-sync-org-test/strip-priority ()
  (should (equal "Buy milk"
                 (org-mode-google-tasks-sync-org-strip-priority "[#A] Buy milk")))
  (should (equal "Buy milk"
                 (org-mode-google-tasks-sync-org-strip-priority "[#B]   Buy milk")))
  (should (equal "Buy milk"
                 (org-mode-google-tasks-sync-org-strip-priority "Buy milk")))
  ;; A bare cookie with no following title is fully stripped — empty headlines aren't meaningful.
  (should (equal "" (org-mode-google-tasks-sync-org-strip-priority "[#A]"))))

(ert-deftest org-mode-google-tasks-sync-org-test/read-task-basic ()
  (org-mode-google-tasks-sync-org-test--with-org
      "* TODO Buy milk\n"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L1")))
      (should (equal "Buy milk" (org-mode-google-tasks-sync-org-task-title task)))
      (should (equal "L1" (org-mode-google-tasks-sync-org-task-list-id task)))
      (should (eq 'needsAction (org-mode-google-tasks-sync-org-task-status task)))
      (should (equal "" (org-mode-google-tasks-sync-org-task-notes task)))
      (should (null (org-mode-google-tasks-sync-org-task-due task)))
      (should (null (org-mode-google-tasks-sync-org-task-id task))))))

(ert-deftest org-mode-google-tasks-sync-org-test/read-task-with-priority ()
  (org-mode-google-tasks-sync-org-test--with-org
      "* TODO [#A] Buy milk\n"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L1")))
      ;; Priority cookie must be stripped from title
      (should (equal "Buy milk" (org-mode-google-tasks-sync-org-task-title task))))))

(ert-deftest org-mode-google-tasks-sync-org-test/read-task-done ()
  (org-mode-google-tasks-sync-org-test--with-org
      "* DONE Buy milk\n"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L1")))
      (should (eq 'completed (org-mode-google-tasks-sync-org-task-status task))))))

(ert-deftest org-mode-google-tasks-sync-org-test/read-task-with-due ()
  (org-mode-google-tasks-sync-org-test--with-org
      "* TODO Buy milk\nSCHEDULED: <2026-06-27 Sat>\n"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L1")))
      (should (equal "2026-06-27" (org-mode-google-tasks-sync-org-task-due task))))))

(ert-deftest org-mode-google-tasks-sync-org-test/read-task-with-notes ()
  (org-mode-google-tasks-sync-org-test--with-org
      "* TODO Buy milk\nGet organic.\nTwo liters.\n"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L1")))
      (should (equal "Get organic.\nTwo liters."
                     (org-mode-google-tasks-sync-org-task-notes task))))))

(ert-deftest org-mode-google-tasks-sync-org-test/read-task-with-properties-and-notes ()
  (org-mode-google-tasks-sync-org-test--with-org
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
    (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L1")))
      (should (equal "abc123" (org-mode-google-tasks-sync-org-task-id task)))
      (should (equal "Buy milk" (org-mode-google-tasks-sync-org-task-title task)))
      (should (equal "Some body text here." (org-mode-google-tasks-sync-org-task-notes task)))
      (should (equal "2026-06-27" (org-mode-google-tasks-sync-org-task-due task)))
      (should (equal "2026-06-27T10:00:00.000Z"
                     (org-mode-google-tasks-sync-org-task-updated task)))
      (should (equal "abcdef" (org-mode-google-tasks-sync-org-task-hash task))))))

(ert-deftest org-mode-google-tasks-sync-org-test/hash-stable-across-whitespace ()
  (let ((t1 (make-org-mode-google-tasks-sync-org-task
             :title "Buy milk" :notes "Two liters" :status 'needsAction :due "2026-06-27"))
        (t2 (make-org-mode-google-tasks-sync-org-task
             :title "Buy milk" :notes "Two liters" :status 'needsAction :due "2026-06-27")))
    (should (equal (org-mode-google-tasks-sync-org-canonical-hash t1)
                   (org-mode-google-tasks-sync-org-canonical-hash t2)))))

(ert-deftest org-mode-google-tasks-sync-org-test/hash-changes-on-title-change ()
  (let ((t1 (make-org-mode-google-tasks-sync-org-task
             :title "Buy milk" :status 'needsAction))
        (t2 (make-org-mode-google-tasks-sync-org-task
             :title "Buy bread" :status 'needsAction)))
    (should-not (equal (org-mode-google-tasks-sync-org-canonical-hash t1)
                       (org-mode-google-tasks-sync-org-canonical-hash t2)))))

(ert-deftest org-mode-google-tasks-sync-org-test/hash-changes-on-status-change ()
  (let ((t1 (make-org-mode-google-tasks-sync-org-task
             :title "Buy milk" :status 'needsAction))
        (t2 (make-org-mode-google-tasks-sync-org-task
             :title "Buy milk" :status 'completed)))
    (should-not (equal (org-mode-google-tasks-sync-org-canonical-hash t1)
                       (org-mode-google-tasks-sync-org-canonical-hash t2)))))

(ert-deftest org-mode-google-tasks-sync-org-test/hash-changes-on-due-change ()
  (let ((t1 (make-org-mode-google-tasks-sync-org-task
             :title "Buy milk" :due "2026-06-27"))
        (t2 (make-org-mode-google-tasks-sync-org-task
             :title "Buy milk" :due "2026-06-28")))
    (should-not (equal (org-mode-google-tasks-sync-org-canonical-hash t1)
                       (org-mode-google-tasks-sync-org-canonical-hash t2)))))

(ert-deftest org-mode-google-tasks-sync-org-test/hash-independent-of-id-and-etag ()
  (let ((t1 (make-org-mode-google-tasks-sync-org-task
              :title "Buy milk" :status 'needsAction
              :id "abc" :etag "e1" :updated "2026-06-27T00:00:00Z"))
         (t2 (make-org-mode-google-tasks-sync-org-task
              :title "Buy milk" :status 'needsAction
              :id "xyz" :etag "e9" :updated "9999-12-31T23:59:59Z")))
    (should (equal (org-mode-google-tasks-sync-org-canonical-hash t1)
                   (org-mode-google-tasks-sync-org-canonical-hash t2)))))

(ert-deftest org-mode-google-tasks-sync-org-test/hash-independent-of-links ()
  "Links and webViewLink are display metadata; they don't affect the content hash.
Regression guard: if someone accidentally adds them to the hash, existing
tasks would get spurious 'local-changed' detections on every pull."
  (let ((t1 (make-org-mode-google-tasks-sync-org-task
              :title "Buy milk" :status 'needsAction))
        (t2 (make-org-mode-google-tasks-sync-org-task
              :title "Buy milk" :status 'needsAction
              :links "[{\"type\":\"email\",\"link\":\"https://mail.google.com/x\"}]"
              :web-view-link "https://tasks.googleapis.com/abc")))
    (should (equal (org-mode-google-tasks-sync-org-canonical-hash t1)
                   (org-mode-google-tasks-sync-org-canonical-hash t2)))))

(ert-deftest org-mode-google-tasks-sync-org-test/write-task-writes-link-properties ()
  "`write-task' writes :GTASK_LINKS: and :GTASK_WEB_LINK: into the property drawer
when the struct carries them."
  (org-mode-google-tasks-sync-org-test--with-org
      "* TODO Buy milk\n"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L1")))
      (setf (org-mode-google-tasks-sync-org-task-links task)
            "[{\"type\":\"email\",\"link\":\"https://mail.google.com/foo\"}]")
      (setf (org-mode-google-tasks-sync-org-task-web-view-link task)
            "https://tasks.googleapis.com/tasks/v1/abc")
      (org-mode-google-tasks-sync-org-write-task task))
    (should (equal "[{\"type\":\"email\",\"link\":\"https://mail.google.com/foo\"}]"
                   (org-entry-get nil "GTASK_LINKS")))
    (should (equal "https://tasks.googleapis.com/tasks/v1/abc"
                   (org-entry-get nil "GTASK_WEB_LINK")))))

(ert-deftest org-mode-google-tasks-sync-org-test/read-task-round-trips-link-properties ()
  "Link properties written by `write-task' are read back by `read-task-at-point'."
  (org-mode-google-tasks-sync-org-test--with-org
      "* TODO Buy milk\n"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L1")))
      (setf (org-mode-google-tasks-sync-org-task-links task)
            "[{\"type\":\"email\",\"link\":\"https://mail.google.com/foo\"}]")
      (setf (org-mode-google-tasks-sync-org-task-web-view-link task)
            "https://tasks.googleapis.com/tasks/v1/abc")
      (org-mode-google-tasks-sync-org-write-task task))
    (let ((read-back (org-mode-google-tasks-sync-org-read-task-at-point "L1")))
      (should (equal "[{\"type\":\"email\",\"link\":\"https://mail.google.com/foo\"}]"
                     (org-mode-google-tasks-sync-org-task-links read-back)))
      (should (equal "https://tasks.googleapis.com/tasks/v1/abc"
                     (org-mode-google-tasks-sync-org-task-web-view-link read-back))))))

(ert-deftest org-mode-google-tasks-sync-org-test/collect-tasks-under-parent ()
  "Collects direct children AND one level of subtasks (2 levels max).
Level 3+ headings are NOT collected.  Each subtask's `parent-id' is
inferred from the org heading hierarchy."
  (let ((file (make-temp-file "gtasks-test" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+TITLE: Test\n\n"
                    "* Other heading\n"
                    "** TODO Should not be collected\n"
                    "* Tasks\n"
                    "** TODO First task\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: first-id\n"
                    "   :END:\n"
                    "** TODO Second task\n"
                    "   :PROPERTIES:\n"
                    "   :GTASK_ID: second-id\n"
                    "   :END:\n"
                    "*** TODO Nested child (subtask of Second)\n"
                    "    :PROPERTIES:\n"
                    "    :GTASK_ID: nested-id\n"
                    "    :END:\n"
                    "**** Deeply nested (should NOT be collected)\n"
                    "** DONE Third task\n"))
          (let ((tasks (org-mode-google-tasks-sync-org-collect-tasks-under
                        file "Tasks" "L1")))
            ;; 4 tasks: First, Second, Nested child, Third.
            ;; The level-4 heading is NOT collected.
            (should (= 4 (length tasks)))
            (should (equal '("First task" "Second task" "Nested child (subtask of Second)" "Third task")
                           (mapcar #'org-mode-google-tasks-sync-org-task-title tasks)))
            (should (eq 'completed
                        (org-mode-google-tasks-sync-org-task-status (nth 3 tasks))))
            ;; Top-level tasks have nil parent-id.
            (should (null (org-mode-google-tasks-sync-org-task-parent-id (nth 0 tasks))))
            (should (null (org-mode-google-tasks-sync-org-task-parent-id (nth 1 tasks))))
            ;; The nested child's parent-id is inferred from the org heading.
            (should (equal "second-id"
                           (org-mode-google-tasks-sync-org-task-parent-id (nth 2 tasks))))))
      (delete-file file))))

(ert-deftest org-mode-google-tasks-sync-org-test/write-task-persists-parent-id ()
  "`write-task' persists :GTASK_PARENT_ID: when the struct carries a parent-id."
  (org-mode-google-tasks-sync-org-test--with-org
      "* Tasks
** TODO Child
"
    (re-search-forward "^\\*\\* ")
    (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L1")))
      (setf (org-mode-google-tasks-sync-org-task-parent-id task) "parent-123")
      (org-mode-google-tasks-sync-org-write-task task))
    (should (equal "parent-123" (org-entry-get nil "GTASK_PARENT_ID")))))

(ert-deftest org-mode-google-tasks-sync-org-test/write-task-clears-parent-id-when-nil ()
  "`write-task' removes a stale :GTASK_PARENT_ID: when the struct is top-level."
  (org-mode-google-tasks-sync-org-test--with-org
      "* Tasks
** TODO Child
   :PROPERTIES:
   :GTASK_PARENT_ID: old-parent
   :END:
"
    (re-search-forward "^\\*\\* ")
    (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L1")))
      ;; parent-id slot stays nil (top-level in the struct).
      (org-mode-google-tasks-sync-org-write-task task))
    (should (null (org-entry-get nil "GTASK_PARENT_ID")))))

(ert-deftest org-mode-google-tasks-sync-org-test/stored-parent-id-round-trip ()
  "`stored-parent-id' reads back what `write-task' persisted.
This is the property the engine compares against the live hierarchy to
tell local reparents (differ) from remote ones (match)."
  (org-mode-google-tasks-sync-org-test--with-org
      "* Tasks
** TODO Child
"
    (re-search-forward "^\\*\\* ")
    (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L1")))
      (should (null (org-mode-google-tasks-sync-org-stored-parent-id task)))
      (setf (org-mode-google-tasks-sync-org-task-parent-id task) "parent-xyz")
      (org-mode-google-tasks-sync-org-write-task task)
      (should (equal "parent-xyz"
                     (org-mode-google-tasks-sync-org-stored-parent-id task))))))

(ert-deftest org-mode-google-tasks-sync-org-test/replace-body-preserves-children ()
  "`--replace-body' must not delete child headings.
Org's `:contents-end' on a headline spans the whole subtree
\(section + nested headings); without clamping the deletion end at
the first child, a `write-task' on a parent task would silently
nuke its subtasks.  Regression for the buffer-clobber bug class."
  (org-mode-google-tasks-sync-org-test--with-org
      "* TODO Parent
SCHEDULED: <2026-08-05 Wed>
:PROPERTIES:
:GTASK_ID: parent-id
:END:
Old body line one.
Old body line two.

** TODO Subtask A
   :PROPERTIES:
   :GTASK_ID: sub-a
   :END:
** TODO Subtask B
   :PROPERTIES:
   :GTASK_ID: sub-b
   :END:
"
    (re-search-forward "^\\*+ ")
    (org-mode-google-tasks-sync-org--replace-body "Fresh body.")
    (goto-char (point-min))
    (should (re-search-forward "Fresh body" nil t))
    (should (re-search-forward "Subtask A" nil t))
    (should (re-search-forward "Subtask B" nil t))
    ;; The old body lines are gone.
    (goto-char (point-min))
    (should-not (re-search-forward "Old body line one" nil t))))

(ert-deftest org-mode-google-tasks-sync-org-test/replace-body-no-children-replaces-whole-section ()
  "When the heading has no children, `--replace-body' replaces the whole body section."
  (org-mode-google-tasks-sync-org-test--with-org
      "* TODO Parent
SCHEDULED: <2026-08-05 Wed>
Old body.
"
    (re-search-forward "^\\*+ ")
    (org-mode-google-tasks-sync-org--replace-body "New body.")
    (goto-char (point-min))
    (should (re-search-forward "New body" nil t))
    (should-not (re-search-forward "Old body" nil t))))

(ert-deftest org-mode-google-tasks-sync-org-test/read-task-marker-is-sticky ()
  "Task struct markers use insertion-type t so they ride with the
heading across org's delete+insert operations (e.g. `org-sort-entries').
Regression for the buffer-clobber bug where a post-sort async
`write-task' landed on the wrong heading."
  (org-mode-google-tasks-sync-org-test--with-org
      "* Tasks
** TODO A
** TODO B
"
    (re-search-forward "^\\*\\* TODO B")
    (beginning-of-line)
    (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L1")))
      (let ((m (org-mode-google-tasks-sync-org-task-marker task)))
        (should (marker-insertion-type m)))
      ;; Sort children of * Tasks alphabetically (A stays first, B stays
      ;; second — no content change).  After the sort the marker must
      ;; still point at the B heading.
      (goto-char (point-min))
      (org-sort-entries nil ?a)
      (should (org-at-heading-p))
      (goto-char (org-mode-google-tasks-sync-org-task-marker task))
      (org-back-to-heading t)
      (should (equal "B"
                     (org-element-property
                      :raw-value (org-element-at-point)))))))

(provide 'org-mode-google-tasks-sync-org-test)
;;; org-mode-google-tasks-sync-org-test.el ends here
