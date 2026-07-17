;;; org-mode-google-tasks-sync-api.el --- Google Tasks REST API client -*- lexical-binding: t -*-

;; Copyright (C) 2026 Alexander Lehmann
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Thin wrappers around the Google Tasks v1 REST API using `plz' for HTTP.
;; Every public function takes a token struct and a pair of THEN/ELSE
;; callbacks.  Pagination, rate-limit backoff, and ETag handling are here.

;;; Code:

(require 'cl-lib)
(require 'plz)
(require 'json)
(require 'subr-x)
(require 'url-util)

(defconst org-mode-google-tasks-sync-api--base-url
  "https://tasks.googleapis.com/tasks/v1"
  "Base URL for the Tasks v1 API.")

(defconst org-mode-google-tasks-sync-api--page-size 100
  "Tasks per page when listing.  Max 100.")

(cl-defstruct org-mode-google-tasks-sync-api-token
  "Holds the OAuth tokens for a session."
  access-token
  refresh-token
  client-id
  client-secret
  expires-at)

(defun org-mode-google-tasks-sync-api--auth-header (token)
  "Return an Authorization header alist for TOKEN."
  `(("Authorization" . ,(concat "Bearer "
                                (org-mode-google-tasks-sync-api-token-access-token token)))))

(defun org-mode-google-tasks-sync-api--parse-json (string)
  "Parse JSON STRING returning an alist."
  (json-parse-string string
                     :object-type 'alist
                     :array-type 'array
                     :null-object nil
                     :false-object :false))

