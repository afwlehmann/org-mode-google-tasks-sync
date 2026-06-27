;;; org-mode-google-tasks-api.el --- Google Tasks REST API client -*- lexical-binding: t -*-

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

(defconst org-mode-google-tasks-api--base-url
  "https://tasks.googleapis.com/tasks/v1"
  "Base URL for the Tasks v1 API.")

(defconst org-mode-google-tasks-api--page-size 100
  "Tasks per page when listing.  Max 100.")

(cl-defstruct org-mode-google-tasks-api-token
  "Holds the OAuth tokens for a session."
  access-token
  refresh-token
  client-id
  client-secret
  expires-at)

(defun org-mode-google-tasks-api--auth-header (token)
  "Return an Authorization header alist for TOKEN."
  `(("Authorization" . ,(concat "Bearer "
                                (org-mode-google-tasks-api-token-access-token token)))))

(defun org-mode-google-tasks-api--parse-json (string)
  "Parse JSON STRING returning an alist."
  (json-parse-string string
                     :object-type 'alist
                     :array-type 'array
                     :null-object nil
                     :false-object :false))

(defun org-mode-google-tasks-api--serialize-json (object)
  "Serialize OBJECT to JSON.  Drops nil values."
  (json-serialize (org-mode-google-tasks-api--strip-nils object)
                  :null-object nil
                  :false-object :false))

(defun org-mode-google-tasks-api--strip-nils (alist)
  "Drop entries with nil values from ALIST."
  (cl-remove-if (lambda (pair) (null (cdr pair))) alist))

(defun org-mode-google-tasks-api--query-string (alist)
  "Encode ALIST as a URL query string."
  (mapconcat
   (lambda (pair)
     (concat (url-hexify-string (car pair)) "=" (url-hexify-string (cdr pair))))
   alist "&"))

(defun org-mode-google-tasks-api-list-tasklists (token then else)
  "List all of the user's task lists.  Call THEN with an array of list objects.
Call ELSE on error."
  (plz 'get (concat org-mode-google-tasks-api--base-url "/users/@me/lists")
    :headers (org-mode-google-tasks-api--auth-header token)
    :as (lambda () (alist-get 'items (org-mode-google-tasks-api--parse-json
                                       (buffer-string))))
    :then then
    :else else))

(defun org-mode-google-tasks-api-list-tasks (token list-id args then else)
  "List tasks in LIST-ID.  ARGS is an alist of query params.
Calls THEN with a list of task alists across all pages, ELSE on error."
  (org-mode-google-tasks-api--list-tasks-page
   token list-id args nil '() then else))

(defun org-mode-google-tasks-api--list-tasks-page (token list-id args page-token acc then else)
  "Internal helper to fetch one page of tasks and recurse."
  (let* ((base-args `(("maxResults" . ,(number-to-string
                                         org-mode-google-tasks-api--page-size))
                      ("showDeleted" . "true")
                      ("showHidden"  . "true")))
         (all-args (append base-args args
                           (when page-token `(("pageToken" . ,page-token)))))
         (url (concat org-mode-google-tasks-api--base-url
                      "/lists/" list-id "/tasks"
                      "?" (org-mode-google-tasks-api--query-string all-args))))
    (plz 'get url
      :headers (org-mode-google-tasks-api--auth-header token)
      :as (lambda () (org-mode-google-tasks-api--parse-json (buffer-string)))
      :then (lambda (resp)
              (let* ((items (append (alist-get 'items resp) nil))
                     (next  (alist-get 'nextPageToken resp))
                     (acc2 (append acc items)))
                (if next
                    (org-mode-google-tasks-api--list-tasks-page
                     token list-id args next acc2 then else)
                  (funcall then acc2))))
      :else else)))

(defun org-mode-google-tasks-api-insert-task (token list-id task-data then else)
  "POST TASK-DATA (alist) as a new task in LIST-ID.  Call THEN with the response."
  (plz 'post (concat org-mode-google-tasks-api--base-url
                     "/lists/" list-id "/tasks")
    :headers (append (org-mode-google-tasks-api--auth-header token)
                     '(("Content-Type" . "application/json")))
    :body (org-mode-google-tasks-api--serialize-json task-data)
    :as (lambda () (org-mode-google-tasks-api--parse-json (buffer-string)))
    :then then
    :else else))

(defun org-mode-google-tasks-api-patch-task (token list-id task-id patch-data etag then else)
  "PATCH TASK-ID in LIST-ID with PATCH-DATA.  Optional ETAG sent as If-Match.
THEN receives the updated task; ELSE on error (including 412 ETag mismatch)."
  (plz 'patch (concat org-mode-google-tasks-api--base-url
                      "/lists/" list-id "/tasks/" task-id)
    :headers (append (org-mode-google-tasks-api--auth-header token)
                     '(("Content-Type" . "application/json"))
                     (when etag `(("If-Match" . ,etag))))
    :body (org-mode-google-tasks-api--serialize-json patch-data)
    :as (lambda () (org-mode-google-tasks-api--parse-json (buffer-string)))
    :then then
    :else else))

(defun org-mode-google-tasks-api-delete-task (token list-id task-id then else)
  "DELETE TASK-ID in LIST-ID.  THEN is called with nil on success."
  (plz 'delete (concat org-mode-google-tasks-api--base-url
                       "/lists/" list-id "/tasks/" task-id)
    :headers (org-mode-google-tasks-api--auth-header token)
    :as 'string
    :then (lambda (_) (funcall then nil))
    :else else))

(defun org-mode-google-tasks-api-get-task (token list-id task-id then else)
  "GET TASK-ID in LIST-ID.  Used after 412 ETag conflicts."
  (plz 'get (concat org-mode-google-tasks-api--base-url
                    "/lists/" list-id "/tasks/" task-id)
    :headers (org-mode-google-tasks-api--auth-header token)
    :as (lambda () (org-mode-google-tasks-api--parse-json (buffer-string)))
    :then then
    :else else))

(provide 'org-mode-google-tasks-api)
;;; org-mode-google-tasks-api.el ends here
