;;; bmkp-gt-test-entry.el --- Tests for entry-point commands   -*- lexical-binding: t -*-

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
  "The jump-via advice is installed by loading the entry point."
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


(ert-deftest bmkp-gt-test-relocate/copies-mode-specific-fields ()
  "Relocate uses the buffer's `bookmark-make-record-function' and copies
mode-specific fields (magit-like: no filename dependency on
`buffer-file-name', custom keys).  Regression: before switching to the
buffer-local recorder, this raised `bookmark-buffer-file-name: Buffer
not visiting a file or directory' in non-file buffers."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer src "hello"
      (bmkp-gt-test--make-bookmark "mode-target" src 1))
    (let ((magit-like-buf (generate-new-buffer " *bmkp-gt-test-magit*")))
      (unwind-protect
          (with-current-buffer magit-like-buf
            ;; Simulate a magit-style buffer: no `buffer-file-name',
            ;; custom `bookmark-make-record-function' returning fields
            ;; that don't route through `bookmark-buffer-file-name'.
            (setq-local bookmark-make-record-function
                        (lambda ()
                          '("magit-view"
                            (filename . "/some/repo/")
                            (position . 42)
                            (magit-hidden-sections . ((untracked)))
                            (handler . my-magit-handler))))
            ;; Must not raise `bookmark-buffer-file-name' error.
            (bmkp-gt-relocate-here "mode-target"))
        (kill-buffer magit-like-buf)))
    (should (= 42 (bookmark-prop-get "mode-target" 'position)))
    (should (equal "/some/repo/"
                   (bookmark-prop-get "mode-target" 'filename)))
    (should (equal '((untracked))
                   (bookmark-prop-get "mode-target" 'magit-hidden-sections)))
    (should (eq 'my-magit-handler
                (bookmark-prop-get "mode-target" 'handler)))))


(ert-deftest bmkp-gt-test-relocate/moves-fringe-mark ()
  "Relocation moves the built-in fringe overlay to the new position."
  (let ((bookmark-set-fringe-mark 'bookmark-mark))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "aaa\nbbb\nccc\n"
        (bmkp-gt-test--make-bookmark "movef-rel" buf 1)
        ;; Move point past the first line and relocate.
        (with-current-buffer buf
          (goto-char 5)  ; inside "bbb"
          (bmkp-gt-relocate-here "movef-rel"))
        (let ((positions
               (with-current-buffer buf
                 (sort (mapcar #'overlay-start
                               (seq-filter
                                (lambda (o) (eq 'bookmark (overlay-get o 'category)))
                                (overlays-in (point-min) (point-max))))
                       #'<))))
          (should (= 1 (length positions)))
          (should (= 5 (car positions))))))))


;;; bmkp-gt-relocate-this-file-here ------------------------------------

(ert-deftest bmkp-gt-test-relocate-this-file/single-match-updates-fields ()
  "One bookmark for the current file: relocated non-interactively."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "hello\nworld\n"
      (bmkp-gt-test--make-bookmark "only" buf 1)
      (let ((end (with-current-buffer buf
                   (goto-char (point-max))
                   (point-max))))
        (with-current-buffer buf
          (bmkp-gt-relocate-this-file-here "only"))
        (should (= end (bookmark-prop-get "only" 'position)))))))

(ert-deftest bmkp-gt-test-relocate-this-file/handler-specific-bookmark-qualifies ()
  "Bookmarks with mode-specific handlers (e.g. `org-bookmark-heading-jump')
whose `filename' resolves to the current buffer's file are visible to
`bmkp-gt-relocate-this-file-here'.  Regression: upstream's
`bmkp-this-file-p' filters them out via `bmkp-file-bookmark-p'."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "hello\n"
      (bmkp-gt-test--make-bookmark "org-heading-like" buf 1)
      ;; Give it a handler upstream's `bmkp-file-bookmark-p' rejects.
      (bookmark-prop-set "org-heading-like" 'handler
                         'org-bookmark-heading-jump)
      (with-current-buffer buf
        ;; Should be found by the scoped predicate — no error.
        (let ((matches (bmkp-gt--this-location-alist-only)))
          (should (assoc "org-heading-like" matches)))
        ;; End-to-end: the command auto-selects it (single match)
        ;; and relocates.  Would signal `user-error' with upstream's
        ;; filter.
        (goto-char (point-max))
        (bmkp-gt-relocate-this-file-here "org-heading-like")
        (should (= (point-max)
                   (bookmark-prop-get "org-heading-like" 'position)))))))

(ert-deftest bmkp-gt-test-relocate-this-file/errors-when-no-match ()
  "No bookmarks for the current buffer: user-error, no state change."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "content\n"
      (with-current-buffer buf
        (should-error (call-interactively #'bmkp-gt-relocate-this-file-here)
                      :type 'user-error)))))


;;; State-file persistence backend --------------------------------------

(defmacro bmkp-gt-test-state--with-scratch-state-file (var &rest body)
  "Bind VAR to a fresh state-file path (not yet created); run BODY.
Cleans up the file if BODY (or the advice) created it."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-name
                (expand-file-name "bmkp-gt-state-"
                                  temporary-file-directory))))
     (unwind-protect (progn ,@body)
       (when (file-exists-p ,var) (delete-file ,var)))))

(ert-deftest bmkp-gt-test-state/intercepted-symbol-writes-to-state-file ()
  "Intercepted symbols route to `bmkp-gt-state-file', bypassing `custom-file'."
  (bmkp-gt-test-state--with-scratch-state-file state-file
    (let ((bmkp-gt-state-file state-file)
          (bmkp-gt--persisted-vars '(bmkp-gt-test--fake-var))
          (custom-save-called nil))
      (cl-letf (((symbol-function 'custom-save-all)
                 (lambda () (setq custom-save-called t))))
        (customize-save-variable 'bmkp-gt-test--fake-var 42))
      (should-not custom-save-called)
      (should (file-readable-p state-file))
      (with-temp-buffer
        (insert-file-contents state-file)
        (should (string-match-p "bmkp-gt-test--fake-var 42" (buffer-string)))))))

(ert-deftest bmkp-gt-test-state/non-intercepted-does-not-write-state-file ()
  "For a symbol not in `bmkp-gt--persisted-vars', the advice must not
touch `bmkp-gt-state-file' — it delegates to the original."
  (bmkp-gt-test-state--with-scratch-state-file state-file
    (let ((bmkp-gt-state-file state-file)
          (bmkp-gt--persisted-vars '()))
      ;; Stub the original so we don't actually mutate `custom-file'.
      (cl-letf* ((orig (advice--cd*r (symbol-function 'customize-save-variable)))
                 ((symbol-function 'customize-save-variable-original)
                  (lambda (&rest _) nil)))
        ;; Call the advised form; since our allowlist is empty, the
        ;; advice must fall through to ORIG.  We don't assert what
        ;; ORIG does — only that our state file is untouched.
        (ignore-errors
          (customize-save-variable 'bmkp-gt-test--other-var 99)))
      (should-not (file-exists-p state-file)))))

(ert-deftest bmkp-gt-test-state/roundtrip-write-then-load ()
  "State written via the advice is restored by `bmkp-gt-load-state'."
  (bmkp-gt-test-state--with-scratch-state-file state-file
    (let ((bmkp-gt-state-file state-file)
          (bmkp-gt--persisted-vars '(bmkp-gt-test--roundtrip-var)))
      (cl-letf (((symbol-function 'custom-save-all) #'ignore))
        (customize-save-variable 'bmkp-gt-test--roundtrip-var "sentinel-value"))
      ;; Simulate a restart: unbind the var, then load.
      (when (boundp 'bmkp-gt-test--roundtrip-var)
        (makunbound 'bmkp-gt-test--roundtrip-var))
      (bmkp-gt-load-state)
      (should (equal "sentinel-value"
                     (and (boundp 'bmkp-gt-test--roundtrip-var)
                          (symbol-value 'bmkp-gt-test--roundtrip-var)))))))


(provide 'bmkp-gt-test-entry)
;;; bmkp-gt-test-entry.el ends here
