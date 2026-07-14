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

(declare-function bmkp-default-bookmark-name       "bookmark+-1")
(declare-function bmkp-this-file/buffer-alist-only "bookmark+-1")
(declare-function bmkp-this-buffer-p               "bookmark+-1")
(declare-function bmkp-same-file-p                 "bookmark+-1")
(declare-function bookmark--set-fringe-mark        "bookmark")
(declare-function bmkp-lighted-p                   "bookmark+-lit")
(declare-function bmkp-unlight-bookmark            "bookmark+-lit")
(declare-function bmkp-light-bookmark              "bookmark+-lit")

(defvar bookmark-set-fringe-mark)      ; In `bookmark' (Emacs 28+).

(defvar pdf-view--bookmark-to-restore) ; In `pdf-view' (pdf-tools).

(defconst bmkp-gt--refresh-preserve-fields
  '(id tags annotation auto-update
    created visits last-visited defaults)
  "Fields that survive an in-place bookmark-location refresh.
Every other field in the fresh record (produced by the buffer's
`bookmark-make-record-function') replaces the bookmark's stored
value.  Used by both `bmkp-gt-relocate-here' and the auto-update
tick.")

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


;;; Persistence backend for bookmark-plus runtime state (always-on) -----
;;
;; Bookmark-plus persists `bmkp-last-as-first-bookmark-file' (its
;; "last bookmark file used" memory) via `customize-save-variable',
;; which routes through Emacs's `custom-file'.  Users who point
;; `custom-file' at /dev/null (or any unwritable path) as a
;; "config-is-code, no Customize crumbs" gesture hit a `file-error'
;; every time bookmark-plus tries to persist — the error aborts
;; `bookmark-save', which in turn breaks anything downstream that
;; expected the save to complete (e.g. `bmkp-add-tags' never reaches
;; its `bmkp-refresh/rebuild-menu-list' call, so the list buffer
;; silently fails to autorefresh after `T +').  See
;; `ai/littering.org' for the full analysis.
;;
;; This layer intercepts `customize-save-variable' for a fixed
;; allowlist of symbols and persists them to a dedicated state file
;; (`bmkp-gt-state-file') instead.  All other symbols pass through
;; to Emacs's normal Customize machinery.  On load, the state file
;; is read once to restore any persisted values.

(defcustom bmkp-gt-state-file
  (locate-user-emacs-file "bookmark-plus-gt-state.el")
  "File where bookmark-plus-gt persists intercepted state variables.
See `bmkp-gt--persisted-vars' for the list of variables routed to
this file instead of `custom-file'.  Format is a self-contained
Emacs Lisp file — a series of `setq' forms, loadable with `load'."
  :type 'file
  :group 'bookmark-plus-gt)

(defvar bmkp-gt--persisted-vars
  '(bmkp-last-as-first-bookmark-file)
  "Symbols intercepted from `customize-save-variable' and persisted
via `bmkp-gt-state-file'.  See `bmkp-gt-state-file' commentary for
the rationale.")

(defun bmkp-gt--write-state ()
  "Serialize each var in `bmkp-gt--persisted-vars' to `bmkp-gt-state-file'.
Only bound vars are written; unbound ones are skipped silently."
  (let ((file bmkp-gt-state-file))
    (with-temp-file file
      (insert ";; -*- lexical-binding: t -*-\n")
      (insert ";; bookmark-plus-gt persisted state.  Auto-generated; do not edit.\n")
      (insert ";; See `bmkp-gt-state-file' and `bmkp-gt--persisted-vars'.\n\n")
      (dolist (sym bmkp-gt--persisted-vars)
        (when (boundp sym)
          (insert (format "(setq %s %S)\n" sym (symbol-value sym))))))))

(defun bmkp-gt-load-state ()
  "Restore persisted state from `bmkp-gt-state-file'.
Called at load time; safe to call again to re-load the file.  If
the file does not exist yet, no state has been persisted — silent
no-op."
  (when (file-readable-p bmkp-gt-state-file)
    (load bmkp-gt-state-file nil 'nomessage)))

(define-advice customize-save-variable
    (:around (orig sym val &optional comment) bmkp-gt-intercept-persistence)
  "Route persistence of `bmkp-gt--persisted-vars' to `bmkp-gt-state-file'.
For every other symbol, delegate to the original
`customize-save-variable'.  Runtime binding still advances via
`customize-set-variable' so the intercepted var behaves normally
in memory; only the file-write path is redirected."
  (if (memq sym bmkp-gt--persisted-vars)
      (progn (customize-set-variable sym val comment)
             (bmkp-gt--write-state))
    (funcall orig sym val comment)))

;; Restore persisted state now that the advice and file paths are set.
(bmkp-gt-load-state)


;;; General commands (always loaded) ------------------------------------

(defun bmkp-gt--refresh-bookmark-fringe (bookmark buffer old-pos)
  "In BUFFER, refresh the built-in fringe mark for BOOKMARK.
Removes any `category'-`bookmark' overlay at OLD-POS's line,
then places a fresh one at BOOKMARK's current stored `position'.
Silent no-op when `bookmark-set-fringe-mark' is nil or BUFFER
is not live.

Used by both `bmkp-gt-relocate-here' and the auto-update tick so
their fringe-update semantics stay identical."
  (when (and (boundp 'bookmark-set-fringe-mark)
             bookmark-set-fringe-mark
             (fboundp 'bookmark--set-fringe-mark)
             (buffer-live-p buffer))
    (with-current-buffer buffer
      ;; Remove the old overlay via explicit OLD-POS rather than
      ;; `bookmark--remove-fringe-mark' — the latter uses the
      ;; bookmark's *current* stored position, which we've already
      ;; updated, so it would miss the old overlay.
      (when old-pos
        (save-excursion
          (goto-char (min old-pos (point-max)))
          (dolist (o (overlays-in (pos-bol) (1+ (pos-bol))))
            (when (eq 'bookmark (overlay-get o 'category))
              (delete-overlay o)))))
      (let ((pos (bookmark-prop-get bookmark 'position)))
        (when pos
          (save-excursion
            (goto-char (min pos (point-max)))
            (bookmark--set-fringe-mark)))))))

(defun bmkp-gt--refresh-bookmark-lighting (bookmark)
  "Move BOOKMARK's `bookmark+-lit' overlay to the current stored position.
No-op when the bookmark was not lit — we do not force-light
bookmarks the user chose to leave unlit.  Bookmark identity is
carried on the overlay, so unlight+relight after a position
change works without knowing the old position."
  (when (and (fboundp 'bmkp-lighted-p)
             (bmkp-lighted-p bookmark))
    (bmkp-unlight-bookmark bookmark 'NOERRORP)
    (bmkp-light-bookmark bookmark)))


;;;###autoload
(defun bmkp-gt-relocate-here (bookmark &optional set-auto-update)
  "Point BOOKMARK at the current buffer's location.
Uses the buffer's own `bookmark-make-record-function' so the
update captures the mode-appropriate fields (page/slice/size
for PDF, info-node for Info, location for EWW, magit-hidden-
sections for magit, dired-directory for Dired, and so on).
Every field in the fresh record replaces the bookmark's stored
value, except those in `bmkp-gt--refresh-preserve-fields' (id,
tags, annotation, auto-update, created, visits, last-visited,
defaults).

Pins `end-position' to the new `position' so upstream's
region-restore path is not taken for the relocated bookmark.

With a prefix argument (non-nil SET-AUTO-UPDATE), also set the
`auto-update' property on BOOKMARK, so future reading-position
tracking is enabled (see `bmkp-gt-auto-update-mode')."
  (interactive
   (list (bookmark-completing-read "Relocate bookmark"
                                   (bmkp-default-bookmark-name))
         current-prefix-arg))
  (let* ((buffer  (current-buffer))
         (old-pos (bookmark-prop-get bookmark 'position))
         (raw
          ;; pdf-view's recorder short-circuits to the cached
          ;; bookmark when `pdf-view--bookmark-to-restore' is set.
          ;; Force a fresh snapshot by let-binding it to nil.
          (let ((pdf-view--bookmark-to-restore nil))
            (funcall bookmark-make-record-function)))
         ;; `bookmark-make-record-function' returns either a raw
         ;; data alist (default text recorder) or a (NAME . DATA)
         ;; pair (pdf-view, info, eww, magit, gnus, etc.).
         (fresh (if (stringp (car-safe raw)) (cdr raw) raw))
         (pos   (alist-get 'position fresh)))
    (dolist (cell fresh)
      (let ((field (car cell)))
        (unless (memq field bmkp-gt--refresh-preserve-fields)
          (bookmark-prop-set bookmark field (cdr cell)))))
    (when pos (bookmark-prop-set bookmark 'end-position pos))
    (when set-auto-update
      (bookmark-prop-set bookmark 'auto-update t))
    (bmkp-gt--refresh-bookmark-fringe   bookmark buffer old-pos)
    (bmkp-gt--refresh-bookmark-lighting bookmark)
    (when (called-interactively-p 'interactive)
      (message "Relocated `%s'%s." bookmark
               (if set-auto-update " (auto-update ON)" "")))))


(defun bmkp-gt--this-location-alist-only ()
  "Return `bookmark-alist' filtered to bookmarks pointing at this buffer.
Like `bmkp-this-file/buffer-alist-only', except any handler
qualifies: any bookmark whose `filename' resolves to the current
buffer's file counts.  Upstream's `bmkp-this-file-p' delegates to
`bmkp-file-bookmark-p', which excludes handler-specific bookmarks
(e.g. `org-bookmark-heading-jump', `pdf-view-bookmark-jump-handler')
even when their `filename' matches the visited file exactly.

Falls back to `bmkp-this-buffer-p' when the current buffer has
no file (magit, gnus, ...)."
  (bookmark-maybe-load-default-file)
  (let ((this-file (or (buffer-file-name)
                       (and (eq major-mode 'dired-mode)
                            (if (consp dired-directory)
                                (car dired-directory)
                              dired-directory)))))
    (if this-file
        (seq-filter (lambda (bm)
                      (let ((bf (bookmark-get-filename bm)))
                        (and bf (bmkp-same-file-p this-file bf))))
                    bookmark-alist)
      (seq-filter #'bmkp-this-buffer-p bookmark-alist))))

;;;###autoload
(defun bmkp-gt-relocate-this-file-here (bookmark &optional set-auto-update)
  "Relocate a bookmark for the current file/buffer to point at point.
Prompts only among bookmarks whose file is the current buffer's
file (or, for non-file buffers, whose buffer is the current
buffer).  If exactly one such bookmark exists, use it without
prompting.  Delegates the field surgery to `bmkp-gt-relocate-here'.

With a prefix argument (non-nil SET-AUTO-UPDATE), also set the
`auto-update' property on the chosen bookmark.

Signals an error when no bookmark points at this file/buffer."
  (interactive
   (let ((candidates (bmkp-gt--this-location-alist-only)))
     (cond
      ((null candidates)
       (user-error "No bookmarks point at this file/buffer"))
      ((null (cdr candidates))
       (list (bookmark-name-from-full-record (car candidates))
             current-prefix-arg))
      (t
       (list (bookmark-completing-read "Relocate bookmark (this file)"
                                       (bmkp-default-bookmark-name candidates)
                                       candidates)
             current-prefix-arg)))))
  (bmkp-gt-relocate-here bookmark set-auto-update)
  (message "Relocated `%s'%s." bookmark
           (if set-auto-update " (auto-update ON)" "")))


(provide 'bookmark-plus-gt)
;;; bookmark-plus-gt.el ends here
