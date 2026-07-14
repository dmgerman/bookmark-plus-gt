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
