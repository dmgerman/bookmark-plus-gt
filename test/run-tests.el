;;; run-tests.el --- Load every bmkp-gt test file   -*- lexical-binding: t -*-

;;; Code:

(require 'bmkp-gt-test-helper)

(dolist (f (directory-files (file-name-directory load-file-name) t
                            "\\`bmkp-gt-test-.*\\.el\\'"))
  (unless (string-match-p "test-helper" f)
    (load f nil 'nomessage)))

(provide 'run-tests)
;;; run-tests.el ends here
