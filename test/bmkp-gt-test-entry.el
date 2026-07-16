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


;;; Post-delete point advice on `bookmark-bmenu-execute-deletions' -----

(ert-deftest bmkp-gt-test-execute-deletions/advice-installed ()
  "`bmkp-gt--execute-deletions-around' is `:around' on the delete command."
  (should (advice-member-p 'bmkp-gt--execute-deletions-around
                           'bookmark-bmenu-execute-deletions)))

(defun bmkp-gt-test--make-bmenu-with-marks (rows)
  "Populate `bookmark-alist' with ROWS (list of (name . mark)).
`mark' is a character (?D, ?>, or ?\\s) written in column 0 of
the corresponding bookmark row.  Renders `*Bookmark List*' with
the tag/type columns off so the row structure is predictable.
Uses `bmkp-bmenu-goto-bookmark-named' to navigate to each row,
so header text can't be accidentally clobbered by a substring
match on the bookmark name.  Returns the buffer."
  (bmkp-gt-test-with-fixture-buffer buf "x"
    (dolist (row rows)
      (bmkp-gt-test--make-bookmark (car row) buf)))
  (let ((bmkp-gt-bmenu-show-tags-flag  nil)
        (bmkp-gt-bmenu-show-type-flag  nil))
    (bookmark-bmenu-list))
  (with-current-buffer bmkp-bmenu-buffer
    (let ((inhibit-read-only  t))
      (dolist (row rows)
        (bmkp-bmenu-goto-bookmark-named (car row))
        (forward-line 0)
        (unless (eq ?\s (cdr row))
          (delete-char 1)
          (insert-char (cdr row))))))
  bmkp-bmenu-buffer)

(ert-deftest bmkp-gt-test-execute-deletions/find-non-marked-row-goes-down ()
  "`bmkp-gt--find-non-marked-row' walks forward past marked rows."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test--make-bmenu-with-marks
     '(("aa" . ?D) ("bb" . ?D) ("cc" . ?\s)))
    (unwind-protect
        (with-current-buffer bmkp-bmenu-buffer
          (bmkp-bmenu-goto-bookmark-named "aa")
          (forward-line 0)
          (should (equal "cc" (bmkp-gt--find-non-marked-row 1))))
      (kill-buffer bmkp-bmenu-buffer))))

(ert-deftest bmkp-gt-test-execute-deletions/find-non-marked-row-goes-up ()
  "`bmkp-gt--find-non-marked-row' walks backward past marked rows."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test--make-bmenu-with-marks
     '(("aa" . ?\s) ("bb" . ?D) ("cc" . ?D)))
    (unwind-protect
        (with-current-buffer bmkp-bmenu-buffer
          (bmkp-bmenu-goto-bookmark-named "cc")
          (forward-line 0)
          (should (equal "aa" (bmkp-gt--find-non-marked-row -1))))
      (kill-buffer bmkp-bmenu-buffer))))

(ert-deftest bmkp-gt-test-execute-deletions/find-post-delete-target-prefers-below ()
  "`bmkp-gt--find-post-delete-target' looks below before above."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test--make-bmenu-with-marks
     '(("above" . ?\s) ("middle" . ?D) ("below" . ?\s)))
    (unwind-protect
        (with-current-buffer bmkp-bmenu-buffer
          (bmkp-bmenu-goto-bookmark-named "middle")
          (forward-line 0)
          (should (equal "below" (bmkp-gt--find-post-delete-target))))
      (kill-buffer bmkp-bmenu-buffer))))

(ert-deftest bmkp-gt-test-execute-deletions/find-post-delete-target-nil-when-alone ()
  "`bmkp-gt--find-post-delete-target' returns nil when every row is marked."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test--make-bmenu-with-marks
     '(("aa" . ?D) ("bb" . ?D) ("cc" . ?D)))
    (unwind-protect
        (with-current-buffer bmkp-bmenu-buffer
          (bmkp-bmenu-goto-bookmark-named "bb")
          (forward-line 0)
          (should-not (bmkp-gt--find-post-delete-target)))
      (kill-buffer bmkp-bmenu-buffer))))

