;;; bmkp-gt-test-auto-update.el --- Tests for bookmark-plus-gt-auto-update   -*- lexical-binding: t -*-

;;; Code:

(require 'bmkp-gt-test-helper)
(require 'bookmark-plus-gt-auto-update)
(require 'cl-lib)


;;; Predicate + property ------------------------------------------------

(ert-deftest bmkp-gt-test-auto-update/predicate-false-by-default ()
  "A fresh bookmark does not carry the `auto-update' property."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "hello"
      (bmkp-gt-test--make-bookmark "fresh" buf))
    (let ((bmk (assoc "fresh" bookmark-alist)))
      (should-not (bmkp-gt-auto-update--enabled-p bmk)))))

(ert-deftest bmkp-gt-test-auto-update/predicate-true-after-set ()
  "Setting the `auto-update' property makes the predicate return non-nil."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "hello"
      (bmkp-gt-test--make-bookmark "on" buf))
    (bookmark-prop-set "on" 'auto-update t)
    (let ((bmk (assoc "on" bookmark-alist)))
      (should (bmkp-gt-auto-update--enabled-p bmk)))))


;;; Toggle command ------------------------------------------------------

(ert-deftest bmkp-gt-test-auto-update/toggle-sets-then-unsets ()
  "`bmkp-gt-auto-update-toggle' flips the property."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "hello"
      (bmkp-gt-test--make-bookmark "flip" buf))
    (bmkp-gt-auto-update-toggle "flip")
    (should (bookmark-prop-get "flip" 'auto-update))
    (bmkp-gt-auto-update-toggle "flip")
    (should-not (bookmark-prop-get "flip" 'auto-update))))


;;; Tick refresh --------------------------------------------------------

(ert-deftest bmkp-gt-test-auto-update/tick-updates-visited-file ()
  "`--tick' updates position for an auto-update bookmark whose file is visited."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "line1\nline2\nline3\n"
      (bmkp-gt-test--make-bookmark "trk" buf 1)
      (bookmark-prop-set "trk" 'auto-update t)
      (let ((end (with-current-buffer buf
                   (goto-char (point-max))
                   (point-max))))
        (bmkp-gt-auto-update--tick)
        (should (= end (bookmark-prop-get "trk" 'position)))))))

(ert-deftest bmkp-gt-test-auto-update/refresh-copies-mode-specific-fields ()
  "Refresh copies mode-specific fields (e.g. `page') from the buffer's
own `bookmark-make-record-function' — not just text-mode fields."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "any content\n"
      (bmkp-gt-test--make-bookmark "mode-mixed" buf 1)
      (bookmark-prop-set "mode-mixed" 'auto-update t)
      (with-current-buffer buf
        ;; Simulate a mode (like pdf-view) that returns a (NAME . DATA)
        ;; record with a mode-specific field (`page').
        (setq-local bookmark-make-record-function
                    (lambda ()
                      (cons "buffer-name"
                            `((filename . ,(buffer-file-name))
                              (position . 1)
                              (page . 7)
                              (handler . my-fake-handler))))))
      (bmkp-gt-auto-update--tick)
      (should (= 7 (bookmark-prop-get "mode-mixed" 'page)))
      (should (eq 'my-fake-handler (bookmark-prop-get "mode-mixed" 'handler))))))

(ert-deftest bmkp-gt-test-auto-update/refresh-preserves-identity-fields ()
  "Refresh does not touch id, tags, annotation, auto-update, created, visits."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "content\n"
      (bmkp-gt-test--make-bookmark "keeper" buf 1)
      (bmkp-add-tags "keeper" '("kept") 'NO-UPDATE-P)
      (bookmark-prop-set "keeper" 'annotation "note")
      (bookmark-prop-set "keeper" 'auto-update t)
      (let ((orig-id      (bookmark-prop-get "keeper" 'id))
            (orig-created (bookmark-prop-get "keeper" 'created))
            (orig-visits  (bookmark-prop-get "keeper" 'visits)))
        (with-current-buffer buf (goto-char (point-max)))
        (bmkp-gt-auto-update--tick)
        (should (equal orig-id      (bookmark-prop-get "keeper" 'id)))
        (should (equal orig-created (bookmark-prop-get "keeper" 'created)))
        (should (equal orig-visits  (bookmark-prop-get "keeper" 'visits)))
        (should (equal "note"       (bookmark-prop-get "keeper" 'annotation)))
        (should (eq t               (bookmark-prop-get "keeper" 'auto-update)))
        (should (member "kept" (mapcar (lambda (tg) (if (consp tg) (car tg) tg))
                                       (bookmark-prop-get "keeper" 'tags))))))))

(ert-deftest bmkp-gt-test-auto-update/tick-pins-end-position-to-position ()
  "`--tick' sets `end-position' equal to `position' so the region-restore path
in `bmkp-handle-region-default' never fires on an auto-update bookmark."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "line1\nline2\nline3\n"
      (bmkp-gt-test--make-bookmark "range" buf 1)
      ;; Simulate an older bookmark that once had a region:
      ;; position != end-position and no region-context strings.
      (bookmark-prop-set "range" 'end-position 5)
      (bookmark-prop-set "range" 'auto-update t)
      (let ((end (with-current-buffer buf
                   (goto-char (point-max))
                   (point-max))))
        (bmkp-gt-auto-update--tick)
        (should (= end (bookmark-prop-get "range" 'position)))
        (should (= end (bookmark-prop-get "range" 'end-position)))))))

(defun bmkp-gt-test-auto-update--bookmark-overlay-positions (buffer)
  "Return sorted starts of category-`bookmark' overlays in BUFFER."
  (with-current-buffer buffer
    (sort (mapcar #'overlay-start
                  (seq-filter (lambda (o) (eq 'bookmark (overlay-get o 'category)))
                              (overlays-in (point-min) (point-max))))
          #'<)))

(ert-deftest bmkp-gt-test-auto-update/tick-moves-fringe-mark ()
  "`--tick' moves the built-in fringe overlay to the new position."
  (let ((bookmark-set-fringe-mark 'bookmark-mark))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "aaa\nbbb\nccc\n"
        (bmkp-gt-test--make-bookmark "movef" buf 1)
        (bookmark-prop-set "movef" 'auto-update t)
        ;; Move point past the first line and refresh.
        (with-current-buffer buf (goto-char 5))  ; inside "bbb" line
        (bmkp-gt-auto-update--tick)
        (let ((positions
               (bmkp-gt-test-auto-update--bookmark-overlay-positions buf)))
          (should (= 1 (length positions)))
          (should (= 5 (car positions))))))))

(ert-deftest bmkp-gt-test-auto-update/tick-skips-fringe-when-flag-off ()
  "`--tick' does not add fringe marks when `bookmark-set-fringe-mark' is nil.
The bookmark's own fringe (if any) was placed at creation time; the
tick's remove/set pair is guarded by the flag."
  (let ((bookmark-set-fringe-mark nil))
    (bmkp-gt-test-with-clean-bookmarks
      (bmkp-gt-test-with-fixture-buffer buf "aaa\nbbb\n"
        (bmkp-gt-test--make-bookmark "no-fringe" buf 1)
        (bookmark-prop-set "no-fringe" 'auto-update t)
        (with-current-buffer buf (goto-char (point-max)))
        (bmkp-gt-auto-update--tick)
        (should
         (null (bmkp-gt-test-auto-update--bookmark-overlay-positions buf)))))))

(defun bmkp-gt-test-auto-update--light-overlay-positions (buffer)
  "Return sorted starts of category-`bookmark-plus' overlays in BUFFER."
  (with-current-buffer buffer
    (sort (mapcar #'overlay-start
                  (seq-filter (lambda (o) (eq 'bookmark-plus (overlay-get o 'category)))
                              (overlays-in (point-min) (point-max))))
          #'<)))

(ert-deftest bmkp-gt-test-auto-update/tick-moves-plus-light ()
  "`--tick' moves bookmark-plus's persistent line highlight to the new position."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "aaa\nbbb\nccc\n"
      (bmkp-gt-test--make-bookmark "moveh" buf 1)
      (bookmark-prop-set "moveh" 'auto-update t)
      ;; Light the bookmark manually — do not depend on auto-light-when-*.
      (let ((bmk (assoc "moveh" bookmark-alist)))
        (bmkp-light-bookmark bmk))
      (should (equal '(1)
                     (bmkp-gt-test-auto-update--light-overlay-positions buf)))
      ;; Move point past the first line; tick moves the highlight.
      (with-current-buffer buf (goto-char 5))  ; inside "bbb"
      (bmkp-gt-auto-update--tick)
      (let ((positions (bmkp-gt-test-auto-update--light-overlay-positions buf)))
        (should (= 1 (length positions)))
        (should (= 5 (car positions)))))))

(ert-deftest bmkp-gt-test-auto-update/tick-does-not-light-unlit-bookmark ()
  "`--tick' leaves an unlit bookmark alone (respects user's lighting choice)."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "aaa\nbbb\n"
      (bmkp-gt-test--make-bookmark "unlit" buf 1)
      (bookmark-prop-set "unlit" 'auto-update t)
      (with-current-buffer buf (goto-char (point-max)))
      (bmkp-gt-auto-update--tick)
      (should
       (null (bmkp-gt-test-auto-update--light-overlay-positions buf))))))

(ert-deftest bmkp-gt-test-auto-update/tick-skips-untracked ()
  "`--tick' leaves position unchanged for bookmarks without the property."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "line1\nline2\nline3\n"
      (bmkp-gt-test--make-bookmark "no-track" buf 1)
      (with-current-buffer buf
        (goto-char (point-max)))
      (bmkp-gt-auto-update--tick)
      (should (= 1 (bookmark-prop-get "no-track" 'position))))))

(ert-deftest bmkp-gt-test-auto-update/tick-skips-unvisited-file ()
  "`--tick' does not touch a bookmark whose file has no live buffer."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "line1\nline2\n"
      (bmkp-gt-test--make-bookmark "off-disk" buf 1)
      (bookmark-prop-set "off-disk" 'auto-update t)
      (kill-buffer buf))
    (bmkp-gt-auto-update--tick)
    (should (= 1 (bookmark-prop-get "off-disk" 'position)))))


;;; Install / uninstall -------------------------------------------------

(ert-deftest bmkp-gt-test-auto-update/install-registers-advice ()
  "`install' registers the list-1 advice, `uninstall' removes it."
  (unwind-protect
      (progn
        (bmkp-gt-auto-update-uninstall)
        (should-not (advice-member-p 'bmkp-gt-auto-update--list-1-advice
                                     'bmkp-bmenu-list-1))
        (bmkp-gt-auto-update-install)
        (should (advice-member-p 'bmkp-gt-auto-update--list-1-advice
                                 'bmkp-bmenu-list-1)))
    (bmkp-gt-auto-update-install)))

(ert-deftest bmkp-gt-test-auto-update/marks-width-unchanged ()
  "`install' does not modify `bmkp-bmenu-marks-width' (upstream bakes 4 in)."
  (should (= 4 bmkp-bmenu-marks-width)))

(ert-deftest bmkp-gt-test-auto-update/install-binds-caret-key ()
  "`install' binds `^' in `bookmark-bmenu-mode-map' to the bmenu toggle."
  (should (eq (lookup-key bookmark-bmenu-mode-map (kbd "^"))
              #'bmkp-gt-auto-update-bmenu-toggle)))


;;; Face selection ------------------------------------------------------

(defun bmkp-gt-test-auto-update--help-text ()
  "Populate *Help* by invoking status-help from a fresh bmenu; return its text."
  (bookmark-bmenu-list)
  (with-current-buffer bmkp-bmenu-buffer
    (cl-letf (((symbol-function 'message) #'ignore))
      (save-window-excursion
        (bmkp-bmenu-mode-status-help))))
  (with-current-buffer "*Help*"
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest bmkp-gt-test-auto-update/help-legend-when-mode-on ()
  "When mode is on, legend line reads `position tracked as you read'."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "help-fixture" buf))
    (let ((was-on bmkp-gt-auto-update-mode))
      (unwind-protect
          (progn
            (bmkp-gt-auto-update-mode 1)
            (let ((text (bmkp-gt-test-auto-update--help-text)))
              (should (string-match-p "auto-update  (`\\^' to toggle)  (position tracked as you read)" text))
              (should-not (string-match-p "tracking mode disabled" text))))
        (when (get-buffer bmkp-bmenu-buffer) (kill-buffer bmkp-bmenu-buffer))
        (when (get-buffer "*Help*") (kill-buffer "*Help*"))
        (bmkp-gt-auto-update-mode (if was-on 1 -1))))))

(ert-deftest bmkp-gt-test-auto-update/help-legend-when-mode-off ()
  "When mode is off, legend line reads `tracking mode disabled'."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "help-fixture" buf))
    (let ((was-on bmkp-gt-auto-update-mode))
      (unwind-protect
          (progn
            (bmkp-gt-auto-update-mode -1)
            (let ((text (bmkp-gt-test-auto-update--help-text)))
              (should (string-match-p "auto-update  (`\\^' to toggle)  (tracking mode disabled)" text))
              (should-not (string-match-p "position tracked as you read" text))))
        (when (get-buffer bmkp-bmenu-buffer) (kill-buffer bmkp-bmenu-buffer))
        (when (get-buffer "*Help*") (kill-buffer "*Help*"))
        (bmkp-gt-auto-update-mode (if was-on 1 -1))))))


;;; Describe-bookmark injection ---------------------------------------

(ert-deftest bmkp-gt-test-auto-update/describe-adds-line-when-on ()
  "`bmkp-bookmark-description' output gains an `Auto-update:' line
just before `Tags:' when the bookmark carries the property."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "content\n"
      (bmkp-gt-test--make-bookmark "annotated" buf 1)
      (bmkp-add-tags "annotated" '("kept") 'NO-UPDATE-P)
      (bookmark-prop-set "annotated" 'auto-update t)
      (let ((desc (bmkp-bookmark-description "annotated")))
        (should (string-match-p "Auto-update:\t\tyes" desc))
        ;; Line ordering: Auto-update appears before Tags.
        (should (< (string-match "Auto-update:" desc)
                   (string-match "Tags:"        desc)))))))

(ert-deftest bmkp-gt-test-auto-update/describe-omits-line-when-off ()
  "`bmkp-bookmark-description' output does NOT contain the auto-update
line when the property is absent."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "content\n"
      (bmkp-gt-test--make-bookmark "plain" buf 1))
    (let ((desc (bmkp-bookmark-description "plain")))
      (should-not (string-match-p "Auto-update:" desc)))))

(ert-deftest bmkp-gt-test-auto-update/describe-inject-line-fallbacks ()
  "`--inject-line' falls back to `Annotation:' anchor, then appends."
  ;; Anchor on Tags.
  (should (string-match-p
           "^Xs\nAuto-update:\tyes\nTags:"
           (bmkp-gt-auto-update--inject-line "Xs\nTags:\n" "Auto-update:\tyes\n")))
  ;; No Tags — anchor on Annotation.
  (should (string-match-p
           "^Xs\nAuto-update:\tyes\n\nAnnotation:"
           (bmkp-gt-auto-update--inject-line "Xs\n\nAnnotation:\n" "Auto-update:\tyes\n")))
  ;; Neither anchor — append.
  (should (equal "Xs\nAuto-update:\tyes\n"
                 (bmkp-gt-auto-update--inject-line "Xs\n" "Auto-update:\tyes\n"))))


(ert-deftest bmkp-gt-test-auto-update/face-tracks-mode-state ()
  "`--face' returns the active face while the mode is on, the inactive one otherwise."
  (let ((was-on bmkp-gt-auto-update-mode))
    (unwind-protect
        (progn
          (bmkp-gt-auto-update-mode 1)
          (should (eq 'bmkp-gt-caret-mark (bmkp-gt-auto-update--face)))
          (bmkp-gt-auto-update-mode -1)
          (should (eq 'bmkp-gt-caret-mark-inactive (bmkp-gt-auto-update--face))))
      (bmkp-gt-auto-update-mode (if was-on 1 -1)))))


(provide 'bmkp-gt-test-auto-update)
;;; bmkp-gt-test-auto-update.el ends here
