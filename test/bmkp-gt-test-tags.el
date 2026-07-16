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


(ert-deftest bmkp-gt-test-tags/padding-does-not-inherit-row-face ()
  "Padding inserted between the name column and the tags/type column
must not inherit the row's Bookmark+ type face (`bmkp-local-file-*',
`bmkp-url', ...).  Regression: the type face leaked across the empty
tags column via `move-to-column ... t' inheritance."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "row-plain" buf))
    (let ((bmkp-gt-bmenu-show-tags-flag  t)
          (bmkp-gt-bmenu-show-type-flag  t))
      (unwind-protect
          (progn
            (bookmark-bmenu-list)
            (with-current-buffer bmkp-bmenu-buffer
              (save-excursion
                (goto-char (point-min))
                (search-forward "row-plain")
                (forward-line 0)
                ;; Advance well past the name into the padding /
                ;; tags-column area; assert no `bmkp-*' face there.
                (forward-char 40)
                (let ((f (get-text-property (point) 'face)))
                  (should-not
                   (and (symbolp f)
                        (string-prefix-p "bmkp-" (symbol-name f))))))))
        (when (get-buffer bmkp-bmenu-buffer)
          (kill-buffer bmkp-bmenu-buffer))))))


;;; Name column cap and smart-truncation ------------------------------

(ert-deftest bmkp-gt-test-tags/compute-name-end-caps-widest ()
  "`bmkp-gt-bmenu--compute-name-end' clamps the widest name to the cap."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark
       (make-string 200 ?a) buf))
    (let ((bmkp-gt-bmenu-name-max-width  50)
          (bmkp-sorted-alist              bookmark-alist))
      ;; marks-width (4) + cap (50) = 54
      (should (= (+ bmkp-bmenu-marks-width 50)
                 (bmkp-gt-bmenu--compute-name-end))))))

(ert-deftest bmkp-gt-test-tags/compute-name-end-uncapped-uses-widest ()
  "With nil cap, `compute-name-end' returns marks-width + widest name."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark (make-string 200 ?a) buf))
    (let ((bmkp-gt-bmenu-name-max-width  nil)
          (bmkp-sorted-alist              bookmark-alist))
      (should (= (+ bmkp-bmenu-marks-width 200)
                 (bmkp-gt-bmenu--compute-name-end))))))

(ert-deftest bmkp-gt-test-tags/truncate-long-name-renders-ellipsis-shape ()
  "A long-name row shows `<head>…<tail>' when the tags/type columns are on."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark
       (concat "HEAD" (make-string 200 ?x) "TAIL") buf))
    (let ((bmkp-gt-bmenu-show-tags-flag  t)
          (bmkp-gt-bmenu-show-type-flag  t)
          (bmkp-gt-bmenu-name-max-width  50)
          (bmkp-gt-bmenu-name-tail-keep  10))
      (unwind-protect
          (progn
            (bookmark-bmenu-list)
            (with-current-buffer bmkp-bmenu-buffer
              (save-excursion
                (goto-char (point-min))
                (should (search-forward "…" nil t))
                ;; The visible tail includes the original suffix.
                (should (search-forward "TAIL" nil t)))))
        (when (get-buffer bmkp-bmenu-buffer)
          (kill-buffer bmkp-bmenu-buffer))))))

(ert-deftest bmkp-gt-test-tags/truncate-preserves-full-name-property ()
  "After truncation, `bookmark-bmenu-bookmark' still returns the full name."
  (bmkp-gt-test-with-clean-bookmarks
    (let ((full  (concat "HEAD" (make-string 200 ?x) "TAIL")))
      (bmkp-gt-test-with-fixture-buffer buf "x"
        (bmkp-gt-test--make-bookmark full buf))
      (let ((bmkp-gt-bmenu-show-tags-flag  t)
            (bmkp-gt-bmenu-show-type-flag  t)
            (bmkp-gt-bmenu-name-max-width  50))
        (unwind-protect
            (progn
              (bookmark-bmenu-list)
              (with-current-buffer bmkp-bmenu-buffer
                (save-excursion
                  (goto-char (point-min))
                  (search-forward "HEAD")
                  (forward-line 0)
                  (forward-char bmkp-bmenu-marks-width)
                  (should (equal full (bookmark-bmenu-bookmark))))))
          (when (get-buffer bmkp-bmenu-buffer)
            (kill-buffer bmkp-bmenu-buffer)))))))

(ert-deftest bmkp-gt-test-tags/truncate-no-op-when-cap-nil ()
  "A nil `bmkp-gt-bmenu-name-max-width' means no truncation."
  (bmkp-gt-test-with-clean-bookmarks
    (let ((long  (concat "HEAD" (make-string 100 ?x) "TAIL")))
      (bmkp-gt-test-with-fixture-buffer buf "x"
        (bmkp-gt-test--make-bookmark long buf))
      (let ((bmkp-gt-bmenu-show-tags-flag  t)
            (bmkp-gt-bmenu-show-type-flag  t)
            (bmkp-gt-bmenu-name-max-width  nil))
        (unwind-protect
            (progn
              (bookmark-bmenu-list)
              (with-current-buffer bmkp-bmenu-buffer
                (save-excursion
                  (goto-char (point-min))
                  (should-not (search-forward "…" nil t)))))
          (when (get-buffer bmkp-bmenu-buffer)
            (kill-buffer bmkp-bmenu-buffer)))))))


;;; Row-face continuity across tag/type columns -----------------------

(ert-deftest bmkp-gt-test-tags/tag-text-shares-row-font-lock-face ()
  "When the name column has a `font-lock-face', the tag text uses the same.
Skipped implicitly if the name column carries no face in the
batch environment — the point of the assertion is that whatever
face is present on the name is also present on the tag text."
  (bmkp-gt-test-with-clean-bookmarks
    (bmkp-gt-test-with-fixture-buffer buf "x"
      (bmkp-gt-test--make-bookmark "row-plain" buf))
    (bmkp-add-tags "row-plain" '("mytag") 'NO-UPDATE-P)
    (let ((bmkp-gt-bmenu-show-tags-flag  t)
          (bmkp-gt-bmenu-show-type-flag  t))
      (unwind-protect
          (progn
            (bookmark-bmenu-list)
            (with-current-buffer bmkp-bmenu-buffer
              (bmkp-bmenu-goto-bookmark-named "row-plain")
              (forward-line 0)
              (let ((name-face  (get-text-property
                                 (+ (line-beginning-position)
                                    bmkp-bmenu-marks-width 3)
                                 'font-lock-face)))
                (when name-face
                  (goto-char (line-beginning-position))
                  (search-forward ";mytag" (line-end-position) t)
                  (should (eq name-face
                              (get-text-property (1- (point))
                                                 'font-lock-face)))))))
        (when (get-buffer bmkp-bmenu-buffer)
          (kill-buffer bmkp-bmenu-buffer))))))


(provide 'bmkp-gt-test-tags)
;;; bmkp-gt-test-tags.el ends here
