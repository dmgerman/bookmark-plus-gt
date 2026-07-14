;;; bmkp-gt-test-tags.el --- Tests for bookmark-plus-gt-tags   -*- lexical-binding: t -*-

;;; Code:

(require 'bmkp-gt-test-helper)
(require 'bookmark-plus-gt-tags)
(require 'cl-lib)


;;; Formatter -----------------------------------------------------------

(ert-deftest bmkp-gt-test-tags/format-empty-for-untagged ()
  "`bmkp-gt-bmenu--format-tags' returns \"\" for a bookmark with no tags."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "no-tags" buf))
    (let ((bmk (assoc "no-tags" bookmark-alist)))
      (should (equal "" (bmkp-gt-bmenu--format-tags bmk))))))

(ert-deftest bmkp-gt-test-tags/format-renders-tag-tokens ()
  "Tags are rendered as space-separated `#tag' tokens."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "tagged" buf))
    (bmkp-add-tags "tagged" '("alpha" "beta") 'NO-UPDATE-P)
    (let ((bmk (assoc "tagged" bookmark-alist)))
      (should (equal ";alpha ;beta" (bmkp-gt-bmenu--format-tags bmk))))))

(ert-deftest bmkp-gt-test-tags/format-truncates-over-cap ()
  "Long tag strings are truncated to `bmkp-gt-bmenu-tags-max-width' with an ellipsis."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "wide" buf))
    (bmkp-add-tags "wide" '("aaaa" "bbbb" "cccc" "dddd" "eeee" "ffff")
                   'NO-UPDATE-P)
    (let* ((bmkp-gt-bmenu-tags-max-width  15)
           (bmk                            (assoc "wide" bookmark-alist))
           (out                            (bmkp-gt-bmenu--format-tags bmk)))
      (should (string-suffix-p "…" out))
      (should (<= (string-width out) 15)))))

(ert-deftest bmkp-gt-test-tags/format-no-cap-honored ()
  "With nil `bmkp-gt-bmenu-tags-max-width', tags are not truncated."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "uncapped" buf))
    (bmkp-add-tags "uncapped" '("aaaa" "bbbb" "cccc" "dddd" "eeee" "ffff")
                   'NO-UPDATE-P)
    (let* ((bmkp-gt-bmenu-tags-max-width  nil)
           (bmk                            (assoc "uncapped" bookmark-alist))
           (out                            (bmkp-gt-bmenu--format-tags bmk)))
      (should-not (string-suffix-p "…" out))
      (should (equal ";aaaa ;bbbb ;cccc ;dddd ;eeee ;ffff" out)))))


;;; Type formatter ------------------------------------------------------

(ert-deftest bmkp-gt-test-tags/format-type-returns-narrow-label ()
  "`bmkp-gt-bmenu--format-type' returns the group label from `bmkp-gt-jump-narrow'."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "type-file" buf))
    (let ((bmk (assoc "type-file" bookmark-alist)))
      (should (equal "File" (bmkp-gt-bmenu--format-type bmk))))))

(ert-deftest bmkp-gt-test-tags/format-type-truncates-over-cap ()
  "Long type labels are truncated with an ellipsis."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "type-cap" buf))
    (let* ((bmkp-gt-bmenu-type-max-width  3)
           (bmk                            (assoc "type-cap" bookmark-alist))
           (out                            (bmkp-gt-bmenu--format-type bmk)))
      (should (string-suffix-p "…" out))
      (should (<= (string-width out) 3)))))


;;; Toggle commands ----------------------------------------------------

(ert-deftest bmkp-gt-test-tags/toggle-flips-flag ()
  "`bmkp-gt-bmenu-toggle-tags' inverts the flag."
  (bmkp-gt-test-with-clean-bookmarks
    (let ((bmkp-gt-bmenu-show-tags-flag  t))
      (cl-letf (((symbol-function 'message) #'ignore))
        (bmkp-gt-bmenu-toggle-tags)
        (should-not bmkp-gt-bmenu-show-tags-flag)
        (bmkp-gt-bmenu-toggle-tags)
        (should bmkp-gt-bmenu-show-tags-flag)))))

(ert-deftest bmkp-gt-test-tags/toggle-type-flips-flag ()
  "`bmkp-gt-bmenu-toggle-type' inverts the flag."
  (bmkp-gt-test-with-clean-bookmarks
    (let ((bmkp-gt-bmenu-show-type-flag  t))
      (cl-letf (((symbol-function 'message) #'ignore))
        (bmkp-gt-bmenu-toggle-type)
        (should-not bmkp-gt-bmenu-show-type-flag)
        (bmkp-gt-bmenu-toggle-type)
        (should bmkp-gt-bmenu-show-type-flag)))))


;;; Advice installed ---------------------------------------------------

(ert-deftest bmkp-gt-test-tags/advice-installed ()
  "Advice on the two Bookmark+ functions is present after loading."
  (should (advice-member-p 'bmkp-gt-bmenu-list-1-advice
                           'bmkp-bmenu-list-1))
  (should (advice-member-p 'bmkp-gt-bmenu-toggle-filenames-advice
                           'bookmark-bmenu-toggle-filenames)))


;;; Integration: real list render --------------------------------------

(ert-deftest bmkp-gt-test-tags/list-renders-tag-tokens ()
  "The rendered `*Bookmark List*' contains the tag tokens when the flag is on."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "row-tagged" buf))
    (bmkp-add-tags "row-tagged" '("emacs" "work") 'NO-UPDATE-P)
    (let ((bmkp-gt-bmenu-show-tags-flag  t))
      (unwind-protect
          (progn
            (bookmark-bmenu-list)
            (with-current-buffer bmkp-bmenu-buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p ";emacs" text))
                (should (string-match-p ";work"  text)))))
        (when (get-buffer bmkp-bmenu-buffer)
          (kill-buffer bmkp-bmenu-buffer))))))

(ert-deftest bmkp-gt-test-tags/list-hides-tag-tokens-when-off ()
  "When the flag is off, tags do not appear in the rendered list."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "row-hidden" buf))
    (bmkp-add-tags "row-hidden" '("hidden-tag") 'NO-UPDATE-P)
    (let ((bmkp-gt-bmenu-show-tags-flag  nil))
      (unwind-protect
          (progn
            (bookmark-bmenu-list)
            (with-current-buffer bmkp-bmenu-buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should-not (string-match-p ";hidden-tag" text)))))
        (when (get-buffer bmkp-bmenu-buffer)
          (kill-buffer bmkp-bmenu-buffer))))))

