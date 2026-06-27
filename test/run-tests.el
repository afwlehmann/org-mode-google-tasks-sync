;;; run-tests.el --- Entry point for ert batch -*- lexical-binding: t -*-

;;; Commentary:

;; Invoked by `emacs --batch -l test/run-tests.el -f ert-run-tests-batch-and-exit'.

;;; Code:

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "test-helper.el" here)))

(require 'ert)

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (dolist (f (directory-files here t "-test\\.el\\'"))
    (load f)))

(provide 'run-tests)
;;; run-tests.el ends here
