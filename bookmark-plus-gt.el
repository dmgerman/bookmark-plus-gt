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
;; Version: 0.2.2
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
;; `use-package' entry point for bookmark-plus-gt:
;;
;;   (use-package bookmark-plus-gt
;;     :load-path "~/.emacs.d/modules/bookmark-plus-gt"
;;     :straight nil
;;     :after bookmark+
;;     :config
;;     (bmkp-gt-bmenu-tags-mode 1)
;;     (bmkp-gt-auto-update-mode 1)
;;     (bmkp-gt-browsel-tabs-mode 1)
;;     (bmkp-gt-default-tags-mode 1))
;;
;; Loading this file requires every feature file (jump, tags,
;; auto-update, browsel-tabs); enable the ones you want by turning on
;; the corresponding global minor mode.  The always-on pieces set up
;; here — the `bookmark--jump-via' display fix, the state-file
;; persistence intercept, and the `bmkp-gt-relocate-here' commands —
;; run unconditionally.

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

(defconst bmkp-gt-version "0.2.2"
  "Version of the bookmark-plus-gt package.
Three-part MAJOR.MINOR.PATCH string.  Kept in sync with the
`;; Version:' header at the top of this file, which
`package.el' reads.")

;;;###autoload
(defun bmkp-gt-version ()
  "Display the bookmark-plus-gt version and return it as a string."
  (interactive)
  (message "bookmark-plus-gt %s" bmkp-gt-version)
  bmkp-gt-version)

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


;;; Preserve point across `bookmark-bmenu-execute-deletions' ------------
;;
;; Upstream's `bookmark-bmenu-execute-deletions' (bookmark+-bmu.el) sets
;; `o-str' to the bookmark name at point only when the current line is
;; NOT itself flagged/marked for deletion.  In the common case where the
;; user marks the row they are on (`d' then `x'), `o-str' is nil and the
;; fallback branch runs `(goto-char o-point) (beginning-of-line)'.
;; After a full buffer erase + re-render inside a `save-excursion',
;; that fallback is unreliable — point often lands on the header area
;; or the first bookmark rather than the row after the one that was
;; deleted.
;;
;; This advice records the nearest surviving bookmark (below point
;; first, then above) before calling upstream and navigates to it
;; after.  Both passes are wrapped in `condition-case' so any failure
;; here can never block the underlying deletion.

(declare-function bmkp-looking-at-p         "bookmark+-bmu")
(declare-function bmkp-bmenu-goto-bookmark-named "bookmark+-bmu")

(defun bmkp-gt--find-non-marked-row (direction)
  "Search DIRECTION lines from point for the first non-marked bookmark row.
DIRECTION is +1 (down) or -1 (up).  Returns the row's bookmark
name, or nil.  A row is `non-marked' when its first column is
neither `D' nor `>' — i.e. it will not be affected by
`bookmark-bmenu-execute-deletions'."
  (save-excursion
    (let ((found  nil))
      (while (and (not found) (zerop (forward-line direction)))
        (unless (bmkp-looking-at-p "^[D>]")
          (let ((name  (bookmark-bmenu-bookmark)))
            (when (and name (not (string-empty-p name)))
              (setq found name)))))
      found)))

(defun bmkp-gt--find-post-delete-target ()
  "Return the name of the nearest surviving bookmark around point.
Looks below first (next non-marked row), then above (previous
non-marked row).  Returns nil when no unmarked bookmark row
remains in the buffer."
  (or (bmkp-gt--find-non-marked-row  1)
      (bmkp-gt--find-non-marked-row -1)))

(defun bmkp-gt--execute-deletions-around (orig-fn &rest args)
  "`:around' advice on `bookmark-bmenu-execute-deletions'.
Records the nearest non-marked bookmark before the deletion (below
point first, then above) and, after ORIG-FN returns, navigates to
that bookmark.  Errors in either the pre or the post pass are
demoted to a warning so ORIG-FN always runs and its return value
is passed through unchanged."
  (let ((target  (condition-case err
                     (bmkp-gt--find-post-delete-target)
                   (error
                    (display-warning
                     'bookmark-plus-gt
                     (format "post-delete target search failed: %s"
                             (error-message-string err))
                     :warning)
                    nil))))
    (prog1 (apply orig-fn args)
      (when target
        (condition-case err
            (bmkp-bmenu-goto-bookmark-named target)
          (error
           (display-warning
            'bookmark-plus-gt
            (format "post-delete navigation to %S failed: %s"
                    target (error-message-string err))
            :warning)))))))

