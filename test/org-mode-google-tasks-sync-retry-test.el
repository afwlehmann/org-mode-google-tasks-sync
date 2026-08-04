;;; org-mode-google-tasks-sync-retry-test.el --- Retry unit tests -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for the transient-error retry wrapper, the error classifier,
;; and the 412 ETag-conflict finalizer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'plz)
(require 'org-mode-google-tasks-sync-api)
(require 'org-mode-google-tasks-sync-engine)

(defvar org-mode-google-tasks-sync-retry-test--plz-calls nil
  "Captured (method url) list for each `plz' invocation in a test.")

(defvar org-mode-google-tasks-sync-retry-test--timers nil
  "Captured (delay thunk) list for each `run-at-time' call in a test.")

(defmacro org-mode-google-tasks-sync-retry-test--with-mocks (responses &rest body)
  "Stub plz and run-at-time; run BODY.
RESPONSES is an expression evaluating to a list of plz outcomes,
consumed left-to-right: an alist response (success) or a `plz-error'
struct (failure) for the ELSE callback.  Each `plz' call appends its
\(method url) to `org-mode-google-tasks-sync-retry-test--plz-calls'.
Each `run-at-time' appends to `org-mode-google-tasks-sync-retry-test--timers'
and immediately invokes the thunk so retries are synchronous in tests."
  (declare (indent 1))
  (let ((responses-var (make-symbol "responses")))
    `(let ((org-mode-google-tasks-sync-retry-test--plz-calls nil)
           (org-mode-google-tasks-sync-retry-test--timers nil)
           (,responses-var ,responses))
       (cl-letf (((symbol-function 'plz)
                  (lambda (method url &rest keys)
                    (push (list method url)
                          org-mode-google-tasks-sync-retry-test--plz-calls)
                    (let ((next (pop ,responses-var)))
                      (if (org-mode-google-tasks-sync-retry-test--plz-error-p next)
                          (funcall (plist-get keys :else) next)
                        (funcall (plist-get keys :then) next)))))
                 ((symbol-function 'run-at-time)
                  (lambda (delay _repeat fn &rest args)
                    (push (list delay fn args)
                          org-mode-google-tasks-sync-retry-test--timers)
                    (apply fn args))))
         ,@body))))

(defun org-mode-google-tasks-sync-retry-test--plz-error-p (x)
  "Return non-nil when X is a `plz-error' struct."
  (plz-error-p x))

(defun org-mode-google-tasks-sync-retry-test--http-error (status &optional headers)
  "Fabricate a `plz-error' for an HTTP STATUS failure with optional HEADERS."
  (make-plz-error
   :response (make-plz-response :version 1.1 :status status :headers headers :body "")))

(defun org-mode-google-tasks-sync-retry-test--curl-error (code)
  "Fabricate a `plz-error' for a curl exit CODE failure."
  (make-plz-error :curl-error (cons code "curl message")))

;;; -- classifier --

(ert-deftest org-mode-google-tasks-sync-retry-test/classify-429 ()
  (should (eq :retry
              (org-mode-google-tasks-sync-api--retry-classify
               (org-mode-google-tasks-sync-retry-test--http-error 429)))))

(ert-deftest org-mode-google-tasks-sync-retry-test/classify-500 ()
  (should (eq :retry
              (org-mode-google-tasks-sync-api--retry-classify
               (org-mode-google-tasks-sync-retry-test--http-error 500)))))

(ert-deftest org-mode-google-tasks-sync-retry-test/classify-503 ()
  (should (eq :retry
              (org-mode-google-tasks-sync-api--retry-classify
               (org-mode-google-tasks-sync-retry-test--http-error 503)))))

(ert-deftest org-mode-google-tasks-sync-retry-test/classify-412 ()
  (should (eq :412
              (org-mode-google-tasks-sync-api--retry-classify
               (org-mode-google-tasks-sync-retry-test--http-error 412)))))

(ert-deftest org-mode-google-tasks-sync-retry-test/classify-curl-timeout ()
  (should (eq :retry
              (org-mode-google-tasks-sync-api--retry-classify
               (org-mode-google-tasks-sync-retry-test--curl-error 28)))))

(ert-deftest org-mode-google-tasks-sync-retry-test/classify-curl-dns ()
  (should (eq :retry
              (org-mode-google-tasks-sync-api--retry-classify
               (org-mode-google-tasks-sync-retry-test--curl-error 6)))))

(ert-deftest org-mode-google-tasks-sync-retry-test/classify-curl-ssl-cert ()
  "SSL peer certificate failure is NOT transient — retrying burns attempts."
  (should-not (org-mode-google-tasks-sync-api--retry-classify
               (org-mode-google-tasks-sync-retry-test--curl-error 51))))

(ert-deftest org-mode-google-tasks-sync-retry-test/classify-400 ()
  (should-not (org-mode-google-tasks-sync-api--retry-classify
               (org-mode-google-tasks-sync-retry-test--http-error 400))))

(ert-deftest org-mode-google-tasks-sync-retry-test/classify-404 ()
  (should-not (org-mode-google-tasks-sync-api--retry-classify
               (org-mode-google-tasks-sync-retry-test--http-error 404))))

;;; -- delay --

(ert-deftest org-mode-google-tasks-sync-retry-test/delay-honors-retry-after ()
  (should (= 5.0
             (org-mode-google-tasks-sync-api--retry-delay
              1 (org-mode-google-tasks-sync-retry-test--http-error
                 429 '((retry-after . "5")))))))

(ert-deftest org-mode-google-tasks-sync-retry-test/delay-caps-retry-after ()
  "Retry-After hint above the cap yields nil — give up, don't wait 2 minutes."
  (should (null (org-mode-google-tasks-sync-api--retry-delay
                 1 (org-mode-google-tasks-sync-retry-test--http-error
                    429 '((retry-after . "120")))))))

(ert-deftest org-mode-google-tasks-sync-retry-test/delay-jitter-range-attempt-1 ()
  "Attempt 1 jitter is uniform in [BASE/2, 2*BASE]."
  (cl-loop repeat 100
           for d = (org-mode-google-tasks-sync-api--retry-delay
                    1 (org-mode-google-tasks-sync-retry-test--http-error 429))
           always (and (>= d 0.5) (<= d 2.0))))

(ert-deftest org-mode-google-tasks-sync-retry-test/delay-jitter-range-attempt-2 ()
  "Attempt 2 jitter is uniform in [BASE/2, 4*BASE]."
  (cl-loop repeat 100
           for d = (org-mode-google-tasks-sync-api--retry-delay
                    2 (org-mode-google-tasks-sync-retry-test--http-error 429))
           always (and (>= d 0.5) (<= d 4.0))))

;;; -- retry loop per endpoint --

(ert-deftest org-mode-google-tasks-sync-retry-test/patch-429-then-succeed ()
  "A 429 on PATCH is retried; the second successful response reaches THEN."
  (let ((ok nil))
    (org-mode-google-tasks-sync-retry-test--with-mocks
        (list (org-mode-google-tasks-sync-retry-test--http-error 429)
              '((id . "t") (updated . "2026")))
      (org-mode-google-tasks-sync-api-patch-task
       (make-org-mode-google-tasks-sync-api-token :access-token "fake")
       "L" "T" '((title . "x")) nil
       (lambda (resp) (setq ok resp))
       #'ignore))
    (should (equal '((id . "t") (updated . "2026")) ok))))

(ert-deftest org-mode-google-tasks-sync-retry-test/patch-429-exhausted ()
  "After MAX attempts of 429 the caller's ELSE receives the last error."
  (let ((failed nil))
    (org-mode-google-tasks-sync-retry-test--with-mocks
        (list (org-mode-google-tasks-sync-retry-test--http-error 429)
              (org-mode-google-tasks-sync-retry-test--http-error 429)
              (org-mode-google-tasks-sync-retry-test--http-error 429))
      (org-mode-google-tasks-sync-api-patch-task
       (make-org-mode-google-tasks-sync-api-token :access-token "fake")
       "L" "T" '((title . "x")) nil
       #'ignore
       (lambda (err) (setq failed err))))
    (should (org-mode-google-tasks-sync-retry-test--plz-error-p failed))
    (should (= 429 (plz-response-status (plz-error-response failed))))))

(ert-deftest org-mode-google-tasks-sync-retry-test/list-tasks-429-then-succeeds ()
  "List-tasks retries a 429 mid-pagination; completed items accumulate.
Real JSON has each `items' array element as one task alist; `(append
VECTOR nil)' flattens the array, so the final accum is the list of
those per-task alists."
  (let ((ok nil))
    (org-mode-google-tasks-sync-retry-test--with-mocks
        (list `((items . [((id . "a"))]) (nextPageToken . "n"))
              (org-mode-google-tasks-sync-retry-test--http-error 429)
              `((items . [((id . "b"))]) (nextPageToken . nil)))
      (org-mode-google-tasks-sync-api-list-tasks
       (make-org-mode-google-tasks-sync-api-token :access-token "fake")
       "L" nil
       (lambda (items) (setq ok items))
       #'ignore))
    (should (equal '(((id . "a")) ((id . "b"))) ok))))

(ert-deftest org-mode-google-tasks-sync-retry-test/delete-429-then-succeeds ()
  (let ((ok nil))
    (org-mode-google-tasks-sync-retry-test--with-mocks
        (list (org-mode-google-tasks-sync-retry-test--http-error 429)
              "")
      (org-mode-google-tasks-sync-api-delete-task
       (make-org-mode-google-tasks-sync-api-token :access-token "fake")
       "L" "T"
       (lambda (_) (setq ok t))
       #'ignore))
    (should ok)))

(ert-deftest org-mode-google-tasks-sync-retry-test/move-429-then-succeeds ()
  (let ((ok nil))
    (org-mode-google-tasks-sync-retry-test--with-mocks
        (list (org-mode-google-tasks-sync-retry-test--http-error 429)
              '((id . "t") (position . "0001")))
      (org-mode-google-tasks-sync-api-move-task
       (make-org-mode-google-tasks-sync-api-token :access-token "fake")
       "L" "T"
       (lambda (resp) (setq ok resp))
       #'ignore
       "PARENT" "PREV"))
    (should (equal "0001" (alist-get 'position ok)))))

(ert-deftest org-mode-google-tasks-sync-retry-test/retry-after-supersedes-jitter ()
  "When Retry-After is present, the captured timer delay equals the hint."
  (org-mode-google-tasks-sync-retry-test--with-mocks
      (list (org-mode-google-tasks-sync-retry-test--http-error
             429 '((retry-after . "7")))
            '((id . "t")))
    (org-mode-google-tasks-sync-api-patch-task
     (make-org-mode-google-tasks-sync-api-token :access-token "fake")
     "L" "T" '((title . "x")) nil
     #'ignore #'ignore)
    (should (= 7.0 (car (car org-mode-google-tasks-sync-retry-test--timers))))))

;;; -- 412 --

(ert-deftest org-mode-google-tasks-sync-retry-test/patch-412-invokes-on-412 ()
  "A 412 with an on-412 hook calls the hook instead of retrying or failing."
  (let ((handler-called nil))
    (org-mode-google-tasks-sync-retry-test--with-mocks
        (list (org-mode-google-tasks-sync-retry-test--http-error 412))
      (org-mode-google-tasks-sync-api-patch-task
       (make-org-mode-google-tasks-sync-api-token :access-token "fake")
       "L" "T" '((title . "x")) "etag"
       #'ignore
       (lambda (err) (error "ELSE shouldn't fire: %S" err))
       (lambda (err) (setq handler-called err))))
    (should (org-mode-google-tasks-sync-retry-test--plz-error-p handler-called))
    (should (= 412 (plz-response-status (plz-error-response handler-called))))))

(ert-deftest org-mode-google-tasks-sync-retry-test/patch-412-no-hook-falls-to-else ()
  "When no on-412 hook is given, ELSE receives the 412 (no retry).
The mock's second response is left unconsumed — only one plz call."
  (let ((failed nil))
    (org-mode-google-tasks-sync-retry-test--with-mocks
        (list (org-mode-google-tasks-sync-retry-test--http-error 412)
              '((id . "should-not-be-consumed")))
      (org-mode-google-tasks-sync-api-patch-task
       (make-org-mode-google-tasks-sync-api-token :access-token "fake")
       "L" "T" '((title . "x")) "etag"
       #'ignore
       (lambda (err) (setq failed err)))
      (should (= 412 (plz-response-status (plz-error-response failed))))
      (should (= 1 (length org-mode-google-tasks-sync-retry-test--plz-calls))))))

(ert-deftest org-mode-google-tasks-sync-retry-test/push-update-wires-412-finalizer ()
  "`--push-update' registers the 412 remote-wins finalizer.
On a 412 from PATCH, `--finalize-push-etag-conflict' is invoked
\(stubbed here) rather than retrying the stale PUT or calling ELSE."
  (let ((finalized nil))
    (cl-letf (((symbol-function
                'org-mode-google-tasks-sync-engine--finalize-push-etag-conflict)
               (lambda (on-failure token list-id task error &optional _on-success)
                 (setq finalized (list on-failure token list-id task error)))))
      (org-mode-google-tasks-sync-retry-test--with-mocks
          (list (org-mode-google-tasks-sync-retry-test--http-error 412))
        (org-mode-google-tasks-sync-engine--push-update
         (make-org-mode-google-tasks-sync-api-token :access-token "fake")
         "L"
         (make-org-mode-google-tasks-sync-org-task
          :id "T" :title "x" :status 'needsAction
          :updated "2026" :etag "old-etag")))
      (should finalized)
      (should (= 412
                 (plz-response-status
                  (plz-error-response (nth 4 finalized))))))))

(provide 'org-mode-google-tasks-sync-retry-test)
;;; org-mode-google-tasks-sync-retry-test.el ends here
