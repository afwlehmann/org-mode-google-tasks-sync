;;; org-mode-google-tasks-oauth.el --- OAuth flow + auth-source -*- lexical-binding: t -*-

;; Copyright (C) 2026 Alexander Lehmann
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; OAuth 2.0 Desktop-app flow.  Reads client_id, client_secret, refresh_token
;; from auth-source.  First-time `org-mode-google-tasks-authorize' spins up a
;; loopback HTTP server on a kernel-assigned port to capture the redirect.

;;; Code:

(require 'cl-lib)
(require 'auth-source)
(require 'plz)
(require 'json)
(require 'url-util)
(require 'org-mode-google-tasks-api)

(defconst org-mode-google-tasks-oauth--host "api.google.com"
  "Auth-source `machine' field for our credentials.")

(defconst org-mode-google-tasks-oauth--login-client-id
  "org-mode-google-tasks-client-id")

(defconst org-mode-google-tasks-oauth--login-client-secret
  "org-mode-google-tasks-client-secret")

(defconst org-mode-google-tasks-oauth--login-refresh-token
  "org-mode-google-tasks-refresh-token")

(defconst org-mode-google-tasks-oauth--auth-url
  "https://accounts.google.com/o/oauth2/v2/auth")

(defconst org-mode-google-tasks-oauth--token-url
  "https://oauth2.googleapis.com/token")

(defconst org-mode-google-tasks-oauth--scope
  "https://www.googleapis.com/auth/tasks")

(defun org-mode-google-tasks-oauth--read-secret (login)
  "Read a secret from auth-source by LOGIN.  Returns nil if not found."
  (let* ((found (car (auth-source-search
                      :host org-mode-google-tasks-oauth--host
                      :user login
                      :require '(:secret)
                      :max 1))))
    (when found
      (let ((s (plist-get found :secret)))
        (if (functionp s) (funcall s) s)))))

(defun org-mode-google-tasks-oauth--save-secret (login secret)
  "Persist SECRET for LOGIN in auth-source."
  (let ((found (car (auth-source-search
                     :host org-mode-google-tasks-oauth--host
                     :user login
                     :secret secret
                     :max 1
                     :create t))))
    (when found
      (let ((save-fn (plist-get found :save-function)))
        (when (functionp save-fn)
          (funcall save-fn))))))

(defun org-mode-google-tasks-oauth-configure ()
  "Prompt for client_id and client_secret and store them in auth-source."
  (interactive)
  (let ((client-id (read-string "Google OAuth client_id: "))
        (client-secret (read-passwd "Google OAuth client_secret: ")))
    (org-mode-google-tasks-oauth--save-secret
     org-mode-google-tasks-oauth--login-client-id client-id)
    (org-mode-google-tasks-oauth--save-secret
     org-mode-google-tasks-oauth--login-client-secret client-secret)
    (message "Stored OAuth client credentials in auth-source.")))

(defvar org-mode-google-tasks-oauth--server-process nil)
(defvar org-mode-google-tasks-oauth--server-port nil)
(defvar org-mode-google-tasks-oauth--expected-state nil)
(defvar org-mode-google-tasks-oauth--callback nil)

