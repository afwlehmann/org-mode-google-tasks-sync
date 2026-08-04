;;; org-mode-google-tasks-sync-api.el --- Google Tasks REST API client -*- lexical-binding: t -*-

;; Copyright (C) 2026 Alexander Lehmann
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Thin wrappers around the Google Tasks v1 REST API using `plz' for HTTP.
;; Every public function takes a token struct and a pair of THEN/ELSE
;; callbacks.  Pagination is here; failures surface via ELSE callbacks.
;; Transient HTTP errors (429, 500, 502, 503, 504) and transient curl
;; failures are retried with exponential backoff and full jitter via
;; `org-mode-google-tasks-sync-api--with-retry'; HTTP 412 from a push is
;; handed to the engine's refetch-and-finalize path.

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

;;; Retry policy

(defconst org-mode-google-tasks-sync-api--retry-statuses '(429 500 502 503 504)
  "HTTP statuses that trigger a retry with jittered backoff.")

(defconst org-mode-google-tasks-sync-api--retry-max-attempts 3
  "Total attempts (initial + retries) before erroring out to the caller's ELSE.")

(defconst org-mode-google-tasks-sync-api--retry-base-delay 1.0
  "Base delay in seconds for jittered backoff.
Attempt N draws a uniform random delay in [0.5, 2 × BASE × (2^(N-1))] — full
jitter so multiple Emacs instances ticking together don't align into a retry
storm.  A Retry-After response header supersedes this when present.")

(defconst org-mode-google-tasks-sync-api--retry-after-cap 60.0
  "Ceiling in seconds for an HTTP Retry-After hint.
Larger values are too long for the timer-driven retry path; the request
is handed to the caller's ELSE instead of being retried.")

(defconst org-mode-google-tasks-sync-api--retryable-curl-codes
  '(6 7 28 35 52 56)
  "Curl exit codes considered transient and safe to retry.
6 = couldn't resolve host, 7 = connection failed, 28 = timeout, 35 = SSL
connect error, 52 = empty reply, 56 = recv failure.  Other curl failures
\(e.g. 51 peer certificate, 60 SSL CA) are configuration bugs — retrying
would just burn attempts.")

(defun org-mode-google-tasks-sync-api--retry-classify (err)
  "Classify plz error ERR for retry purposes.
Return `:retry' for transient HTTP/curl errors, `:412' for an ETag
mismatch (HTTP 412), or nil for anything else.  ERR is the `plz-error'
struct handed to a plz `:else' callback."
  (cond
   ((plz-error-response err)
    (let ((status (plz-response-status (plz-error-response err))))
      (cond ((eq status 412) :412)
            ((memq status org-mode-google-tasks-sync-api--retry-statuses)
             :retry))))
   ((plz-error-curl-error err)
    (let ((code (car-safe (plz-error-curl-error err))))
      (when (memq code org-mode-google-tasks-sync-api--retryable-curl-codes)
        :retry)))))

(defun org-mode-google-tasks-sync-api--retry-delay (attempt err)
  "Compute the delay in seconds before retry ATTEMPT after error ERR.
ATTEMPT is 1-based (the attempt that just failed).  A Retry-After header
on ERR is honored when it parses as a positive integer number of seconds
and is within `org-mode-google-tasks-sync-api--retry-after-cap'; HTTP-date
forms fall back to jitter (Google Tasks doesn't use them).  Otherwise draw
a jittered exponential backoff.  Returns nil when a Retry-After hint
exceeds the cap — the caller should give up."
  (let ((retry-after
         (and (plz-error-response err)
              (alist-get 'retry-after
                         (plz-response-headers
                          (plz-error-response err))))))
    (if retry-after
        (let ((secs (string-to-number retry-after)))
          (cond ((> secs org-mode-google-tasks-sync-api--retry-after-cap)
                 nil)
                ((> secs 0) (float secs))
                (t (org-mode-google-tasks-sync-api--jitter attempt))))
      (org-mode-google-tasks-sync-api--jitter attempt))))

(defun org-mode-google-tasks-sync-api--jitter (attempt)
  "Draw a full-jitter exponential backoff delay in seconds for ATTEMPT.
Uniform random in [BASE/2, BASE × 2^ATTEMPT] where BASE is
`org-mode-google-tasks-sync-api--retry-base-delay'."
  (let* ((base org-mode-google-tasks-sync-api--retry-base-delay)
         (low (/ base 2.0))
         (high (* base (expt 2 attempt))))
    (+ low (random (float (- high low))))))

(defun org-mode-google-tasks-sync-api--with-retry
    (request-fn then else &optional on-412 attempt)
  "Run REQUEST-FN with THEN/ELSE callbacks, retrying transient errors.
REQUEST-FN is a function of (THEN ELSE) that initiates one attempt —
typically a closure wrapping a `plz' call.  THEN and ELSE are the
caller's callbacks (ELSE receives a `plz-error' struct on final
failure).  On a retryable error, schedule another attempt with
`run-at-time' (non-blocking) up to
`org-mode-google-tasks-sync-api--retry-max-attempts' total.  On 412
and when ON-412 is non-nil, call it with the error instead of ELSE:
etag conflicts need a fetch-and-finalize, not a blind re-push.  The
handler runs inside `condition-case'; if IT errors, ELSE receives the
handler's error.  ATTEMPT is the 1-based counter; normally omitted."
  (let ((attempt (or attempt 1)))
    (funcall
     request-fn
     (lambda (resp) (funcall then resp))
     (lambda (err)
       (let ((kind (org-mode-google-tasks-sync-api--retry-classify err)))
         (cond
          ((and (eq kind :412) on-412)
           (condition-case on-412-err
               (funcall on-412 err)
             (error (funcall else on-412-err))))
          ((eq kind :retry)
           (if (>= attempt org-mode-google-tasks-sync-api--retry-max-attempts)
               (progn
                 (when (fboundp 'org-mode-google-tasks-sync-engine--log)
                   (org-mode-google-tasks-sync-engine--log
                    "Request failed after %d attempts: %S" attempt err))
                 (funcall else err))
             (let ((delay (org-mode-google-tasks-sync-api--retry-delay
                           attempt err)))
               (if (null delay)
                   (funcall else err)
                 (when (fboundp 'org-mode-google-tasks-sync-engine--log)
                   (org-mode-google-tasks-sync-engine--log
                    "Transient error (attempt %d/%d), retrying in %.1fs: %S"
                    attempt org-mode-google-tasks-sync-api--retry-max-attempts
                    delay err))
                 (run-at-time
                  delay nil
                  (lambda ()
                    (org-mode-google-tasks-sync-api--with-retry
                     request-fn then else on-412 (1+ attempt))))))))
          (t
           (funcall else err))))))))

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
  (org-mode-google-tasks-sync-api--with-retry
   (lambda (then2 else2)
     (plz 'get (concat org-mode-google-tasks-sync-api--base-url
                       "/users/@me/lists")
       :headers (org-mode-google-tasks-sync-api--auth-header token)
       :as (lambda () (alist-get 'items
                                 (org-mode-google-tasks-sync-api--parse-json
                                  (buffer-string))))
       :then then2
       :else else2))
   then else))

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
    (org-mode-google-tasks-sync-api--with-retry
     (lambda (then2 else2)
       (plz 'get url
         :headers (org-mode-google-tasks-sync-api--auth-header token)
         :as (lambda () (org-mode-google-tasks-sync-api--parse-json
                          (buffer-string)))
         :then (lambda (resp)
                 (let* ((items (append (alist-get 'items resp) nil))
                        (next  (alist-get 'nextPageToken resp))
                        (acc2 (append acc items)))
                   (if next
                       (org-mode-google-tasks-sync-api--list-tasks-page
                        token list-id args next acc2 then else)
                     (funcall then2 acc2))))
         :else else2))
     then else)))

(defun org-mode-google-tasks-sync-api-get-task (token list-id task-id then else)
  "GET TASK-ID in LIST-ID using TOKEN.
Called by the 412 ETag-conflict finalizer to fetch the live task
before applying remote-wins semantics.  THEN receives the task alist;
ELSE on error.  Transient errors are retried."
  (org-mode-google-tasks-sync-api--with-retry
   (lambda (then2 else2)
     (plz 'get (concat org-mode-google-tasks-sync-api--base-url
                        "/lists/" list-id "/tasks/" task-id)
       :headers (org-mode-google-tasks-sync-api--auth-header token)
       :as (lambda () (org-mode-google-tasks-sync-api--parse-json
                        (buffer-string)))
       :then then2
       :else else2))
   then else))

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
     (org-mode-google-tasks-sync-api--with-retry
      (lambda (then2 else2)
        (plz 'post url
          :headers (append (org-mode-google-tasks-sync-api--auth-header token)
                           '(("Content-Type" . "application/json")))
          :body (org-mode-google-tasks-sync-api--serialize-json task-data)
          :as (lambda () (org-mode-google-tasks-sync-api--parse-json
                           (buffer-string)))
          :then then2
          :else else2))
      then else)))

(defun org-mode-google-tasks-sync-api-patch-task (token list-id task-id patch-data etag then else &optional on-etag-conflict)
  "Update TASK-ID in LIST-ID using TOKEN with PATCH-DATA.
Uses PUT (tasks.update) instead of PATCH because plz < 0.10 does not
support the PATCH method.  Since we always send the full task body
\(title, notes, status, due), PUT semantics are equivalent.
Optional ETAG sent as If-Match.
THEN receives the updated task; ELSE on error.  On HTTP 412 (etag
mismatch) and when ON-ETAG-CONFLICT is non-nil, call it with the
error instead of ELSE — the handler typically refetches the live
task and finalizes local state rather than retrying the stale push.
412s bypass the usual retry loop entirely: retrying a stale If-Match
PATCH would just 412 again."
  (org-mode-google-tasks-sync-api--with-retry
   (lambda (then2 else2)
     (plz 'put (concat org-mode-google-tasks-sync-api--base-url
                        "/lists/" list-id "/tasks/" task-id)
       :headers (append (org-mode-google-tasks-sync-api--auth-header token)
                        '(("Content-Type" . "application/json"))
                        (when etag `(("If-Match" . ,etag))))
       :body (org-mode-google-tasks-sync-api--serialize-json patch-data)
       :as (lambda () (org-mode-google-tasks-sync-api--parse-json
                        (buffer-string)))
       :then then2
       :else else2))
   then else on-etag-conflict))

