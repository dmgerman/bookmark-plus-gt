;;; bmkp-gt-test-browsel-tabs.el --- Tests for bookmark-plus-gt-browsel-tabs   -*- lexical-binding: t -*-
;;
;; Runs against a stub `browsel' (test/browsel-stub.el).  Each test
;; overrides the four browsel functions we care about via `cl-letf'
;; to simulate specific browser state.

;;; Code:

(require 'bmkp-gt-test-helper)
(require 'bookmark-plus-gt-browsel-tabs)
(require 'cl-lib)


;;; Helpers ------------------------------------------------------------

(defun bmkp-gt-test-btabs--make-tab (id url title &optional browser)
  "Return a browsel tab plist for tests."
  (list :id id
        :url url
        :title title
        :browsel-browser (or browser "chrome")))

(defmacro bmkp-gt-test-btabs--with-tabs (tabs &rest body)
  "Run BODY with `browsel-browser-tabs' stubbed to return TABS."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'browsel-browser-tabs)
              (lambda (&rest _) ,tabs)))
     ,@body))


;;; Predicate ---------------------------------------------------------

(ert-deftest bmkp-gt-test-btabs/predicate-true-for-browsel-record ()
  "`bmkp-gt-browsel-tabs-p' returns non-nil for a browsel-tab record."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A"))
     (bmkp-gt-browsel-tabs-refresh))
    (let ((bmk  (assoc "A" bookmark-alist)))
      (should bmk)
      (should (bmkp-gt-browsel-tabs-p bmk)))))

(ert-deftest bmkp-gt-test-btabs/predicate-false-for-plain-record ()
  "`bmkp-gt-browsel-tabs-p' returns nil for a non-browsel bookmark."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "hello"
      (bmkp-gt-test--make-bookmark "plain" buf))
    (let ((bmk  (assoc "plain" bookmark-alist)))
      (should bmk)
      (should-not (bmkp-gt-browsel-tabs-p bmk)))))


;;; Unique-name -------------------------------------------------------

(ert-deftest bmkp-gt-test-btabs/unique-name-passthrough-when-free ()
  "`bmkp-gt-browsel-tabs--unique-name' returns BASE unchanged when unused."
  (bmkp-gt-test-with-clean-bookmarks
    (should (equal "Foo" (bmkp-gt-browsel-tabs--unique-name "Foo")))))