(advice-add 'bookmark-bmenu-execute-deletions
            :around #'bmkp-gt--execute-deletions-around)


;;; Same-named bookmarks — safety guards (always-on) -------------------
;;
;; Upstream `bookmark-set' silently merges into an existing bookmark of
;; the same name — the new record picks up the old record's `tags' and
;; `annotation' via `bmkp-properties-to-keep' (default '(tags
;; annotation)) — so a second `bookmark-set' at a different location
;; with the same name absorbs the previous bookmark's tags rather than
;; creating a distinct bookmark.  Bookmark-plus-gt turns on the
;; confirm-on-overwrite prompt so the merge cannot happen silently.
;;
;; Separately, verify `bmkp-propertize-bookmark-names-flag' — bookmark-
;; plus needs it non-nil so that `C-u M-x bookmark-set' can hold
;; multiple bookmarks with the same literal name in `bookmark-alist',
;; disambiguated by text properties on the name string.  It's the
;; default on Emacs > 20; we only check and warn.  The same
;; disambiguation lets `bookmark-load' safely rename collisions to
;; NAME<2>, NAME<3>, ...

(defvar bmkp-bookmark-set-confirms-overwrite-p)
(defvar bmkp-propertize-bookmark-names-flag)

(setq bmkp-bookmark-set-confirms-overwrite-p t)

(unless (and (boundp 'bmkp-propertize-bookmark-names-flag)
             bmkp-propertize-bookmark-names-flag)
  (display-warning
   'bookmark-plus-gt
   "`bmkp-propertize-bookmark-names-flag' is nil; same-named bookmarks may collide silently."
   :warning))


