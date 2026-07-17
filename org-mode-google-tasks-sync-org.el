;;; org-mode-google-tasks-sync-org.el --- Org buffer parser/serializer -*- lexical-binding: t -*-

;; Copyright (C) 2026 Alexander Lehmann
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Read and write a Google Task representation in an org buffer.  Pure
;; functions that operate on the buffer at point or on a region.  No
;; network code here.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'subr-x)

(defconst org-mode-google-tasks-sync-org--prop-id "GTASK_ID"
  "Property holding the Google Tasks task ID for a heading.")

(defconst org-mode-google-tasks-sync-org--prop-updated "GTASK_UPDATED"
  "Property holding the server `updated' timestamp at last successful sync.")

(defconst org-mode-google-tasks-sync-org--prop-etag "GTASK_ETAG"
  "Property holding the server ETag at last successful sync.")

(defconst org-mode-google-tasks-sync-org--prop-hash "GTASK_CONTENT_HASH"
  "Property holding the canonical content hash at last successful sync.")

(defconst org-mode-google-tasks-sync-org--prop-list "GTASK_LIST"
  "Property holding the Google Tasks list ID this heading belongs to.")

(defconst org-mode-google-tasks-sync-org--prop-position "GTASK_POSITION"
  "Property holding the server `position' lexicographic-rank string.
Used by the sort step in the engine; not included in the canonical
content hash because it's display metadata, not user content.")

(defconst org-mode-google-tasks-sync-org--prop-completed "GTASK_COMPLETED"
  "Property holding the server `completed' RFC3339 timestamp for done tasks.
Used as a secondary sort key so DONE entries land in
most-recently-completed-first order.  Not in the canonical hash;
status (which IS in the hash) covers the meaningful state change.")

(defconst org-mode-google-tasks-sync-org--prop-links "GTASK_LINKS"
  "Property holding the server `links' array as a JSON string.
Read-only display metadata populated by Gmail, Keep, Chat, Docs.
Not in the canonical hash; not pushable via the Tasks API.")

(defconst org-mode-google-tasks-sync-org--prop-web-view-link "GTASK_WEB_LINK"
  "Property holding the server `webViewLink' URL to the task in Google's web UI.
Read-only display metadata.  Not in the canonical hash; not pushable.")

(cl-defstruct org-mode-google-tasks-sync-org-task
  "In-memory representation of a synced task heading."
  id            ; string or nil for unsynced local tasks
  list-id       ; string
  title         ; string, never includes TODO keyword or priority cookie
  notes         ; string, may be empty
  status        ; symbol: 'needsAction or 'completed
  due           ; string YYYY-MM-DD or nil
  parent-id     ; string or nil (Google parent task ID)
  updated       ; string RFC3339 from server, or nil for unsynced
  etag          ; string from server, or nil
  hash          ; canonical content hash at last sync, or nil
  position      ; string from server (lexicographic rank), or nil
  completed     ; string RFC3339 from server for DONE tasks, or nil
  links         ; string JSON-encoded links array from server, or nil
  web-view-link ; string URL to task in Google web UI, or nil
  marker)       ; buffer marker pointing at the heading, or nil

(defun org-mode-google-tasks-sync-org--priority-cookie-re ()
  "Regexp matching an org priority cookie like \"[#A] \"."
  "\\[#[A-Z]\\][ \t]*")

(defun org-mode-google-tasks-sync-org-strip-priority (title)
  "Remove a leading priority cookie from TITLE, if any."
  (replace-regexp-in-string (concat "\\`" (org-mode-google-tasks-sync-org--priority-cookie-re))
                            ""
                            title))

(defun org-mode-google-tasks-sync-org--todo-state (element)
  "Return the TODO state symbol for headline ELEMENT.
`needsAction' if state is a not-done keyword or nil, `completed'
if a done keyword."
  (let ((kw (org-element-property :todo-type element)))
    (if (eq kw 'done) 'completed 'needsAction)))

(defun org-mode-google-tasks-sync-org--headline-due (element)
  "Return the SCHEDULED date for headline ELEMENT as YYYY-MM-DD, or nil."
  (let ((sched (org-element-property :scheduled element)))
    (when sched
      (format "%04d-%02d-%02d"
              (org-element-property :year-start sched)
              (org-element-property :month-start sched)
              (org-element-property :day-start sched)))))

(defun org-mode-google-tasks-sync-org--headline-body (element)
  "Return the body text of headline ELEMENT, excluding the property drawer.
Trimmed; runs of blank lines collapsed."
  (let* ((begin (org-element-property :contents-begin element))
         (end   (org-element-property :contents-end element)))
    (if (and begin end)
        (let ((raw (buffer-substring-no-properties begin end)))
          (org-mode-google-tasks-sync-org--canonicalize-body raw))
      "")))

(defun org-mode-google-tasks-sync-org--canonicalize-body (raw)
  "Strip property drawer, planning lines, and trim whitespace from RAW body text.
Planning lines and the property drawer may appear in either order; this loops
until neither prefix matches."
  (let ((s raw)
        (prev nil))
    (while (not (equal s prev))
      (setq prev s)
      (setq s (replace-regexp-in-string
               "\\`[ \t]*:PROPERTIES:[ \t]*\n\\(?:.*\n\\)*?[ \t]*:END:[ \t]*\n?"
               "" s))
      (setq s (replace-regexp-in-string
               "\\`\\(?:[ \t]*\\(?:SCHEDULED\\|DEADLINE\\|CLOSED\\):[^\n]*\n\\)+"
               "" s)))
    (setq s (replace-regexp-in-string "\n\n+" "\n\n" s))
    (string-trim s)))

(defun org-mode-google-tasks-sync-org-read-task-at-point (list-id)
  "Build a task struct from the heading at point.  LIST-ID is the configured list."
  (save-excursion
    (org-back-to-heading t)
    (let* ((element (org-element-at-point))
           (raw-title (org-element-property :raw-value element))
           (title (org-mode-google-tasks-sync-org-strip-priority raw-title)))
      (make-org-mode-google-tasks-sync-org-task
       :id        (org-entry-get nil org-mode-google-tasks-sync-org--prop-id)
       :list-id   list-id
       :title     title
       :notes     (org-mode-google-tasks-sync-org--headline-body element)
       :status    (org-mode-google-tasks-sync-org--todo-state element)
       :due       (org-mode-google-tasks-sync-org--headline-due element)
       :parent-id nil
        :updated   (org-entry-get nil org-mode-google-tasks-sync-org--prop-updated)
        :etag      (org-entry-get nil org-mode-google-tasks-sync-org--prop-etag)
        :hash      (org-entry-get nil org-mode-google-tasks-sync-org--prop-hash)
        :position  (org-entry-get nil org-mode-google-tasks-sync-org--prop-position)
        :completed (org-entry-get nil org-mode-google-tasks-sync-org--prop-completed)
        :links     (org-entry-get nil org-mode-google-tasks-sync-org--prop-links)
        :web-view-link (org-entry-get nil org-mode-google-tasks-sync-org--prop-web-view-link)
        :marker    (point-marker)))))

(defun org-mode-google-tasks-sync-org-canonical-hash (task)
  "Return a stable SHA-1 hash over the synced fields of TASK.
Excludes priority cookies, IDs, etags, timestamps."
  (let ((projection
         (string-join
          (list (or (org-mode-google-tasks-sync-org-task-title task) "")
                (or (org-mode-google-tasks-sync-org-task-notes task) "")
                (symbol-name (or (org-mode-google-tasks-sync-org-task-status task)
                                 'needsAction))
                (or (org-mode-google-tasks-sync-org-task-due task) ""))
          "\n")))
    (secure-hash 'sha1 projection)))

(defun org-mode-google-tasks-sync-org-write-task (task)
  "Write TASK to the buffer position at TASK's marker, creating or updating fields.
Preserves the existing TODO keyword and priority cookie when updating title."
  (let ((m (org-mode-google-tasks-sync-org-task-marker task)))
    (if (and m (marker-buffer m))
        (with-current-buffer (marker-buffer m)
          (org-mode-google-tasks-sync-org--write-task-1 task))
      (org-mode-google-tasks-sync-org--write-task-1 task))))

(defun org-mode-google-tasks-sync-org--write-task-1 (task)
  "Write TASK fields to the heading at point.
Expects to be called in the correct org buffer with point at or near
the target heading."
  (save-excursion
    (let ((m (org-mode-google-tasks-sync-org-task-marker task)))
      (when m (goto-char m)))
    (org-back-to-heading t)
    (org-mode-google-tasks-sync-org--replace-title
     (org-mode-google-tasks-sync-org-task-title task))
    (let ((target (org-mode-google-tasks-sync-org-task-status task)))
      (cond
       ((and (eq target 'completed) (not (org-entry-is-done-p)))
        (org-todo 'done))
       ((and (eq target 'needsAction) (org-entry-is-done-p))
        (org-todo 'todo))))
    (let ((due (org-mode-google-tasks-sync-org-task-due task)))
      (if due
          (org-schedule nil due)
        (org-schedule '(4))))
    (org-mode-google-tasks-sync-org--replace-body
     (or (org-mode-google-tasks-sync-org-task-notes task) ""))
    (org-entry-put nil org-mode-google-tasks-sync-org--prop-id
                   (org-mode-google-tasks-sync-org-task-id task))
    (org-entry-put nil org-mode-google-tasks-sync-org--prop-list
                   (org-mode-google-tasks-sync-org-task-list-id task))
    (when (org-mode-google-tasks-sync-org-task-updated task)
      (org-entry-put nil org-mode-google-tasks-sync-org--prop-updated
                     (org-mode-google-tasks-sync-org-task-updated task)))
    (when (org-mode-google-tasks-sync-org-task-etag task)
      (org-entry-put nil org-mode-google-tasks-sync-org--prop-etag
                     (org-mode-google-tasks-sync-org-task-etag task)))
    (when (org-mode-google-tasks-sync-org-task-position task)
      (org-entry-put nil org-mode-google-tasks-sync-org--prop-position
                     (org-mode-google-tasks-sync-org-task-position task)))
    (when (org-mode-google-tasks-sync-org-task-completed task)
      (org-entry-put nil org-mode-google-tasks-sync-org--prop-completed
                     (org-mode-google-tasks-sync-org-task-completed task)))
    (when (org-mode-google-tasks-sync-org-task-links task)
      (org-entry-put nil org-mode-google-tasks-sync-org--prop-links
                     (org-mode-google-tasks-sync-org-task-links task)))
    (when (org-mode-google-tasks-sync-org-task-web-view-link task)
      (org-entry-put nil org-mode-google-tasks-sync-org--prop-web-view-link
                     (org-mode-google-tasks-sync-org-task-web-view-link task)))
    (org-entry-put nil org-mode-google-tasks-sync-org--prop-hash
                   (org-mode-google-tasks-sync-org-canonical-hash task))))

(defun org-mode-google-tasks-sync-org--replace-title (new-title)
  "Replace the title portion of the heading at point with NEW-TITLE.
Preserves the leading stars, TODO keyword, and any priority cookie."
  (save-excursion
    (org-back-to-heading t)
    (let* ((element (org-element-at-point))
           (raw-old (org-element-property :raw-value element))
           (priority-match (string-match
                            (concat "\\`" (org-mode-google-tasks-sync-org--priority-cookie-re))
                            raw-old))
           (priority-prefix (if priority-match (match-string 0 raw-old) "")))
      (re-search-forward org-complex-heading-regexp (line-end-position) t)
      (let ((title-start (match-beginning 4))
            (title-end   (match-end 4)))
        (when (and title-start title-end)
          (goto-char title-start)
          (delete-region title-start title-end)
          (insert priority-prefix new-title))))))

(defun org-mode-google-tasks-sync-org--replace-body (new-body)
  "Replace the body of the current heading with NEW-BODY.
Preserves the property drawer and planning lines."
  (save-excursion
    (org-back-to-heading t)
    (let* ((element (org-element-at-point))
           (contents-begin (org-element-property :contents-begin element))
           (contents-end (org-element-property :contents-end element)))
      (when (and contents-begin contents-end)
        (goto-char contents-begin)
        (when (looking-at "[ \t]*:PROPERTIES:")
          (re-search-forward "^[ \t]*:END:[ \t]*\n" contents-end t))
        (while (looking-at "[ \t]*\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):")
          (forward-line 1))
        (let ((body-start (point)))
          (delete-region body-start contents-end)
          (unless (string-empty-p new-body)
            (insert new-body)
            (unless (string-suffix-p "\n" new-body)
              (insert "\n"))))))))

(defun org-mode-google-tasks-sync-org-insert-task-under (parent-marker task)
  "Insert TASK as a new child heading under the heading at PARENT-MARKER.
Returns the marker of the new heading."
  (with-current-buffer (marker-buffer parent-marker)
    (save-excursion
      (goto-char parent-marker)
      (org-back-to-heading t)
      (let ((parent-level (org-current-level)))
        (org-end-of-subtree t t)
        (unless (bolp) (insert "\n"))
        (insert (make-string (1+ parent-level) ?*) " TODO "
                (or (org-mode-google-tasks-sync-org-task-title task) "") "\n")
        (let ((new-marker (save-excursion
                            (forward-line -1)
                            (point-marker))))
          (setf (org-mode-google-tasks-sync-org-task-marker task) new-marker)
          (goto-char new-marker)
          (org-mode-google-tasks-sync-org-write-task task)
          new-marker)))))

(defun org-mode-google-tasks-sync-org-collect-tasks-under (file parent-heading list-id)
  "Return all task structs that are direct children of PARENT-HEADING in FILE.
LIST-ID is attached to each returned task."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char (point-min))
      (let ((tasks '()))
        (when (re-search-forward (format "^\\*+ %s" (regexp-quote parent-heading)) nil t)
          (let ((parent-level (org-current-level)))
            (forward-line 1)
            (while (and (not (eobp))
                        (or (not (looking-at "^\\*+ "))
                            (> (org-current-level) parent-level)))
              (when (and (looking-at "^\\*+ ")
                         (= (org-current-level) (1+ parent-level)))
                (push (org-mode-google-tasks-sync-org-read-task-at-point list-id) tasks))
              (forward-line 1))))
        (nreverse tasks)))))

(provide 'org-mode-google-tasks-sync-org)
;;; org-mode-google-tasks-sync-org.el ends here
