;;; bmkp-gt-test-helper.el --- Shared helpers for the test suite   -*- lexical-binding: t -*-
;;
;; Every test goes through `bmkp-gt-test-with-clean-bookmarks', which:
;;   - rebinds `bookmark-alist' to nil,
;;   - rebinds `bookmark-default-file' to a unique temp file,
;;   - rebinds `bookmark-save-flag' to nil (no auto-save),
;;   - rebinds Bookmark+'s file/state variables so they can't leak,
;;   - cleans up the temp file on exit.
;;
;; The user's real bookmarks are never touched.
;;
;; Ported from `bmkx-test-helper.el' (bookmark-x, same author).

;;; Code:

(require 'ert)
(require 'bookmark)
(require 'bookmark+)
(require 'bookmark-plus-gt-jump)

(defvar bmkp-gt-test--temp-files nil
  "Temp bookmark files created in the current test run, for cleanup.")

(defun bmkp-gt-test--make-temp-bookmark-file ()
  "Return a unique bookmark-file path with no file at it yet.
Registered for cleanup.

We use `make-temp-name' (not `make-temp-file') so the path exists but
the file does not, which lets `bookmark-set' create it from scratch
without first trying to load garbage from an empty file."
  (let ((f  (make-temp-name
             (expand-file-name "bmkp-gt-test-" temporary-file-directory))))
    (push f bmkp-gt-test--temp-files)
    f))

(defmacro bmkp-gt-test-with-clean-bookmarks (&rest body)
  "Run BODY with a fresh, isolated bookmark environment.
Inside BODY:
  - `bookmark-alist' starts at nil.
  - `bookmark-default-file' is a fresh temp file.
  - `bookmark-save-flag' is nil (no auto-save).
  - Bookmark+'s per-file state variables are pinned to the same
    temp file (or nil where appropriate) so they cannot pick up
    the user's real bookmark state."
  (declare (indent 0) (debug t))
  `(let* ((bmkp-gt-test--temp-files       nil)
          (tmp                            (bmkp-gt-test--make-temp-bookmark-file))
          (bookmark-alist                 nil)
          (bookmark-default-file          tmp)
          (bookmark-save-flag             nil)
          (bookmark-current-file          tmp)
          (bmkp-current-bookmark-file     tmp)
          (bmkp-last-bookmark-file        tmp)
          (bmkp-last-as-first-bookmark-file  nil)
          (bmkp-bmenu-state-file          nil)
          (bookmark-bookmarks-timestamp   nil)
          (bookmarks-already-loaded       nil))
     (unwind-protect
         (progn ,@body)
       (dolist (f bmkp-gt-test--temp-files)
         (when (and f (file-exists-p f)) (delete-file f))))))

(defun bmkp-gt-test--fresh-file-buffer (text)
  "Write TEXT to a fresh temp file and visit it.  Return the buffer.
The file is registered for cleanup; caller is responsible for
`kill-buffer'."
  (let ((f  (make-temp-file "bmkp-gt-test-fix-" nil ".txt")))
    (push f bmkp-gt-test--temp-files)
    (with-temp-file f (insert text))
    (find-file-noselect f)))

(defmacro bmkp-gt-test-with-fixture-buffer (var text &rest body)
  "Bind VAR to a fresh file-visiting buffer containing TEXT.
Run BODY.  Kill the buffer (and delete the file) at exit."
  (declare (indent 2) (debug t))
  `(let ((,var (bmkp-gt-test--fresh-file-buffer ,text)))
     (unwind-protect (progn ,@body)
       (when (buffer-live-p ,var) (kill-buffer ,var)))))

(defun bmkp-gt-test--make-bookmark (name buffer &optional position)
  "Set a bookmark named NAME at POSITION (default: point-min) in BUFFER.
Uses the standard `bookmark-set' (Bookmark+ redefines it, so the
record picks up whatever fields Bookmark+ adds).  Returns the stored
bookmark record."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (or position (point-min)))
      (bookmark-set name)))
  (bookmark-get-bookmark name 'NOERROR))

(provide 'bmkp-gt-test-helper)
;;; bmkp-gt-test-helper.el ends here
