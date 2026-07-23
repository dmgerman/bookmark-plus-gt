;;; bookmark-plus-gt-tags.el --- Tags and type columns for *Bookmark List*   -*- lexical-binding:t -*-
;;
;; Filename:    bookmark-plus-gt-tags.el
;; Description: Renders a tags column and a type column between the
;;              name and filename columns of Bookmark+'s
;;              `*Bookmark List*'.  Part of bookmark-plus-gt.
;;
;; Author:     Daniel M. German
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;;
;; Copyright (C) 2026, Daniel M. German, all rights reserved.
;;
;; URL: https://github.com/dmgerman/bookmark-plus-gt
;;
;; Keywords:      bookmarks, convenience
;; Compatibility: GNU Emacs 30+
;; Package-Requires: ((bookmark+ "0"))
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; Assisted-by: Claude:claude-opus-4-7

;;; Commentary:
;;
;; Bookmark+ deliberately does not use `tabulated-list-mode' for its
;; `*Bookmark List*' buffer; the layout is built by hand in
;; `bmkp-bmenu-list-1' (pass 1: marks + name) with an optional
;; second pass `bookmark-bmenu-show-filenames' that overlays
;; filenames at `bookmark-bmenu-file-column'.
;;
;; This file adds two intermediate columns — tags and type — between
;; the name and the filename via non-invasive `:around' advice on
;; two Bookmark+ functions:
;;
;;   `bmkp-bmenu-list-1'
;;       Suppresses the built-in filename pass, then runs the tags
;;       pass, then the type pass, then re-invokes the filename pass
;;       with `bookmark-bmenu-file-column' let-bound to the correct
;;       position (past both added columns).
;;
;;   `bookmark-bmenu-toggle-filenames'
;;       Let-binds `bookmark-bmenu-file-column' to the columns-aware
;;       position, so toggling filenames on/off from the standard
;;       command respects both added columns.
;;
;; Bookmark+ itself is not modified.  Layout with everything on:
;;
;;     [marks] [name] [;tag ;tag ...] [Type] [filename]
;;
;; Toggles bound in `bookmark-bmenu-mode-map':
;;
;;     ;   `bmkp-gt-bmenu-toggle-tags'
;;     @   `bmkp-gt-bmenu-toggle-type'
;;
;; The `;' / `@' prefixes match the hidden tokens on `bmkp-gt-jump'
;; candidates (`bookmark-plus-gt-jump'), so the same characters
;; carry the same meaning in both interfaces.

;;; Code:

(require 'bookmark)
(require 'bookmark+)
(require 'bookmark-plus-gt-jump)     ; for `bmkp-gt-jump-candidate-type-name'
(require 'cl-lib)

;; Bookmark+ symbols we call into.  Declared for the byte compiler in
;; case this file is compiled before `bookmark+' is loaded.
(declare-function bmkp-bmenu-list-1               "bookmark+-bmu")
(declare-function bookmark-bmenu-show-filenames   "bookmark+-bmu")
(declare-function bookmark-bmenu-toggle-filenames "bookmark+-bmu")
(declare-function bmkp-bmenu-mode-status-help     "bookmark+-bmu")
(declare-function bmkp-get-tags                   "bookmark+-1")
(declare-function bmkp-get-bookmark               "bookmark+-1")
(declare-function bmkp-bookmark-name-from-record  "bookmark+-1")
(declare-function bmkp-refresh/rebuild-menu-list  "bookmark+-1")

(defvar bmkp-bmenu-header-lines)   ; In `bookmark+-bmu'.
(defvar bmkp-bmenu-marks-width)    ; In `bookmark+-bmu'.
(defvar bmkp-bmenu-buffer)         ; In `bookmark+.el'.
(defvar bookmark-bmenu-mode-map)       ; In `bookmark+-bmu'.
(defvar bmkp-sorted-alist)         ; In `bookmark+-1.el'.


;;; Customization --------------------------------------------------------

(defgroup bookmark-plus-gt nil
  "Non-invasive extensions to Bookmark+."
  :group 'bookmark-plus)

(defcustom bmkp-gt-bmenu-show-tags-flag t
  "Non-nil means show a tags column in `*Bookmark List*'.
Toggle with `bmkp-gt-bmenu-toggle-tags'."
  :type 'boolean
  :group 'bookmark-plus-gt)

(defcustom bmkp-gt-bmenu-show-type-flag t
  "Non-nil means show a type column in `*Bookmark List*'.
Toggle with `bmkp-gt-bmenu-toggle-type'.  The label comes from
`bmkp-gt-jump-narrow' (same source used by the consult jump
minibuffer) — see `bmkp-gt-jump-candidate-type-name'."
  :type 'boolean
  :group 'bookmark-plus-gt)

(defcustom bmkp-gt-bmenu-tags-max-width 40
  "Maximum width, in characters, of the tags column in `*Bookmark List*'.
Longer tag lists are truncated with an ellipsis.  Nil means no cap."
  :type '(choice (const :tag "No limit" nil) (integer :tag "Chars"))
  :group 'bookmark-plus-gt)

(defcustom bmkp-gt-bmenu-type-max-width 20
  "Maximum width, in characters, of the type column in `*Bookmark List*'.
Longer type labels are truncated with an ellipsis.  Nil means no
cap."
  :type '(choice (const :tag "No limit" nil) (integer :tag "Chars"))
  :group 'bookmark-plus-gt)

(defcustom bmkp-gt-bmenu-column-gap 2
  "Column-separator width between name, tags, type, and filename columns."
  :type 'integer
  :group 'bookmark-plus-gt)

(defcustom bmkp-gt-bmenu-name-max-width 50
  "Cap on the name-column width, in characters.

Non-nil (positive integer) — the tags/type start columns are
computed from `min(widest-name, cap)', and each row's name is
smart-truncated at render time so no row extends past the cap.
Truncation keeps the first characters of the name and the last
`bmkp-gt-bmenu-name-tail-keep' characters, joined by a single
ellipsis (`…').  The buffer text itself is left intact — only a
`display' property is set — so `bookmark-bmenu-bookmark',
`bmkp-jump-to-current-annotation-position', and other lookups
still see the full name.

nil — no cap; the tags and type columns start after the widest
name in the alist (the pre-cap behavior).

The cap has no effect when both `bmkp-gt-bmenu-show-tags-flag'
and `bmkp-gt-bmenu-show-type-flag' are nil: with neither extra
column shown, the render advice bails out before applying the cap
and the full name is displayed in the row."
  :type '(choice (const :tag "No cap" nil) (integer :tag "Max chars"))
  :group 'bookmark-plus-gt)

(defcustom bmkp-gt-bmenu-name-tail-keep 10
  "Number of characters kept at the tail of a truncated name.
Used only when `bmkp-gt-bmenu-name-max-width' is non-nil.  Rows
whose name exceeds the cap render as `<head>…<tail>' where <tail>
is this many characters."
  :type 'integer
  :group 'bookmark-plus-gt)

(defface bmkp-gt-bmenu-tags
  '((t :inherit completions-annotations))
  "Face for the tags column in `*Bookmark List*'."
  :group 'bookmark-plus-gt)

(defface bmkp-gt-bmenu-type
  '((t :inherit font-lock-type-face))
  "Face for the type column in `*Bookmark List*'."
  :group 'bookmark-plus-gt)


;;; Formatting helpers --------------------------------------------------

(defun bmkp-gt-bmenu--truncate (str max-width)
  "Return STR truncated to MAX-WIDTH characters with an ellipsis, or STR.
Nil MAX-WIDTH means no cap."
  (cond ((null max-width) str)
        ((<= (string-width str) max-width) str)
        (t (concat (truncate-string-to-width
                    str (max 0 (1- max-width)) 0 nil)
                   "…"))))

(defun bmkp-gt-bmenu--format-tags (bmk)
  "Return BMK's tags as a `;tag ;tag ...' string, or the empty string.
Tags are sorted alphabetically for deterministic display (Bookmark+
stores them in reverse-insertion order, which is not meaningful for
the user).  Truncated to `bmkp-gt-bmenu-tags-max-width'."
  (let* ((raw    (bmkp-get-tags bmk))
         (names  (mapcar (lambda (tag) (if (consp tag) (car tag) tag)) raw))
         (sorted (sort (copy-sequence names) #'string<))
         (str    (mapconcat (lambda (n) (concat ";" n)) sorted " ")))
    (if (string-empty-p str)
        ""
      (bmkp-gt-bmenu--truncate str bmkp-gt-bmenu-tags-max-width))))

(defun bmkp-gt-bmenu--format-type (bmk)
  "Return BMK's type-group label as a string, or the empty string.
Uses `bmkp-gt-jump-candidate-type-name' so the label matches what
`bmkp-gt-jump' shows and what `@Type' filters in the consult
minibuffer.  Truncated to `bmkp-gt-bmenu-type-max-width'."
  (let ((label  (or (bmkp-gt-jump-candidate-type-name bmk) "")))
    (bmkp-gt-bmenu--truncate label bmkp-gt-bmenu-type-max-width)))


;;; Column widths -------------------------------------------------------

(defun bmkp-gt-bmenu--compute-name-end ()
  "Return the column at which the name column ends in the current list.
Uses `bmkp-sorted-alist' (populated by `bmkp-bmenu-list-1').
When `bmkp-gt-bmenu-name-max-width' is non-nil, the widest name
is clamped to that value before the marks-width offset is added."
  (let ((widest  (apply #'max 0
                        (mapcar (lambda (bmk)
                                  (string-width (bmkp-bookmark-name-from-record bmk)))
                                (or bmkp-sorted-alist ())))))
    (+ bmkp-bmenu-marks-width
       (if (and bmkp-gt-bmenu-name-max-width
                (> widest bmkp-gt-bmenu-name-max-width))
           bmkp-gt-bmenu-name-max-width
         widest))))

(defun bmkp-gt-bmenu--compute-tags-width ()
  "Return the widest tags-string width across `bmkp-sorted-alist'."
  (apply #'max 0
         (mapcar (lambda (bmk)
                   (string-width (bmkp-gt-bmenu--format-tags bmk)))
                 (or bmkp-sorted-alist ()))))

(defun bmkp-gt-bmenu--compute-type-width ()
  "Return the widest type-label width across `bmkp-sorted-alist'."
  (apply #'max 0
         (mapcar (lambda (bmk)
                   (string-width (bmkp-gt-bmenu--format-type bmk)))
                 (or bmkp-sorted-alist ()))))

(defun bmkp-gt-bmenu--column-layout ()
  "Compute column start positions and the target file column.
Returns a plist (:name-end N :tags-start T :type-start Y :file-col F)
where each field is a column number.  Columns for disabled flags
are left at nil in the plist."
  (let* ((name-end   (bmkp-gt-bmenu--compute-name-end))
         (gap        bmkp-gt-bmenu-column-gap)
         (tags-start (when bmkp-gt-bmenu-show-tags-flag (+ name-end gap)))
         (tags-end   (when tags-start
                       (+ tags-start (bmkp-gt-bmenu--compute-tags-width))))
         (type-start (when bmkp-gt-bmenu-show-type-flag
                       (+ (or tags-end name-end) gap)))
         (type-end   (when type-start
                       (+ type-start (bmkp-gt-bmenu--compute-type-width))))
         (last-end   (or type-end tags-end name-end))
         (file-col   (+ last-end gap)))
    (list :name-end   name-end
          :tags-start tags-start
          :type-start type-start
          :file-col   file-col)))

(defun bmkp-gt-bmenu--file-column ()
  "Return the column at which filenames should be placed.
Uses `bmkp-gt-bmenu--column-layout' when either the tags or the type
column is on; otherwise falls back to the upstream defcustom."
  (if (or bmkp-gt-bmenu-show-tags-flag bmkp-gt-bmenu-show-type-flag)
      (plist-get (bmkp-gt-bmenu--column-layout) :file-col)
    bookmark-bmenu-file-column))


;;; Column passes ------------------------------------------------------

(defun bmkp-gt-bmenu--insert-column (start-col format-fn face)
  "Walk every bookmark row, insert a column starting at START-COL.
For each row, calls FORMAT-FN with the bookmark record and inserts
its result padded to the column start.  Empty strings from
FORMAT-FN insert only the padding.

The inserted text is propertized with the row's own
`font-lock-face' — bookmark-plus's row-type face (`bmkp-url',
`bmkp-local-file-without-region', `bmkp-info', ...) — read from
the beginning of the name column.  Upstream applies that same
face to the whole `[marks-width, max-width]' range, so any
background carried by the row-type face flows continuously across
the name, the padding, and the tag / type text — no visible
seam where the tag or type column starts.  FACE is used only as
the fallback for rows that somehow lack a row-level face."
  (save-excursion
    (goto-char (point-min))
    (forward-line bmkp-bmenu-header-lines)
    (let ((inhibit-read-only  t))
      (while (< (point) (point-max))
        (let ((name  (bookmark-bmenu-bookmark)))
          (when name
            (let* ((bmk       (bmkp-get-bookmark name 'NOERROR))
                   (str       (and bmk (funcall format-fn bmk)))
                   (row-face  (get-text-property
                               (+ (line-beginning-position) bmkp-bmenu-marks-width)
                               'font-lock-face)))
              (move-to-column start-col t)
              (when (and str (not (string-empty-p str)))
                (insert (propertize str 'font-lock-face (or row-face face)))))))
        (forward-line 1)))))


;;; Long-name truncation ------------------------------------------------

(defconst bmkp-gt-bmenu--ellipsis "…"
  "Character rendered in place of the hidden middle of a truncated name.")

(defun bmkp-gt-bmenu--truncate-long-names ()
  "Truncate over-cap bookmark names in `*Bookmark List*'.
For each row whose name exceeds `bmkp-gt-bmenu-name-max-width',
rewrites the rendered name in the buffer to `<head>…<tail>' where
<tail> is `bmkp-gt-bmenu-name-tail-keep' characters.  The
bookmark-plus row-level text properties (`bmkp-bookmark-name',
`bmkp-full-record', etc.) are copied onto the rewritten range so
`bookmark-bmenu-bookmark' and every other row lookup still returns
the full record.  The underlying bookmark alist entry is untouched.

Buffer-text truncation (not `display' property) is used because
`move-to-column' in `bmkp-gt-bmenu--insert-column' counts buffer
characters — a `display' string is not accounted for and the
tag/type columns would still land past the full-width name.

No-op when `bmkp-gt-bmenu-name-max-width' is nil, or the head
window (cap minus tail-keep minus 1 for the ellipsis) is zero or
negative."
  (when bmkp-gt-bmenu-name-max-width
    (let* ((cap        bmkp-gt-bmenu-name-max-width)
           (tail-keep  (max 0 bmkp-gt-bmenu-name-tail-keep))
           (ellipsis   bmkp-gt-bmenu--ellipsis)
           (head-keep  (- cap tail-keep (string-width ellipsis))))
      (when (> head-keep 0)
        (save-excursion
          (goto-char (point-min))
          (forward-line bmkp-bmenu-header-lines)
          (let ((inhibit-read-only  t))
            (while (< (point) (point-max))
              (let ((name  (bookmark-bmenu-bookmark)))
                (when (and name (> (length name) cap))
                  (let* ((line-start  (line-beginning-position))
                         (name-start  (+ line-start bmkp-bmenu-marks-width))
                         (name-end    (+ name-start (length name)))
                         (props       (text-properties-at name-start))
                         (truncated   (concat (substring name 0 head-keep)
                                              ellipsis
                                              (substring name (- (length name) tail-keep)))))
                    (delete-region name-start name-end)
                    (goto-char name-start)
                    (insert truncated)
                    (add-text-properties name-start
                                         (+ name-start (length truncated))
                                         props))))
              (forward-line 1))))))))


;;; :around advice on `bmkp-bmenu-list-1' --------------------------------

(defun bmkp-gt-bmenu-list-1-advice (orig-fn &rest args)
  "Insert the tags and/or type columns when their flags are on."
  (if (not (or bmkp-gt-bmenu-show-tags-flag bmkp-gt-bmenu-show-type-flag))
      (apply orig-fn args)
    ;; Suppress upstream's filename pass; we re-invoke it below with
    ;; `bookmark-bmenu-file-column' let-bound to the correct value.
    (let ((filenames-were-on  bookmark-bmenu-toggle-filenames))
      (let ((bookmark-bmenu-toggle-filenames  nil))
        (apply orig-fn args))
      (with-current-buffer bmkp-bmenu-buffer
        (bmkp-gt-bmenu--truncate-long-names)
        (bmkp-gt-bmenu--insert-passes)
        (when filenames-were-on
          (let ((bookmark-bmenu-file-column       (bmkp-gt-bmenu--file-column))
                (bookmark-bmenu-toggle-filenames  t))
            (bookmark-bmenu-show-filenames nil 'NO-MSG-P)))))))


;;; :around advice on `bookmark-bmenu-toggle-filenames' -----------------

(defun bmkp-gt-bmenu--insert-passes ()
  "Re-run the tags and type insertion passes over the current buffer."
  (let* ((layout      (bmkp-gt-bmenu--column-layout))
         (tags-start  (plist-get layout :tags-start))
         (type-start  (plist-get layout :type-start)))
    (when tags-start
      (bmkp-gt-bmenu--insert-column
       tags-start #'bmkp-gt-bmenu--format-tags 'bmkp-gt-bmenu-tags))
    (when type-start
      (bmkp-gt-bmenu--insert-column
       type-start #'bmkp-gt-bmenu--format-type 'bmkp-gt-bmenu-type))))

(defun bmkp-gt-bmenu-toggle-filenames-advice (orig-fn &rest args)
  "Route the filename toggle past our added columns when they are shown.
When filenames are being hidden, `bookmark-bmenu-hide-filenames' does
a full row rewrite from `bmkp-bmenu-marks-width' to end-of-line,
which wipes the tags and type columns.  In that transition we
re-render our columns after the original returns."
  (if (not (or bmkp-gt-bmenu-show-tags-flag bmkp-gt-bmenu-show-type-flag))
      (apply orig-fn args)
    (let ((was-on  bookmark-bmenu-toggle-filenames))
      (let ((bookmark-bmenu-file-column  (bmkp-gt-bmenu--file-column)))
        (apply orig-fn args))
      (when (and was-on (not bookmark-bmenu-toggle-filenames))
        (with-current-buffer bmkp-bmenu-buffer
          (bmkp-gt-bmenu--insert-passes))))))


;;; Toggle commands ----------------------------------------------------

(defun bmkp-gt-bmenu--rerender ()
  "Re-render `*Bookmark List*' if the buffer is live."
  (when (and (boundp 'bmkp-bmenu-buffer) (get-buffer bmkp-bmenu-buffer))
    (with-current-buffer bmkp-bmenu-buffer
      (bookmark-bmenu-list))))

;;;###autoload
(defun bmkp-gt-bmenu-toggle-tags ()
  "Toggle the tags column in `*Bookmark List*'."
  (interactive)
  (setq bmkp-gt-bmenu-show-tags-flag  (not bmkp-gt-bmenu-show-tags-flag))
  (bmkp-gt-bmenu--rerender)
  (message "Tags column %s"
           (if bmkp-gt-bmenu-show-tags-flag "shown" "hidden")))

;;;###autoload
(defun bmkp-gt-bmenu-toggle-type ()
  "Toggle the type column in `*Bookmark List*'."
  (interactive)
  (setq bmkp-gt-bmenu-show-type-flag  (not bmkp-gt-bmenu-show-type-flag))
  (bmkp-gt-bmenu--rerender)
  (message "Type column %s"
           (if bmkp-gt-bmenu-show-type-flag "shown" "hidden")))


;;; Help buffer augmentation ------------------------------------------

(defconst bmkp-gt-bmenu--help-marker "temporary (will not be saved)\n"
  "Line in Bookmark+'s help buffer we anchor our insertion after.")

(defun bmkp-gt-bmenu-help-advice (&rest _args)
  "Insert bookmark-plus-gt column toggles into the *Help* buffer.
Runs as `:after' advice on `bmkp-bmenu-mode-status-help', which
populates `*Help*' via `with-help-window' and freezes it read-only.
Locates the `X temporary (will not be saved)' line in the Legend
for Markings section and inserts a small toggle-columns block right
after it."
  (let ((buf  (get-buffer "*Help*")))
    (when buf
      (with-current-buffer buf
        (let ((inhibit-read-only  t))
          (save-excursion
            (goto-char (point-min))
            (when (search-forward bmkp-gt-bmenu--help-marker nil t)
              (insert
               "\n"
               "Toggle columns\n"
               "--------------\n"
               "\n"
               "   (  Filenames column\n"
               "   ;  Tags column\n"
               "   @  Type column\n"))))))))


;;; Mode -----------------------------------------------------------------

;;;###autoload
(define-minor-mode bmkp-gt-bmenu-tags-mode
  "Toggle the tags and type columns in `*Bookmark List*'.

When on, three advices decorate the Bookmark+ list buffer with
tags and type columns between the name and filename columns, and
two keys are bound in `bookmark-bmenu-mode-map':

  `;'  `bmkp-gt-bmenu-toggle-tags'
  `@'  `bmkp-gt-bmenu-toggle-type'

The columns themselves can be shown or hidden independently via
`bmkp-gt-bmenu-show-tags-flag' and `bmkp-gt-bmenu-show-type-flag';
turning the mode off removes the machinery entirely and restores
the vanilla Bookmark+ layout."
  :init-value nil :global t :group 'bookmark-plus-gt
  (cond
   (bmkp-gt-bmenu-tags-mode
    ;; Force both columns visible on enable — the visible columns are
    ;; the user's confirmation that the mode is on.  They can hide
    ;; either afterward with `;' / `@'.
    (setq bmkp-gt-bmenu-show-tags-flag t
          bmkp-gt-bmenu-show-type-flag t)
    (advice-add 'bmkp-bmenu-list-1               :around #'bmkp-gt-bmenu-list-1-advice)
    (advice-add 'bookmark-bmenu-toggle-filenames :around #'bmkp-gt-bmenu-toggle-filenames-advice)
    (advice-add 'bmkp-bmenu-mode-status-help     :after  #'bmkp-gt-bmenu-help-advice)
    (when (boundp 'bookmark-bmenu-mode-map)
      (define-key bookmark-bmenu-mode-map (kbd ";") #'bmkp-gt-bmenu-toggle-tags)
      (define-key bookmark-bmenu-mode-map (kbd "@") #'bmkp-gt-bmenu-toggle-type)))
   (t
    (advice-remove 'bmkp-bmenu-list-1               #'bmkp-gt-bmenu-list-1-advice)
    (advice-remove 'bookmark-bmenu-toggle-filenames #'bmkp-gt-bmenu-toggle-filenames-advice)
    (advice-remove 'bmkp-bmenu-mode-status-help     #'bmkp-gt-bmenu-help-advice)
    (when (boundp 'bookmark-bmenu-mode-map)
      (when (eq (lookup-key bookmark-bmenu-mode-map (kbd ";")) #'bmkp-gt-bmenu-toggle-tags)
        (define-key bookmark-bmenu-mode-map (kbd ";") nil))
      (when (eq (lookup-key bookmark-bmenu-mode-map (kbd "@")) #'bmkp-gt-bmenu-toggle-type)
        (define-key bookmark-bmenu-mode-map (kbd "@") nil)))))
  ;; Rerender `*Bookmark List*' if visible so the column toggle is reflected
  ;; immediately (adding/removing the tags/type columns).
  (when (and (fboundp 'bmkp-refresh/rebuild-menu-list)
             (get-buffer "*Bookmark List*"))
    (bmkp-refresh/rebuild-menu-list nil 'no-msg)))


(provide 'bookmark-plus-gt-tags)
;;; bookmark-plus-gt-tags.el ends here
