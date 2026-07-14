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

(provide 'bookmark-plus-gt)
;;; bookmark-plus-gt.el ends here
