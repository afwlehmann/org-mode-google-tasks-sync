;;; org-mode-google-tasks-sync-move-test.el --- Tests for reorder/reparent advice -*- lexical-binding: t -*-

;;; Commentary:

;; Verifies the sibling-walk helpers that back the advised M-<up>/
;; M-<down>/M-<left>/M-<right> keys.  These are pure functions over
;; the buffer at point; no network calls are exercised.  Regression
;; coverage for the critical bug where `--sibling-ids' never
;; included the current heading and `--last-child-id' always returned
;; nil.

;;; Code:

(require 'ert)
(require 'org)
(require 'cl-lib)
(require 'org-mode-google-tasks-sync)

(defmacro org-mode-google-tasks-sync-move-test--with-org (org-text &rest body)
  "Run BODY in a temp org buffer containing ORG-TEXT, point at min."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,org-text)
     (org-mode)
     (goto-char (point-min))
     ,@body))

(defun org-mode-google-tasks-sync-move-test--goto-title (title)
  "Move point to the heading whose title is TITLE.
Matches the headline title text after the TODO keyword, if any."
  (goto-char (point-min))
  (should (re-search-forward
           (format "^\\*+ \\(?:TODO \\)?\\(?:DONE \\)?%s$"
                   (regexp-quote title))
           nil t))
  (goto-char (match-beginning 0))
  ;; Move to the headline start so org functions see the heading.
  (beginning-of-line))

(defun org-mode-google-tasks-sync-move-test--sib-titles ()
  "Return sibling titles at point, in buffer order, for `--sibling-ids'."
  (let ((sibs (org-mode-google-tasks-sync--sibling-ids)))
    (mapcar (lambda (cell)
              (with-current-buffer (marker-buffer (car cell))
                (save-excursion
                  (goto-char (car cell))
                  (org-element-property :raw-value (org-element-at-point)))))
            sibs)))

;;; -- `--sibling-ids' --------------------------------------------------------

(ert-deftest move-test/sibling-ids-includes-current-heading ()
  "The current heading MUST appear in its own sibling list.
Regression for the critical bug where `re-search-backward' from the
heading start could never match the heading itself, making every
`cl-position' lookup return nil and silently no-op'ing M-<up>/M-<down>."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :END:
** TODO B
   :PROPERTIES:
   :GTASK_ID: b
   :END:
** TODO C
   :PROPERTIES:
   :GTASK_ID: c
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "B")
    (let ((ids (mapcar #'cdr (org-mode-google-tasks-sync--sibling-ids))))
      (should (equal '("a" "b" "c") ids)))))

(ert-deftest move-test/sibling-ids-single-task ()
  "An only child returns a singleton list containing itself."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO Only
   :PROPERTIES:
   :GTASK_ID: only
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "Only")
    (should (equal '("only")
                   (mapcar #'cdr (org-mode-google-tasks-sync--sibling-ids))))))

(ert-deftest move-test/sibling-ids-first-and-last ()
  "First and last siblings return the full list in buffer order."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :END:
** TODO B
   :PROPERTIES:
   :GTASK_ID: b
   :END:
** TODO C
   :PROPERTIES:
   :GTASK_ID: c
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "A")
    (should (equal '("a" "b" "c")
                   (mapcar #'cdr (org-mode-google-tasks-sync--sibling-ids))))
    (org-mode-google-tasks-sync-move-test--goto-title "C")
    (should (equal '("a" "b" "c")
                   (mapcar #'cdr (org-mode-google-tasks-sync--sibling-ids))))))

(ert-deftest move-test/sibling-ids-keeps-local-only-siblings ()
  "Siblings without :GTASK_ID: are kept with a nil cdr.
They occupy a slot in buffer order that matters for computing
the `previous' query param of `tasks.move' (Google only knows
about synced tasks, so the nearest synced predecessor determines
`previous'; the unsynced ones are preserved for index arithmetic)."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO Synced
   :PROPERTIES:
   :GTASK_ID: s
   :END:
** TODO Local only (no ID)
** TODO Also synced
   :PROPERTIES:
   :GTASK_ID: t
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "Synced")
    (should (equal '("s" nil "t")
                   (mapcar #'cdr (org-mode-google-tasks-sync--sibling-ids))))))

(ert-deftest move-test/sibling-ids-ignores-nephews ()
  "A sibling's child subtree must not appear as a sibling of the current heading.
Regression for the old `re-search-backward' walk which descended into
the previous sibling's subtree and picked up level-mismatched headings."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :END:
*** TODO A-subtask
    :PROPERTIES:
    :GTASK_ID: asub
    :END:
** TODO B
   :PROPERTIES:
   :GTASK_ID: b
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "B")
    (should (equal '("a" "b")
                   (mapcar #'cdr (org-mode-google-tasks-sync--sibling-ids))))))

(ert-deftest move-test/sibling-ids-titles-in-buffer-order ()
  "Titles (not just IDs) come back in buffer order across the full walk."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO First
   :PROPERTIES:
   :GTASK_ID: f
   :END:
** TODO Middle
   :PROPERTIES:
   :GTASK_ID: m
   :END:
*** TODO Middle-child (must not appear)
    :PROPERTIES:
    :GTASK_ID: mc
    :END:
** TODO Last
   :PROPERTIES:
   :GTASK_ID: l
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "Middle")
    (should (equal '("First" "Middle" "Last")
                   (org-mode-google-tasks-sync-move-test--sib-titles)))))

;;; -- `--prev-sibling-id' -----------------------------------------------------

(ert-deftest move-test/prev-sibling-id-boundaries ()
  "`--prev-sibling-id' returns nil for the first sibling, the prior ID otherwise."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :END:
** TODO B
   :PROPERTIES:
   :GTASK_ID: b
   :END:
** TODO C
   :PROPERTIES:
   :GTASK_ID: c
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "A")
    (let* ((sibs (org-mode-google-tasks-sync--sibling-ids))
           (here (point-marker)))
      (should (null (org-mode-google-tasks-sync--prev-sibling-id sibs here))))
    (org-mode-google-tasks-sync-move-test--goto-title "B")
    (let* ((sibs (org-mode-google-tasks-sync--sibling-ids))
           (here (point-marker)))
      (should (equal "a"
                     (org-mode-google-tasks-sync--prev-sibling-id sibs here))))))

