;;; bookmark-plus-gt.el --- Entry point for bookmark-plus-gt features   -*- lexical-binding:t -*-
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
;; the entry point is required — from `use-package :init':
;;
;;   (use-package bookmark-plus-gt
;;     :init (setq bmkp-gt-features '(preview tags))  ; skip auto-update
;;     ...)
;;
;; The auto-update feature has an additional per-file toggle
;; (`bmkp-gt-auto-update-enable-flag') for controlling whether the
;; mode auto-enables *after* the file is loaded.  The entry-point
;; flag controls whether the file is loaded at all.

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

Set this before the entry point is required — for example, in a
`use-package :init' block — otherwise the require happens with
the default (all features on)."
  :type '(set (const :tag "Preview / consult jump reader" preview)
              (const :tag "Tags and type columns"         tags)
              (const :tag "Auto-update reading position"  auto-update))
  :group 'bookmark-plus-gt)

(dolist (feat bmkp-gt-features)
  (require (intern (format "bookmark-plus-gt-%s" feat))))


;;; Bug 1 — Custom-handler jumps do not display (always-on) -------------
;;
;; Under `bookmark-plus', `bookmark--jump-via' deliberately does NOT
;; call the caller's DISPLAY-FUNCTION after the handler returns — the
;; handler is expected to consult `bmkp-jump-display-function' itself.
;; Only the default handler path does that; every custom handler
;; (PDF, EWW, Info, Gnus, Man, image, org, third-party) follows the
;; vanilla contract (set-buffer, leave display to caller), so nothing
;; visible happens.
;;
;; See `ai/plus-potential-bugs.org' entry "Bug 1" and
;; `bookmark-x-1.el' (upstream reference).
;;
;; Design: explicit whitelist, no window-state observation.  Every
;; handler in `bmkp-gt-jump-via-displays-itself' is trusted to arrange
;; display; every other handler (including nil = default, and every
;; third-party set-buffer handler) gets DISPLAY-FUNCTION called after
;; the handler returns.
;;
;; We deliberately do NOT observe window state (as an earlier
;; Approach C did) — window-state heuristics produced false positives:
;; a prior split, a consult preview, or an unrelated hook could all
;; make "the destination is already visible somewhere" fire when the
;; handler had only set-buffer'd.  The whitelist is deterministic.
;;
;; Also `let'-binds `bmkp-jump-display-function' (via `unwind-protect'
;; around a saved value) so nested jumps — e.g. `find-file-noselect'
;; inside `bookmark-default-handler' running `find-file-hook' which
;; calls back into the bookmark dispatch — cannot clobber the outer
;; call's display function.
;;
;; Implementation is `:around' advice on `bookmark--jump-via' that
;; uses `cl-letf' to intercept the single `bookmark-handle-bookmark'
;; call inside it — not the function itself globally, because
;; `bookmark-jump-noselect' and `bmkp-handle-region+narrow-indirect'
;; also call it and must remain unaffected.

(require 'cl-lib)

(declare-function bmkp-get-bookmark "bookmark+-1")

(defvar bmkp-jump-display-function)     ; In `bookmark+-1.el'.

(defconst bmkp-gt-jump-via-displays-itself
  '(nil
    ;; Route through `bookmark-default-handler', which calls the
    ;; display function via `bmkp-goto-position'.
    bookmark-default-handler
    ;; Delegate to `bookmark-default-handler' internally.
    bmkp-jump-gnus bmkp-jump-woman bmkp-jump-man
    ;; Have their own `display-buffer'/`pop-to-buffer' logic.
    bmkp-jump-dired
    bmkp-jump-bookmark-list bmkp-jump-bookmark-file
    bmkp-jump-variable-list
    ;; Non-window operations (browser, snippet kill-ring, sound, etc.).
    bmkp-jump-w3m bmkp-jump-w3m-new-buffer bmkp-jump-w3m-only-one-buffer
    bmkp-jump-url-browse
    bmkp-jump-desktop
    bmkp-jump-snippet bmkp-jump-sequence bmkp-jump-function
    bmkp-sound-jump)
  "Handlers that arrange their own display for `bookmark-jump'.
For any handler not on this list, `bmkp-gt-jump-display--jump-via-advice'
calls its DISPLAY-FUNCTION after the handler returns.")

(defun bmkp-gt-jump-display--jump-via-advice (orig-fn bookmark &optional display-function)
  "Around advice on `bookmark--jump-via'.
If BOOKMARK's handler is not in `bmkp-gt-jump-via-displays-itself',
call DISPLAY-FUNCTION on the destination after the handler runs.
Also restores `bmkp-jump-display-function' on exit so nested jumps
cannot clobber the outer call's value."
  (let* ((bmk         (and bookmark (bmkp-get-bookmark bookmark 'NOERROR)))
         (handler     (and bmk (or (bookmark-prop-get bmk 'file-handler)
                                   (bookmark-get-handler bmk))))
         (real-handle (symbol-function 'bookmark-handle-bookmark))
         (prev-df     (and (boundp 'bmkp-jump-display-function)
                           bmkp-jump-display-function)))
    (unwind-protect
        (cl-letf (((symbol-function 'bookmark-handle-bookmark)
                   (lambda (bm)
                     (funcall real-handle bm)
                     (when (and display-function
                                (not (memq handler
                                           bmkp-gt-jump-via-displays-itself)))
                       (funcall display-function (current-buffer))))))
          (funcall orig-fn bookmark display-function))
      (when (boundp 'bmkp-jump-display-function)
        (setq bmkp-jump-display-function prev-df)))))

(advice-add 'bookmark--jump-via :around #'bmkp-gt-jump-display--jump-via-advice)


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