(defun org-mode-google-tasks-oauth--start-loopback (callback)
  "Start a one-shot loopback HTTP server.  CALLBACK is called with the code."
  (when org-mode-google-tasks-oauth--server-process
    (delete-process org-mode-google-tasks-oauth--server-process))
  (setq org-mode-google-tasks-oauth--callback callback)
  (let ((proc (make-network-process
               :name "org-mode-google-tasks-oauth"
               :server t
               :host 'local
               :service t                 ; kernel-assigned port
               :family 'ipv4
               :filter #'org-mode-google-tasks-oauth--server-filter
               :coding 'utf-8)))
    (setq org-mode-google-tasks-oauth--server-process proc
          org-mode-google-tasks-oauth--server-port
          (cadr (process-contact proc)))
    proc))

(defun org-mode-google-tasks-oauth--server-filter (proc string)
  "Process filter for the loopback server.  PROC, STRING per Emacs convention."
  (let ((first-line (car (split-string string "\r\n"))))
    (when (string-match "^GET /\\?\\(.*\\) HTTP" first-line)
      (let* ((query (match-string 1 first-line))
             (params (org-mode-google-tasks-oauth--parse-query query))
             (code  (cdr (assoc "code" params)))
             (state (cdr (assoc "state" params)))
             (err   (cdr (assoc "error" params))))
        (process-send-string
         proc
         (concat "HTTP/1.1 200 OK\r\n"
                 "Content-Type: text/html; charset=utf-8\r\n"
                 "Connection: close\r\n\r\n"
                 "<html><body><h1>Authorization complete</h1>"
                 "<p>You can close this tab.</p></body></html>"))
        (delete-process proc)
        (when org-mode-google-tasks-oauth--server-process
          (delete-process org-mode-google-tasks-oauth--server-process)
          (setq org-mode-google-tasks-oauth--server-process nil))
        (cond
         (err
          (message "OAuth error: %s" err))
         ((not (equal state org-mode-google-tasks-oauth--expected-state))
          (message "OAuth state mismatch — possible CSRF; aborting"))
         (code
          (funcall org-mode-google-tasks-oauth--callback code)))))))

(defun org-mode-google-tasks-oauth--parse-query (query)
  "Parse a URL QUERY string into an alist."
  (mapcar (lambda (kv)
            (let ((eq (string-match "=" kv)))
              (if eq
                  (cons (url-unhex-string (substring kv 0 eq))
                        (url-unhex-string (substring kv (1+ eq))))
                (cons (url-unhex-string kv) ""))))
          (split-string query "&" t)))

(defun org-mode-google-tasks-oauth--gen-state ()
  "Generate a random state nonce."
  (let ((bytes (apply #'string
                      (cl-loop repeat 16 collect (random 256)))))
    (base64-encode-string bytes t)))

(defun org-mode-google-tasks-oauth-authorize ()
  "Run the OAuth authorization flow and persist the refresh token."
  (interactive)
  (let ((client-id (org-mode-google-tasks-oauth--read-secret
                    org-mode-google-tasks-oauth--login-client-id))
        (client-secret (org-mode-google-tasks-oauth--read-secret
                        org-mode-google-tasks-oauth--login-client-secret)))
    (unless (and client-id client-secret)
      (user-error "Run `M-x org-mode-google-tasks-configure' first to set credentials"))
    (setq org-mode-google-tasks-oauth--expected-state
          (org-mode-google-tasks-oauth--gen-state))
    (org-mode-google-tasks-oauth--start-loopback
     (lambda (code)
       (org-mode-google-tasks-oauth--exchange-code
        client-id client-secret code)))
    (let* ((port org-mode-google-tasks-oauth--server-port)
           (redirect (format "http://127.0.0.1:%d/" port))
           (url (concat
                 org-mode-google-tasks-oauth--auth-url
                 "?response_type=code"
                 "&client_id=" (url-hexify-string client-id)
                 "&redirect_uri=" (url-hexify-string redirect)
                 "&scope=" (url-hexify-string org-mode-google-tasks-oauth--scope)
                 "&access_type=offline"
                 "&prompt=consent"
                 "&state=" (url-hexify-string
                            org-mode-google-tasks-oauth--expected-state))))
      (browse-url url)
      (message "Browser opened.  Complete consent in your browser..."))))

(defun org-mode-google-tasks-oauth--exchange-code (client-id client-secret code)
  "Exchange CODE for tokens.  Persist refresh_token in auth-source."
  (let* ((redirect (format "http://127.0.0.1:%d/"
                           org-mode-google-tasks-oauth--server-port))
         (body (concat
                "grant_type=authorization_code"
                "&code=" (url-hexify-string code)
                "&client_id=" (url-hexify-string client-id)
                "&client_secret=" (url-hexify-string client-secret)
                "&redirect_uri=" (url-hexify-string redirect))))
    (plz 'post org-mode-google-tasks-oauth--token-url
      :headers '(("Content-Type" . "application/x-www-form-urlencoded"))
      :body body
      :as (lambda () (json-parse-string (buffer-string)
                                        :object-type 'alist
                                        :null-object nil
                                        :false-object :false))
      :then (lambda (resp)
              (let ((refresh (alist-get 'refresh_token resp)))
                (when refresh
                  (org-mode-google-tasks-oauth--save-secret
                   org-mode-google-tasks-oauth--login-refresh-token refresh)
                  (message "Authorized.  Refresh token stored in ~/.authinfo.gpg"))))
      :else (lambda (err)
              (message "Token exchange failed: %S" err)))))

(defun org-mode-google-tasks-oauth-make-token ()
  "Build a fresh API token with a valid access token.
Refreshes via the stored refresh_token if necessary."
  (let* ((client-id (org-mode-google-tasks-oauth--read-secret
                     org-mode-google-tasks-oauth--login-client-id))
         (client-secret (org-mode-google-tasks-oauth--read-secret
                         org-mode-google-tasks-oauth--login-client-secret))
         (refresh (org-mode-google-tasks-oauth--read-secret
                   org-mode-google-tasks-oauth--login-refresh-token)))
    (unless (and client-id client-secret refresh)
      (user-error "Not authorized.  Run M-x org-mode-google-tasks-authorize"))
    (org-mode-google-tasks-oauth--refresh-access-token
     client-id client-secret refresh)))

(defun org-mode-google-tasks-oauth--refresh-access-token (client-id client-secret refresh)
  "Synchronously exchange REFRESH for a new access token.  Returns a token struct."
  (let* ((body (concat
                "grant_type=refresh_token"
                "&refresh_token=" (url-hexify-string refresh)
                "&client_id=" (url-hexify-string client-id)
                "&client_secret=" (url-hexify-string client-secret)))
         (response-string
          (plz 'post org-mode-google-tasks-oauth--token-url
            :headers '(("Content-Type" . "application/x-www-form-urlencoded"))
            :body body
            :as 'string))
         (resp (json-parse-string response-string
                                  :object-type 'alist
                                  :null-object nil
                                  :false-object :false))
         (access (alist-get 'access_token resp))
         (expires-in (alist-get 'expires_in resp)))
    (make-org-mode-google-tasks-api-token
     :access-token access
     :refresh-token refresh
     :client-id client-id
     :client-secret client-secret
     :expires-at (when expires-in (+ (float-time) (- expires-in 60))))))

(provide 'org-mode-google-tasks-oauth)
;;; org-mode-google-tasks-oauth.el ends here
