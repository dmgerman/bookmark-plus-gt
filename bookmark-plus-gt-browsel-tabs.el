;;; bookmark-plus-gt-browsel-tabs.el --- Temporary bookmarks for open browser tabs -*- lexical-binding:t -*-
;;
;; Filename:    bookmark-plus-gt-browsel-tabs.el
;; Description: Expose the browser's open tabs as temporary URL bookmarks.
;;              Part of bookmark-plus-gt.
;;
;; Author:     Daniel M. German
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;;
;; Copyright (C) 2026, Daniel M. German, all rights reserved.
;;
;; URL: https://github.com/dmgerman/bookmark-plus-gt
;;
;; Keywords:      bookmarks, convenience, browser
;; Compatibility: GNU Emacs 30+
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; Assisted-by: Claude:claude-opus-4-7

;;; Commentary:
;;
;; Populate `bookmark-alist' with temporary bookmarks representing the
;; browser tabs currently reported by `browsel-browser-tabs'.  Each
;; entry is a URL/Web bookmark of its own bookmark type:
;;
;;   - handler `bmkp-gt-browsel-tabs-jump' focuses the tab via
;;     `browsel-focus-tab', falling back to `browsel-browse-url' when
;;     the tab id or its owning browser is stale.
;;   - predicate `bmkp-gt-browsel-tabs-p' recognises the type.
;;   - `bmkp-url-bookmark-p' is advised so URL-only commands and
;;     filters (e.g. `bmkp-url-jump', `bmkp-bmenu-show-only-urls')
;;     also include browsel-tab bookmarks.
;;
;; Each record carries:
;;
;;   name       — the tab URL, suffixed <2>/<3>/... on name collision
;;   annotation — the tab title
;;   location   — the tab URL
;;   browsel-id, browsel-browser — used by the handler to focus the tab
;;   bmkp-temp  — t (temporary; not saved to disk)
;;
;; The entries are refreshed automatically before any function that
;; would otherwise show a stale list:
;;
;;   `bookmark-bmenu-list', `bookmark-completing-read',
;;   `bmkp-url-jump', `bmkp-url-jump-other-window'.
;;
;; Manual refresh: M-x `bmkp-gt-browsel-tabs-refresh'.
;;
;; Filtering: `bmkp-gt-browsel-tabs-filter' takes nil (all), a regexp
;; matched against the tab URL, or a predicate function of the tab
;; plist.  Browser selection: `bmkp-gt-browsel-tabs-browsers' is
;; passed straight to `browsel-browser-tabs' (nil, a browser name, or
;; a list of names).
;;
;; When the browser is disconnected at refresh time, this module
;; issues a warning and continues — existing bookmarks (of any type)
;; keep working; the browsel-tab set is simply empty until the browser
;; reconnects.

;;; Code:

