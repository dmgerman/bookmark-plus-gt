;;; bmkp-gt-test-umbrella.el --- Tests for umbrella-level commands   -*- lexical-binding: t -*-

;;; Code:

(require 'bmkp-gt-test-helper)
(require 'bookmark-plus-gt)
(require 'cl-lib)


;;; bmkp-gt-relocate-here ----------------------------------------------

(ert-deftest bmkp-gt-test-relocate/updates-location-fields ()
  "`bmkp-gt-relocate-here' points BOOKMARK at the current file/point."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer src "one\ntwo\nthree\n"
      (bmkp-gt-test--make-bookmark "moving" src 1)
      (bmkp-gt-test-with-fixture-buffer dst "AAAA\nBBBB\nCCCC\n"
        (let ((dst-file (buffer-file-name dst))
              (target   (with-current-buffer dst
                          (goto-char 6)
                          (point))))
          (with-current-buffer dst
            (bmkp-gt-relocate-here "moving"))
          (should (equal dst-file
                         (expand-file-name
                          (bookmark-prop-get "moving" 'filename))))
          (should (= target (bookmark-prop-get "moving" 'position)))
          (should (= target (bookmark-prop-get "moving" 'end-position))))))))

(ert-deftest bmkp-gt-test-relocate/preserves-name-tags-annotation ()
  "Non-location fields (tags, annotation, custom props) survive relocation."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer src "hello world\n"
      (bmkp-gt-test--make-bookmark "keep" src 1)
      (bmkp-add-tags "keep" '("alpha" "beta") 'NO-UPDATE-P)
      (bookmark-prop-set "keep" 'annotation "hand-written note")
      (bookmark-prop-set "keep" 'auto-update t)
      (bmkp-gt-test-with-fixture-buffer dst "over here\n"
        (with-current-buffer dst
          (goto-char (point-max))
          (bmkp-gt-relocate-here "keep"))
        (should (member "alpha" (mapcar (lambda (tag) (if (consp tag) (car tag) tag))
                                        (bookmark-prop-get "keep" 'tags))))
        (should (member "beta"  (mapcar (lambda (tag) (if (consp tag) (car tag) tag))
                                        (bookmark-prop-get "keep" 'tags))))
        (should (equal "hand-written note" (bookmark-prop-get "keep" 'annotation)))
        (should (eq t (bookmark-prop-get "keep" 'auto-update)))
        (should (assoc "keep" bookmark-alist))))))

(ert-deftest bmkp-gt-test-relocate/sets-auto-update-on-prefix ()
  "Non-nil second arg (prefix arg) sets the `auto-update' property."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer src "hi"
      (bmkp-gt-test--make-bookmark "opt-in" src 1))
    (bmkp-gt-test-with-fixture-buffer dst "hello"
      (with-current-buffer dst
        (bmkp-gt-relocate-here "opt-in" 'auto-update))
      (should (eq t (bookmark-prop-get "opt-in" 'auto-update))))))

(ert-deftest bmkp-gt-test-relocate/no-auto-update-without-prefix ()
  "Without the prefix arg, `auto-update' is not touched."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer src "hi"
      (bmkp-gt-test--make-bookmark "no-opt-in" src 1))
    (bmkp-gt-test-with-fixture-buffer dst "hello"
      (with-current-buffer dst
        (bmkp-gt-relocate-here "no-opt-in"))
      (should-not (bookmark-prop-get "no-opt-in" 'auto-update)))))

(ert-deftest bmkp-gt-test-relocate/pins-end-position ()
  "After relocation, `end-position' equals `position' — no region-restore path."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer src "abc"
      (bmkp-gt-test--make-bookmark "range" src 1)
      ;; Simulate a stale region shape: pos != end-pos, no region contexts.
      (bookmark-prop-set "range" 'end-position 42)
      (bmkp-gt-test-with-fixture-buffer dst "1234567890"
        (with-current-buffer dst
          (goto-char 5)
          (bmkp-gt-relocate-here "range"))
        (let ((pos (bookmark-prop-get "range" 'position))
              (end (bookmark-prop-get "range" 'end-position)))
          (should (= pos end)))))))


;;; Bug 1 whitelist (bmkp-gt-jump-display--*) -------------------------
;;
;; The advice calls DISPLAY-FUNCTION iff the handler is NOT in
;; `bmkp-gt-jump-via-displays-itself'.  Tests exercise both branches
;; end-to-end via `bookmark-jump'.

(ert-deftest bmkp-gt-test-jd/advice-installed ()
  "The jump-via advice is installed by loading the umbrella."
  (should (advice-member-p 'bmkp-gt-jump-display--jump-via-advice
                           'bookmark--jump-via)))

(ert-deftest bmkp-gt-test-jd/whitelist-includes-nil-and-default ()
  "The whitelist includes the sentinel values for the default handler path."
  (should (memq nil                       bmkp-gt-jump-via-displays-itself))
  (should (memq 'bookmark-default-handler bmkp-gt-jump-via-displays-itself)))

(ert-deftest bmkp-gt-test-jd/off-whitelist-handler-gets-display ()
  "A handler NOT on the whitelist has DISPLAY-FUNCTION called on it."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer target "hello target\n"
      (let ((target-buf-name (buffer-name target)))
        (cl-letf (((symbol-function 'my-set-buffer-handler)
                   (lambda (_bmk)
                     (set-buffer (get-buffer target-buf-name)))))
          (bmkp-gt-test--make-bookmark "off-list" target 1)
          (bookmark-prop-set "off-list" 'handler 'my-set-buffer-handler)
          (with-temp-buffer
            (let ((displayed nil))
              (cl-letf (((symbol-function 'switch-to-buffer)
                         (lambda (buf &rest _) (setq displayed buf))))
                (bookmark-jump "off-list" #'switch-to-buffer))
              (should (eq displayed target)))))))))

(ert-deftest bmkp-gt-test-jd/on-whitelist-handler-does-not-get-display ()
  "A handler ON the whitelist does not have DISPLAY-FUNCTION called on it."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer target "hello target\n"
      (let ((target-buf-name (buffer-name target))
            (bmkp-gt-jump-via-displays-itself
             (cons 'my-well-behaved-handler bmkp-gt-jump-via-displays-itself)))
        (cl-letf (((symbol-function 'my-well-behaved-handler)
                   (lambda (_bmk)
                     (set-buffer (get-buffer target-buf-name)))))
          (bmkp-gt-test--make-bookmark "on-list" target 1)
          (bookmark-prop-set "on-list" 'handler 'my-well-behaved-handler)
          (with-temp-buffer
            (let ((displayed nil))
              (cl-letf (((symbol-function 'switch-to-buffer)
                         (lambda (buf &rest _) (setq displayed buf))))
                (bookmark-jump "on-list" #'switch-to-buffer))
              (should-not displayed))))))))

(ert-deftest bmkp-gt-test-jd/restores-display-function-var ()
  "The advice restores `bmkp-jump-display-function' to its prior value."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer target "hello target\n"
      (let ((target-buf-name (buffer-name target))
            (bmkp-jump-display-function 'sentinel-outer))
        (cl-letf (((symbol-function 'my-set-buffer-handler-2)
                   (lambda (_bmk)
                     (set-buffer (get-buffer target-buf-name))))
                  ((symbol-function 'switch-to-buffer)
                   (lambda (&rest _) nil)))
          (bmkp-gt-test--make-bookmark "restores" target 1)
          (bookmark-prop-set "restores" 'handler 'my-set-buffer-handler-2)
          (bookmark-jump "restores" #'switch-to-buffer)
          (should (eq 'sentinel-outer bmkp-jump-display-function)))))))


(provide 'bmkp-gt-test-umbrella)
;;; bmkp-gt-test-umbrella.el ends here
