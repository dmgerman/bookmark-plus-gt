;;; bmkp-gt-test-jump.el --- Tests for bmkp-gt-list-preview-mode and consult reader   -*- lexical-binding: t -*-
;;
;; Ported from `bmkx-test-preview.el' (bookmark-x, same author).

;;; Code:

(require 'bmkp-gt-test-helper)
(require 'cl-lib)


(ert-deftest bmkp-gt-test-jump/mode-defined ()
  "`bmkp-gt-list-preview-mode' is defined."
  (should (fboundp 'bmkp-gt-list-preview-mode)))

(ert-deftest bmkp-gt-test-jump/mode-toggles ()
  "Toggling the mode sets and unsets the variable."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "p1" buf))
    (unwind-protect
        (progn
          (bookmark-bmenu-list)
          (with-current-buffer bookmark-bmenu-buffer
            (should-not bmkp-gt-list-preview-mode)
            (bmkp-gt-list-preview-mode 1)
            (should bmkp-gt-list-preview-mode)
            (bmkp-gt-list-preview-mode -1)
            (should-not bmkp-gt-list-preview-mode)))
      (when (get-buffer bookmark-bmenu-buffer)
        (kill-buffer bookmark-bmenu-buffer)))))

(ert-deftest bmkp-gt-test-jump/lighter-present-when-active ()
  "The mode-line lighter `\" Pv\"' appears when the mode is on."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "p2" buf))
    (unwind-protect
        (progn
          (bookmark-bmenu-list)
          (with-current-buffer bookmark-bmenu-buffer
            (bmkp-gt-list-preview-mode 1)
            (let ((lighter (assq 'bmkp-gt-list-preview-mode minor-mode-alist)))
              (should lighter)
              (should (string-match-p "Pv" (or (cadr lighter) ""))))))
      (when (get-buffer bookmark-bmenu-buffer)
        (kill-buffer bookmark-bmenu-buffer)))))

(ert-deftest bmkp-gt-test-jump/consult-jump-reader-defined ()
  "`bmkp-gt-read-bookmark-for-jump' is defined."
  (should (fboundp 'bmkp-gt-read-bookmark-for-jump)))

(ert-deftest bmkp-gt-test-jump/preview-warn-once-per-name ()
  "`bmkp-gt-preview--warn' emits a message the first time for a name
and stays silent for the same name until reset.  A different name
warns again."
  (let ((msgs                        nil)
        (bmkp-gt-preview--last-warned nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
      (bmkp-gt-preview--warn "b1" '(error "bang"))
      (bmkp-gt-preview--warn "b1" '(error "bang"))     ; suppressed
      (bmkp-gt-preview--warn "b2" '(error "boom"))     ; new name → warns
      (bmkp-gt-preview--clear-warning)
      (bmkp-gt-preview--warn "b2" '(error "boom")))    ; re-warns after clear
    (should (= 3 (length msgs)))
    (should (cl-every (lambda (m) (string-prefix-p "bmkp-gt: preview failed for " m))
                      msgs))))

(ert-deftest bmkp-gt-test-jump/consult-flag-default ()
  "`bmkp-gt-jump-use-consult-flag' is t by default."
  (should (boundp 'bmkp-gt-jump-use-consult-flag))
  (should bmkp-gt-jump-use-consult-flag))


;;; bmkp-gt-bookmark-location-function (annotation substitution for non-file bookmarks)

(defun bmkp-gt-test--make-url-bookmark (name url)
  "Register a URL bookmark NAME pointing at URL.  No buffer required."
  (let ((bmk  (list (cons 'filename bmkp-non-file-filename)
                    (cons 'location url)
                    (cons 'handler  #'bmkp-jump-url-browse)
                    (cons 'position 0))))
    (bookmark-store name bmk nil)
    (bookmark-get-bookmark name 'NOERROR)))

(ert-deftest bmkp-gt-test-jump/location-default-returns-url-for-url-bookmark ()
  "`bmkp-gt-bookmark-location-default' returns the URL of a URL bookmark."
  (bmkp-gt-test-with-clean-bookmarks
    (let ((rec  (bmkp-gt-test--make-url-bookmark "url-bmk" "https://example.com/")))
      (should (equal "https://example.com/"
                     (bmkp-gt-bookmark-location-default rec))))))

(ert-deftest bmkp-gt-test-jump/location-default-nil-for-file-bookmark ()
  "`bmkp-gt-bookmark-location-default' returns nil for a plain file bookmark."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "file-bmk" buf))
    (should-not (bmkp-gt-bookmark-location-default (assoc "file-bmk" bookmark-alist)))))

(ert-deftest bmkp-gt-test-jump/annotation-substitutes-url-for-no-file-marker ()
  "`bmkp-gt-bookmark-annotation' replaces the no-file marker with the URL.
Stubs marginalia so the test does not require the package."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test--make-url-bookmark "url-annot" "https://example.org/path")
    (cl-letf (((symbol-function 'marginalia-annotate-bookmark)
               (lambda (_n) (concat "TYPE" bmkp-non-file-filename "EXTRA"))))
      (let ((annot  (bmkp-gt-bookmark-annotation "url-annot")))
        (should (stringp annot))
        (should (string-match-p "https://example.org/path" annot))
        (should-not (string-match-p (regexp-quote bmkp-non-file-filename) annot))))))

(ert-deftest bmkp-gt-test-jump/annotation-honors-user-override ()
  "A user-supplied `bmkp-gt-bookmark-location-function' takes effect."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test--make-url-bookmark "url-override" "https://example.net/")
    (cl-letf (((symbol-function 'marginalia-annotate-bookmark)
               (lambda (_n) (concat "T" bmkp-non-file-filename "Z")))
              (bmkp-gt-bookmark-location-function
               (lambda (_bmk) "<<custom>>")))
      (let ((annot  (bmkp-gt-bookmark-annotation "url-override")))
        (should (string-match-p "<<custom>>" annot))
        (should-not (string-match-p "https://example.net/" annot))))))

(ert-deftest bmkp-gt-test-jump/annotation-rewrites-marginalia-type-column ()
  "Marginalia's type column is replaced by the `bmkp-gt-jump-narrow' label.
Width is preserved so column alignment does not shift."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "rewrite-type" buf))
    (cl-letf (((symbol-function 'marginalia-annotate-bookmark)
               (lambda (_n)
                 (concat "   "
                         (propertize "Bmkp-File " 'face 'marginalia-type)
                         "  /tmp/foo"))))
      (let ((annot  (bmkp-gt-bookmark-annotation "rewrite-type")))
        (should (stringp annot))
        ;; New label is present with the marginalia-type face.
        (should (string-match "File" annot))
        (let ((idx  (string-match "File" annot)))
          (let ((f  (get-text-property idx 'face annot)))
            (should (or (eq f 'marginalia-type)
                        (and (listp f) (memq 'marginalia-type f))))))
        ;; Old "Bmkp-File" is gone.
        (should-not (string-match-p "Bmkp-File" annot))
        ;; Column width unchanged: "Bmkp-File " is 10 chars; the
        ;; replacement is "File" plus 6 spaces so the second column
        ;; still starts where it did.
        (should (string-match-p "File      " annot))))))

(ert-deftest bmkp-gt-test-jump/annotation-leaves-type-column-alone-when-unknown ()
  "Unknown handler leaves marginalia's type column untouched."
  (bmkp-gt-test-with-clean-bookmarks
    (let ((bmk  (list (cons 'filename bmkp-non-file-filename)
                      (cons 'handler  'no-such-handler)
                      (cons 'position 0))))
      (bookmark-store "unknown-type" bmk nil))
    (cl-letf (((symbol-function 'marginalia-annotate-bookmark)
               (lambda (_n)
                 (concat "   "
                         (propertize "Nosuch    " 'face 'marginalia-type)
                         "  /tmp/foo"))))
      (let ((annot  (bmkp-gt-bookmark-annotation "unknown-type")))
        (should (string-match-p "Nosuch" annot))))))

(ert-deftest bmkp-gt-test-jump/annotation-leaves-file-bookmark-alone ()
  "Annotation for a file bookmark does not invoke the substitution."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "file-annot" buf))
    (cl-letf (((symbol-function 'marginalia-annotate-bookmark)
               (lambda (_n) "TYPE  /tmp/some/file  ")))
      (let ((annot  (bmkp-gt-bookmark-annotation "file-annot")))
        (should (stringp annot))
        (should (string-match-p "/tmp/some/file" annot))))))

(ert-deftest bmkp-gt-test-jump/annotation-distinguishes-duplicate-names ()
  "Each duplicate-name candidate is annotated from its own full record."
  (bmkp-gt-test-with-clean-bookmarks
    (let* ((url-name  (copy-sequence "duplicate"))
           (file-name (copy-sequence "duplicate"))
           (url-bmk   (list url-name
                            (cons 'filename bmkp-non-file-filename)
                            (cons 'location "https://example.org/duplicate")
                            (cons 'handler #'bmkp-jump-url-browse)))
           (file-bmk  (list file-name
                            (cons 'filename "/tmp/duplicate.org")))
           (narrow    `((,#'bmkp-jump-url-browse . ?u)
                        (,#'bookmark-default-handler . ?f))))
      (put-text-property 0 (length url-name) 'bmkp-full-record url-bmk url-name)
      (put-text-property 0 (length file-name) 'bmkp-full-record file-bmk file-name)
      (setq bookmark-alist (list url-bmk file-bmk))
      ;; Model Marginalia's name-only `assoc' lookup: our annotator must make
      ;; the identity-selected record first before delegating to it.
      (cl-letf (((symbol-function 'marginalia-annotate-bookmark)
                 (lambda (cand)
                   (let ((bmk (assoc cand bookmark-alist)))
                     (or (bookmark-prop-get bmk 'location)
                         (bookmark-prop-get bmk 'filename))))))
        (let ((url-annot
               (bmkp-gt-bookmark-annotation
                (bmkp-gt-jump-candidate-default url-bmk narrow)))
              (file-annot
               (bmkp-gt-bookmark-annotation
                (bmkp-gt-jump-candidate-default file-bmk narrow))))
          (should (string-match-p "https://example.org/duplicate" url-annot))
          (should (string-match-p "/tmp/duplicate.org" file-annot)))))))


;;; bmkp-gt-jump-candidate-format-function (consult candidate row)

(ert-deftest bmkp-gt-test-jump/candidate-default-name-and-properties ()
  "Default formatter returns the name with required text properties."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "cand-bmk" buf))
    (let* ((bm     (assoc "cand-bmk" bookmark-alist))
           (narrow `((,#'bookmark-default-handler . ?f)))
           (cand   (bmkp-gt-jump-candidate-default bm narrow)))
      (should (stringp cand))
      (should (string-prefix-p "cand-bmk" cand))
      (should (equal "cand-bmk" (get-text-property 0 'bmkp-gt-bookmark-name cand)))
      (should (eq ?f          (get-text-property 0 'consult--type         cand))))))

(ert-deftest bmkp-gt-test-jump/candidate-default-appends-hidden-type-name ()
  "Type-group name is appended with `@' prefix under `display \"\"'."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "cand-type" buf))
    (let* ((bm     (assoc "cand-type" bookmark-alist))
           (narrow `((,#'bookmark-default-handler . ?f)))
           (cand   (bmkp-gt-jump-candidate-default bm narrow)))
      (should (string-match-p "@File" cand))
      (should (equal "" (get-text-property (length "cand-type") 'display cand))))))

(ert-deftest bmkp-gt-test-jump/candidate-type-name-lookup ()
  "`bmkp-gt-jump-candidate-type-name' resolves handlers via `bmkp-gt-jump-narrow'."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "cand-type-lookup" buf))
    (let ((bm  (assoc "cand-type-lookup" bookmark-alist)))
      (should (equal "File" (bmkp-gt-jump-candidate-type-name bm))))))

(ert-deftest bmkp-gt-test-jump/candidate-default-appends-hidden-tags ()
  "Tag tokens are appended with `display \"\"' so they are searchable but hidden."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "cand-tagged" buf))
    (bmkp-add-tags "cand-tagged" '("alpha" "beta") 'NO-UPDATE-P)
    (let* ((bm     (assoc "cand-tagged" bookmark-alist))
           (narrow `((,#'bookmark-default-handler . ?f)))
           (cand   (bmkp-gt-jump-candidate-default bm narrow)))
      (should (string-match-p ";alpha" cand))
      (should (string-match-p ";beta"  cand))
      ;; The hidden segment starts right after the bookmark name; its first
      ;; character must carry `display ""'.
      (should (equal "" (get-text-property (length "cand-tagged") 'display cand))))))

(ert-deftest bmkp-gt-test-jump/candidate-format-honors-user-override ()
  "A user-supplied `bmkp-gt-jump-candidate-format-function' takes effect.
The override prepends `[T] ' to the visible name; properties must
still be applied or consult could not lookup the candidate."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "cand-ovr" buf))
    (let* ((bm     (assoc "cand-ovr" bookmark-alist))
           (narrow `((,#'bookmark-default-handler . ?f)))
           (bmkp-gt-jump-candidate-format-function
            (lambda (bm narrow-alist)
              (let* ((name      (car bm))
                     (type-char (bmkp-gt-jump-candidate-type-char bm narrow-alist)))
                (propertize (concat "[T] " name)
                            'bmkp-gt-bookmark-name name
                            'consult--type        type-char)))))
      (let ((cand  (bmkp-gt--make-jump-candidate bm narrow)))
        (should (string-prefix-p "[T] cand-ovr" cand))
        (should (equal "cand-ovr" (get-text-property 0 'bmkp-gt-bookmark-name cand)))))))

(ert-deftest bmkp-gt-test-jump/candidate-format-falls-back-when-non-function ()
  "A non-function `bmkp-gt-jump-candidate-format-function' falls back to the default."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "cand-fallback" buf))
    (let* ((bm     (assoc "cand-fallback" bookmark-alist))
           (narrow `((,#'bookmark-default-handler . ?f)))
           (bmkp-gt-jump-candidate-format-function 'not-a-function))
      (let ((cand  (bmkp-gt--make-jump-candidate bm narrow)))
        (should (string-prefix-p "cand-fallback" cand))))))


(ert-deftest bmkp-gt-test-jump/sort-mru-uses-last-visited ()
  "`bmkp-gt--sort-candidates' with `mru' orders by `last-visited',
not by `last-modified'.  Regression: bookmark-plus (unlike bookmark-x)
does not update `last-modified' on jump, so `last-visited' is the
only correct MRU signal."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "older" buf)
      (bmkp-gt-test--make-bookmark "newer" buf))
    ;; older visited long ago; newer visited recently.
    (bookmark-prop-set "older" 'last-visited '(20000 0))
    (bookmark-prop-set "newer" 'last-visited '(30000 0))
    ;; Make last-modified go the OTHER way — if the sort were still
    ;; using last-modified this would fail.
    (bookmark-prop-set "older" 'last-modified '(40000 0))
    (bookmark-prop-set "newer" 'last-modified '(10000 0))
    (let* ((bmkp-gt-jump-sort-by 'mru)
           (sorted (bmkp-gt--sort-candidates
                    (list (propertize "older") (propertize "newer")))))
      (should (equal '("newer" "older")
                     (mapcar #'substring-no-properties sorted))))))

(provide 'bmkp-gt-test-jump)
;;; bmkp-gt-test-jump.el ends here