;;; Load-order stack sort ---------------------------------------------
;;
;; Bookmark files loaded on top of each other form a stack: the file
;; loaded most recently is the top of the stack, and its bookmarks
;; should sort first in `*Bookmark List*'.  Bookmark-plus does not
;; track load order out of the box, so we tag each loaded bookmark
;; with a monotonic `bmkp-gt-load-index' property (higher = more
;; recently loaded) and expose a comparer `bmkp-gt-sort-by-load-order'
;; the user opts into via `bmkp-sort-comparer'.
;;
;; The initial auto-load path (`bookmark-maybe-load-default-file' →
;; `bookmark-load') runs through the same advice, so the default
;; bookmark file's entries get index 1; a subsequent `M-x
;; bookmark-load' gets index 2; and so on.  Bookmarks created in
;; the current session with `bookmark-set' carry no index — the
;; comparer treats them as `most-positive-fixnum' so they sort at
;; the top (they are the freshest); ties fall through to whatever
;; next comparer bookmark-plus is chaining.

(defvar bmkp-gt--load-counter 0
  "Monotonic counter incremented on every `bookmark-load' call.
Used by `bmkp-gt--stamp-load-index' to assign a `bmkp-gt-load-index'
property to each loaded bookmark.  Reset only by killing Emacs.")

(defun bmkp-gt--stamp-load-index (blist)
  "`:filter-return' advice on `bookmark-load'.
BLIST is the list of freshly-loaded bookmarks returned by
`bookmark-load'.  Increment `bmkp-gt--load-counter' and stamp each
bookmark in BLIST with that new value under property
`bmkp-gt-load-index' — but only if the bookmark does not already
carry an index (so a re-load preserves the earlier assignment).
Returns BLIST unchanged so `bookmark-load's contract is preserved."
  (setq bmkp-gt--load-counter (1+ bmkp-gt--load-counter))
  (dolist (bmk blist)
    (unless (bookmark-prop-get bmk 'bmkp-gt-load-index)
      (bookmark-prop-set bmk 'bmkp-gt-load-index bmkp-gt--load-counter)))
  blist)

(advice-add 'bookmark-load :filter-return #'bmkp-gt--stamp-load-index)


;;; File-rename tracking (always-on) ----------------------------------
;;
;; When a file or directory is renamed through Emacs (dired `R',
;; `rename-visited-file', any Lisp call to `rename-file'), rewrite
;; every bookmark whose `filename' equals the renamed path, or lives
;; under it in the directory-rename case, to the new path.
;;
;; Installed as `:after' advice on `rename-file'.  The OS-level
;; rename has already succeeded by the time we run, so the advice
;; must NEVER signal back to the caller — otherwise a successful
;; rename would look like a failure.  Two `condition-case' traps
;; guard against that: a per-bookmark inner trap so one bad record
;; does not stop the sweep, and an outer trap so nothing escapes.
;;
;; Non-file bookmarks (URL / EWW / etc., identified by
;; `bmkp-non-file-filename') are skipped.  Renames performed outside
;; Emacs (shell, Finder, `git mv') are not covered — those would
;; need file-notify watches, which are much heavier.

(defvar bmkp-non-file-filename)         ; In `bookmark+-1.el'.

(defun bmkp-gt-on-file-rename (oldname newname &rest _)
  "Update bookmarks whose filename equals or lives under OLDNAME to NEWNAME.
Never signals: any internal error is caught and logged.  Runs as
`:after' advice on `rename-file'."
  (condition-case err
      (save-match-data
        (let* ((old      (expand-file-name oldname))
               (new      (expand-file-name newname))
               (old-dir  (file-name-as-directory old))
               (new-dir  (file-name-as-directory new))
               (dir-p    (file-directory-p new))
               (changed  0))
          (dolist (bm bookmark-alist)
            (condition-case per-bm
                (let ((f (bookmark-get-filename bm)))
                  (when (and f
                             (stringp f)
                             (not (string= f bmkp-non-file-filename)))
                    (let ((abs (expand-file-name f)))
                      (cond
                       ((string= abs old)
                        (bookmark-set-filename bm new)
                        (cl-incf changed))
                       ((and dir-p (string-prefix-p old-dir abs))
                        (bookmark-set-filename
                         bm (concat new-dir (substring abs (length old-dir))))
                        (cl-incf changed))))))
              (error
               (message "bmkp-gt-on-file-rename: skipped %S: %s"
                        (car-safe bm) (error-message-string per-bm)))))
          (when (> changed 0)
            (setq bookmark-alist-modification-count
                  (1+ bookmark-alist-modification-count))
            (message "bmkp-gt: updated %d bookmark(s) after rename of %s"
                     changed (abbreviate-file-name old)))))
    (error
     (message "bmkp-gt-on-file-rename: failed (%s)"
              (error-message-string err)))))

(advice-add 'rename-file :after #'bmkp-gt-on-file-rename)


;;;###autoload
(defun bmkp-gt-creation-oldest-cp (b1 b2)
  "Comparer: bookmark created earlier sorts first (ascending by age).
Reads the upstream `created' timestamp on each record.  Returns:
  `(t)'   — B1 was created strictly before B2
  `(nil)' — B2 was created strictly before B1
  nil     — either bookmark has no `created' entry, or the two
            timestamps are equal (tie, fall through)

Intended as the second predicate after `bmkp-gt-sort-by-load-order':
within a single load, bookmarks from the file are ordered oldest
first.  Bookmarks without a `created' entry (older bookmarks predate
the field, or the entry has been stripped) fall through to whatever
final comparer bookmark-plus chains underneath — typically
`bmkp-alpha-p'."
  (setq b1  (bmkp-get-bookmark b1)
        b2  (bmkp-get-bookmark b2))
  (let ((t1  (bookmark-prop-get b1 'created))
        (t2  (bookmark-prop-get b2 'created)))
    (when (and t1 t2)
      (let ((f1  (bmkp-float-time t1))
            (f2  (bmkp-float-time t2)))
        (cond ((< f1 f2) '(t))
              ((> f1 f2) '(nil))
              (t         nil))))))

;;;###autoload
(defun bmkp-gt-sort-by-load-order (b1 b2)
  "Comparer: bookmarks from a more-recent `bookmark-load' sort first.
Reads `bmkp-gt-load-index' from each bookmark record.  Higher index
sorts before lower.  Bookmarks with no index (created in-session via
`bookmark-set') are treated as `most-positive-fixnum' so they sort at
the top with each other; ties (same index) return nil so bookmark-
plus's chained comparer takes over — usually alphabetical.

Return value follows bookmark-plus's comparer convention:
  `(t)'   — B1 sorts before B2
  `(nil)' — B2 sorts before B1
  nil     — incomparable / tie, fall through.

To make this the default sort in `*Bookmark List*':
  (setq bmkp-sort-comparer #\\='bmkp-gt-sort-by-load-order)"
  (setq b1  (bmkp-get-bookmark b1)
        b2  (bmkp-get-bookmark b2))
  (let* ((max-idx  most-positive-fixnum)
         (i1  (or (bookmark-prop-get b1 'bmkp-gt-load-index) max-idx))
         (i2  (or (bookmark-prop-get b2 'bmkp-gt-load-index) max-idx)))
    (cond ((> i1 i2)  '(t))
          ((< i1 i2)  '(nil))
          (t          nil))))



;;; Feature files ------------------------------------------------------
;;
;; All optional feature files are loaded here so users need only
;; `(require 'bookmark-plus-gt)' (or `use-package bookmark-plus-gt') to
;; make every mode available.  Each file defines a global minor mode
;; but attaches no side effects at load; enable a feature with:
;;
;;     (bmkp-gt-bmenu-tags-mode 1)
;;     (bmkp-gt-auto-update-mode 1)
;;     (bmkp-gt-browsel-tabs-mode 1)
;;     (bmkp-gt-default-tags-mode 1)

(require 'bookmark-plus-gt-jump)
(require 'bookmark-plus-gt-tags)
(require 'bookmark-plus-gt-auto-update)
(require 'bookmark-plus-gt-default-tags)

;; The browsel-tabs module hard-requires `browsel'.  When browsel is
;; not installed, skip the load — the mode simply is not available.
(when (locate-library "browsel")
  (require 'bookmark-plus-gt-browsel-tabs))


(provide 'bookmark-plus-gt)
;;; bookmark-plus-gt.el ends here