(defun org-mode-google-tasks-sync-api-delete-task (token list-id task-id then else)
  "DELETE TASK-ID in LIST-ID using TOKEN.
THEN is called with nil on success."
  (org-mode-google-tasks-sync-api--with-retry
   (lambda (then2 else2)
     (plz 'delete (concat org-mode-google-tasks-sync-api--base-url
                          "/lists/" list-id "/tasks/" task-id)
       :headers (org-mode-google-tasks-sync-api--auth-header token)
       :as 'string
       :then (lambda (_) (funcall then2 nil))
       :else else2))
   then else))

(defun org-mode-google-tasks-sync-api-move-task
    (token list-id task-id then else &optional new-parent-id previous-id)
  "Move TASK-ID in LIST-ID using TOKEN to a new parent and/or position.
NEW-PARENT-ID is the new parent task ID, or nil to move to top level.
PREVIOUS-ID is the ID of the task to insert after, or nil to move
to the first position within the new parent.  When both are nil the
task stays in place parent-wise and moves to the first position.
Calls THEN with the updated task; ELSE on error."
  (let* ((base-url (concat org-mode-google-tasks-sync-api--base-url
                           "/lists/" list-id "/tasks/" task-id "/move"))
         (query-args
          (delq nil
                (list (when new-parent-id `("parent" . ,new-parent-id))
                      (when previous-id `("previous" . ,previous-id)))))
         (url (if query-args
                  (concat base-url "?"
                          (org-mode-google-tasks-sync-api--query-string query-args))
                base-url)))
    (org-mode-google-tasks-sync-api--with-retry
     (lambda (then2 else2)
       (plz 'post url
         :headers (org-mode-google-tasks-sync-api--auth-header token)
         :as (lambda () (org-mode-google-tasks-sync-api--parse-json
                          (buffer-string)))
         :then then2
         :else else2))
     then else)))

(provide 'org-mode-google-tasks-sync-api)
;;; org-mode-google-tasks-sync-api.el ends here
