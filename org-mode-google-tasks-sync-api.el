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
list or ELSE on error."
  (let* ((base-args `(("maxResults" . ,(number-to-string
                                         org-mode-google-tasks-sync-api--page-size))
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

(defun org-mode-google-tasks-sync-api-insert-task (token list-id task-data then else)
  "POST TASK-DATA (alist) as a new task in LIST-ID using TOKEN.
Call THEN with the response."
  (plz 'post (concat org-mode-google-tasks-sync-api--base-url
                     "/lists/" list-id "/tasks")
    :headers (append (org-mode-google-tasks-sync-api--auth-header token)
                     '(("Content-Type" . "application/json")))
    :body (org-mode-google-tasks-sync-api--serialize-json task-data)
    :as (lambda () (org-mode-google-tasks-sync-api--parse-json (buffer-string)))
    :then then
    :else else))

(defun org-mode-google-tasks-sync-api-patch-task (token list-id task-id patch-data etag then else)
  "PATCH TASK-ID in LIST-ID using TOKEN with PATCH-DATA.
Optional ETAG sent as If-Match.
THEN receives the updated task; ELSE on error (including 412 ETag mismatch)."
  (plz 'patch (concat org-mode-google-tasks-sync-api--base-url
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

(provide 'org-mode-google-tasks-sync-api)
;;; org-mode-google-tasks-sync-api.el ends here
