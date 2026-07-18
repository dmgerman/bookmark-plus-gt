;;; bmkp-gt-test-default-tags.el --- Tests for bookmark-plus-gt-default-tags   -*- lexical-binding: t -*-

;;; Code:

(require 'bmkp-gt-test-helper)
(require 'bookmark-plus-gt-default-tags)
(require 'bookmark-plus-gt-browsel-tabs)
(require 'cl-lib)

;; Tests below assume the feature is active — the mode is off by
;; default, but individual tests toggle it as they need.  We enable it
;; at file load so tests that call the create hook or read the seed
;; function see a coherent baseline.
(bmkp-gt-default-tags-mode 1)


;;; Resolver ------------------------------------------------------------

(ert-deftest bmkp-gt-test-default-tags/resolve-nil ()
  "Resolver returns nil for a nil source variable."
  (let ((bmkp-gt-default-tags-on-create nil))
    (should (null (bmkp-gt-default-tags--resolve 'bmkp-gt-default-tags-on-create)))))

(ert-deftest bmkp-gt-test-default-tags/resolve-bare-string-accepted ()
  "A bare string is accepted at the DSL level and returned verbatim."
  (let ((bmkp-gt-default-tags-on-create "solo"))
    (should (equal "solo"
                   (bmkp-gt-default-tags--resolve
                    'bmkp-gt-default-tags-on-create)))))

(ert-deftest bmkp-gt-test-default-tags/resolve-alist-form-accepted ()
  "A list of (SYMBOL . ANYTHING) cons cells is recognized as the alist DSL shape."
  (let ((bmkp-gt-default-tags-on-jump
         '((tag . "work") (tag-any . ("a" "b")))))
    (should (equal '((tag . "work") (tag-any . ("a" "b")))
                   (bmkp-gt-default-tags--resolve
                    'bmkp-gt-default-tags-on-jump)))))

(ert-deftest bmkp-gt-test-default-tags/resolve-list ()
  "Resolver returns a list of strings unchanged."
  (let ((bmkp-gt-default-tags-on-create '("a" "b" "c")))
    (should (equal '("a" "b" "c")
                   (bmkp-gt-default-tags--resolve 'bmkp-gt-default-tags-on-create)))))

(ert-deftest bmkp-gt-test-default-tags/resolve-function-returning-list ()
  "Resolver calls a nullary function and returns its list result."
  (let ((bmkp-gt-default-tags-on-create (lambda () '("x" "y"))))
    (should (equal '("x" "y")
                   (bmkp-gt-default-tags--resolve 'bmkp-gt-default-tags-on-create)))))

(ert-deftest bmkp-gt-test-default-tags/resolve-function-returning-string ()
  "Function form can return a bare string — a valid DSL shape."
  (let ((bmkp-gt-default-tags-on-create (lambda () "fn-tag")))
    (should (equal "fn-tag"
                   (bmkp-gt-default-tags--resolve
                    'bmkp-gt-default-tags-on-create)))))

(ert-deftest bmkp-gt-test-default-tags/resolve-function-returning-alist ()
  "Function form can return an alist — a valid DSL shape."
  (let ((bmkp-gt-default-tags-on-jump
         (lambda () '((tag . "fn") (tag-any . ("x"))))))
    (should (equal '((tag . "fn") (tag-any . ("x")))
                   (bmkp-gt-default-tags--resolve
                    'bmkp-gt-default-tags-on-jump)))))

(ert-deftest bmkp-gt-test-default-tags/resolve-function-returning-nil ()
  "Resolver returns nil when the function returns nil."
  (let ((bmkp-gt-default-tags-on-create (lambda () nil)))
    (should (null (bmkp-gt-default-tags--resolve 'bmkp-gt-default-tags-on-create)))))

(ert-deftest bmkp-gt-test-default-tags/resolve-function-signaling ()
  "Resolver catches errors from the function and returns nil."
  (let ((bmkp-gt-default-tags-on-create (lambda () (error "boom"))))
    (should (null (bmkp-gt-default-tags--resolve 'bmkp-gt-default-tags-on-create)))))

(ert-deftest bmkp-gt-test-default-tags/resolve-unexpected-shape ()
  "Resolver returns nil for a value that is neither string, list-of-strings, nor function."
  (let ((bmkp-gt-default-tags-on-create 42))
    (should (null (bmkp-gt-default-tags--resolve 'bmkp-gt-default-tags-on-create)))))

(ert-deftest bmkp-gt-test-default-tags/resolve-mixed-list-rejected ()
  "Resolver returns nil for a list that contains a non-string non-nil element."
  (let ((bmkp-gt-default-tags-on-create '("ok" 3 "also-ok")))
    (should (null (bmkp-gt-default-tags--resolve 'bmkp-gt-default-tags-on-create)))))

(ert-deftest bmkp-gt-test-default-tags/resolve-nil-elements-accepted ()
  "Resolver accepts nil elements — nil is the `untagged' sentinel in the DSL."
  (let ((bmkp-gt-default-tags-on-jump '("work" nil "home")))
    (should (equal '("work" nil "home")
                   (bmkp-gt-default-tags--resolve
                    'bmkp-gt-default-tags-on-jump)))))

(ert-deftest bmkp-gt-test-default-tags/resolve-only-nil-accepted ()
  "Resolver accepts a list with a single nil element."
  (let ((bmkp-gt-default-tags-on-jump '(nil)))
    (should (equal '(nil)
                   (bmkp-gt-default-tags--resolve
                    'bmkp-gt-default-tags-on-jump)))))


;;; Create side --------------------------------------------------------

(ert-deftest bmkp-gt-test-default-tags/create-adds-configured-tag ()
  "Setting a bookmark while the mode is on appends the configured tag."
  (let ((bmkp-gt-default-tags-on-create '("auto")))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "content"
        (bmkp-gt-test--make-bookmark "auto-tagged" buf))
      (should (member "auto"
                      (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                              (bookmark-prop-get "auto-tagged" 'tags)))))))

(ert-deftest bmkp-gt-test-default-tags/create-adds-list-of-tags ()
  "A list-valued `on-create' contributes every tag."
  (let ((bmkp-gt-default-tags-on-create '("alpha" "beta")))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "content"
        (bmkp-gt-test--make-bookmark "multi" buf))
      (let ((tags (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                          (bookmark-prop-get "multi" 'tags))))
        (should (member "alpha" tags))
        (should (member "beta"  tags))))))

(ert-deftest bmkp-gt-test-default-tags/create-function-form ()
  "A nullary-function `on-create' contributes its resolved tags."
  (let ((bmkp-gt-default-tags-on-create (lambda () '("computed"))))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "content"
        (bmkp-gt-test--make-bookmark "fn-tagged" buf))
      (should (member "computed"
                      (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                              (bookmark-prop-get "fn-tagged" 'tags)))))))

(ert-deftest bmkp-gt-test-default-tags/create-nil-adds-nothing ()
  "`on-create' at nil leaves a new bookmark with no tags."
  (let ((bmkp-gt-default-tags-on-create nil))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "content"
        (bmkp-gt-test--make-bookmark "no-defaults" buf))
      (should (null (bookmark-prop-get "no-defaults" 'tags))))))

(ert-deftest bmkp-gt-test-default-tags/create-off-adds-nothing ()
  "When the mode is off, `on-create' is inert even if set."
  (let ((was-on bmkp-gt-default-tags-mode))
    (unwind-protect
        (let ((bmkp-gt-default-tags-on-create '("should-not-apply")))
          (bmkp-gt-default-tags-mode -1)
          (bmkp-gt-test-with-clean-bookmarks
            (bmkp-gt-test-with-fixture-buffer buf "content"
              (bmkp-gt-test--make-bookmark "mode-off" buf))
            (should (null (bookmark-prop-get "mode-off" 'tags)))))
      (bmkp-gt-default-tags-mode (if was-on 1 -1)))))

(ert-deftest bmkp-gt-test-default-tags/tag-applied-under-browsel-refresh ()
  "Regression: when `bmkp-gt-browsel-tabs-mode' is also on, its refresh
runs inside `bookmark-store' (via `bmkp-refresh/rebuild-menu-list' →
`bookmark-bmenu-list', which browsel-tabs has advised).  The refresh
calls `bookmark-store' for each tab, which historically clobbered
`bookmark-current-bookmark'.  That would leave our hook applying the
default tag to the last browsel-tab instead of the freshly-set
bookmark.  The fix isolates `bookmark-current-bookmark' inside the
browsel refresh; this test locks in that invariant."
  (let ((bmkp-gt-default-tags-on-create '("regression-tag"))
        (browsel-was-on bmkp-gt-browsel-tabs-mode))
    (unwind-protect
        (cl-letf (((symbol-function 'browsel-browser-tabs)
                   (lambda (&rest _)
                     (list (list :id 1
                                 :url "https://tab-a.example.com/"
                                 :title "Tab A"
                                 :browsel-browser "stub")
                           (list :id 2
                                 :url "https://tab-b.example.com/"
                                 :title "Tab B"
                                 :browsel-browser "stub")))))
          (bmkp-gt-browsel-tabs-mode 1)
          (bmkp-gt-test-with-clean-bookmarks
            (bmkp-gt-test-with-fixture-buffer buf "content"
              (with-current-buffer buf
                (let ((bmkp-prompt-for-tags-flag nil))
                  (bookmark-set "target-under-refresh" nil t nil))))
            (should (member
                     "regression-tag"
                     (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                             (bookmark-prop-get "target-under-refresh" 'tags))))
            ;; And the browsel-tab records must NOT have picked up our
            ;; default tag (they were made via `bookmark-store', which
            ;; does not fire `bmkp-after-set-hook').
            (dolist (tab-name '("Tab A" "Tab B"))
              (let ((rec (assoc tab-name bookmark-alist)))
                (when rec
                  (should-not
                   (member "regression-tag"
                           (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                                   (bookmark-prop-get tab-name 'tags)))))))))
      (bmkp-gt-browsel-tabs-mode (if browsel-was-on 1 -1)))))

(ert-deftest bmkp-gt-test-default-tags/interactive-bookmark-set-tags-bookmark ()
  "Full interactive-shape path: `bookmark-set' called with `interactivep=t'
must fire `bmkp-after-set-hook' with `bookmark-current-bookmark' bound, and
our hook must apply the default tag to the new bookmark record."
  (let ((bmkp-gt-default-tags-on-create '("intx")))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "content"
        ;; Explicitly pass interactivep=t so this exercises the branch
        ;; that also runs `bmkp-prompt-for-tags-flag' handling and, at
        ;; the tail, `bmkp-after-set-hook'.  The interactive tags prompt
        ;; itself is inhibited by binding `bmkp-prompt-for-tags-flag' nil.
        (let ((bmkp-prompt-for-tags-flag nil))
          (with-current-buffer buf
            (bookmark-set "int-shape" nil t nil))))
      (should (member "intx"
                      (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                              (bookmark-prop-get "int-shape" 'tags)))))))

(ert-deftest bmkp-gt-test-default-tags/setter-then-bookmark-set-tags-bookmark ()
  "Full path: enable mode, set the variable via the interactive setter, then
`bookmark-set' a new bookmark — the bookmark record must carry the tag.
This mirrors the exact user flow: `M-x bmkp-gt-default-tags-set-on-create'
followed by `C-x r m'."
  (let ((was-on   bmkp-gt-default-tags-mode)
        (previous bmkp-gt-default-tags-on-create))
    (unwind-protect
        (progn
          (bmkp-gt-default-tags-mode 1)
          ;; Force the setter's Lisp-call path (no interactive read, no confirm).
          (let ((bmkp-gt-default-tags-on-create nil)
                (bmkp-gt-default-tags-confirm-set nil))
            (bmkp-gt-default-tags-set-on-create '("via-setter"))
            (should (equal '("via-setter") bmkp-gt-default-tags-on-create))
            (bmkp-gt-test-with-clean-bookmarks
              (bmkp-gt-test-with-fixture-buffer buf "content"
                (bmkp-gt-test--make-bookmark "e2e-set" buf))
              (should (member "via-setter"
                              (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                                      (bookmark-prop-get "e2e-set" 'tags)))))))
      (setq bmkp-gt-default-tags-on-create previous)
      (bmkp-gt-default-tags-mode (if was-on 1 -1)))))

(ert-deftest bmkp-gt-test-default-tags/create-drops-nil-elements ()
  "On the create side, nil elements in the list are silently dropped —
they are the `untagged' sentinel, meaningful only on the jump side."
  (let ((bmkp-gt-default-tags-on-create '("keep" nil "also-keep")))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "content"
        (bmkp-gt-test--make-bookmark "nil-dropper" buf))
      (let ((tags (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                          (bookmark-prop-get "nil-dropper" 'tags))))
        (should (member "keep" tags))
        (should (member "also-keep" tags))
        (should-not (member nil tags))))))

(ert-deftest bmkp-gt-test-default-tags/create-accepts-bare-string ()
  "DSL: a bare string on the create side adds that single tag."
  (let ((bmkp-gt-default-tags-on-create "singular"))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "content"
        (bmkp-gt-test--make-bookmark "bare-tagged" buf))
      (should (member "singular"
                      (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                              (bookmark-prop-get "bare-tagged" 'tags)))))))

(ert-deftest bmkp-gt-test-default-tags/create-alist-form-ignored ()
  "The alist DSL shape is meaningless on the create side.  The apply
hook must not add any tag when it resolves to an alist."
  (let ((bmkp-gt-default-tags-on-create
         '((tag . "should-not-appear") (tag-any . ("either")))))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "content"
        (bmkp-gt-test--make-bookmark "alist-ignored" buf))
      (should (null (bookmark-prop-get "alist-ignored" 'tags))))))

(ert-deftest bmkp-gt-test-default-tags/create-only-nil-adds-nothing ()
  "A create list of only nils resolves to an empty tag list; the bookmark
is left untagged."
  (let ((bmkp-gt-default-tags-on-create '(nil)))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "content"
        (bmkp-gt-test--make-bookmark "only-nil" buf))
      (should (null (bookmark-prop-get "only-nil" 'tags))))))

(ert-deftest bmkp-gt-test-default-tags/create-additive-to-existing ()
  "Default tags append to tags already set on the bookmark record."
  (let ((bmkp-gt-default-tags-on-create '("defaulted")))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "content"
        (bmkp-gt-test--make-bookmark "combined" buf))
      (bmkp-add-tags "combined" '("manual") 'NO-UPDATE-P)
      (let ((tags (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                          (bookmark-prop-get "combined" 'tags))))
        (should (member "manual"    tags))
        (should (member "defaulted" tags))))))


;;; Jump side ---------------------------------------------------------

;; Seed shape follows the DSL:
;;
;;   nil                    → no filter (seed is nil).
;;   '("work")              → ((tag-any . ("work")))
;;   '("work" "home")       → ((tag-any . ("work" "home")))
;;   '("work" nil)          → ((tag-any . ("work" nil)))
;;   '(nil)                 → ((tag-any . (nil)))
;;   fn returning any above → same as its return.

(ert-deftest bmkp-gt-test-default-tags/seed-dsl-nil ()
  "DSL: `nil' means no seed."
  (let ((bmkp-gt-default-tags-on-jump nil))
    (should (null (bmkp-gt-default-tags--seed-jump-filters)))))

(ert-deftest bmkp-gt-test-default-tags/seed-dsl-single-string ()
  "DSL: `\\='(\"work\")' → single `tag-any' entry with one value."
  (let ((bmkp-gt-default-tags-on-jump '("work")))
    (should (equal '((tag-any . ("work")))
                   (bmkp-gt-default-tags--seed-jump-filters)))))

(ert-deftest bmkp-gt-test-default-tags/seed-dsl-multiple-strings ()
  "DSL: `\\='(\"work\" \"home\")' → single `tag-any' entry OR'ing both."
  (let ((bmkp-gt-default-tags-on-jump '("work" "home")))
    (should (equal '((tag-any . ("work" "home")))
                   (bmkp-gt-default-tags--seed-jump-filters)))))

(ert-deftest bmkp-gt-test-default-tags/seed-dsl-string-and-nil ()
  "DSL: `\\='(\"work\" nil)' → OR of `work' and the untagged sentinel."
  (let ((bmkp-gt-default-tags-on-jump '("work" nil)))
    (should (equal '((tag-any . ("work" nil)))
                   (bmkp-gt-default-tags--seed-jump-filters)))))

(ert-deftest bmkp-gt-test-default-tags/seed-dsl-only-untagged ()
  "DSL: `\\='(nil)' → seed matches only untagged bookmarks."
  (let ((bmkp-gt-default-tags-on-jump '(nil)))
    (should (equal '((tag-any . (nil)))
                   (bmkp-gt-default-tags--seed-jump-filters)))))

(ert-deftest bmkp-gt-test-default-tags/seed-dsl-function-returning-list ()
  "DSL: nullary function returning a DSL list is used verbatim."
  (let ((bmkp-gt-default-tags-on-jump (lambda () '("dyn" nil))))
    (should (equal '((tag-any . ("dyn" nil)))
                   (bmkp-gt-default-tags--seed-jump-filters)))))

(ert-deftest bmkp-gt-test-default-tags/seed-dsl-bare-string ()
  "DSL: a bare string wraps into `((tag-any . (STRING)))'."
  (let ((bmkp-gt-default-tags-on-jump "focus"))
    (should (equal '((tag-any . ("focus")))
                   (bmkp-gt-default-tags--seed-jump-filters)))))

(ert-deftest bmkp-gt-test-default-tags/seed-dsl-alist-verbatim ()
  "DSL: an alist of `(FACET . VALUE)' entries is used as the seed verbatim."
  (let ((bmkp-gt-default-tags-on-jump
         '((tag . "work") (tag-any . ("a" "b")))))
    (should (equal '((tag . "work") (tag-any . ("a" "b")))
                   (bmkp-gt-default-tags--seed-jump-filters)))))

(ert-deftest bmkp-gt-test-default-tags/seed-dsl-function-returning-alist ()
  "DSL: a function returning an alist has its alist used verbatim as the seed."
  (let ((bmkp-gt-default-tags-on-jump
         (lambda () '((tag . "urgent")))))
    (should (equal '((tag . "urgent"))
                   (bmkp-gt-default-tags--seed-jump-filters)))))


;;; Mode toggle -------------------------------------------------------

(ert-deftest bmkp-gt-test-default-tags/mode-on-attaches-hook ()
  "Enabling the mode adds the create-side function to `bmkp-after-set-hook'."
  (let ((was-on bmkp-gt-default-tags-mode))
    (unwind-protect
        (progn
          (bmkp-gt-default-tags-mode 1)
          (should (member #'bmkp-gt-default-tags--apply-on-create
                          bmkp-after-set-hook)))
      (bmkp-gt-default-tags-mode (if was-on 1 -1)))))

(ert-deftest bmkp-gt-test-default-tags/mode-off-removes-hook ()
  "Disabling the mode removes the create-side function from `bmkp-after-set-hook'."
  (let ((was-on bmkp-gt-default-tags-mode))
    (unwind-protect
        (progn
          (bmkp-gt-default-tags-mode 1)
          (bmkp-gt-default-tags-mode -1)
          (should-not (member #'bmkp-gt-default-tags--apply-on-create
                              bmkp-after-set-hook)))
      (bmkp-gt-default-tags-mode (if was-on 1 -1)))))

(ert-deftest bmkp-gt-test-default-tags/mode-on-sets-jump-seed ()
  "Enabling the mode installs the seed function on the jump variable."
  (let ((was-on bmkp-gt-default-tags-mode))
    (unwind-protect
        (progn
          (bmkp-gt-default-tags-mode 1)
          (should (eq #'bmkp-gt-default-tags--seed-jump-filters
                      bmkp-gt-jump-default-filters-function)))
      (bmkp-gt-default-tags-mode (if was-on 1 -1)))))

(ert-deftest bmkp-gt-test-default-tags/mode-off-clears-jump-seed ()
  "Disabling the mode clears the jump variable only when it's ours."
  (let ((was-on bmkp-gt-default-tags-mode))
    (unwind-protect
        (progn
          (bmkp-gt-default-tags-mode 1)
          (bmkp-gt-default-tags-mode -1)
          (should (null bmkp-gt-jump-default-filters-function)))
      (bmkp-gt-default-tags-mode (if was-on 1 -1)))))

(ert-deftest bmkp-gt-test-default-tags/mode-off-preserves-foreign-seed ()
  "If some other module has set the jump variable, disabling our mode
must not clobber it."
  (let ((was-on   bmkp-gt-default-tags-mode)
        (foreign  (lambda () '((tag . "foreign")))))
    (unwind-protect
        (progn
          (bmkp-gt-default-tags-mode 1)
          (setq bmkp-gt-jump-default-filters-function foreign)
          (bmkp-gt-default-tags-mode -1)
          (should (eq bmkp-gt-jump-default-filters-function foreign)))
      (setq bmkp-gt-jump-default-filters-function nil)
      (bmkp-gt-default-tags-mode (if was-on 1 -1)))))



;;; Tags-with-defaults reader (create side) -----------------------------

(ert-deftest bmkp-gt-test-default-tags/edit-pop-removes-last ()
  "The M-D action pops the last tag from the edit state."
  (let ((bmkp-gt-default-tags--edit-state '("a" "b" "c"))
        (bmkp-gt-default-tags--edit-restart nil))
    (cl-letf (((symbol-function 'abort-minibuffers) #'ignore))
      (bmkp-gt-default-tags--edit-pop))
    (should (equal '("a" "b") bmkp-gt-default-tags--edit-state))
    (should bmkp-gt-default-tags--edit-restart)))

(ert-deftest bmkp-gt-test-default-tags/edit-pop-empty-state ()
  "M-D on an empty state leaves it empty and still sets the restart flag."
  (let ((bmkp-gt-default-tags--edit-state nil)
        (bmkp-gt-default-tags--edit-restart nil))
    (cl-letf (((symbol-function 'abort-minibuffers) #'ignore))
      (bmkp-gt-default-tags--edit-pop))
    (should (null bmkp-gt-default-tags--edit-state))
    (should bmkp-gt-default-tags--edit-restart)))

(ert-deftest bmkp-gt-test-default-tags/edit-clear-empties ()
  "M-T empties the whole state."
  (let ((bmkp-gt-default-tags--edit-state '("x" "y"))
        (bmkp-gt-default-tags--edit-restart nil))
    (cl-letf (((symbol-function 'abort-minibuffers) #'ignore))
      (bmkp-gt-default-tags--edit-clear))
    (should (null bmkp-gt-default-tags--edit-state))
    (should bmkp-gt-default-tags--edit-restart)))

(ert-deftest bmkp-gt-test-default-tags/edit-add-appends ()
  "M-t reads a tag via `completing-read' and appends it to the state."
  (let ((bmkp-gt-default-tags--edit-state '("first"))
        (bmkp-gt-default-tags--edit-restart nil))
    (cl-letf (((symbol-function 'abort-minibuffers) #'ignore)
              ((symbol-function 'completing-read)
               (lambda (&rest _) "second"))
              ((symbol-function 'bmkp-tags-list)
               (lambda (&rest _) '(("first") ("second")))))
      (bmkp-gt-default-tags--edit-add))
    (should (equal '("first" "second") bmkp-gt-default-tags--edit-state))
    (should bmkp-gt-default-tags--edit-restart)))

(ert-deftest bmkp-gt-test-default-tags/edit-with-defaults-c-g-propagates ()
  "C-g at the outer reader propagates the quit signal — no override."
  (let ((got-quit nil))
    (cl-letf (((symbol-function 'bmkp-gt-default-tags--edit-read-once)
               (lambda () (signal 'quit nil))))
      (condition-case _
          (bmkp-gt-default-tags--edit-with-defaults '("d1"))
        (quit (setq got-quit t))))
    (should got-quit)))

(ert-deftest bmkp-gt-test-default-tags/edit-with-defaults-empty-ret-commits ()
  "Empty RET at the outer reader commits the pre-populated state."
  (cl-letf (((symbol-function 'bmkp-gt-default-tags--edit-read-once)
             (lambda () "")))
    (should (equal '("d1")
                   (bmkp-gt-default-tags--edit-with-defaults '("d1"))))))

(ert-deftest bmkp-gt-test-default-tags/edit-add-empty-input-ignored ()
  "M-t with empty input from the tag reader leaves state unchanged."
  (let ((bmkp-gt-default-tags--edit-state '("kept"))
        (bmkp-gt-default-tags--edit-restart nil))
    (cl-letf (((symbol-function 'abort-minibuffers) #'ignore)
              ((symbol-function 'completing-read)
               (lambda (&rest _) ""))
              ((symbol-function 'bmkp-tags-list) (lambda (&rest _) nil)))
      (bmkp-gt-default-tags--edit-add))
    (should (equal '("kept") bmkp-gt-default-tags--edit-state))))


;;; Advice — substitution inside `bookmark-set' ------------------------

(ert-deftest bmkp-gt-test-default-tags/reader-substitutes-inside-bookmark-set ()
  "When the mode is on and defaults are configured, the advice substitutes
our tags-with-defaults reader for `bmkp-read-tags-completing' during a
`bookmark-set' call."
  (let ((bmkp-gt-default-tags-on-create '("substituted"))
        (bmkp-prompt-for-tags-flag t)
        (edit-called nil))
    (bmkp-gt-test-with-clean-bookmarks
      (cl-letf (((symbol-function 'bmkp-gt-default-tags--edit-with-defaults)
                 (lambda (defaults)
                   (setq edit-called t)
                   defaults)))
        (bmkp-gt-test-with-fixture-buffer buf "content"
          (with-current-buffer buf
            (bookmark-set "reader-sub" nil t nil))))
      (should edit-called)
      ;; Tags were applied inside bookmark-set, not by the after-set hook.
      (should (member "substituted"
                      (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                              (bookmark-prop-get "reader-sub" 'tags)))))))

(ert-deftest bmkp-gt-test-default-tags/reader-not-substituted-outside-bookmark-set ()
  "Calling `bmkp-read-tags-completing' outside `bookmark-set' passes through."
  (let ((bmkp-gt-default-tags-on-create '("would-not-be-substituted"))
        (edit-called nil)
        (orig-called nil))
    (cl-letf (((symbol-function 'bmkp-gt-default-tags--edit-with-defaults)
               (lambda (_) (setq edit-called t) nil))
              ((symbol-function 'completing-read)
               (lambda (&rest _) (setq orig-called t) "")))
      (bmkp-read-tags-completing))
    (should orig-called)
    (should-not edit-called)))

(ert-deftest bmkp-gt-test-default-tags/hook-skips-when-reader-ran ()
  "When the tags-with-defaults reader ran, the after-set hook skips its
auto-append (the tags were already applied inside `bookmark-set')."
  (let ((bmkp-gt-default-tags-on-create '("would-double"))
        (bmkp-prompt-for-tags-flag t))
    (bmkp-gt-test-with-clean-bookmarks
      (cl-letf (((symbol-function 'bmkp-gt-default-tags--edit-with-defaults)
                 (lambda (defaults) defaults)))
        (bmkp-gt-test-with-fixture-buffer buf "content"
          (with-current-buffer buf
            (bookmark-set "single-apply" nil t nil))))
      ;; The tag appears exactly once — no double-tagging.
      (let ((tags (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                          (bookmark-prop-get "single-apply" 'tags))))
        (should (equal 1 (cl-count "would-double" tags :test #'equal)))))))

(ert-deftest bmkp-gt-test-default-tags/hook-runs-when-tags-prompt-off ()
  "With `bmkp-prompt-for-tags-flag' nil, the reader never fires; the hook
does its usual auto-append."
  (let ((bmkp-gt-default-tags-on-create '("hook-path"))
        (bmkp-prompt-for-tags-flag nil))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "content"
        (with-current-buffer buf
          (bookmark-set "no-prompt" nil t nil)))
      (should (member "hook-path"
                      (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                              (bookmark-prop-get "no-prompt" 'tags)))))))


;;; Filter engine (tag-any facet) -------------------------------------
;;
;; The engine's `tag-any' facet is what the jump seed maps into.  These
;; tests exercise the semantics directly against synthetic bookmark
;; records — no bookmark-set / bookmark-alist plumbing needed.

(defmacro bmkp-gt-test-default-tags--with-tagged-alist (specs &rest body)
  "Bind `bookmark-alist' to SPECS then run BODY.
SPECS is a list of (NAME TAGS) pairs; each becomes a minimal
bookmark record `(NAME (tags . TAGS))'.  BODY sees `bookmark-alist'
containing exactly those records — enough for
`bmkp-gt--bookmark-passes-filters-p' to run since it consults
`bookmark-prop-get' which does an alist lookup."
  (declare (indent 1) (debug t))
  `(let ((bookmark-alist
          (mapcar (lambda (s) (cons (car s) (list (cons 'tags (cadr s)))))
                  ,specs)))
     ,@body))

(defun bmkp-gt-test-default-tags--bm (name)
  "Return the record for NAME in the currently-bound `bookmark-alist'."
  (assoc name bookmark-alist))

(ert-deftest bmkp-gt-test-default-tags/engine-tag-any-matches-any-value ()
  "`(tag-any . (X Y))' matches bookmarks with X, with Y, or with both;
does not match a bookmark with neither."
  (bmkp-gt-test-default-tags--with-tagged-alist
      '(("with-x"       ("x"))
        ("with-y"       ("y"))
        ("with-both"    ("x" "y"))
        ("with-neither" ("z")))
    (let ((filters '((tag-any . ("x" "y")))))
      (should     (bmkp-gt--bookmark-passes-filters-p
                   (bmkp-gt-test-default-tags--bm "with-x")       filters))
      (should     (bmkp-gt--bookmark-passes-filters-p
                   (bmkp-gt-test-default-tags--bm "with-y")       filters))
      (should     (bmkp-gt--bookmark-passes-filters-p
                   (bmkp-gt-test-default-tags--bm "with-both")    filters))
      (should-not (bmkp-gt--bookmark-passes-filters-p
                   (bmkp-gt-test-default-tags--bm "with-neither") filters)))))

(ert-deftest bmkp-gt-test-default-tags/engine-tag-any-nil-matches-untagged ()
  "A nil element in `tag-any' VALUES matches bookmarks with no tags."
  (bmkp-gt-test-default-tags--with-tagged-alist
      '(("untagged" nil)
        ("tagged"   ("x")))
    (let ((filters '((tag-any . (nil)))))
      (should     (bmkp-gt--bookmark-passes-filters-p
                   (bmkp-gt-test-default-tags--bm "untagged") filters))
      (should-not (bmkp-gt--bookmark-passes-filters-p
                   (bmkp-gt-test-default-tags--bm "tagged")   filters)))))

(ert-deftest bmkp-gt-test-default-tags/engine-tag-any-mixes-string-and-untagged ()
  "`(tag-any . (X nil))' matches bookmarks with X OR bookmarks with no tags."
  (bmkp-gt-test-default-tags--with-tagged-alist
      '(("with-x"   ("x"))
        ("untagged" nil)
        ("with-y"   ("y")))
    (let ((filters '((tag-any . ("x" nil)))))
      (should     (bmkp-gt--bookmark-passes-filters-p
                   (bmkp-gt-test-default-tags--bm "with-x")   filters))
      (should     (bmkp-gt--bookmark-passes-filters-p
                   (bmkp-gt-test-default-tags--bm "untagged") filters))
      (should-not (bmkp-gt--bookmark-passes-filters-p
                   (bmkp-gt-test-default-tags--bm "with-y")   filters)))))

(ert-deftest bmkp-gt-test-default-tags/engine-tag-and-tag-any-and-together ()
  "A `tag' facet and a `tag-any' facet compose as AND across the alist."
  (bmkp-gt-test-default-tags--with-tagged-alist
      '(("both"     ("urgent" "work"))
        ("any-only" ("work"))
        ("and-only" ("urgent")))
    (let ((filters '((tag-any . ("work" "home")) (tag . "urgent"))))
      (should     (bmkp-gt--bookmark-passes-filters-p
                   (bmkp-gt-test-default-tags--bm "both")     filters))
      (should-not (bmkp-gt--bookmark-passes-filters-p
                   (bmkp-gt-test-default-tags--bm "any-only") filters))
      (should-not (bmkp-gt--bookmark-passes-filters-p
                   (bmkp-gt-test-default-tags--bm "and-only") filters)))))

(ert-deftest bmkp-gt-test-default-tags/format-tag-any-with-untagged ()
  "The prompt formatter renders `(tag-any . (a b nil))' as `[;(a|b|—)]'."
  (let ((bmkp-gt-jump--active-filters '((tag-any . ("a" "b" nil)))))
    (let ((s (bmkp-gt--format-active-filters)))
      (should (string-match-p "(a|b|—)" s)))))


;;; Interactive setters ------------------------------------------------

(ert-deftest bmkp-gt-test-default-tags/set-on-create-lisp-call ()
  "From Lisp, `set-on-create' assigns the given list unconditionally."
  (let ((bmkp-gt-default-tags-on-create nil))
    (bmkp-gt-default-tags-set-on-create '("alpha" "beta"))
    (should (equal '("alpha" "beta") bmkp-gt-default-tags-on-create))))

(ert-deftest bmkp-gt-test-default-tags/set-on-jump-lisp-call ()
  "From Lisp, `set-on-jump' assigns the given list unconditionally."
  (let ((bmkp-gt-default-tags-on-jump nil))
    (bmkp-gt-default-tags-set-on-jump '("focus"))
    (should (equal '("focus") bmkp-gt-default-tags-on-jump))))

(ert-deftest bmkp-gt-test-default-tags/set-on-create-clears-with-nil ()
  "Passing nil clears the current default."
  (let ((bmkp-gt-default-tags-on-create '("stale")))
    (bmkp-gt-default-tags-set-on-create nil)
    (should (null bmkp-gt-default-tags-on-create))))

(ert-deftest bmkp-gt-test-default-tags/interactive-no-confirm-when-current-nil ()
  "When the current value is nil, no confirmation is asked and the new list is applied."
  (let ((bmkp-gt-default-tags-on-create nil)
        (bmkp-gt-default-tags-confirm-set t)
        (y-or-n-p-called nil))
    (cl-letf (((symbol-function 'bmkp-read-tags-completing)
               (lambda (&rest _) '("chosen")))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq y-or-n-p-called t) t))
              ((symbol-function 'message) #'ignore))
      (call-interactively #'bmkp-gt-default-tags-set-on-create))
    (should-not y-or-n-p-called)
    (should (equal '("chosen") bmkp-gt-default-tags-on-create))))

(ert-deftest bmkp-gt-test-default-tags/interactive-confirms-overwrite ()
  "When the current value is non-nil, the setter asks and applies on `y'."
  (let ((bmkp-gt-default-tags-on-create '("prior"))
        (bmkp-gt-default-tags-confirm-set t))
    (cl-letf (((symbol-function 'bmkp-read-tags-completing)
               (lambda (&rest _) '("chosen")))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) t))
              ((symbol-function 'message) #'ignore))
      (call-interactively #'bmkp-gt-default-tags-set-on-create))
    (should (equal '("chosen") bmkp-gt-default-tags-on-create))))

(ert-deftest bmkp-gt-test-default-tags/interactive-aborts-when-refused ()
  "When the current value is non-nil and the user refuses, abort and preserve the value."
  (let ((bmkp-gt-default-tags-on-create '("preserved"))
        (bmkp-gt-default-tags-confirm-set t))
    (cl-letf (((symbol-function 'bmkp-read-tags-completing)
               (lambda (&rest _) '("would-overwrite")))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) nil)))
      (should-error (call-interactively #'bmkp-gt-default-tags-set-on-create)
                    :type 'user-error))
    (should (equal '("preserved") bmkp-gt-default-tags-on-create))))

(ert-deftest bmkp-gt-test-default-tags/setter-refuses-when-mode-off ()
  "Calling the setter (Lisp path) while the mode is off signals `user-error'
and leaves the target variable untouched."
  (let ((was-on bmkp-gt-default-tags-mode)
        (bmkp-gt-default-tags-on-create '("prior")))
    (unwind-protect
        (progn
          (bmkp-gt-default-tags-mode -1)
          (should-error (bmkp-gt-default-tags-set-on-create '("new"))
                        :type 'user-error)
          (should (equal '("prior") bmkp-gt-default-tags-on-create)))
      (bmkp-gt-default-tags-mode (if was-on 1 -1)))))

(ert-deftest bmkp-gt-test-default-tags/interactive-refuses-when-mode-off ()
  "Interactive setter with the mode off aborts before reading tags."
  (let ((was-on bmkp-gt-default-tags-mode)
        (bmkp-gt-default-tags-on-jump nil)
        (reader-called nil))
    (unwind-protect
        (cl-letf (((symbol-function 'bmkp-read-tags-completing)
                   (lambda (&rest _) (setq reader-called t) '("should-not-read"))))
          (bmkp-gt-default-tags-mode -1)
          (should-error (call-interactively #'bmkp-gt-default-tags-set-on-jump)
                        :type 'user-error)
          (should-not reader-called))
      (bmkp-gt-default-tags-mode (if was-on 1 -1)))))

(ert-deftest bmkp-gt-test-default-tags/set-on-jump-appends-nil-on-yes ()
  "When the untagged follow-up gets `y', nil is appended to the tag list."
  (let ((bmkp-gt-default-tags-on-jump nil)
        (bmkp-gt-default-tags-confirm-set nil))
    (cl-letf (((symbol-function 'bmkp-read-tags-completing)
               (lambda (&rest _) '("work")))
              ((symbol-function 'y-or-n-p)
               ;; Only expected question is `Also match untagged?'.
               (lambda (&rest _) t))
              ((symbol-function 'message) #'ignore))
      (call-interactively #'bmkp-gt-default-tags-set-on-jump))
    (should (equal '("work" nil) bmkp-gt-default-tags-on-jump))))

(ert-deftest bmkp-gt-test-default-tags/set-on-jump-omits-nil-on-no ()
  "When the untagged follow-up gets `n', nil is NOT appended."
  (let ((bmkp-gt-default-tags-on-jump nil)
        (bmkp-gt-default-tags-confirm-set nil))
    (cl-letf (((symbol-function 'bmkp-read-tags-completing)
               (lambda (&rest _) '("work")))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) nil))
              ((symbol-function 'message) #'ignore))
      (call-interactively #'bmkp-gt-default-tags-set-on-jump))
    (should (equal '("work") bmkp-gt-default-tags-on-jump))))

(ert-deftest bmkp-gt-test-default-tags/set-on-jump-untagged-only ()
  "Empty tag reader + `y' to untagged → `(nil)' (only untagged bookmarks)."
  (let ((bmkp-gt-default-tags-on-jump nil)
        (bmkp-gt-default-tags-confirm-set nil))
    (cl-letf (((symbol-function 'bmkp-read-tags-completing)
               (lambda (&rest _) nil))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) t))
              ((symbol-function 'message) #'ignore))
      (call-interactively #'bmkp-gt-default-tags-set-on-jump))
    (should (equal '(nil) bmkp-gt-default-tags-on-jump))))

(ert-deftest bmkp-gt-test-default-tags/set-on-create-does-not-ask-untagged ()
  "The `-set-on-create' setter does not ask about untagged — nil is meaningless
on the create side."
  (let ((bmkp-gt-default-tags-on-create nil)
        (bmkp-gt-default-tags-confirm-set nil)
        (y-called nil))
    (cl-letf (((symbol-function 'bmkp-read-tags-completing)
               (lambda (&rest _) '("work")))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq y-called t) t))
              ((symbol-function 'message) #'ignore))
      (call-interactively #'bmkp-gt-default-tags-set-on-create))
    (should-not y-called)
    (should (equal '("work") bmkp-gt-default-tags-on-create))))

(ert-deftest bmkp-gt-test-default-tags/interactive-skips-confirm-when-off ()
  "With `confirm-set' nil, the overwrite y/n is skipped even when the
current value is non-nil.  Tested on the create setter, which does not
also ask the untagged y/n."
  (let ((bmkp-gt-default-tags-on-create '("prior"))
        (bmkp-gt-default-tags-confirm-set nil)
        (y-or-n-p-called nil))
    (cl-letf (((symbol-function 'bmkp-read-tags-completing)
               (lambda (&rest _) '("no-prompt")))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq y-or-n-p-called t) t))
              ((symbol-function 'message) #'ignore))
      (call-interactively #'bmkp-gt-default-tags-set-on-create))
    (should-not y-or-n-p-called)
    (should (equal '("no-prompt") bmkp-gt-default-tags-on-create))))


(provide 'bmkp-gt-test-default-tags)
;;; bmkp-gt-test-default-tags.el ends here