;;; -- `--last-child-id' -------------------------------------------------------

(ert-deftest move-test/last-child-id-no-children ()
  "A parent with no children returns nil."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
"
    (should (null (org-mode-google-tasks-sync--last-child-id (point-marker))))))

(ert-deftest move-test/last-child-id-single-child ()
  (org-mode-google-tasks-sync-move-test--with-org
      "* Parent
   :PROPERTIES:
   :GTASK_ID: p
   :END:
** TODO Only child
   :PROPERTIES:
   :GTASK_ID: c1
   :END:
"
    (goto-char (point-min))
    (should (equal "c1"
                   (org-mode-google-tasks-sync--last-child-id (point-marker))))))

(ert-deftest move-test/last-child-id-multiple-children ()
  "The last direct child's ID wins, ignoring grandchildren."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Parent
   :PROPERTIES:
   :GTASK_ID: p
   :END:
** TODO Child 1
   :PROPERTIES:
   :GTASK_ID: c1
   :END:
** TODO Child 2
   :PROPERTIES:
   :GTASK_ID: c2
   :END:
*** Grandchild (must not win)
    :PROPERTIES:
    :GTASK_ID: g1
    :END:
** TODO Child 3
   :PROPERTIES:
   :GTASK_ID: c3
   :END:
"
    (goto-char (point-min))
    (should (equal "c3"
                   (org-mode-google-tasks-sync--last-child-id (point-marker))))))

(ert-deftest move-test/last-child-id-skips-unsynced ()
  "Unsynced children are skipped; the last synced child's ID is returned."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Parent
   :PROPERTIES:
   :GTASK_ID: p
   :END:
** TODO Synced child
   :PROPERTIES:
   :GTASK_ID: c1
   :END:
** TODO Local-only child (no ID)
"
    (goto-char (point-min))
    (should (equal "c1"
                   (org-mode-google-tasks-sync--last-child-id (point-marker))))))

;;; -- `--compute-move-params' ------------------------------------------------

