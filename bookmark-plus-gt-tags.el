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
;; candidates (`bookmark-plus-gt-preview'), so the same characters
;; carry the same meaning in both interfaces.

;;; Code:

(require 'bookmark)
(require 'bookmark+)
(require 'bookmark-plus-gt-preview)     ; for `bmkp-gt-jump-candidate-type-name'
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
Uses `bmkp-sorted-alist' (populated by `bmkp-bmenu-list-1')."
  (+ bmkp-bmenu-marks-width
     (apply #'max 0
            (mapcar (lambda (bmk)
                      (string-width (bmkp-bookmark-name-from-record bmk)))
                    (or bmkp-sorted-alist ())))))

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
its result padded to the column start.  FACE is applied to the
inserted text.  Empty strings from FORMAT-FN insert only the
padding.

Padding inserted by `move-to-column ... t' inherits text
properties (including `face') from the preceding character.
Bookmark+'s row-level type face (e.g. `bmkp-url', `bmkp-file')
therefore bleeds across the tags column when the row is padded.
Strip `face' from the padding to prevent that."
  (save-excursion
    (goto-char (point-min))
    (forward-line bmkp-bmenu-header-lines)
    (let ((inhibit-read-only  t))
      (while (< (point) (point-max))
        (let ((name  (bookmark-bmenu-bookmark)))
          (when name
            (let* ((bmk         (bmkp-get-bookmark name 'NOERROR))
                   (str         (and bmk (funcall format-fn bmk)))
                   ;; Snapshot line end BEFORE `move-to-column' so we
                   ;; can tell whether it inserted padding.  If the row
                   ;; was already at least START-COL wide, no insert
                   ;; happens and we must not touch existing faces.
                   (row-end     (line-end-position)))
              (move-to-column start-col t)
              (when (> (line-end-position) row-end)
                ;; Padding was inserted at ROW-END..point.  It
                ;; inherited the preceding character's `face' via
                ;; `insert' stickiness — strip so Bookmark+'s row-type
                ;; face (e.g. `bmkp-url') does not bleed across the
                ;; empty tags column.
                (put-text-property row-end (point) 'face nil))
              (when (and str (not (string-empty-p str)))
                (insert (propertize str 'face face))))))
        (forward-line 1)))))


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


;;; Install / uninstall -------------------------------------------------

(defun bmkp-gt-bmenu-tags-install ()
  "Install advice and key bindings for bookmark-plus-gt-tags."
  (advice-add 'bmkp-bmenu-list-1               :around #'bmkp-gt-bmenu-list-1-advice)
  (advice-add 'bookmark-bmenu-toggle-filenames :around #'bmkp-gt-bmenu-toggle-filenames-advice)
  (advice-add 'bmkp-bmenu-mode-status-help     :after  #'bmkp-gt-bmenu-help-advice)
  (when (boundp 'bookmark-bmenu-mode-map)
    (define-key bookmark-bmenu-mode-map (kbd ";") #'bmkp-gt-bmenu-toggle-tags)
    (define-key bookmark-bmenu-mode-map (kbd "@") #'bmkp-gt-bmenu-toggle-type)))

(defun bmkp-gt-bmenu-tags-uninstall ()
  "Remove advice and key bindings installed by bookmark-plus-gt-tags."
  (advice-remove 'bmkp-bmenu-list-1               #'bmkp-gt-bmenu-list-1-advice)
  (advice-remove 'bookmark-bmenu-toggle-filenames #'bmkp-gt-bmenu-toggle-filenames-advice)
  (advice-remove 'bmkp-bmenu-mode-status-help     #'bmkp-gt-bmenu-help-advice)
  (when (boundp 'bookmark-bmenu-mode-map)
    (define-key bookmark-bmenu-mode-map (kbd ";") nil)
    (define-key bookmark-bmenu-mode-map (kbd "@") nil)))

(bmkp-gt-bmenu-tags-install)


(provide 'bookmark-plus-gt-tags)
;;; bookmark-plus-gt-tags.el ends here