(ert-deftest bmkp-gt-test-btabs/unique-name-suffix-on-collision ()
  "Collisions get `<2>', `<3>', ... suffixes in order."
  (bmkp-gt-test-with-clean-bookmarks
    (push (cons "Foo" '((filename . "/tmp/x"))) bookmark-alist)
    (should (equal "Foo<2>" (bmkp-gt-browsel-tabs--unique-name "Foo")))
    (push (cons "Foo<2>" '((filename . "/tmp/x"))) bookmark-alist)
    (should (equal "Foo<3>" (bmkp-gt-browsel-tabs--unique-name "Foo")))))


;;; Filter ------------------------------------------------------------

(ert-deftest bmkp-gt-test-btabs/allow-p-nil-includes-everything ()
  "`nil' filter includes every tab."
  (let ((bmkp-gt-browsel-tabs-filter  nil))
    (should (bmkp-gt-browsel-tabs--allow-p
             (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A")))))

(ert-deftest bmkp-gt-test-btabs/allow-p-regexp-matches-url ()
  "Regexp filter matches against the tab URL."
  (let ((bmkp-gt-browsel-tabs-filter  "example\\.com"))
    (should (bmkp-gt-browsel-tabs--allow-p
             (bmkp-gt-test-btabs--make-tab 1 "https://example.com/x" "X")))
    (should-not (bmkp-gt-browsel-tabs--allow-p
                 (bmkp-gt-test-btabs--make-tab 2 "https://other.com/y" "Y")))))

(ert-deftest bmkp-gt-test-btabs/allow-p-function-called-with-tab ()
  "Function filter is called with the tab plist; non-nil return keeps."
  (let* ((seen  nil)
         (bmkp-gt-browsel-tabs-filter
          (lambda (tab) (push tab seen) (equal (plist-get tab :id) 42))))
    (should (bmkp-gt-browsel-tabs--allow-p
             (bmkp-gt-test-btabs--make-tab 42 "https://a.com" "A")))
    (should-not (bmkp-gt-browsel-tabs--allow-p
                 (bmkp-gt-test-btabs--make-tab 7 "https://a.com" "A")))
    (should (= 2 (length seen)))))


;;; Store record shape ------------------------------------------------

(ert-deftest bmkp-gt-test-btabs/store-name-uses-title ()
  "The stored bookmark name is the tab title when present."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "My Tab"))
     (bmkp-gt-browsel-tabs-refresh))
    (should (assoc "My Tab" bookmark-alist))))

(ert-deftest bmkp-gt-test-btabs/store-name-falls-back-to-url ()
  "Empty title falls back to the URL as the bookmark name."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" ""))
     (bmkp-gt-browsel-tabs-refresh))
    (should (assoc "https://a.com" bookmark-alist))))

(ert-deftest bmkp-gt-test-btabs/store-location-is-url ()
  "The `location' slot is the tab URL."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A"))
     (bmkp-gt-browsel-tabs-refresh))
    (let ((bmk  (assoc "A" bookmark-alist)))
      (should (equal "https://a.com" (bookmark-prop-get bmk 'location))))))

(ert-deftest bmkp-gt-test-btabs/store-handler-is-jump-fn ()
  "The `handler' slot points at our jump handler."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A"))
     (bmkp-gt-browsel-tabs-refresh))
    (let ((bmk  (assoc "A" bookmark-alist)))
      (should (eq 'bmkp-gt-browsel-tabs-jump (bookmark-get-handler bmk))))))

(ert-deftest bmkp-gt-test-btabs/store-attaches-browser-tag ()
  "The tab's owning browser is attached as a tag."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A" "firefox"))
     (bmkp-gt-browsel-tabs-refresh))
    (let ((bmk  (assoc "A" bookmark-alist)))
      (should (equal '("firefox") (bmkp-get-tags bmk))))))

(ert-deftest bmkp-gt-test-btabs/store-marks-record-temporary ()
  "The stored record has `bmkp-temp' set (never saved to disk)."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A"))
     (bmkp-gt-browsel-tabs-refresh))
    (let ((bmk  (assoc "A" bookmark-alist)))
      (should (bmkp-temporary-bookmark-p bmk)))))

(ert-deftest bmkp-gt-test-btabs/store-annotation-is-title ()
  "The `annotation' slot is the tab title."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A Title"))
     (bmkp-gt-browsel-tabs-refresh))
    (let ((bmk  (assoc "A Title" bookmark-alist)))
      (should (equal "A Title" (bookmark-get-annotation bmk))))))


;;; Refresh -----------------------------------------------------------

(ert-deftest bmkp-gt-test-btabs/refresh-idempotent ()
  "Two successive refreshes leave the same count of browsel-tab bookmarks."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A")
           (bmkp-gt-test-btabs--make-tab 2 "https://b.com" "B"))
     (bmkp-gt-browsel-tabs-refresh)
     (bmkp-gt-browsel-tabs-refresh))
    (should (= 2 (cl-count-if #'bmkp-gt-browsel-tabs-p bookmark-alist)))))

(ert-deftest bmkp-gt-test-btabs/refresh-drops-vanished-tabs ()
  "Rows disappear from the alist when the underlying tab is gone."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A")
           (bmkp-gt-test-btabs--make-tab 2 "https://b.com" "B"))
     (bmkp-gt-browsel-tabs-refresh))
    (should (= 2 (cl-count-if #'bmkp-gt-browsel-tabs-p bookmark-alist)))
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A"))
     (bmkp-gt-browsel-tabs-refresh))
    (should (= 1 (cl-count-if #'bmkp-gt-browsel-tabs-p bookmark-alist)))
    (should-not (assoc "B" bookmark-alist))))

(ert-deftest bmkp-gt-test-btabs/refresh-preserves-non-browsel-bookmarks ()
  "Refresh does not touch bookmarks with a different handler."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "hi"
      (bmkp-gt-test--make-bookmark "keep-me" buf))
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A"))
     (bmkp-gt-browsel-tabs-refresh))
    (should (assoc "keep-me" bookmark-alist))
    (should (assoc "A" bookmark-alist))))

(ert-deftest bmkp-gt-test-btabs/refresh-fetch-error-warns-and-returns ()
  "A fetch error is swallowed into a warning; the alist is left empty of tabs."
  (bmkp-gt-test-with-clean-bookmarks
    (cl-letf (((symbol-function 'browsel-browser-tabs)
               (lambda (&rest _) (error "boom"))))
      ;; Must not signal.
      (bmkp-gt-browsel-tabs-refresh))
    (should (= 0 (cl-count-if #'bmkp-gt-browsel-tabs-p bookmark-alist)))))

(ert-deftest bmkp-gt-test-btabs/refresh-skips-empty-url ()
  "Tabs with no URL are dropped even when the title is present."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (list :id 1 :url "" :title "empty" :browsel-browser "chrome")
           (bmkp-gt-test-btabs--make-tab 2 "https://a.com" "A"))
     (bmkp-gt-browsel-tabs-refresh))
    (should (= 1 (cl-count-if #'bmkp-gt-browsel-tabs-p bookmark-alist)))
    (should (assoc "A" bookmark-alist))))


;;; URL/Web subtype wiring --------------------------------------------

(ert-deftest bmkp-gt-test-btabs/url-bookmark-p-matches-browsel-record ()
  "`bmkp-url-bookmark-p' returns non-nil for browsel-tab records via advice."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A"))
     (bmkp-gt-browsel-tabs-refresh))
    (let ((bmk  (assoc "A" bookmark-alist)))
      (should (bmkp-url-bookmark-p bmk)))))


;;; Handler -----------------------------------------------------------

(ert-deftest bmkp-gt-test-btabs/jump-calls-focus-tab ()
  "The handler calls `browsel-focus-tab' with the record's id and browser."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 42 "https://a.com" "A" "firefox"))
     (bmkp-gt-browsel-tabs-refresh))
    (let* ((bmk       (assoc "A" bookmark-alist))
           (calls     nil))
      (cl-letf (((symbol-function 'browsel-focus-tab)
                 (lambda (tab &optional focus)
                   (push (list :tab tab :focus focus) calls))))
        (bmkp-gt-browsel-tabs-jump bmk))
      (should (= 1 (length calls)))
      (let ((call  (car calls)))
        (should (equal 42 (plist-get (plist-get call :tab) :id)))
        (should (equal "firefox"
                       (plist-get (plist-get call :tab) :browsel-browser)))
        (should (plist-get call :focus))))))

(ert-deftest bmkp-gt-test-btabs/jump-falls-back-to-browse-url ()
  "On `user-error' from `browsel-focus-tab', the handler calls
`browsel-browse-url' with the recorded URL."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A"))
     (bmkp-gt-browsel-tabs-refresh))
    (let* ((bmk       (assoc "A" bookmark-alist))
           (browsed   nil))
      (cl-letf (((symbol-function 'browsel-focus-tab)
                 (lambda (&rest _) (user-error "closed")))
                ((symbol-function 'browsel-browse-url)
                 (lambda (url) (setq browsed url))))
        (bmkp-gt-browsel-tabs-jump bmk))
      (should (equal "https://a.com" browsed)))))


;;; Delete-advice -----------------------------------------------------

(ert-deftest bmkp-gt-test-btabs/delete-closes-tab-and-removes-record ()
  "Deleting a browsel-tab bookmark calls `browsel-close-tab' and drops the record."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 99 "https://a.com" "A" "chrome"))
     (bmkp-gt-browsel-tabs-refresh))
    (should (assoc "A" bookmark-alist))
    (let ((closed  nil))
      (cl-letf (((symbol-function 'browsel-close-tab)
                 (lambda (tab) (setq closed tab)))
                ;; `bookmark-delete' triggers a rebuild; suppress it here.
                ((symbol-function 'bmkp-refresh/rebuild-menu-list) #'ignore))
        (bookmark-delete "A"))
      (should closed)
      (should (equal 99 (plist-get closed :id)))
      (should (equal "chrome" (plist-get closed :browsel-browser))))
    (should-not (assoc "A" bookmark-alist))))

(ert-deftest bmkp-gt-test-btabs/delete-non-browsel-bookmark-does-not-call-close ()
  "Non-browsel bookmarks pass through the delete-advice untouched."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "hi"
      (bmkp-gt-test--make-bookmark "plain" buf))
    (let ((closed  nil))
      (cl-letf (((symbol-function 'browsel-close-tab)
                 (lambda (tab) (setq closed tab)))
                ((symbol-function 'bmkp-refresh/rebuild-menu-list) #'ignore))
        (bookmark-delete "plain"))
      (should-not closed))))

(ert-deftest bmkp-gt-test-btabs/delete-close-error-does-not-block-deletion ()
  "An error inside `browsel-close-tab' is demoted; the bookmark is still removed."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A"))
     (bmkp-gt-browsel-tabs-refresh))
    (should (assoc "A" bookmark-alist))
    (cl-letf (((symbol-function 'browsel-close-tab)
               (lambda (_tab) (error "browser gone")))
              ((symbol-function 'bmkp-refresh/rebuild-menu-list) #'ignore))
      (bookmark-delete "A"))
    (should-not (assoc "A" bookmark-alist))))


;;; Register-jump-narrow -----------------------------------------------

(ert-deftest bmkp-gt-test-btabs/jump-narrow-has-browser-tab-entry ()
  "`?b Browser tab' is registered in `bmkp-gt-jump-narrow' when preview is loaded."
  (should (assoc ?b bmkp-gt-jump-narrow))
  (let ((entry  (assoc ?b bmkp-gt-jump-narrow)))
    (should (equal "Browser tab" (cadr entry)))
    (should (memq 'bmkp-gt-browsel-tabs-jump (cddr entry)))))


;;; Auto-refresh advice defensiveness ----------------------------------

(ert-deftest bmkp-gt-test-btabs/auto-refresh-swallows-errors ()
  "`bmkp-gt-browsel-tabs--auto-refresh' does not signal when refresh errors."
  ;; Force `bmkp-gt-browsel-tabs-refresh' to throw and confirm the hook does not.
  (cl-letf (((symbol-function 'bmkp-gt-browsel-tabs-refresh)
             (lambda () (error "boom"))))
    ;; Must not raise.
    (bmkp-gt-browsel-tabs--auto-refresh)))


;;; browsel-tab type predicate helper ----------------------------------

(ert-deftest bmkp-gt-test-btabs/predicate-accepts-string-name ()
  "The predicate resolves a string NAME through `bookmark-get-handler'."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-btabs--with-tabs
     (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A"))
     (bmkp-gt-browsel-tabs-refresh))
    (should (bmkp-gt-browsel-tabs-p "A"))))


;;; Interactive delete flow (d + x through *Bookmark List*) -----------

(ert-deftest bmkp-gt-test-btabs/dx-flow-removes-record-and-closes-tab ()
  "Marking a browsel-tab row with `d' and pressing `x' via
`bookmark-bmenu-execute-deletions' calls `browsel-close-tab' AND
removes the record from `bookmark-alist' — even after the mid-flow
rebuild triggers our auto-refresh (which may re-query
`browsel-browser-tabs' and re-populate).

Uses coordinated mocks for both `browsel-browser-tabs' and
`browsel-close-tab' so a `close' actually removes the tab from the
live tab list; that models the real-browser behavior and ensures
the auto-refresh does not resurrect the row we just deleted."
  (bmkp-gt-test-with-clean-bookmarks
    (let ((live-tabs  (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A")
                            (bmkp-gt-test-btabs--make-tab 2 "https://b.com" "B")
                            (bmkp-gt-test-btabs--make-tab 3 "https://c.com" "C")))
          (closed     nil))
      (cl-letf (((symbol-function 'browsel-browser-tabs)
                 (lambda (&rest _) live-tabs))
                ((symbol-function 'browsel-close-tab)
                 (lambda (tab)
                   (setq closed (append closed (list tab)))
                   ;; Simulate the browser really closing the tab.
                   (setq live-tabs
                         (cl-remove-if
                          (lambda (t2) (equal (plist-get t2 :id)
                                              (plist-get tab :id)))
                          live-tabs)))))
        (bmkp-gt-browsel-tabs-refresh)
        (should (= 3 (cl-count-if #'bmkp-gt-browsel-tabs-p bookmark-alist)))
        (unwind-protect
            (progn
              (bookmark-bmenu-list)
              (with-current-buffer bmkp-bmenu-buffer
                (bmkp-bmenu-goto-bookmark-named "B")
                (bmkp-bmenu-flag-for-deletion)
                ;; Emulate `x' — mark-flow deletion.
                (bookmark-bmenu-execute-deletions))
              ;; browsel-close-tab was called once, with tab B.
              (should (= 1 (length closed)))
              (should (equal 2 (plist-get (car closed) :id)))
              ;; The record is gone from the alist.
              (should-not (assoc "B" bookmark-alist))
              ;; The other two tabs are still there.
              (should (assoc "A" bookmark-alist))
              (should (assoc "C" bookmark-alist))
              (should (= 2 (cl-count-if #'bmkp-gt-browsel-tabs-p bookmark-alist))))
          (when (get-buffer bmkp-bmenu-buffer)
            (kill-buffer bmkp-bmenu-buffer)))))))

(ert-deftest bmkp-gt-test-btabs/dx-flow-stale-fetch-does-not-resurrect ()
  "If the auto-refresh's `browsel-browser-tabs' still reports the
deleted tab (browser hasn't yet propagated the close), the D+x flow
must still leave the record deleted at the end of the operation.

Regression scenario: an auto-refresh fired by
`bookmark-bmenu-surreptitiously-rebuild-list' re-populates the
alist with the tab we just closed, so the user sees the bookmark
still in place.  This test simulates that condition and asserts
the row does NOT come back."
  (bmkp-gt-test-with-clean-bookmarks
    (let ((tabs  (list (bmkp-gt-test-btabs--make-tab 1 "https://a.com" "A")
                       (bmkp-gt-test-btabs--make-tab 2 "https://b.com" "B"))))
      (cl-letf (((symbol-function 'browsel-browser-tabs)
                 (lambda (&rest _) tabs))
                ;; `close' does NOT remove from `tabs' — the browser is
                ;; still catching up.
                ((symbol-function 'browsel-close-tab) #'ignore))
        (bmkp-gt-browsel-tabs-refresh)
        (should (= 2 (cl-count-if #'bmkp-gt-browsel-tabs-p bookmark-alist)))
        (unwind-protect
            (progn
              (bookmark-bmenu-list)
              (with-current-buffer bmkp-bmenu-buffer
                (bmkp-bmenu-goto-bookmark-named "B")
                (bmkp-bmenu-flag-for-deletion)
                (bookmark-bmenu-execute-deletions))
              ;; Even though browsel still reports B as open, the record
              ;; must be gone.  Otherwise the user's "delete" appears
              ;; ineffective.
              (should-not (assoc "B" bookmark-alist)))
          (when (get-buffer bmkp-bmenu-buffer)
            (kill-buffer bmkp-bmenu-buffer)))))))


;;; bmkp-gt-test-browsel-tabs.el ends here