(ert-deftest bmkp-gt-test-tags/list-renders-type-label ()
  "The rendered list contains the type label when the type flag is on."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "row-type" buf))
    (let ((bmkp-gt-bmenu-show-type-flag  t))
      (unwind-protect
          (progn
            (bookmark-bmenu-list)
            (with-current-buffer bmkp-bmenu-buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "File" text)))))
        (when (get-buffer bmkp-bmenu-buffer)
          (kill-buffer bmkp-bmenu-buffer))))))

(ert-deftest bmkp-gt-test-tags/list-hides-type-when-off ()
  "When the type flag is off, no type label appears in the row area."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "row-notype" buf))
    (let ((bmkp-gt-bmenu-show-type-flag  nil)
          (bmkp-gt-bmenu-show-tags-flag  nil))
      (unwind-protect
          (progn
            (bookmark-bmenu-list)
            (with-current-buffer bmkp-bmenu-buffer
              ;; Restrict to rows below the header — the header itself
              ;; carries "Bookmark file:", which would trip a naive
              ;; match on "File".
              (save-excursion
                (goto-char (point-min))
                (forward-line bmkp-bmenu-header-lines)
                (let ((rows (buffer-substring-no-properties (point) (point-max))))
                  (should-not (string-match-p "\\bFile\\b" rows))))))
        (when (get-buffer bmkp-bmenu-buffer)
          (kill-buffer bmkp-bmenu-buffer))))))


;;; Key bindings -------------------------------------------------------

(ert-deftest bmkp-gt-test-tags/keys-bound ()
  "`;' and `@' are bound to our toggles in `bookmark-bmenu-mode-map'."
  (should (eq #'bmkp-gt-bmenu-toggle-tags
              (lookup-key bookmark-bmenu-mode-map (kbd ";"))))
  (should (eq #'bmkp-gt-bmenu-toggle-type
              (lookup-key bookmark-bmenu-mode-map (kbd "@")))))


;;; Hide-filenames wipe recovery ---------------------------------------

(ert-deftest bmkp-gt-test-tags/hide-filenames-preserves-columns ()
  "Hiding filenames re-renders tags/type columns (hide does a full row rewrite)."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "wipe-recover" buf))
    (bmkp-add-tags "wipe-recover" '("survivor") 'NO-UPDATE-P)
    (let ((bmkp-gt-bmenu-show-tags-flag  t)
          (bmkp-gt-bmenu-show-type-flag  t)
          (bookmark-bmenu-toggle-filenames  t))
      (unwind-protect
          (progn
            (bookmark-bmenu-list)
            ;; Toggle off — this exercises the hide-filenames path
            ;; that used to wipe our columns.
            (cl-letf (((symbol-function 'message) #'ignore))
              (with-current-buffer bmkp-bmenu-buffer
                (bookmark-bmenu-toggle-filenames)))
            (with-current-buffer bmkp-bmenu-buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p ";survivor" text))
                (should (string-match-p "\\bFile\\b" text)))))
        (when (get-buffer bmkp-bmenu-buffer)
          (kill-buffer bmkp-bmenu-buffer))))))


;;; Help buffer augmentation ------------------------------------------

(ert-deftest bmkp-gt-test-tags/help-advice-inserts-toggle-block ()
  "`:after' advice on the status-help function inserts the toggle block."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "help-fixture" buf))
    (unwind-protect
        (progn
          (bookmark-bmenu-list)
          (with-current-buffer bmkp-bmenu-buffer
            (cl-letf (((symbol-function 'message) #'ignore))
              (save-window-excursion
                (bmkp-bmenu-mode-status-help))))
          (with-current-buffer "*Help*"
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "Toggle columns" text))
              (should (string-match-p "Filenames column" text))
              (should (string-match-p "Tags column"      text))
              (should (string-match-p "Type column"      text)))))
      (when (get-buffer bmkp-bmenu-buffer)
        (kill-buffer bmkp-bmenu-buffer))
      (when (get-buffer "*Help*")
        (kill-buffer "*Help*")))))


(provide 'bmkp-gt-test-tags)
;;; bmkp-gt-test-tags.el ends here