(ert-deftest move-test/compute-move-up-at-first-errors ()
  "M-<up> on the first sibling signals `user-error'."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :END:
** TODO B
   :PROPERTIES:
   :GTASK_ID: b
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "A")
    (should-error (org-mode-google-tasks-sync--compute-move-params 'up)
                  :type 'user-error)))

(ert-deftest move-test/compute-move-down-at-last-errors ()
  "M-<down> on the last sibling signals `user-error'."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :END:
** TODO B
   :PROPERTIES:
   :GTASK_ID: b
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "B")
    (should-error (org-mode-google-tasks-sync--compute-move-params 'down)
                  :type 'user-error)))

(ert-deftest move-test/compute-move-up-middle ()
  "Moving B up: new predecessor is A (the first sibling), so previous-id=nil
would move B to first position.  Actually for an up-move, B lands
between A's predecessor (none here) and A, so previous should be nil
meaning B becomes first."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :END:
** TODO B
   :PROPERTIES:
   :GTASK_ID: b
   :END:
** TODO C
   :PROPERTIES:
   :GTASK_ID: c
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "B")
    (let ((params (org-mode-google-tasks-sync--compute-move-params 'up)))
      (should params)
      (should (null (cdr params))))))             ; previous=nil → move to first

(ert-deftest move-test/compute-move-up-from-third ()
  "Moving C (idx 2) up: target-idx=1, prev-sib=nth 0=A, previous=a."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :END:
** TODO B
   :PROPERTIES:
   :GTASK_ID: b
   :END:
** TODO C
   :PROPERTIES:
   :GTASK_ID: c
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "C")
    (let ((params (org-mode-google-tasks-sync--compute-move-params 'up)))
      (should params)
      (should (equal "a" (cdr params))))))

(ert-deftest move-test/compute-move-down-middle ()
  "Moving B down: the sibling after B (C) becomes its predecessor, so previous=c."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :END:
** TODO B
   :PROPERTIES:
   :GTASK_ID: b
   :END:
** TODO C
   :PROPERTIES:
   :GTASK_ID: c
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "B")
    (let ((params (org-mode-google-tasks-sync--compute-move-params 'down)))
      (should params)
      (should (equal "c" (cdr params))))))

;;; -- `--compute-demote-params' -----------------------------------------------

(ert-deftest move-test/demote-refuses-when-has-subtasks ()
  "Demoting a task with subtasks is refused (they'd fall past level 2)."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :END:
** TODO B (has subtask)
   :PROPERTIES:
   :GTASK_ID: b
   :END:
*** TODO B-subtask
"
    (org-mode-google-tasks-sync-move-test--goto-title "B (has subtask)")
    (should-error (org-mode-google-tasks-sync--compute-demote-params)
                  :type 'user-error)))

(ert-deftest move-test/demote-refuses-when-no-preceding-sibling ()
  "Demoting the first sibling is refused (nowhere to nest)."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :END:
** TODO B
   :PROPERTIES:
   :GTASK_ID: b
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "A")
    (should-error (org-mode-google-tasks-sync--compute-demote-params)
                  :type 'user-error)))

(ert-deftest move-test/demote-happy-path-no-existing-children ()
  "Demoting B under A (which has no children): new-parent=a, previous=nil."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :END:
** TODO B
   :PROPERTIES:
   :GTASK_ID: b
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "B")
    (let ((params (org-mode-google-tasks-sync--compute-demote-params)))
      (should params)
      (should (equal "a" (car params)))
      (should (null (cdr params))))))             ; no existing children → first

(ert-deftest move-test/demote-happy-path-with-existing-children ()
  "Demoting C under B (which has child D): previous=d (last child of B)."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :END:
** TODO B
   :PROPERTIES:
   :GTASK_ID: b
   :END:
*** TODO D (existing child of B)
    :PROPERTIES:
    :GTASK_ID: d
    :END:
** TODO C
   :PROPERTIES:
   :GTASK_ID: c
   :END:
"
    (org-mode-google-tasks-sync-move-test--goto-title "C")
    (let ((params (org-mode-google-tasks-sync--compute-demote-params)))
      (should params)
      (should (equal "b" (car params)))
      (should (equal "d" (cdr params))))))

;;; -- --apply-server-move pins writes to the moved heading --------------------

(ert-deftest move-test/apply-server-move-writes-position-at-marker-not-point ()
  "`--apply-server-move' writes GTASK_POSITION at HEADING-MARKER, not at point.
The async callback fires with point wherever the user left it; without
pinning the write to the moved heading's marker, GTASK_POSITION would
land on the wrong heading and the next tick's sort would reset the
moved task to its old position."
  (org-mode-google-tasks-sync-move-test--with-org
      "* Tasks
** TODO A
   :PROPERTIES:
   :GTASK_ID: a
   :GTASK_LIST: L
   :GTASK_POSITION: 00000000000000000000
   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z
   :GTASK_CONTENT_HASH: old
   :END:
** TODO B
   :PROPERTIES:
   :GTASK_ID: b
   :GTASK_LIST: L
   :GTASK_POSITION: 00000000000000000001
   :GTASK_UPDATED: 2026-01-01T00:00:00.000Z
   :GTASK_CONTENT_HASH: old
   :END:
"
    (require 'org-mode-google-tasks-sync-engine)
    (org-mode-google-tasks-sync-move-test--goto-title "B")
    (let ((b-marker (org-mode-google-tasks-sync-org--sticky-marker)))
      ;; Point is on B; capture B's marker, then move point to A.
      (org-mode-google-tasks-sync-move-test--goto-title "A")
      (cl-letf (((symbol-function 'org-mode-google-tasks-sync-api-move-task)
                 (lambda (_token _list-id _task-id then _else _parent _prev)
                   (funcall then '((updated . "2026-08-05T10:00:00.000Z")
                                   (etag . "new-etag")
                                   (position . "00000000000000000005"))))))
        (org-mode-google-tasks-sync--apply-server-move
         nil "L" "b" nil nil "B" #'ignore b-marker))
      ;; B should have the new position + etag + hash; A should be untouched.
      (org-mode-google-tasks-sync-move-test--goto-title "B")
      (should (equal "00000000000000000005" (org-entry-get nil "GTASK_POSITION")))
      (should (equal "new-etag" (org-entry-get nil "GTASK_ETAG")))
      (should (equal "2026-08-05T10:00:00.000Z" (org-entry-get nil "GTASK_UPDATED")))
      ;; Content hash should be refreshed (not "old").
      (should-not (equal "old" (org-entry-get nil "GTASK_CONTENT_HASH")))
      ;; A is untouched.
      (org-mode-google-tasks-sync-move-test--goto-title "A")
      (should (equal "00000000000000000000" (org-entry-get nil "GTASK_POSITION")))
      (should (equal "old" (org-entry-get nil "GTASK_CONTENT_HASH"))))))

(provide 'org-mode-google-tasks-sync-move-test)
;;; org-mode-google-tasks-sync-move-test.el ends here
