;;; bookmark-plus-gt.el --- Umbrella for bookmark-plus-gt features   -*- lexical-binding:t -*-
;;
;; Filename:    bookmark-plus-gt.el
;; Description: Loads the bookmark-plus-gt feature files selected by
;;              `bmkp-gt-features'.
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
;; Single `use-package' entry point for bookmark-plus-gt:
;;
;;   (use-package bookmark-plus-gt
;;     :load-path "~/.emacs.d/modules/bookmark-plus-gt"
;;     :straight nil
;;     :after bookmark+)
;;
;; Which feature files load is controlled by `bmkp-gt-features',
;; a list of symbols (default: all features on).  Set it before
;; the umbrella is required — from `use-package :init':
;;
;;   (use-package bookmark-plus-gt
;;     :init (setq bmkp-gt-features '(preview tags))  ; skip auto-update
;;     ...)
;;
;; The auto-update feature has an additional per-file toggle
;; (`bmkp-gt-auto-update-enable-flag') for controlling whether the
;; mode auto-enables *after* the file is loaded.  The umbrella flag
;; controls whether the file is loaded at all.

;;; Code:

(require 'bookmark)
(require 'bookmark+)

(declare-function bmkp-default-bookmark-name "bookmark+-1")

(defgroup bookmark-plus-gt nil
  "Non-invasive extensions to Bookmark+."
  :group 'bookmark-plus)

(defcustom bmkp-gt-features '(preview tags auto-update)
  "Feature files loaded by `bookmark-plus-gt'.
Each symbol NAME triggers a `require' of `bookmark-plus-gt-NAME'.

Set this before the umbrella is required — for example, in a
`use-package :init' block — otherwise the require happens with
the default (all features on)."
  :type '(set (const :tag "Preview / consult jump reader" preview)
              (const :tag "Tags and type columns"         tags)
              (const :tag "Auto-update reading position"  auto-update))
  :group 'bookmark-plus-gt)

(dolist (feat bmkp-gt-features)
  (require (intern (format "bookmark-plus-gt-%s" feat))))


;;; General commands (always loaded) ------------------------------------

;;;###autoload
(defun bmkp-gt-relocate-here (bookmark &optional set-auto-update)
  "Point BOOKMARK at the current buffer's file and position.
Preserves the bookmark's name, tags, annotation, handler, and
every property other than the location fields (filename,
buffer-name, position, context strings, and end-position).

Pins `end-position' to the new `position' so upstream's
region-restore path is not taken for the relocated bookmark.

With a prefix argument (non-nil SET-AUTO-UPDATE), also set the
`auto-update' property on BOOKMARK, so future reading-position
tracking is enabled (see `bmkp-gt-auto-update-mode')."
  (interactive
   (list (bookmark-completing-read "Relocate bookmark"
                                   (bmkp-default-bookmark-name))
         current-prefix-arg))
  (let* ((fresh  (bookmark-make-record-default))
         (pos    (alist-get 'position fresh)))
    (dolist (field '(filename buffer-name position
                     front-context-string rear-context-string
                     front-context-region-string rear-context-region-string))
      (bookmark-prop-set bookmark field (alist-get field fresh)))
    (when pos (bookmark-prop-set bookmark 'end-position pos))
    (when set-auto-update
      (bookmark-prop-set bookmark 'auto-update t))
    (when (called-interactively-p 'interactive)
      (message "Relocated `%s'%s." bookmark
               (if set-auto-update " (auto-update ON)" "")))))


(provide 'bookmark-plus-gt)
;;; bookmark-plus-gt.el ends here
