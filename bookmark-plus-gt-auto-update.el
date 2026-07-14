;;; bookmark-plus-gt-auto-update.el --- Reading-position tracking for bookmarks   -*- lexical-binding:t -*-
;;
;; Filename:    bookmark-plus-gt-auto-update.el
;; Description: Track a bookmark's position as its file is read.
;;              Part of bookmark-plus-gt.
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
;; A bookmark carrying the `auto-update' property is refreshed to the
;; current point of the buffer visiting its file, on three triggers:
;;
;;   - An idle timer firing every `bmkp-gt-auto-update-interval' seconds.
;;   - `kill-buffer-hook'         (catches "closing the file").
;;   - `window-state-change-hook' (catches "switching away").
;;
;; The refresh only runs while `bmkp-gt-auto-update-mode' is on.  The
;; mode auto-enables at load time when
;; `bmkp-gt-auto-update-enable-flag' is non-nil (the default).
;;
;; Display: `*Bookmark List*' shows a `^' in a fifth marks column for
;; each bookmark carrying the property.  The mark uses face
;; `bmkp-gt-caret-mark' when the mode is on, and
;; `bmkp-gt-caret-mark-inactive' (dim) when the mode is off — so the
;; user can see at a glance whether tracking is active.
;;
;; Key `^' in `bookmark-bmenu-mode-map' toggles the property on the
;; bookmark at point.  From outside the list, use
;; `bmkp-gt-auto-update-toggle'.
;;
;; No Bookmark+ source is modified.  `bmkp-bmenu-marks-width' is left
;; at 4 because upstream's render bakes in that value: it computes
;; `start = row-start + marks-width' for the text-property range and
;; `forward-char marks-width' for the bookmark-at-point lookup, both
;; assuming exactly 4 mark chars will be inserted.  Instead, an
;; `:around' advice on `bmkp-bmenu-list-1' runs after upstream renders
;; and inserts a fifth char (`^' or space) at column 4, propagating
;; upstream's `bmkp-bookmark-name' property onto the inserted char so
;; that `bookmark-bmenu-bookmark' still identifies the row correctly.

;;; Code:

(require 'bookmark)
(require 'bookmark+)
(require 'cl-lib)

(declare-function bmkp-bmenu-list-1              "bookmark+-bmu")
(declare-function bmkp-bmenu-mode-status-help    "bookmark+-bmu")
(declare-function bmkp-refresh/rebuild-menu-list "bookmark+-1")
(declare-function bmkp-same-file-p               "bookmark+-1")

(defvar bmkp-bmenu-marks-width)     ; In `bookmark+-bmu'.
(defvar bmkp-bmenu-header-lines)    ; In `bookmark+-bmu'.
(defvar bookmark-bmenu-mode-map)    ; In `bookmark+-bmu'.
(defvar bmkp-gt-auto-update-mode)   ; Defined below by `define-minor-mode'.


;;; Customization -------------------------------------------------------

(defgroup bookmark-plus-gt-auto-update nil
  "Reading-position tracking for bookmarks."
  :group 'bookmark-plus-gt)

(defcustom bmkp-gt-auto-update-enable-flag t
  "Non-nil means auto-enable `bmkp-gt-auto-update-mode' at load time.
When nil, the file is loaded and the advice + marks-column widening
still install, but the mode itself stays off until the user calls
`bmkp-gt-auto-update-mode' explicitly.  Existing auto-update
bookmarks then render with the inactive face."
  :type 'boolean
  :group 'bookmark-plus-gt-auto-update)

(defcustom bmkp-gt-auto-update-interval 60
  "Seconds of idle time between ticks of `bmkp-gt-auto-update-mode'."
  :type 'integer
  :group 'bookmark-plus-gt-auto-update)


;;; Faces ---------------------------------------------------------------

(defface bmkp-gt-caret-mark
  '((((background dark)) (:foreground "Cyan"    :weight bold))
    (t                   (:foreground "DarkCyan" :weight bold)))
  "Face for the auto-update mark (`^') when the mode is on."
  :group 'bookmark-plus-gt-auto-update)

(defface bmkp-gt-caret-mark-inactive
  '((t :inverse-video t :inherit bmkp-gt-caret-mark))
  "Face for the auto-update mark (`^') when the mode is off.
Same colors as `bmkp-gt-caret-mark' but inverse-video, so the
bookmark is visually flagged: property is set, but tracking is
not currently running."
  :group 'bookmark-plus-gt-auto-update)


;;; Predicate + refresh -------------------------------------------------

(defun bmkp-gt-auto-update--enabled-p (bmk)
  "Return non-nil if bookmark record BMK has the `auto-update' property."
  (bookmark-prop-get (car bmk) 'auto-update))

(defun bmkp-gt-auto-update--refresh (bmk buffer)
  "Refresh BMK's location from BUFFER's current point.
Updates position, front/rear context strings, and pins
`end-position' to the same point so the bookmark reads as a
point-not-a-region.  Otherwise, when `bmkp-use-region' is on,
upstream's region-restore path fires and errors on bookmarks
that never had a saved region (nil `front-context-region-string'
passed to `string='.  Leaves name, tags, annotation, handler
intact."
  (with-current-buffer buffer
    (let* ((fresh (cdr (bookmark-make-record-default)))
           (new-pos (alist-get 'position fresh)))
      (dolist (field '(position front-context-string rear-context-string))
        (let ((val (alist-get field fresh)))
          (when val (bookmark-prop-set (car bmk) field val))))
      (when new-pos
        (bookmark-prop-set (car bmk) 'end-position new-pos)))))

(defun bmkp-gt-auto-update--tick (&optional only-buffer)
  "Refresh auto-update bookmarks whose file is currently visited.
With ONLY-BUFFER non-nil, restrict to the bookmark whose file is
that buffer's `buffer-file-name'."
  (let ((target-file (and only-buffer (buffer-file-name only-buffer))))
    (dolist (bmk bookmark-alist)
      (when (bmkp-gt-auto-update--enabled-p bmk)
        (let* ((file (bookmark-get-filename bmk))
               (buf  (cond
                      (target-file
                       (and file (bmkp-same-file-p file target-file) only-buffer))
                      (file
                       (find-buffer-visiting file)))))
          (when (buffer-live-p buf)
            (bmkp-gt-auto-update--refresh bmk buf)))))))

;;;###autoload
(defun bmkp-gt-auto-update-now ()
  "Force an immediate refresh of every auto-update bookmark.
Refreshes any bookmark carrying the `auto-update' property whose
file is currently visited by a live buffer."
  (interactive)
  (bmkp-gt-auto-update--tick)
  (when (called-interactively-p 'interactive)
    (message "Auto-update bookmarks refreshed.")))


;;; Timer + hooks -------------------------------------------------------

(defvar bmkp-gt-auto-update--timer nil
  "Internal idle timer for `bmkp-gt-auto-update-mode'.")

(defun bmkp-gt-auto-update--on-kill-buffer ()
  "Refresh auto-update bookmarks for the buffer being killed."
  (when (and bmkp-gt-auto-update-mode (buffer-file-name))
    (bmkp-gt-auto-update--tick (current-buffer))))

(defun bmkp-gt-auto-update--on-window-state-change ()
  "Run a global auto-update tick on every window-state change."
  (when bmkp-gt-auto-update-mode
    (bmkp-gt-auto-update--tick)))

;;;###autoload
(define-minor-mode bmkp-gt-auto-update-mode
  "Toggle global auto-tracking of bookmarks with the `auto-update' property.

When on, three triggers refresh such a bookmark's position and
context strings to the current point of the buffer visiting its
file:

  - An idle timer firing every `bmkp-gt-auto-update-interval' seconds.
  - `kill-buffer-hook'         (catches \"closing the file\").
  - `window-state-change-hook' (catches \"switching away\").

Bookmarks without the property are not touched.  Files whose
buffer is not currently visited are not touched either.

The auto-update mark in `*Bookmark List*' uses face
`bmkp-gt-caret-mark' while this mode is on, and
`bmkp-gt-caret-mark-inactive' while it is off.

Set the property on a bookmark with `bmkp-gt-auto-update-toggle'
or by pressing `^' in `*Bookmark List*'."
  :init-value nil :global t :group 'bookmark-plus-gt-auto-update
  (when bmkp-gt-auto-update--timer
    (cancel-timer bmkp-gt-auto-update--timer)
    (setq bmkp-gt-auto-update--timer nil))
  (cond
   (bmkp-gt-auto-update-mode
    (setq bmkp-gt-auto-update--timer
          (run-with-idle-timer bmkp-gt-auto-update-interval 'REPEAT
                               #'bmkp-gt-auto-update--tick))
    (add-hook 'kill-buffer-hook         #'bmkp-gt-auto-update--on-kill-buffer)
    (add-hook 'window-state-change-hook #'bmkp-gt-auto-update--on-window-state-change))
   (t
    (remove-hook 'kill-buffer-hook         #'bmkp-gt-auto-update--on-kill-buffer)
    (remove-hook 'window-state-change-hook #'bmkp-gt-auto-update--on-window-state-change)))
  ;; The mark's face depends on the mode; redisplay the list if it exists.
  (when (get-buffer "*Bookmark List*")
    (bmkp-refresh/rebuild-menu-list nil 'no-msg)))


;;; Toggle command ------------------------------------------------------

;;;###autoload
(defun bmkp-gt-auto-update-toggle (bookmark)
  "Toggle the `auto-update' property on BOOKMARK.
When on, `bmkp-gt-auto-update-mode' periodically refreshes the
bookmark's position to point in the buffer visiting its file.

Does not save the bookmark file — `bookmark-prop-set' (redefined
by Bookmark+) already tracks the change in `bmkp-modified-bookmarks',
and disk save follows the normal Bookmark+ triggers.  This matches
`bmkp-toggle-temporary-bookmark' and other in-place property toggles."
  (interactive (list (bookmark-completing-read "Bookmark" (bmkp-default-bookmark-name))))
  (let* ((was-on (bookmark-prop-get bookmark 'auto-update))
         (now-on (not was-on)))
    (bookmark-prop-set bookmark 'auto-update now-on)
    (bmkp-refresh/rebuild-menu-list bookmark 'no-msg)
    (message "Auto-update %s for `%s'." (if now-on "ON" "OFF") bookmark)))

(defun bmkp-gt-auto-update-bmenu-toggle ()
  "Toggle the `auto-update' property on the bookmark at point.
For use inside `*Bookmark List*'.  Bound to `^'."
  (interactive)
  (let ((name (bookmark-bmenu-bookmark)))
    (unless name (user-error "No bookmark on this line"))
    (bmkp-gt-auto-update-toggle name)))


;;; Marks-column widening + `^' overlay ---------------------------------

(defun bmkp-gt-auto-update--face ()
  "Return the face to use for the `^' mark, based on mode state."
  (if bmkp-gt-auto-update-mode 'bmkp-gt-caret-mark 'bmkp-gt-caret-mark-inactive))

(defun bmkp-gt-auto-update--paint-column ()
  "Walk every row of the current bmenu buffer and insert `^' at col 4.
For rows whose bookmark carries the `auto-update' property, insert
`^' with the appropriate face; otherwise insert a plain space.
The inserted char inherits the `bmkp-bookmark-name' text property
from what was at col 4 (upstream's first char of the name) before
the insert, so `bookmark-bmenu-bookmark' still resolves the row
via its `forward-char marks-width' lookup."
  (save-excursion
    (goto-char (point-min))
    (forward-line bmkp-bmenu-header-lines)
    (let ((inhibit-read-only t)
          (face             (bmkp-gt-auto-update--face)))
      (while (< (point) (point-max))
        (let ((name (bookmark-bmenu-bookmark)))
          (when name
            (let* ((bmk        (bookmark-get-bookmark name 'NOERROR))
                   (enabled-p  (and bmk (bmkp-gt-auto-update--enabled-p bmk))))
              (move-to-column 4 t)
              (let* ((row-name-prop (get-text-property (point) 'bmkp-bookmark-name))
                     (base-props    (and row-name-prop
                                         (list 'bmkp-bookmark-name row-name-prop))))
                (insert (apply #'propertize
                               (if enabled-p "^" " ")
                               (append (and enabled-p (list 'face face))
                                       base-props)))))))
        (forward-line 1)))))

(defun bmkp-gt-auto-update--list-1-advice (orig-fn &rest args)
  "Run ORIG-FN, then paint the `^' auto-update column."
  (apply orig-fn args)
  (with-current-buffer (get-buffer-create "*Bookmark List*")
    (bmkp-gt-auto-update--paint-column)))


;;; Legend --------------------------------------------------------------

(defun bmkp-gt-auto-update--legend-advice (&rest _args)
  "Append a `^' entry to the marks legend in the *Help* buffer.
Runs `:after' `bmkp-bmenu-mode-status-help', which populates
`*Help*' via `bmkp-with-help-window' and freezes it read-only.
Locates the `X temporary (will not be saved)' line and inserts a
`^' auto-update line right after it.  The description reflects
whether `bmkp-gt-auto-update-mode' is currently on or off."
  (let ((buf  (get-buffer "*Help*")))
    (when buf
      (with-current-buffer buf
        (let ((inhibit-read-only  t))
          (save-excursion
            (goto-char (point-min))
            (when (search-forward "temporary (will not be saved)" nil t)
              (end-of-line)
              (let ((caret   (propertize "^" 'face (bmkp-gt-auto-update--face)))
                    (status  (if bmkp-gt-auto-update-mode
                                 "(position tracked as you read)"
                               "(tracking mode disabled)")))
                (insert "\n  " caret "  auto-update  (`^' to toggle)  " status)))))))))


;;; Install / uninstall -------------------------------------------------

(defun bmkp-gt-auto-update-install ()
  "Register advices and install the `^' keybinding.
Idempotent.  Called at load time when
`bmkp-gt-auto-update-enable-flag' is non-nil."
  (advice-add 'bmkp-bmenu-list-1 :around
              #'bmkp-gt-auto-update--list-1-advice
              '((depth . -100)))
  (advice-add 'bmkp-bmenu-mode-status-help :after
              #'bmkp-gt-auto-update--legend-advice)
  (define-key bookmark-bmenu-mode-map (kbd "^") #'bmkp-gt-auto-update-bmenu-toggle))

(defun bmkp-gt-auto-update-uninstall ()
  "Reverse `bmkp-gt-auto-update-install'."
  (advice-remove 'bmkp-bmenu-list-1 #'bmkp-gt-auto-update--list-1-advice)
  (advice-remove 'bmkp-bmenu-mode-status-help #'bmkp-gt-auto-update--legend-advice)
  (when (eq (lookup-key bookmark-bmenu-mode-map (kbd "^"))
            #'bmkp-gt-auto-update-bmenu-toggle)
    (define-key bookmark-bmenu-mode-map (kbd "^") nil)))


;;; Auto-install --------------------------------------------------------

(when bmkp-gt-auto-update-enable-flag
  (bmkp-gt-auto-update-install)
  (bmkp-gt-auto-update-mode 1))


(provide 'bookmark-plus-gt-auto-update)
;;; bookmark-plus-gt-auto-update.el ends here