(defun org-mode-google-tasks-sync-api--serialize-json (object)
  "Serialize OBJECT to JSON as a unibyte UTF-8 string.  Drops nil values.
The result is encoded with `utf-8-unix' so that `length' equals
`string-bytes' — curl's `CURLOPT_POSTFIELDSIZE' requires this
agreement, otherwise libcurl fails with CURLE_FAILED_INIT (2) on any
body containing non-ASCII code points."
  (let* ((json-str (json-serialize (org-mode-google-tasks-sync-api--strip-nils object)
                                   :null-object nil
                                   :false-object :false))
         (body (encode-coding-string json-str 'utf-8-unix)))
    (when (fboundp 'org-mode-google-tasks-sync-engine--log-debug)
      (org-mode-google-tasks-sync-engine--log-debug
       "serialize-json: len=%d bytes=%d multibyte=%s preview=%S"
       (length body) (string-bytes body)
       (not (eq (length body) (string-bytes body)))
       (substring body 0 (min 80 (length body)))))
    body))

(defun org-mode-google-tasks-sync-api--strip-nils (alist)
  "Drop entries with nil values from ALIST."
  (cl-remove-if (lambda (pair) (null (cdr pair))) alist))

(defun org-mode-google-tasks-sync-api--query-string (alist)
  "Encode ALIST as a URL query string."
  (mapconcat
   (lambda (pair)
     (concat (url-hexify-string (car pair)) "=" (url-hexify-string (cdr pair))))
   alist "&"))

(defun org-mode-google-tasks-sync-api-list-tasklists (token then else)
  "List all of the user's task lists using TOKEN.
Call THEN with an array of list objects.
Call ELSE on error."
  (plz 'get (concat org-mode-google-tasks-sync-api--base-url "/users/@me/lists")
    :headers (org-mode-google-tasks-sync-api--auth-header token)
    :as (lambda () (alist-get 'items (org-mode-google-tasks-sync-api--parse-json
                                       (buffer-string))))
    :then then
    :else else))

(defun org-mode-google-tasks-sync-api-list-tasks (token list-id args then else)
  "List tasks in LIST-ID using TOKEN.  ARGS is an alist of query params.
Calls THEN with a list of task alists across all pages, ELSE on error."
  (org-mode-google-tasks-sync-api--list-tasks-page
   token list-id args nil '() then else))

(defun org-mode-google-tasks-sync-api--list-tasks-page (token list-id args page-token acc then else)
  "Internal helper to fetch one page of tasks using TOKEN in LIST-ID.
ARGS is an alist of query params.  Recurses via PAGE-TOKEN,
accumulating into ACC, until done, then calls THEN with the full
list or ELSE on error.

Base query params are pinned to `showCompleted=true',
`showDeleted=true', and `showHidden=true'.  `showCompleted' must
be explicit: without it, Google may omit completed tasks from a
complete response, and the full-sync deletion sweep in `--apply'
would then nuke every local DONE heading — the \"items vanish on
full sync\" bug."
  (let* ((base-args `(("maxResults" . ,(number-to-string
                                         org-mode-google-tasks-sync-api--page-size))
                      ("showCompleted" . "true")
                      ("showDeleted" . "true")
                      ("showHidden"  . "true")))
         (all-args (append base-args args
                           (when page-token `(("pageToken" . ,page-token)))))
         (url (concat org-mode-google-tasks-sync-api--base-url
                      "/lists/" list-id "/tasks"
                      "?" (org-mode-google-tasks-sync-api--query-string all-args))))
    (plz 'get url
      :headers (org-mode-google-tasks-sync-api--auth-header token)
      :as (lambda () (org-mode-google-tasks-sync-api--parse-json (buffer-string)))
      :then (lambda (resp)
              (let* ((items (append (alist-get 'items resp) nil))
                     (next  (alist-get 'nextPageToken resp))
                     (acc2 (append acc items)))
                (if next
                    (org-mode-google-tasks-sync-api--list-tasks-page
                     token list-id args next acc2 then else)
                  (funcall then acc2))))
      :else else)))

(defun org-mode-google-tasks-sync-api-insert-task (token list-id task-data then else &optional query-args)
  "POST TASK-DATA (alist) as a new task in LIST-ID using TOKEN.
Call THEN with the response.  Optional QUERY-ARGS is an alist of
extra query params (e.g. `((\"parent\" . \"<id>\"))' to create
a subtask under an existing task)."
  (let* ((base-url (concat org-mode-google-tasks-sync-api--base-url
                           "/lists/" list-id "/tasks"))
         (url (if query-args
                 (concat base-url "?"
                         (org-mode-google-tasks-sync-api--query-string query-args))
               base-url)))
    (plz 'post url
      :headers (append (org-mode-google-tasks-sync-api--auth-header token)
                       '(("Content-Type" . "application/json")))
      :body (org-mode-google-tasks-sync-api--serialize-json task-data)
      :as (lambda () (org-mode-google-tasks-sync-api--parse-json (buffer-string)))
      :then then
      :else else)))

(defun org-mode-google-tasks-sync-api-patch-task (token list-id task-id patch-data etag then else)
  "Update TASK-ID in LIST-ID using TOKEN with PATCH-DATA.
Uses PUT (tasks.update) instead of PATCH because plz < 0.10 does not
support the PATCH method.  Since we always send the full task body
\(title, notes, status, due), PUT semantics are equivalent.
Optional ETAG sent as If-Match.
THEN receives the updated task; ELSE on error (including 412 ETag mismatch)."
  (plz 'put (concat org-mode-google-tasks-sync-api--base-url
                     "/lists/" list-id "/tasks/" task-id)
    :headers (append (org-mode-google-tasks-sync-api--auth-header token)
                     '(("Content-Type" . "application/json"))
                     (when etag `(("If-Match" . ,etag))))
    :body (org-mode-google-tasks-sync-api--serialize-json patch-data)
    :as (lambda () (org-mode-google-tasks-sync-api--parse-json (buffer-string)))
    :then then
    :else else))

(defun org-mode-google-tasks-sync-api-delete-task (token list-id task-id then else)
  "DELETE TASK-ID in LIST-ID using TOKEN.
THEN is called with nil on success."
  (plz 'delete (concat org-mode-google-tasks-sync-api--base-url
                       "/lists/" list-id "/tasks/" task-id)
    :headers (org-mode-google-tasks-sync-api--auth-header token)
    :as 'string
    :then (lambda (_) (funcall then nil))
    :else else))

(defun org-mode-google-tasks-sync-api-get-task (token list-id task-id then else)
  "GET TASK-ID in LIST-ID using TOKEN.  Used after 412 ETag conflicts."
  (plz 'get (concat org-mode-google-tasks-sync-api--base-url
                    "/lists/" list-id "/tasks/" task-id)
    :headers (org-mode-google-tasks-sync-api--auth-header token)
    :as (lambda () (org-mode-google-tasks-sync-api--parse-json (buffer-string)))
    :then then
    :else else))

(defun org-mode-google-tasks-sync-api-move-task (token list-id task-id then else &optional new-parent-id)
  "Move TASK-ID in LIST-ID using TOKEN to a new parent and/or position.
NEW-PARENT-ID is the new parent task ID, or nil to move to top level.
Calls THEN with the updated task; ELSE on error."
  (let* ((base-url (concat org-mode-google-tasks-sync-api--base-url
                           "/lists/" list-id "/tasks/" task-id "/move"))
         (query-args (if new-parent-id
                         `(("parent" . ,new-parent-id))
                       nil))
         (url (if query-args
                  (concat base-url "?"
                          (org-mode-google-tasks-sync-api--query-string query-args))
                base-url)))
    (plz 'post url
      :headers (org-mode-google-tasks-sync-api--auth-header token)
      :as (lambda () (org-mode-google-tasks-sync-api--parse-json (buffer-string)))
      :then then
      :else else)))

(provide 'org-mode-google-tasks-sync-api)
;;; org-mode-google-tasks-sync-api.el ends here
