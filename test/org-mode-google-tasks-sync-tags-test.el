;;; org-mode-google-tasks-sync-tags-test.el --- Tag <-> title encoding tests -*- lexical-binding: t -*-

;;; Commentary:
;; Covers the `@' hashtag encoding of org tags onto the Google Tasks
;; title — the only tag-representation surface the Tasks API offers.
;; Untagged tasks must keep a byte-identical hash projection across the
;; upgrade; tagged tasks gain tag-awareness via the same hash.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-mode-google-tasks-sync-org)
(require 'org-mode-google-tasks-sync-engine)

;;; -- encode --

(ert-deftest org-mode-google-tasks-sync-tags-test/encode-untagged-passthrough ()
  "Untagged task encodes to the bare title — required for hash stability."
  (should (equal "Buy milk"
                 (org-mode-google-tasks-sync-org-title-encode-tags
                  "Buy milk" nil))))

(ert-deftest org-mode-google-tasks-sync-tags-test/encode-sorted-and-prefixed ()
  "Tags are emitted sorted and each prefixed with `@'."
  (should (equal "Buy milk @errands @work"
                 (org-mode-google-tasks-sync-org-title-encode-tags
                  "Buy milk" '("work" "errands")))))

(ert-deftest org-mode-google-tasks-sync-tags-test/encode-drops-whitespace-tags ()
  "Tags containing whitespace cannot round-trip as hashtags — drop silently."
  (should (equal "Buy milk @work"
                 (org-mode-google-tasks-sync-org-title-encode-tags
                  "Buy milk" '("my family" "work" "")))))

(ert-deftest org-mode-google-tasks-sync-tags-test/decode-none ()
  "A title without trailing `@' hashtags decodes to itself with no tags."
  (should (equal '("Buy milk" . nil)
                 (org-mode-google-tasks-sync-org-title-decode-tags "Buy milk"))))

(ert-deftest org-mode-google-tasks-sync-tags-test/decode-bare-at-is-not-a-tag ()
  "A bare `@' (length 1) is title text, not a tag token."
  (should (equal '("Buy milk @" . nil)
                 (org-mode-google-tasks-sync-org-title-decode-tags "Buy milk @"))))

(ert-deftest org-mode-google-tasks-sync-tags-test/decode-contiguous-trailing ()
  "Only the CONTIGUOUS trailing run of `@' hashtags is decoded.
A hypothetical `@' earlier in the title, followed by a non-tag word,
is not interrupted by the trailing block."
  (should (equal '("Pay acme bills" . ("alice" "work"))
                 (org-mode-google-tasks-sync-org-title-decode-tags
                  "Pay acme bills @alice @work")))
  ;; And a `@' in the middle with NO trailing block is NOT a tag.
  (should (equal '("call @alice for the errand" . nil)
                 (org-mode-google-tasks-sync-org-title-decode-tags
                  "call @alice for the errand"))))

(ert-deftest org-mode-google-tasks-sync-tags-test/decode-mid-word-at-stays ()
  "An `@' mid-word (e.g. `user@host') is part of the title, not a tag."
  (should (equal '("Email user@x.org" . nil)
                 (org-mode-google-tasks-sync-org-title-decode-tags
                  "Email user@x.org"))))

(ert-deftest org-mode-google-tasks-sync-tags-test/round-trip ()
  "encode ∘ decode = identity for any title+tag combination."
  (cl-loop for (title tags)
           in '(("Buy milk" nil)
                ("Buy milk" ("errands"))
                ("Buy milk" ("work" "errands" "home" "alice"))
                ("Async task with spaces" ("async" "test")))
           do (let* ((encoded (org-mode-google-tasks-sync-org-title-encode-tags
                               title tags))
                     (decoded (org-mode-google-tasks-sync-org-title-decode-tags
                               encoded)))
                (should (equal title (car decoded)))
                (should (equal (sort (copy-sequence tags) #'string<)
                               (cdr decoded))))))

;;; -- hash --

(ert-deftest org-mode-google-tasks-sync-tags-test/hash-untagged-backward-compat ()
  "Untagged task hash is identical to the pre-tag-sync projection.
Regression guard against a spurious push-storm on upgrade."
  (let ((t1 (make-org-mode-google-tasks-sync-org-task
             :title "Buy milk" :status 'needsAction))
        (t2 (make-org-mode-google-tasks-sync-org-task
             :title "Buy milk" :status 'needsAction :tags nil)))
    (should (equal (org-mode-google-tasks-sync-org-canonical-hash t1)
                   (org-mode-google-tasks-sync-org-canonical-hash t2)))))

(ert-deftest org-mode-google-tasks-sync-tags-test/hash-respects-tags ()
  "Two tasks differing only in tags hash differently."
  (let ((t1 (make-org-mode-google-tasks-sync-org-task
             :title "Buy milk" :status 'needsAction))
        (t2 (make-org-mode-google-tasks-sync-org-task
             :title "Buy milk" :status 'needsAction :tags '("errands"))))
    (should-not (equal (org-mode-google-tasks-sync-org-canonical-hash t1)
                       (org-mode-google-tasks-sync-org-canonical-hash t2)))))

(ert-deftest org-mode-google-tasks-sync-tags-test/hash-tag-order-invariant ()
  "Tag ORDER does not affect the hash — only the tag SET."
  (let ((t1 (make-org-mode-google-tasks-sync-org-task
             :title "Buy milk" :status 'needsAction :tags '("b" "a")))
        (t2 (make-org-mode-google-tasks-sync-org-task
             :title "Buy milk" :status 'needsAction :tags '("a" "b"))))
    (should (equal (org-mode-google-tasks-sync-org-canonical-hash t1)
                   (org-mode-google-tasks-sync-org-canonical-hash t2)))))

;;; -- api payload --

(ert-deftest org-mode-google-tasks-sync-tags-test/api-data-encodes-title ()
  "`task->api-data' pushes the hashtag-encoded title."
  (let* ((task (make-org-mode-google-tasks-sync-org-task
                :title "Buy milk" :status 'needsAction
                :tags '("errands" "work")))
         (data (org-mode-google-tasks-sync-engine--task->api-data task)))
    (should (equal "Buy milk @errands @work" (alist-get 'title data)))))

(ert-deftest org-mode-google-tasks-sync-tags-test/remote->struct-decodes-title ()
  "`remote->struct' splits a hashtag-suffixed title into title + tags."
  (let ((struct (org-mode-google-tasks-sync-engine--remote-task->struct
                 '((id . "t") (title . "Buy milk @errands @work"))
                 "L" nil)))
    (should (equal "Buy milk"
                   (org-mode-google-tasks-sync-org-task-title struct)))
    (should (equal '("errands" "work")
                   (org-mode-google-tasks-sync-org-task-tags struct)))))

;;; -- pull write --

(ert-deftest org-mode-google-tasks-sync-tags-test/write-task-applies-tags ()
  "`write-task' writes the title and applies tags via `org-set-tags'."
  (org-mode-google-tasks-sync-org-test--with-org
      "* TODO Buy milk :placeholder:\n"
    (re-search-forward "^\\*+ ")
    (let ((task (org-mode-google-tasks-sync-org-read-task-at-point "L")))
      (setf (org-mode-google-tasks-sync-org-task-tags task) '("errands" "work"))
      (setf (org-mode-google-tasks-sync-org-task-title task) "Buy milk")
      (org-mode-google-tasks-sync-org-write-task task))
    (should (equal '("errands" "work") (org-get-tags nil t)))
    (should (equal "Buy milk"
                   (org-element-property :raw-value (org-element-at-point))))))

(provide 'org-mode-google-tasks-sync-tags-test)
;;; org-mode-google-tasks-sync-tags-test.el ends here