(ert-deftest bmkp-gt-test-execute-deletions/advice-swallows-target-error ()
  "An error in the pre-pass is demoted; ORIG-FN still runs and returns."
  (cl-letf (((symbol-function 'bmkp-gt--find-post-delete-target)
             (lambda () (error "target search boom"))))
    ;; ORIG-FN's contract: return non-nil sentinel when reached.
    (cl-letf (((symbol-function 'bookmark-bmenu-execute-deletions--orig)
               (lambda (&rest _) 'called)))
      ;; Rebuild the advised function on top of the stub so `apply orig-fn'
      ;; hits our stub, not the real command.
      (let ((got  (bmkp-gt--execute-deletions-around
                   (lambda (&rest _) 'reached))))
        (should (eq 'reached got))))))

(ert-deftest bmkp-gt-test-execute-deletions/advice-swallows-navigation-error ()
  "An error in the post-pass is demoted; the return value of ORIG-FN wins."
  (cl-letf (((symbol-function 'bmkp-gt--find-post-delete-target)
             (lambda () "any-name"))
            ((symbol-function 'bmkp-bmenu-goto-bookmark-named)
             (lambda (_) (error "nav boom"))))
    (let ((got  (bmkp-gt--execute-deletions-around
                 (lambda (&rest _) 'orig-result))))
      (should (eq 'orig-result got)))))


;;; Load-order stack sort ---------------------------------------------

(ert-deftest bmkp-gt-test-load-order/counter-defined ()
  "`bmkp-gt--load-counter' starts as a non-negative integer."
  (should (boundp 'bmkp-gt--load-counter))
  (should (integerp bmkp-gt--load-counter)))

(ert-deftest bmkp-gt-test-load-order/comparer-defined ()
  "`bmkp-gt-sort-by-load-order' is a two-arg function."
  (should (fboundp 'bmkp-gt-sort-by-load-order)))

(ert-deftest bmkp-gt-test-load-order/comparer-higher-index-first ()
  "The comparer returns `(t)' when B1's load index is higher than B2's."
  (let ((b1  (list "high" '(bmkp-gt-load-index . 5)))
        (b2  (list "low"  '(bmkp-gt-load-index . 2))))
    (should (equal '(t)   (bmkp-gt-sort-by-load-order b1 b2)))
    (should (equal '(nil) (bmkp-gt-sort-by-load-order b2 b1)))))

(ert-deftest bmkp-gt-test-load-order/comparer-tie-falls-through ()
  "Same load-index returns nil (fall through to next comparer)."
  (let ((b1  (list "a" '(bmkp-gt-load-index . 3)))
        (b2  (list "b" '(bmkp-gt-load-index . 3))))
    (should (null (bmkp-gt-sort-by-load-order b1 b2)))))

(ert-deftest bmkp-gt-test-load-order/unindexed-sorts-at-top ()
  "Bookmarks with no `bmkp-gt-load-index' sort at the top."
  (let ((indexed    (list "loaded"  '(bmkp-gt-load-index . 5)))
        (unindexed  (list "in-session" '(filename . "x"))))
    (should (equal '(t)   (bmkp-gt-sort-by-load-order unindexed indexed)))
    (should (equal '(nil) (bmkp-gt-sort-by-load-order indexed  unindexed)))))

(ert-deftest bmkp-gt-test-load-order/stamp-assigns-fresh-index ()
  "`bmkp-gt--stamp-load-index' bumps the counter and stamps each bookmark."
  (let* ((bmkp-gt--load-counter  0)
         (blist  (list (list "a" '(filename . "/tmp/a"))
                       (list "b" '(filename . "/tmp/b")))))
    (bmkp-gt--stamp-load-index blist)
    (should (= 1 bmkp-gt--load-counter))
    (should (= 1 (bookmark-prop-get (car blist)  'bmkp-gt-load-index)))
    (should (= 1 (bookmark-prop-get (cadr blist) 'bmkp-gt-load-index)))))

(ert-deftest bmkp-gt-test-load-order/stamp-preserves-existing-index ()
  "A bookmark that already has `bmkp-gt-load-index' keeps its value."
  (let* ((bmkp-gt--load-counter  0)
         (pre    (list "old" '(bmkp-gt-load-index . 42) '(filename . "/tmp/a")))
         (fresh  (list "new" '(filename . "/tmp/b"))))
    (bmkp-gt--stamp-load-index (list pre fresh))
    (should (= 42 (bookmark-prop-get pre   'bmkp-gt-load-index)))
    (should (= 1  (bookmark-prop-get fresh 'bmkp-gt-load-index)))))

(ert-deftest bmkp-gt-test-load-order/stack-behavior-across-loads ()
  "Two `bookmark-load' calls tag the second file's bookmarks higher."
  (let ((bmkp-gt--load-counter  0)
        (blist-a  (list (list "a1" '(filename . "/tmp/a1"))))
        (blist-b  (list (list "b1" '(filename . "/tmp/b1")))))
    (bmkp-gt--stamp-load-index blist-a)
    (bmkp-gt--stamp-load-index blist-b)
    (let ((ia  (bookmark-prop-get (car blist-a) 'bmkp-gt-load-index))
          (ib  (bookmark-prop-get (car blist-b) 'bmkp-gt-load-index)))
      (should (< ia ib))
      (should (equal '(t) (bmkp-gt-sort-by-load-order (car blist-b) (car blist-a)))))))


;;; Overwrite-confirm guard --------------------------------------------

(ert-deftest bmkp-gt-test-safety/overwrite-confirm-set ()
  "`bmkp-bookmark-set-confirms-overwrite-p' is set to t at load time."
  (should (eq t bmkp-bookmark-set-confirms-overwrite-p)))


(provide 'bmkp-gt-test-entry)
;;; bmkp-gt-test-entry.el ends here