(require 'bookmark)
(require 'bookmark+)
(require 'browsel)
(require 'seq)

(declare-function browsel-browser-tabs "browsel")
(declare-function browsel-focus-tab    "browsel")
(declare-function browsel-close-tab    "browsel")
(declare-function browsel-browse-url   "browsel-url-handler")
(declare-function bmkp-make-bookmark-temporary "bookmark+-1")
(declare-function bmkp-url-bookmark-p          "bookmark+-1")

(defvar bmkp-non-file-filename)         ; In `bookmark+-1'.


;;; Customization -------------------------------------------------------

(defgroup bookmark-plus-gt-browsel-tabs nil
  "Temporary bookmarks for open browser tabs via browsel."
  :group 'bookmark-plus-gt)

(defcustom bmkp-gt-browsel-tabs-browsers nil
  "Which browsers to poll for tabs.
Passed unchanged to `browsel-browser-tabs':
  - nil              — every connected browser.
  - string           — that single browser only.
  - list of strings  — every browser in the list."
  :type '(choice (const  :tag "All connected browsers" nil)
                 (string :tag "Single browser name")
                 (repeat :tag "List of browser names" string))
  :group 'bookmark-plus-gt-browsel-tabs)

(defcustom bmkp-gt-browsel-tabs-filter nil
  "Filter applied to each tab before it becomes a bookmark.
  - nil       — include every tab.
  - regexp    — include a tab only if its URL matches the regexp.
  - function  — called with the tab plist; non-nil means include."
  :type '(choice (const    :tag "All tabs" nil)
                 (regexp   :tag "URL regexp")
                 (function :tag "Predicate function"))
  :group 'bookmark-plus-gt-browsel-tabs)


;;; Bookmark type: handler + predicate ---------------------------------

(defun bmkp-gt-browsel-tabs-p (bookmark)
  "Return non-nil if BOOKMARK is a browsel-tab bookmark.
BOOKMARK is a bookmark name or a bookmark record."
  (eq (bookmark-get-handler bookmark) 'bmkp-gt-browsel-tabs-jump))

(defun bmkp-gt-browsel-tabs-jump (bookmark)
  "Handler: focus the browser tab represented by BOOKMARK.
Uses `browsel-focus-tab' with the recorded `browsel-id' and
`browsel-browser'.  On `user-error' (tab closed, browser
disconnected, id no longer valid) falls back to
`browsel-browse-url' with the recorded URL.

Ends by throwing to `bookmark--jump-via' so bookmark-plus's
post-handler chain — annotation display, auto-light, fringe mark
— does not run and steal focus back from the browser."
  (let* ((id      (bookmark-prop-get bookmark 'browsel-id))
         (browser (bookmark-prop-get bookmark 'browsel-browser))
         (url     (bookmark-prop-get bookmark 'location))
         (tab     (list :id id :browsel-browser browser)))
    (condition-case _err
        (browsel-focus-tab tab t)
      (user-error
       (if (and url (not (string-empty-p url)))
           (browsel-browse-url url)
         (user-error "browsel-tab bookmark has no usable URL"))))
    ;; The `throw' is only meaningful when this handler is called from
    ;; `bookmark--jump-via'; `no-catch' makes direct calls safe.
    (condition-case nil
        (throw 'bookmark--jump-via 'BROWSEL-TAB)
      (no-catch nil))))


;;; Register with the preview module's type list ---------------------
;;
;; `bmkp-gt-jump-narrow' (in `bookmark-plus-gt-preview') maps a
;; bookmark handler symbol to a group label + narrow key.  Both
;; `bmkp-gt-jump' (consult narrow / minibuffer @Type filter) and the
;; type column in `*Bookmark List*' read from it, so registering the
;; browsel-tab handler makes it appear as `Browser tab' in both.
;; The registration is a no-op when the preview module is not loaded.

(defvar bmkp-gt-jump-narrow)            ; In `bookmark-plus-gt-preview'.

(defun bmkp-gt-browsel-tabs--register-jump-narrow ()
  "Register the browsel-tab handler as `Browser tab' in `bmkp-gt-jump-narrow'.
Idempotent; safe to call repeatedly."
  (when (boundp 'bmkp-gt-jump-narrow)
    (unless (assoc ?b bmkp-gt-jump-narrow)
      (add-to-list 'bmkp-gt-jump-narrow
                   '(?b "Browser tab" bmkp-gt-browsel-tabs-jump)))))

(bmkp-gt-browsel-tabs--register-jump-narrow)
(with-eval-after-load 'bookmark-plus-gt-preview
  (bmkp-gt-browsel-tabs--register-jump-narrow))


;;; URL/Web subtype: teach `bmkp-url-bookmark-p' about us --------------

(defun bmkp-gt-browsel-tabs--url-p-advice (orig bookmark)
  "Advice for `bmkp-url-bookmark-p'.
Return non-nil for the upstream URL types and for browsel-tab
bookmarks.  ORIG is the advised function; BOOKMARK is its arg."
  (or (funcall orig bookmark)
      (bmkp-gt-browsel-tabs-p bookmark)))

(advice-add 'bmkp-url-bookmark-p :around
            #'bmkp-gt-browsel-tabs--url-p-advice)


;;; Refresh -------------------------------------------------------------

(defvar bmkp-gt-browsel-tabs--refreshing nil
  "Non-nil while `bmkp-gt-browsel-tabs-refresh' is running.
Prevents re-entrancy from advised functions that the refresh
itself might call.")

(defun bmkp-gt-browsel-tabs--clear ()
  "Remove all browsel-tab bookmarks from `bookmark-alist'."
  (setq bookmark-alist
        (seq-remove #'bmkp-gt-browsel-tabs-p bookmark-alist)))

(defun bmkp-gt-browsel-tabs--allow-p (tab)
  "Return non-nil when TAB passes `bmkp-gt-browsel-tabs-filter'."
  (let ((filt bmkp-gt-browsel-tabs-filter)
        (url  (or (plist-get tab :url) "")))
    (cond
     ((null filt)      t)
     ((stringp filt)   (string-match-p filt url))
     ((functionp filt) (funcall filt tab))
     (t                t))))

(defun bmkp-gt-browsel-tabs--unique-name (base)
  "Return BASE, or BASE<N> with the smallest N making the name unique.
Uniqueness is checked against `bookmark-alist' as it stands at
call time."
  (if (not (assoc base bookmark-alist))
      base
    (let ((n 2))
      (while (assoc (format "%s<%d>" base n) bookmark-alist)
        (setq n (1+ n)))
      (format "%s<%d>" base n))))

(defun bmkp-gt-browsel-tabs--fetch ()
  "Return the current tab list, or nil (after a warning) on failure."
  (condition-case err
      (browsel-browser-tabs bmkp-gt-browsel-tabs-browsers)
    (error
     (display-warning
      'bmkp-gt-browsel-tabs
      (format "Cannot fetch tabs: %s" (error-message-string err))
      :warning)
     nil)))

(defun bmkp-gt-browsel-tabs--store (tab)
  "Add a temporary bookmark for TAB (a browsel tab plist).
Assumes TAB has already passed `bmkp-gt-browsel-tabs--allow-p'.
The bookmark name is the tab title, falling back to the URL when
the title is empty.  Collisions are deduped with `<2>', `<3>', ...
The tab's owning browser (client name) is attached as a tag so
the row displays it in the tags column and it is filterable via
bookmark-plus's tag machinery."
  (let* ((url     (or (plist-get tab :url) ""))
         (title   (or (plist-get tab :title) ""))
         (id      (plist-get tab :id))
         (browser (plist-get tab :browsel-browser))
         (base    (if (string-empty-p title) url title))
         (name    (bmkp-gt-browsel-tabs--unique-name base))
         (tags    (and (stringp browser) (not (string-empty-p browser))
                       (list browser)))
         (record  `((filename        . ,bmkp-non-file-filename)
                    (location        . ,url)
                    (handler         . bmkp-gt-browsel-tabs-jump)
                    (browsel-id      . ,id)
                    (browsel-browser . ,browser)
                    (tags            . ,tags)
                    (annotation      . ,title))))
    (bookmark-store name record nil 'no-refresh 'no-msg)
    (bmkp-make-bookmark-temporary name)))

;;;###autoload
(defun bmkp-gt-browsel-tabs-refresh ()
  "Rebuild the browsel-tab bookmarks from live browser state.
Removes any existing browsel-tab bookmarks, then reads tabs via
`browsel-browser-tabs' (targeting `bmkp-gt-browsel-tabs-browsers'),
filters through `bmkp-gt-browsel-tabs-filter', and adds one
temporary bookmark per surviving tab.

If the fetch fails the function warns and returns; the alist is
left with no browsel-tab entries until the next successful
refresh.  Other bookmarks are untouched."
  (interactive)
  (unless bmkp-gt-browsel-tabs--refreshing
    (let ((bmkp-gt-browsel-tabs--refreshing t)
          ;; Prevent `bookmark-store's internal `bmkp-maybe-save-bookmarks'
          ;; from writing a not-yet-marked-temporary entry to disk.
          (bookmark-save-flag nil))
      (bmkp-gt-browsel-tabs--clear)
      (dolist (tab (bmkp-gt-browsel-tabs--fetch))
        (let ((url (plist-get tab :url)))
          (when (and (stringp url)
                     (not (string-empty-p url))
                     (bmkp-gt-browsel-tabs--allow-p tab))
            (bmkp-gt-browsel-tabs--store tab)))))))


;;; Auto-refresh advice ------------------------------------------------

(defun bmkp-gt-browsel-tabs--auto-refresh (&rest _)
  "Before-advice hook that refreshes browsel-tab bookmarks.
Attached to every function that reads `bookmark-alist' for user
display or completion.  Errors are demoted to a warning so the
underlying advised function always runs — a broken refresh must
never block a `bookmark-bmenu-list', `bookmark-completing-read',
or `bmkp-url-jump' call."
  (condition-case err
      (bmkp-gt-browsel-tabs-refresh)
    (error
     (display-warning
      'bmkp-gt-browsel-tabs
      (format "Auto-refresh failed: %s" (error-message-string err))
      :warning))))

(defconst bmkp-gt-browsel-tabs--auto-refresh-triggers
  '(bookmark-bmenu-list
    bookmark-completing-read
    bmkp-url-jump
    bmkp-url-jump-other-window)
  "Functions advised to refresh browsel-tab bookmarks before running.")

(dolist (fn bmkp-gt-browsel-tabs--auto-refresh-triggers)
  (advice-add fn :before #'bmkp-gt-browsel-tabs--auto-refresh))


;;; Delete-closes-tab -------------------------------------------------

(defun bmkp-gt-browsel-tabs--delete-advice (bookmark-name &rest _)
  "`:before' advice on `bookmark-delete': close the browser tab too.
If BOOKMARK-NAME resolves to a browsel-tab bookmark, closes the
underlying browser tab via `browsel-close-tab' before the bookmark
itself is removed from `bookmark-alist'.  Errors from the close
call (tab already gone, browser disconnected, id no longer valid)
are demoted to a warning so the bookmark-side deletion still
proceeds.

Covers the `*Bookmark List*' mark-and-execute flow (=d= + =x=,
which calls `bookmark-delete' once per marked record) and
`M-x bookmark-delete' equally."
  (let ((bmk  (and (stringp bookmark-name)
                   (bmkp-get-bookmark-in-alist bookmark-name 'NOERROR))))
    (when (and bmk (bmkp-gt-browsel-tabs-p bmk))
      (let ((id       (bookmark-prop-get bmk 'browsel-id))
            (browser  (bookmark-prop-get bmk 'browsel-browser)))
        (condition-case err
            (browsel-close-tab (list :id id :browsel-browser browser))
          (error
           (display-warning
            'bmkp-gt-browsel-tabs
            (format "Could not close tab for %S: %s"
                    bookmark-name (error-message-string err))
            :warning)))))))

(advice-add 'bookmark-delete :before #'bmkp-gt-browsel-tabs--delete-advice)


(provide 'bookmark-plus-gt-browsel-tabs)

;;; bookmark-plus-gt-browsel-tabs.el ends here
