;;; bmkp-gt-test-rename.el --- Tests for bmkp-gt-on-file-rename   -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Exercises the always-on `:after' advice on `rename-file' installed
;; by `bookmark-plus-gt.el': file rename, directory rename cascade,
;; non-file bookmark immunity, per-record error isolation, unrelated
;; bookmark isolation, modification-count bump, and the bulletproof
;; contract (never signal back to the `rename-file' caller).

;;; Code:

(require 'bmkp-gt-test-helper)
(require 'bookmark-plus-gt)
(require 'cl-lib)

(defvar bmkp-gt-test-rename--tmpdirs nil
  "Per-test list of temp directories for recursive cleanup.")

(defun bmkp-gt-test-rename--tmpdir ()
  "Return a fresh temp directory, registered for recursive cleanup."
  (let ((d (make-temp-file "bmkp-gt-test-rename-" 'DIR)))
    (push d bmkp-gt-test-rename--tmpdirs)
    d))

(defmacro bmkp-gt-test-rename--with-env (&rest body)
  "Run BODY inside `bmkp-gt-test-with-clean-bookmarks' with tmpdir cleanup."
  (declare (indent 0) (debug t))
  `(bmkp-gt-test-with-clean-bookmarks
     (let ((bmkp-gt-test-rename--tmpdirs nil))
       (unwind-protect
           (progn ,@body)
         (dolist (d bmkp-gt-test-rename--tmpdirs)
           (when (and d (file-directory-p d))
             (delete-directory d 'RECURSIVE)))))))

(defun bmkp-gt-test-rename--set-file-bookmark (name path)
  "Create a bookmark NAME whose filename is PATH.
Bypasses `bookmark-set' so no buffer needs to visit PATH."
  (let ((rec `((filename . ,path)
               (position . 1))))
    (push (cons name rec) bookmark-alist)
    rec))


(ert-deftest bmkp-gt-test-rename/advice-installed ()
  "`bmkp-gt-on-file-rename' is installed as `:after' advice on `rename-file'."
  (should (advice-member-p #'bmkp-gt-on-file-rename 'rename-file)))

(ert-deftest bmkp-gt-test-rename/file-exact-match ()
  "Renaming a file updates a bookmark whose filename is exactly that file."
  (bmkp-gt-test-rename--with-env
    (let* ((dir  (bmkp-gt-test-rename--tmpdir))
           (old  (expand-file-name "old.txt" dir))
           (new  (expand-file-name "new.txt" dir)))
      (with-temp-file old (insert "hi"))
      (bmkp-gt-test-rename--set-file-bookmark "b" old)
      (rename-file old new)
      (should (equal (expand-file-name new)
                     (expand-file-name (bookmark-get-filename "b")))))))

(ert-deftest bmkp-gt-test-rename/directory-cascades-to-children ()
  "Renaming a directory rewrites every bookmark whose file lives under it."
  (bmkp-gt-test-rename--with-env
    (let* ((parent   (bmkp-gt-test-rename--tmpdir))
           (old-dir  (expand-file-name "old" parent))
           (new-dir  (expand-file-name "new" parent))
           (child-a  (expand-file-name "a.txt" old-dir))
           (child-b  (expand-file-name "sub/b.txt" old-dir)))
      (make-directory (file-name-directory child-b) 'PARENTS)
      (with-temp-file child-a (insert "a"))
      (with-temp-file child-b (insert "b"))
      (bmkp-gt-test-rename--set-file-bookmark "ba" child-a)
      (bmkp-gt-test-rename--set-file-bookmark "bb" child-b)
      (rename-file old-dir new-dir)
      (should (equal (expand-file-name (expand-file-name "a.txt" new-dir))
                     (expand-file-name (bookmark-get-filename "ba"))))
      (should (equal (expand-file-name
                      (expand-file-name "sub/b.txt" new-dir))
                     (expand-file-name (bookmark-get-filename "bb")))))))

(ert-deftest bmkp-gt-test-rename/directory-itself-no-trailing-slash ()
  "A bookmark whose filename IS the renamed directory (no trailing slash)
is rewritten to the new directory path."
  (bmkp-gt-test-rename--with-env
    (let* ((parent   (bmkp-gt-test-rename--tmpdir))
           (old-dir  (expand-file-name "old" parent))
           (new-dir  (expand-file-name "new" parent)))
      (make-directory old-dir)
      (bmkp-gt-test-rename--set-file-bookmark "dired" old-dir)
      (rename-file old-dir new-dir)
      (should (equal (expand-file-name new-dir)
                     (expand-file-name (bookmark-get-filename "dired")))))))

(ert-deftest bmkp-gt-test-rename/directory-itself-trailing-slash ()
  "A bookmark whose filename is the renamed directory WITH a trailing slash
is rewritten (via the prefix branch, since prefix-of-itself matches)."
  (bmkp-gt-test-rename--with-env
    (let* ((parent   (bmkp-gt-test-rename--tmpdir))
           (old-dir  (expand-file-name "old" parent))
           (new-dir  (expand-file-name "new" parent)))
      (make-directory old-dir)
      (bmkp-gt-test-rename--set-file-bookmark
       "dired" (file-name-as-directory old-dir))
      (rename-file old-dir new-dir)
      (should (equal (file-name-as-directory (expand-file-name new-dir))
                     (expand-file-name (bookmark-get-filename "dired")))))))

(ert-deftest bmkp-gt-test-rename/non-file-bookmark-untouched ()
  "URL / non-file bookmarks (sentinel filename) are not rewritten."
  (bmkp-gt-test-rename--with-env
    (let* ((dir  (bmkp-gt-test-rename--tmpdir))
           (old  (expand-file-name "old.txt" dir))
           (new  (expand-file-name "new.txt" dir)))
      (with-temp-file old (insert "hi"))
      (push (cons "url"
                  `((filename . ,bmkp-non-file-filename)
                    (location . "https://example.com")
                    (handler  . bmkp-jump-url-browse)))
            bookmark-alist)
      (rename-file old new)
      (should (equal bmkp-non-file-filename
                     (bookmark-get-filename "url"))))))

(ert-deftest bmkp-gt-test-rename/unrelated-file-untouched ()
  "Renaming an unrelated file leaves other bookmarks alone."
  (bmkp-gt-test-rename--with-env
    (let* ((dir  (bmkp-gt-test-rename--tmpdir))
           (kept (expand-file-name "kept.txt" dir))
           (old  (expand-file-name "old.txt" dir))
           (new  (expand-file-name "new.txt" dir)))
      (with-temp-file kept (insert "k"))
      (with-temp-file old  (insert "o"))
      (bmkp-gt-test-rename--set-file-bookmark "kept" kept)
      (bmkp-gt-test-rename--set-file-bookmark "moved" old)
      (rename-file old new)
      (should (equal (expand-file-name kept)
                     (expand-file-name (bookmark-get-filename "kept"))))
      (should (equal (expand-file-name new)
                     (expand-file-name (bookmark-get-filename "moved")))))))

(ert-deftest bmkp-gt-test-rename/one-bad-record-does-not-abort-sweep ()
  "A malformed record is skipped; siblings still get updated."
  (bmkp-gt-test-rename--with-env
    (let* ((dir  (bmkp-gt-test-rename--tmpdir))
           (old  (expand-file-name "old.txt" dir))
           (new  (expand-file-name "new.txt" dir)))
      (with-temp-file old (insert "hi"))
      (push (cons "bad"
                  `((filename . 42)
                    (position . 1)))
            bookmark-alist)
      (bmkp-gt-test-rename--set-file-bookmark "good" old)
      (rename-file old new)
      (should (equal (expand-file-name new)
                     (expand-file-name (bookmark-get-filename "good")))))))

(ert-deftest bmkp-gt-test-rename/never-signals-to-caller ()
  "Even if the advice body errors, `rename-file' completes successfully.
Forces an error by monkey-patching `bookmark-get-filename' to always
raise, then confirms the rename itself still succeeded."
  (bmkp-gt-test-rename--with-env
    (let* ((dir  (bmkp-gt-test-rename--tmpdir))
           (old  (expand-file-name "old.txt" dir))
           (new  (expand-file-name "new.txt" dir)))
      (with-temp-file old (insert "hi"))
      (bmkp-gt-test-rename--set-file-bookmark "b" old)
      (cl-letf (((symbol-function 'bookmark-get-filename)
                 (lambda (&rest _) (error "boom"))))
        (should (progn (rename-file old new) t))
        (should (file-exists-p new))
        (should-not (file-exists-p old))))))

(ert-deftest bmkp-gt-test-rename/bumps-modification-count-on-change ()
  "A successful rewrite bumps `bookmark-alist-modification-count'."
  (bmkp-gt-test-rename--with-env
    (let* ((dir  (bmkp-gt-test-rename--tmpdir))
           (old  (expand-file-name "old.txt" dir))
           (new  (expand-file-name "new.txt" dir)))
      (with-temp-file old (insert "hi"))
      (bmkp-gt-test-rename--set-file-bookmark "b" old)
      (let ((before bookmark-alist-modification-count))
        (rename-file old new)
        (should (> bookmark-alist-modification-count before))))))

(ert-deftest bmkp-gt-test-rename/no-count-bump-when-no-match ()
  "Renaming a file with no matching bookmark does not bump the count."
  (bmkp-gt-test-rename--with-env
    (let* ((dir  (bmkp-gt-test-rename--tmpdir))
           (kept (expand-file-name "kept.txt" dir))
           (old  (expand-file-name "old.txt" dir))
           (new  (expand-file-name "new.txt" dir)))
      (with-temp-file kept (insert "k"))
      (with-temp-file old  (insert "o"))
      (bmkp-gt-test-rename--set-file-bookmark "kept" kept)
      (let ((before bookmark-alist-modification-count))
        (rename-file old new)
        (should (= bookmark-alist-modification-count before))))))

(provide 'bmkp-gt-test-rename)
;;; bmkp-gt-test-rename.el ends here
