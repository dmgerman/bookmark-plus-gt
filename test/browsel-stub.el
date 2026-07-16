;;; browsel-stub.el --- Minimal `browsel' stub for the test suite   -*- lexical-binding: t -*-
;;
;; Provides the `browsel' feature and stub definitions of the four
;; functions `bookmark-plus-gt-browsel-tabs' calls at runtime.  The
;; stubs return safe defaults; individual tests override them via
;; `cl-letf' to simulate specific browser state.
;;
;; Loaded from `run-tests.el' before any test file requires
;; `bookmark-plus-gt-browsel-tabs', so the top-level `(require
;; 'browsel)' in that file resolves without pulling in the real
;; browsel module (which needs `websocket' and a live browser
;; extension).

;;; Code:

(unless (featurep 'browsel)

  (defvar browsel-version "0.94"
    "Stub browsel version — meets `bookmark-plus-gt-browsel-tabs' minimum.")

  (defun browsel-browser-tabs (&optional _browsers)
    "Stub: return nil (no tabs)."
    nil)

  (defun browsel-focus-tab (_tab &optional _focus-window)
    "Stub: no-op."
    nil)

  (defun browsel-close-tab (_tab)
    "Stub: no-op."
    nil)

  (defun browsel-browse-url (_url)
    "Stub: no-op."
    nil)

  (defun browsel-connected-clients ()
    "Stub: return empty list."
    nil)

  (provide 'browsel)
  (provide 'browsel-url-handler))

(provide 'browsel-stub)
;;; browsel-stub.el ends here
