;;; bookmark-plus-gt-jump.el --- Consult-backed jump reader and live preview for Bookmark+  -*- lexical-binding:t -*-
;;
;; Filename:    bookmark-plus-gt-jump.el
;; Description: `bmkp-gt-jump' and its variants: a consult-backed
;;              jump reader with type narrowing and tag filtering,
;;              plus the buffer-local live-preview mode for
;;              `*Bookmark List*'.  Also owns `bmkp-gt-jump-narrow'
;;              (the handler → type-label taxonomy consumed by the
;;              tags module) and marginalia annotations.  Part of
;;              bookmark-plus-gt, a non-invasive extension layer
;;              over Bookmark+ (`bookmark-plus').
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
;;
;; Adapted to layer on top of Bookmark+.  Bookmark+ is not
;; modified.

;;; Commentary:
;;
;; Two ways to preview a bookmark's destination without committing to a jump:
;;
;;   `bmkp-gt-list-preview-mode' — buffer-local minor mode intended for
;;       the Bookmark+ list buffer `*Bookmark List*'.  Modeled on the
;;       built-in `next-error-follow-minor-mode' (simple.el): a
;;       `post-command-hook' watches point motion and dispatches the
;;       bookmark on the current line into another window without
;;       selecting it.
;;
;;   `bmkp-gt-jump' minibuffer preview — when `consult' is loaded and
;;       `bmkp-gt-jump-use-consult-flag' is non-nil, the interactive
;;       bookmark-name read for `bmkp-gt-jump' (and its other-window /
;;       other-frame variants) is routed through `consult--read' with
;;       `consult--bookmark-preview' as the `:state' callback, the
;;       same mechanism `consult-bookmark' uses.
;;
;; The minibuffer-side path also shows each candidate's tags as a
;; completion annotation, via `bmkp-gt-bookmark-annotation'.  The
;; annotator is additive: it prepends a `;tag ;tag ...' segment to
;; whatever `marginalia-annotate-bookmark' would otherwise return
;; (type / file / location), so the existing bookmark completion
;; display is preserved and tags are added in front of it.  When
;; `marginalia' is loaded, the same annotator is registered on the
;; `bookmark' completion category so `consult-bookmark' and any other
;; bookmark completion benefit.
;;
;; In `bmkp-gt-jump' (but not `consult-bookmark') each candidate is
;; augmented further so the completion matches against tags and so
;; bookmark types can be narrowed / grouped:
;;
;;   - Tag tokens (`;name1 ;name2 ...') are appended to the candidate
;;     string with `display ""', which keeps them in the candidate for
;;     orderless/substring matching while hiding them from view.
;;     Typing a tag name in the minibuffer filters the list.
;;
;;   - Each candidate carries a `consult--type' text property derived
;;     from its handler via `bmkp-gt-jump-narrow', enabling the
;;     same single-key type narrowing (`,' prefix by default) as
;;     `consult-bookmark'.
;;
;;   - `bmkp-gt-jump-sort-by' chooses the candidate order: `mru'
;;     (default; recently modified first), `visits' (most-jumped
;;     first), or `alpha' (alphabetical).  The chosen order is
;;     applied within each group when grouping is enabled.
;;
;;   - `bmkp-gt-jump-group-by' selects whether the completion is grouped
;;     by handler type (`type'), by the bookmark's first tag (`tag'),
;;     or not at all (nil, default).  When grouping is enabled,
;;     candidates are clustered by group key and the chosen sort
;;     applies within each group; groups appear in first-seen order.
;;
;;   - Multi-axis filter state (foundation for richer faceted UI).
;;     `bmkp-gt-jump--active-filters' is an alist of (FACET . VALUE)
;;     describing facets that further constrain the candidate set
;;     beyond what the input string and `consult-narrow-key' provide.
;;     The minibuffer keymap `bmkp-gt-jump-minibuffer-map' binds:
;;
;;         M-t   add a tag filter (completing-read from all known tags)
;;         M-D   pop the most recently added filter
;;         M-T   clear all filters
;;
;;     Active filters are shown bracketed in the prompt
;;     (`[;emacs ;work] Bookmark: '), and candidates failing any
;;     facet are excluded.  Mutation rebuilds the candidate list by
;;     quitting and re-entering `consult--read', driven by
;;     `bmkp-gt-jump--restart-flag'.
;;
;; This file does not modify Bookmark+.  It adds new commands
;; (`bmkp-gt-jump*') that call Bookmark+'s dispatcher (`bmkp-jump-1')
;; after reading through the consult-aware reader.  Users who want the
;; consult reader on the standard `bookmark-jump' keys rebind them to
;; `bmkp-gt-jump' themselves.

;;; Code:

(require 'bookmark)
(require 'cl-lib)

;; Bookmark+ symbols we call into.  Declared for the byte compiler in
;; case this file is compiled before `bookmark+' is loaded.
(declare-function bmkp-jump-1                     "bookmark+-1")
(declare-function bmkp-default-bookmark-name      "bookmark+-1")
(declare-function bmkp-get-tags                   "bookmark+-1")
(declare-function bmkp-select-buffer-other-window "bookmark+-1")
(declare-function bmkp--pop-to-buffer-same-window "bookmark+-1")
(defvar bmkp-non-file-filename)

;; Soft consult deps — only used when `(featurep 'consult)'.
(declare-function consult--read                  "consult")
(declare-function consult--bookmark-preview      "consult")
(declare-function consult--type-group            "consult")
(declare-function consult--type-narrow           "consult")

;; Marginalia integration — only touched inside `with-eval-after-load 'marginalia'.
(defvar marginalia-annotators)
(declare-function marginalia-annotate-bookmark "marginalia")


;;; Customization --------------------------------------------------------

(defgroup bookmark-plus-gt nil
  "Non-invasive extensions to Bookmark+."
  :group 'bookmark-plus)

(defcustom bmkp-gt-jump-use-consult-flag t
  "Non-nil means use `consult' for live preview in `bmkp-gt-jump' commands.
Only takes effect when the `consult' package is loaded.  When nil, or
when `consult' is not loaded, `bmkp-gt-jump' reads bookmark names
through the usual `bookmark-completing-read', with no preview."
  :type 'boolean :group 'bookmark-plus-gt)

(defcustom bmkp-gt-list-preview-display-action
  '(display-buffer-use-some-window . ((inhibit-same-window . t)))
  "`display-buffer' action used to show preview windows.
Used by `bmkp-gt-list-preview-mode'.  The default opens the preview
in some other window without stealing focus from `*Bookmark List*'."
  :type '(cons function alist) :group 'bookmark-plus-gt)

(defcustom bmkp-gt-jump-name-max-width 50
  "Cap on the visible width of a bookmark name in `bmkp-gt-jump'.
Non-nil (positive integer) — names longer than this cap render
in the minibuffer as `<head>…<tail>' where <tail> is
`bmkp-gt-jump-name-tail-keep' characters.  Only the DISPLAY is
truncated: the underlying candidate string still carries every
character, so orderless and other matchers see the full name.
nil — no truncation."
  :type '(choice (const :tag "No cap" nil) (integer :tag "Max chars"))
  :group 'bookmark-plus-gt)

(defcustom bmkp-gt-jump-name-tail-keep 10
  "Number of characters kept at the tail of a truncated name in `bmkp-gt-jump'.
Only meaningful when `bmkp-gt-jump-name-max-width' is non-nil."
  :type 'integer
  :group 'bookmark-plus-gt)

(defcustom bmkp-gt-jump-narrow
  '((?f "File"           bookmark-default-handler)
    (?d "Dired"          bmkp-jump-dired
                         vc-dir-bookmark-jump)
    (?i "Info"           Info-bookmark-jump)
    (?o "Org heading"    org-bookmark-heading-jump)
    (?n "News/Gnus"      bmkp-jump-gnus
                         gnus-summary-bookmark-jump)
    (?m "Man/Help"       bmkp-jump-man
                         bmkp-jump-woman
                         Man-bookmark-jump
                         woman-bookmark-jump
                         help-bookmark-jump)
    (?p "Picture"        image-bookmark-jump)
    (?w "Web"            bmkp-jump-eww
                         bmkp-jump-w3m
                         eww-bookmark-jump
                         xwidget-webkit-bookmark-jump-handler)
    (?u "URL"            bmkp-jump-url-browse)
    (?s "Shell"          eshell-bookmark-jump
                         shell-bookmark-jump)
    (?v "Doc view/PDF"   doc-view-bookmark-jump
                         pdf-view-bookmark-jump-handler)
    (?D "Desktop"        bmkp-jump-desktop)
    (?L "Bookmark list"  bmkp-jump-bookmark-list)
    (?F "Bookmark file"  bmkp-jump-bookmark-file)
    (?S "Snippet"        bmkp-jump-snippet)
    (?V "Variable list"  bmkp-jump-variable-list)
    (?q "Sequence"       bmkp-jump-sequence)
    (?x "Function/kmacro" bmkp-jump-function)
    (?g "Magit"          magit--handle-bookmark)
    (?e "Epub"           nov-bookmark-jump-handler)
    (nil "Other"))
  "Narrowing configuration for `bmkp-gt-jump'.

Each element has the form (CHAR NAME HANDLER...).  CHAR is the
single-character narrow key (or nil for the catch-all).  NAME is the
group label.  HANDLERs are the bookmark-handler symbols routed under
that group.

Used by the `consult'-backed `bmkp-gt-jump' completion path to drive
both type narrowing and (when `bmkp-gt-jump-group-by' is `type')
candidate grouping."
  :type '(alist :key-type (choice character (const :tag "Catch-all" nil))
                :value-type (cons string (repeat function)))
  :group 'bookmark-plus-gt)

(defcustom bmkp-gt-jump-group-by nil
  "How `bmkp-gt-jump' groups completion candidates.

  `type'  Group by bookmark handler type (file, dired, info, ...).
          Uses `bmkp-gt-jump-narrow'.
  `tag'   Group by the bookmark's first tag; untagged bookmarks
          collect under \"(untagged)\".
  nil     No grouping (default).

When non-nil, candidates are clustered by group key (preserving the
order chosen by `bmkp-gt-jump-sort-by' within each group), and groups
appear in first-seen order.

Affects only the `consult'-backed `bmkp-gt-jump' completion path."
  :type '(choice (const :tag "No grouping" nil)
                 (const :tag "By type" type)
                 (const :tag "By primary tag" tag))
  :group 'bookmark-plus-gt)

(defcustom bmkp-gt-jump-sort-by 'mru
  "How `bmkp-gt-jump' sorts completion candidates.

  `mru'    Most recently visited first (uses each bookmark's
           `last-visited' property, set by `bmkp-record-visit'
           on every jump).
  `visits' Most-jumped first (uses each bookmark's `visits' count).
  `alpha'  Alphabetical by bookmark name.

When `bmkp-gt-jump-group-by' is non-nil this order is applied within
each group; groups themselves appear in first-seen order, so the
group containing the best-sorting candidate comes first.

Affects only the `consult'-backed `bmkp-gt-jump' completion path."
  :type '(choice (const :tag "Most recently used" mru)
                 (const :tag "By visit count"     visits)
                 (const :tag "Alphabetical"       alpha))
  :group 'bookmark-plus-gt)


;;; Preview error reporting --------------------------------------------

(defvar bmkp-gt-preview--last-warned nil
  "Bookmark name we most recently warned about during preview.
Used to rate-limit `message' output so a stationary point on a
broken bookmark does not spam the echo area.  Reset by
`bmkp-gt-preview--clear-warning' when a subsequent preview succeeds
or when the previewed name changes.")

(defun bmkp-gt-preview--warn (bmk err)
  "Emit a one-line warning that previewing BMK raised ERR.
BMK is a bookmark name or record.  Message is suppressed when the
last warning was for the same name — so scrolling to a different
bookmark warns again, but sitting on the same broken one does
not."
  (let ((name (cond ((stringp bmk) bmk)
                    ((and (consp bmk) (stringp (car bmk))) (car bmk))
                    (t "<unknown>"))))
    (unless (equal name bmkp-gt-preview--last-warned)
      (setq bmkp-gt-preview--last-warned name)
      (message "bmkp-gt: preview failed for %s: %s"
               name (error-message-string err)))))

(defun bmkp-gt-preview--clear-warning ()
  "Reset the rate-limit state so the next failure will warn."
  (setq bmkp-gt-preview--last-warned nil))


;;; Buffer-side: `bmkp-gt-list-preview-mode' ----------------------------

(defvar bmkp-gt-list-preview-mode)         ; Forward decl (defined by `define-minor-mode' below).

(defvar-local bmkp-gt-list-preview--last-line nil
  "Line number of the bookmark last previewed in the current buffer.")

(defvar-local bmkp-gt-list-preview--saved-window-config nil
  "Window configuration saved when `bmkp-gt-list-preview-mode' was enabled.")

(defun bmkp-gt-list-preview--show ()
  "Preview the bookmark on the current line, leaving point in the list buffer."
  (when bmkp-gt-list-preview-mode
    (let ((line  (line-number-at-pos)))
      (unless (eq line bmkp-gt-list-preview--last-line)
        (setq bmkp-gt-list-preview--last-line  line)
        (let ((bmk  (ignore-errors (bookmark-bmenu-bookmark))))
          (when bmk
            (save-selected-window
              (condition-case err
                  (progn
                    (let ((display-buffer-overriding-action  bmkp-gt-list-preview-display-action))
                      (bmkp-jump-1 bmk #'pop-to-buffer nil))
                    (bmkp-gt-preview--clear-warning))
                (error (bmkp-gt-preview--warn bmk err))))))))))

;;;###autoload
(define-minor-mode bmkp-gt-list-preview-mode
  "Toggle live preview of the bookmark on point in the bookmark list buffer.

When enabled, moving point onto a bookmark line opens its destination
in another window without changing the selected window.  This is the
bookmark-list analog of `next-error-follow-minor-mode'.

Disabling the mode restores the window configuration that was in
effect when the mode was enabled."
  :lighter " Pv"
  :group 'bookmark-plus-gt
  (cond
   (bmkp-gt-list-preview-mode
    (setq bmkp-gt-list-preview--saved-window-config  (current-window-configuration))
    (setq bmkp-gt-list-preview--last-line            nil)
    (add-hook 'post-command-hook #'bmkp-gt-list-preview--show nil 'local)
    (bmkp-gt-list-preview--show))
   (t
    (remove-hook 'post-command-hook #'bmkp-gt-list-preview--show 'local)
    (when bmkp-gt-list-preview--saved-window-config
      (set-window-configuration bmkp-gt-list-preview--saved-window-config)
      (setq bmkp-gt-list-preview--saved-window-config  nil)))))


;;; Minibuffer-side: consult integration for `bmkp-gt-jump' -------------

(defun bmkp-gt--candidate-name (cand)
  "Return the bare bookmark name carried by completion candidate CAND.
Augmented candidates produced by `bmkp-gt-read-bookmark-for-jump' store
the bare name in a `bmkp-gt-bookmark-name' text property.  Plain
strings (e.g. produced by `consult-bookmark') are returned unchanged."
  (or (and (stringp cand) (get-text-property 0 'bmkp-gt-bookmark-name cand))
      cand))

(defun bmkp-gt--bookmark-primary-tag (name)
  "Return the first tag of bookmark NAME as a string, or nil if untagged."
  (let ((first  (car (bookmark-prop-get name 'tags))))
    (cond ((consp first) (car first))
          (first first))))

(defun bmkp-gt-jump-candidate-type-char (bm narrow-alist)
  "Return the narrow char for bookmark BM under NARROW-ALIST.
Helper for `bmkp-gt-jump-candidate-format-function' implementations:
returns the single character that `consult--type-narrow' uses to
filter BM, mapped from its handler.  Returns nil if no entry in
NARROW-ALIST matches the bookmark's handler."
  (alist-get (or (bookmark-get-handler bm) #'bookmark-default-handler)
             narrow-alist))

(defun bmkp-gt-jump-candidate-type-name (bm)
  "Return the type-group name string for bookmark BM, or nil.
Walks `bmkp-gt-jump-narrow' to find the entry whose HANDLER list
contains BM's handler and returns its NAME field (e.g. \"File\",
\"Dired\", \"Org heading\").  Returns nil if no entry matches."
  (let ((handler  (or (bookmark-get-handler bm) #'bookmark-default-handler)))
    (cl-loop for (_char name . handlers) in bmkp-gt-jump-narrow
             when (memq handler handlers)
             return name)))

(defun bmkp-gt-jump--truncate-name (name)
  "Return NAME smart-truncated to `bmkp-gt-jump-name-max-width' as a real string.
When NAME exceeds the cap, returns `<head>…<tail>' where <tail>
is `bmkp-gt-jump-name-tail-keep' characters.  The returned string
is shorter than NAME (unlike a display-only trick), so consult and
marginalia size the annotation column from the truncated length,
not the underlying full-name length.

Trade-off: orderless / substring / flex can only match the visible
head and tail characters — not the elided middle.  The full,
untouched name is still recoverable from the caller-attached
`bmkp-gt-bookmark-name' text property on the candidate."
  (let ((cap  bmkp-gt-jump-name-max-width))
    (if (or (null cap) (<= (length name) cap))
        name
      (let* ((tail-keep  (max 0 bmkp-gt-jump-name-tail-keep))
             (ellipsis   "…")
             (head-keep  (- cap tail-keep (string-width ellipsis))))
        (if (<= head-keep 0)
            name
          (concat (substring name 0 head-keep)
                  ellipsis
                  (substring name (- (length name) tail-keep))))))))

(defun bmkp-gt-jump-candidate-default (bm narrow-alist)
  "Default candidate formatter for `bmkp-gt-jump'.

Returns a propertized string composed of three parts:

  - The bookmark name (visible).
  - The type-group name preceded by `@' (`@File', `@Dired', ...),
    when a type is resolved via `bmkp-gt-jump-narrow'.  Appended
    with `display \"\"' so typing `@File' filters against it via
    orderless / substring matching without showing the token.
    `@' avoids orderless's affix-dispatch characters (`!', `,',
    `=', `~', `%', backtick), so the token is matched literally.
  - Any tag tokens (`;tag1 ;tag2 ...'), appended the same way.

All parts carry the text properties required by `consult--read'
\(see `bmkp-gt-jump-candidate-format-function' for the contract\):
`bmkp-gt-bookmark-name' and `consult--type'."
  (let* ((name      (car bm))
         (visible   (bmkp-gt-jump--truncate-name name))
         (tags      (bookmark-prop-get name 'tags))
         (raw-tags  (when tags (bmkp-gt--tags-segment-raw tags)))
         (type-name (bmkp-gt-jump-candidate-type-name bm))
         (type-tok  (when type-name (concat "@" type-name)))
         (type-char (bmkp-gt-jump-candidate-type-char bm narrow-alist))
         (hidden    (string-join (delq nil (list type-tok raw-tags)) " "))
         (head      (propertize visible
                                'bmkp-gt-bookmark-name name
                                'consult--type        type-char)))
    (if (string-empty-p hidden)
        head
      (concat head
              (propertize (concat " " hidden)
                          'display              ""
                          'bmkp-gt-bookmark-name name
                          'consult--type        type-char)))))

(defcustom bmkp-gt-jump-candidate-format-function #'bmkp-gt-jump-candidate-default
  "Function that builds a `consult--read' candidate string for `bmkp-gt-jump'.

Called with two arguments:

  BM           -- the bookmark record (an alist entry from
                  `bookmark-alist').
  NARROW-ALIST -- the (HANDLER . CHAR) alist used by
                  `consult--type-narrow' / `consult--type-group',
                  derived from `bmkp-gt-jump-narrow' for the current
                  invocation.

The function must return a propertized string used as the candidate
in the `consult--read' minibuffer.  The string MUST have these text
properties applied to every character (the simplest way is to build
the string with `propertize'):

  `bmkp-gt-bookmark-name' -- the bare bookmark name (a string); consult
                             uses it for `:lookup', `:state', and the
                             annotator.  Use the value of `(car BM)'.
  `consult--type'         -- the narrow character (a fixnum); used by
                             `consult--type-narrow' /
                             `consult--type-group'.  Compute with
                             `bmkp-gt-jump-candidate-type-char'.

To include searchable-but-invisible text (e.g. type-name and tag
tokens for substring matching), append a `propertize'd segment with
the `display \"\"' property in addition to the two above.  The
default formatter appends `@TypeName' (from `bmkp-gt-jump-narrow')
and `;tag1 ;tag2 ...' this way -- overrides that want the same
filtering ergonomics should follow suit.

Customize this when you want to control what appears in the candidate
row -- e.g. include tags inline, prepend the bookmark type, show
visit counts, etc.  The default is `bmkp-gt-jump-candidate-default'."
  :type 'function
  :group 'bookmark-plus-gt)

(defun bmkp-gt--make-jump-candidate (bm narrow-alist)
  "Build a `bmkp-gt-jump' completion candidate for bookmark record BM.
Dispatches to `bmkp-gt-jump-candidate-format-function'; falls back to
`bmkp-gt-jump-candidate-default' if the configured value is not a
function."
  (funcall (if (functionp bmkp-gt-jump-candidate-format-function)
               bmkp-gt-jump-candidate-format-function
             #'bmkp-gt-jump-candidate-default)
           bm narrow-alist))

(defun bmkp-gt--jump-group-function (narrow)
  "Return a `:group' function honoring `bmkp-gt-jump-group-by'.
NARROW is the (CHAR . NAME) alist used by `consult--type-group'."
  (pcase bmkp-gt-jump-group-by
    ('type (consult--type-group narrow))
    ('tag  (lambda (cand transform)
             (if transform
                 cand
               (or (bmkp-gt--bookmark-primary-tag (bmkp-gt--candidate-name cand))
                   "(untagged)"))))
    (_     nil)))

(defun bmkp-gt--sort-candidates (cands)
  "Order CANDS per `bmkp-gt-jump-sort-by'."
  (pcase bmkp-gt-jump-sort-by
    ('alpha
     (sort cands (lambda (a b)
                   (string< (bmkp-gt--candidate-name a)
                            (bmkp-gt--candidate-name b)))))
    ('mru
     (sort cands (lambda (a b)
                   (time-less-p
                    (or (bookmark-prop-get (bmkp-gt--candidate-name b) 'last-visited) '(0 0))
                    (or (bookmark-prop-get (bmkp-gt--candidate-name a) 'last-visited) '(0 0))))))
    ('visits
     (sort cands (lambda (a b)
                   (> (or (bookmark-prop-get (bmkp-gt--candidate-name a) 'visits) 0)
                      (or (bookmark-prop-get (bmkp-gt--candidate-name b) 'visits) 0)))))
    (_ cands)))

(defun bmkp-gt--candidate-group-key (cand)
  "Return the group key for CAND per `bmkp-gt-jump-group-by', or nil."
  (pcase bmkp-gt-jump-group-by
    ('type (get-text-property 0 'consult--type cand))
    ('tag  (or (bmkp-gt--bookmark-primary-tag (bmkp-gt--candidate-name cand))
               "(untagged)"))))

(defun bmkp-gt--cluster-by-group (cands)
  "If grouping is enabled, cluster sorted CANDS by group key.
Within-group order is preserved (so the sort chosen by
`bmkp-gt-jump-sort-by' still applies within each group).  Groups
appear in first-seen order — the group whose best-sorting candidate
is first in CANDS leads."
  (if (null bmkp-gt-jump-group-by)
      cands
    (let ((buckets (make-hash-table :test 'equal))
          (order   nil))
      (dolist (c cands)
        (let ((g (bmkp-gt--candidate-group-key c)))
          (unless (gethash g buckets) (push g order))
          (puthash g (cons c (gethash g buckets nil)) buckets)))
      (mapcan (lambda (g) (nreverse (gethash g buckets)))
              (nreverse order)))))


;;; Multi-axis filter state -------------------------------------------

(defvar bmkp-gt-jump--active-filters nil
  "Active filter facets for the current `bmkp-gt-jump' session.
An alist of (FACET . VALUE).  Facets compose as AND across the alist.

Supported facets:

  `tag'      VALUE is a tag name string.  Candidate matches if it has
             that tag.
  `tag-any'  VALUE is a list of tag names, possibly containing nil.
             Candidate matches if it has ANY of the listed tags
             (internal OR); a nil element in VALUE matches candidates
             that have no tags at all.

The list is reset on every fresh invocation of `bmkp-gt-jump' (via
`bmkp-gt-read-bookmark-for-jump').  Designed to grow new facets
(annotation regex, autofile-only, date range) without changing the
calling shape.")

(defvar bmkp-gt-jump--restart-flag nil
  "Non-nil signals the `bmkp-gt-read-bookmark-for-jump' loop to re-enter
`consult--read' after a filter command quit the minibuffer.")

(defvar bmkp-gt-jump-default-filters-function nil
  "Nullary function returning the initial value of `bmkp-gt-jump--active-filters'.
Called at the start of every `bmkp-gt-read-bookmark-for-jump'
session; the returned alist of `(FACET . VALUE)' entries seeds the
filter set before the reader enters `consult--read'.  The user
sees the seeded entries in the prompt (`[;tag ...]') and can
remove any of them with `M-D', clear the whole set with `M-T', or
add more with `M-t' — the seed is not distinguishable from
user-added filters.

Nil (the default) means no seed: every session starts with an
empty filter set.  Errors from the function are caught and demoted
to a warning; the session then starts empty.

Feature modules (e.g. `bookmark-plus-gt-default-tags') set this
variable in their mode's on-branch and restore it in the
off-branch.")

(defun bmkp-gt--all-tags ()
  "Return the sorted, distinct list of tag names across `bookmark-alist'."
  (let ((seen  (make-hash-table :test 'equal)))
    (dolist (bm bookmark-alist)
      (dolist (tag (bookmark-prop-get (car bm) 'tags))
        (puthash (if (consp tag) (car tag) tag) t seen)))
    (let (out) (maphash (lambda (k _v) (push k out)) seen)
         (sort out #'string<))))

(defun bmkp-gt--bookmark-has-tag-p (bm tag)
  "Return non-nil if bookmark record BM carries the tag named TAG."
  (let ((bmk-tags (bookmark-prop-get (car bm) 'tags)))
    (cl-some (lambda (tg) (equal (if (consp tg) (car tg) tg) tag))
             bmk-tags)))

(defun bmkp-gt--bookmark-passes-filters-p (bm filters)
  "Return non-nil if bookmark record BM satisfies every facet in FILTERS.
Facets compose as AND across the alist.  Supported facets:

  `tag'       VALUE is a tag name.  BM must have that tag.
  `tag-any'   VALUE is a list of tag names, possibly including nil.
              BM matches when it has ANY of the listed tags
              (internal OR).  A nil element in VALUE matches
              bookmarks that have no tags at all."
  (cl-every
   (lambda (f)
     (pcase (car f)
       ('tag     (bmkp-gt--bookmark-has-tag-p bm (cdr f)))
       ('tag-any (let ((values (cdr f)))
                   (cl-some (lambda (v)
                              (if (null v)
                                  (null (bookmark-prop-get (car bm) 'tags))
                                (bmkp-gt--bookmark-has-tag-p bm v)))
                            values)))
       (_ t)))
   filters))

(defconst bmkp-gt--untagged-glyph "—"
  "String rendered for the `untagged' member of a `tag-any' filter (nil).")

(defun bmkp-gt--format-active-filters ()
  "Format `bmkp-gt-jump--active-filters' for display in the prompt.
Returns a possibly-empty propertized string (no trailing space).

Rendering:
  `(tag . X)'        → `;X'
  `(tag-any . VS)'   → `;(V1|V2|...)'; a nil element in VS renders as
                       `bmkp-gt--untagged-glyph' (the `untagged' mark)."
  (if (null bmkp-gt-jump--active-filters) ""
    (mapconcat (lambda (f)
                 (pcase (car f)
                   ('tag
                    (propertize (concat ";" (cdr f))
                                'face 'completions-annotations))
                   ('tag-any
                    (propertize
                     (concat ";("
                             (mapconcat (lambda (v)
                                          (if (null v)
                                              bmkp-gt--untagged-glyph
                                            v))
                                        (cdr f) "|")
                             ")")
                     'face 'completions-annotations))
                   (_    (format "%S" f))))
               (reverse bmkp-gt-jump--active-filters)
               " ")))

(defun bmkp-gt--jump-build-prompt (base default)
  "Build the consult `:prompt' string with active-filter indicator and DEFAULT."
  (let* ((tail   (if default
                     (format " (%s): "
                             (if (consp default) (car default) default))
                   ": "))
         (filter (bmkp-gt--format-active-filters)))
    (if (string-empty-p filter)
        (concat base tail)
      (concat "[" filter "] " base tail))))

;;;###autoload
(defun bmkp-gt-jump-add-tag-filter ()
  "Inside `bmkp-gt-jump's minibuffer: prompt for a tag and add it as a filter.
Quits and re-enters the completion with the updated filter set.  The
tag is read from `bmkp-gt--all-tags' (every distinct tag in
`bookmark-alist')."
  (interactive)
  (let* ((known  (bmkp-gt--all-tags))
         (tag    (and known
                      (completing-read "Tag filter: " known nil t))))
    (when (and tag (not (string-empty-p tag)))
      (cl-pushnew (cons 'tag tag) bmkp-gt-jump--active-filters :test #'equal)
      (setq bmkp-gt-jump--restart-flag t)
      (abort-minibuffers))))

;;;###autoload
(defun bmkp-gt-jump-pop-filter ()
  "Inside `bmkp-gt-jump's minibuffer: remove the most recently added filter."
  (interactive)
  (when bmkp-gt-jump--active-filters
    (pop bmkp-gt-jump--active-filters)
    (setq bmkp-gt-jump--restart-flag t)
    (abort-minibuffers)))

;;;###autoload
(defun bmkp-gt-jump-clear-filters ()
  "Inside `bmkp-gt-jump's minibuffer: clear all active filters."
  (interactive)
  (when bmkp-gt-jump--active-filters
    (setq bmkp-gt-jump--active-filters nil)
    (setq bmkp-gt-jump--restart-flag t)
    (abort-minibuffers)))

(defvar-keymap bmkp-gt-jump-minibuffer-map
  :doc "Keymap active in the minibuffer during `bmkp-gt-jump' completion.
Bindings are layered on top of consult's own minibuffer map."
  "M-t" #'bmkp-gt-jump-add-tag-filter
  "M-T" #'bmkp-gt-jump-clear-filters
  "M-D" #'bmkp-gt-jump-pop-filter)

(defun bmkp-gt--jump-read-once (prompt default)
  "One pass of the `bmkp-gt-jump' consult read; signals `quit' on filter restart.
Caller (`bmkp-gt-read-bookmark-for-jump') loops while
`bmkp-gt-jump--restart-flag' is set after each pass."
  (let* ((narrow-alist  (cl-loop for (y _ . xs) in bmkp-gt-jump-narrow nconc
                                 (cl-loop for x in xs collect (cons x y))))
         (narrow        (cl-loop for (x y . _) in bmkp-gt-jump-narrow collect (cons x y)))
         (cands         (bmkp-gt--cluster-by-group
                         (bmkp-gt--sort-candidates
                          (cl-loop for bm in bookmark-alist
                                   when (bmkp-gt--bookmark-passes-filters-p
                                         bm bmkp-gt-jump--active-filters)
                                   collect (bmkp-gt--make-jump-candidate bm narrow-alist)))))
         (preview       (consult--bookmark-preview)))
    (consult--read
     cands
     :prompt        (bmkp-gt--jump-build-prompt prompt default)
     :require-match t
     :sort          nil
     :default       (if (consp default) (car default) default)
     :history       'bookmark-history
     :category      'bookmark
     :annotate      #'bmkp-gt-bookmark-annotation
     :group         (bmkp-gt--jump-group-function narrow)
     :narrow        (consult--type-narrow narrow)
     :keymap        bmkp-gt-jump-minibuffer-map
     :lookup        (lambda (selected candidates &rest _)
                      ;; The selected string arrives without the text
                      ;; properties we put on the augmented candidate (the
                      ;; minibuffer strips them).  Resolve back to the
                      ;; original candidate via `member' so the
                      ;; `bmkp-gt-bookmark-name' property is visible.
                      (bmkp-gt--candidate-name
                       (or (car (member selected candidates)) selected)))
     :state         (lambda (action cand)
                      (let ((name  (and cand (bmkp-gt--candidate-name cand))))
                        (if (eq action 'preview)
                            (condition-case err
                                (progn
                                  (funcall preview action name)
                                  (bmkp-gt-preview--clear-warning))
                              (error (bmkp-gt-preview--warn name err)))
                          (funcall preview action name)))))))

;;;###autoload
(defun bmkp-gt-read-bookmark-for-jump (prompt &optional default bookmarks-list)
  "Read a bookmark name with live preview, for the `bmkp-gt-jump' commands.

When `consult' is loaded and `bmkp-gt-jump-use-consult-flag' is
non-nil, read through `consult--read', augmenting each candidate with:

  - hidden tag tokens so typing a tag name narrows the candidate
    list (the tag text is matched by completion but not displayed);
  - handler-type narrowing via `consult--type-narrow' and the
    configuration in `bmkp-gt-jump-narrow';
  - grouping per `bmkp-gt-jump-group-by' (by type or by primary tag);
  - sorting per `bmkp-gt-jump-sort-by' (mru/visits/alpha);
  - a multi-axis filter state in `bmkp-gt-jump--active-filters' that the
    minibuffer keys in `bmkp-gt-jump-minibuffer-map' mutate (M-t adds a
    tag filter, M-D pops, M-T clears).  Active filters are shown in
    the prompt and candidates failing them are excluded.

Non-nil BOOKMARKS-LIST is an alist of bookmarks (same shape as
`bookmark-alist') used as the candidate pool for this read; when
nil the pool is `bookmark-alist'.  Callers that supply
BOOKMARKS-LIST skip `bmkp-gt-jump-default-filters-function' for this
session — the seeded default-tag filter would compound with an
externally supplied pool and typically exclude what the caller
intended to show.

Otherwise falls back to `bookmark-completing-read'."
  (bookmark-maybe-load-default-file)
  (setq bmkp-gt-jump--active-filters
        (and (null bookmarks-list)
             bmkp-gt-jump-default-filters-function
             (condition-case err
                 (funcall bmkp-gt-jump-default-filters-function)
               (error
                (display-warning
                 'bookmark-plus-gt-jump
                 (format
                  "`bmkp-gt-jump-default-filters-function' (%s) signaled: %s.  Starting session with an empty filter set."
                  bmkp-gt-jump-default-filters-function
                  (error-message-string err))
                 :warning)
                nil))))
  (let ((bookmark-alist  (or bookmarks-list bookmark-alist)))
    (if (and bmkp-gt-jump-use-consult-flag
             (featurep 'consult)
             (fboundp 'consult--read)
             (fboundp 'consult--bookmark-preview))
        (let (result done)
          (while (not done)
            (setq bmkp-gt-jump--restart-flag nil)
            (condition-case _
                (progn
                  (setq result (bmkp-gt--jump-read-once prompt default))
                  (setq done t))
              (quit
               ;; A filter command triggered the quit -> loop and re-enter.
               ;; A genuine C-g -> propagate so the caller aborts cleanly
               ;; instead of receiving nil and erroring downstream.
               (unless bmkp-gt-jump--restart-flag
                 (signal 'quit nil)))))
          result)
      (bookmark-completing-read prompt default))))


;;; Jump commands -------------------------------------------------------
;;
;; New entry points that read via the consult-aware reader and dispatch
;; through Bookmark+'s `bmkp-jump-1'.  Users bind them where they want.
;; The standard `bookmark-jump' key bindings are left alone.

(defun bmkp-gt--read-jump-target (prompt bookmarks-list bookmarks-filter)
  "Prompt for a bookmark from a filtered pool, for the `bmkp-gt-jump' commands.
Compute the candidate pool from BOOKMARKS-LIST (defaults to
`bookmark-alist') and, when BOOKMARKS-FILTER is non-nil, narrow it
further by applying that predicate to each bookmark record.  Signal
an error when the pool is empty.  Otherwise call
`bmkp-gt-read-bookmark-for-jump' with PROMPT and the pool."
  (let* ((pool  (or bookmarks-list bookmark-alist))
         (pool  (if bookmarks-filter
                    (cl-remove-if-not bookmarks-filter pool)
                  pool)))
    (unless pool (error "No bookmarks match the given filter"))
    (bmkp-gt-read-bookmark-for-jump
     prompt (bmkp-default-bookmark-name pool) pool)))

;;;###autoload
(cl-defun bmkp-gt-jump
    (&optional bookmark jump-display-function flip-use-region-p
               &key bookmarks-list bookmarks-filter)
  "Jump to BOOKMARK, reading with `bmkp-gt-read-bookmark-for-jump'.

Positional arguments mirror Bookmark+'s `bookmark-jump'; only the
interactive read differs (consult live preview when available).

In Lisp code:
BOOKMARK is a bookmark name or a bookmark record.  When nil, prompt
 for one.
Non-nil JUMP-DISPLAY-FUNCTION is passed to `bookmark--jump-via' — a
 function of one argument (a buffer) that displays it.  Defaults to
 `bmkp--pop-to-buffer-same-window'.
Non-nil FLIP-USE-REGION-P flips the value of `bmkp-use-region'.

Keyword arguments narrow the candidate pool for the prompt; they
are ignored when BOOKMARK is already supplied:
:BOOKMARKS-LIST is an alist in the same shape as `bookmark-alist'
 to use as the pool.  Defaults to `bookmark-alist'.
:BOOKMARKS-FILTER is a predicate of one argument — a bookmark
 record — that further narrows the pool; a candidate is kept when
 the predicate returns non-nil.

Signals an error when the pool is empty."
  (interactive (list nil nil current-prefix-arg))
  (let ((bookmark  (or bookmark
                       (bmkp-gt--read-jump-target
                        "Jump to bookmark"
                        bookmarks-list bookmarks-filter))))
    (bmkp-jump-1 bookmark
                 (or jump-display-function #'bmkp--pop-to-buffer-same-window)
                 flip-use-region-p)))

;;;###autoload
(cl-defun bmkp-gt-jump-other-window
    (&optional bookmark flip-use-region-p
               &key bookmarks-list bookmarks-filter)
  "Jump to BOOKMARK in another window, reading with consult live preview.
See `bmkp-gt-jump' for the meaning of the arguments."
  (interactive (list nil current-prefix-arg))
  (let ((bookmark  (or bookmark
                       (bmkp-gt--read-jump-target
                        "Jump to bookmark (in another window)"
                        bookmarks-list bookmarks-filter))))
    (bmkp-jump-1 bookmark #'bmkp-select-buffer-other-window flip-use-region-p)))

;;;###autoload
(cl-defun bmkp-gt-jump-other-frame
    (&optional bookmark flip-use-region-p
               &key bookmarks-list bookmarks-filter)
  "Jump to BOOKMARK in another frame, reading with consult live preview.
See `bmkp-gt-jump' for the meaning of the arguments."
  (interactive (list nil current-prefix-arg))
  (let ((bookmark        (or bookmark
                             (bmkp-gt--read-jump-target
                              "Jump to bookmark (in another frame)"
                              bookmarks-list bookmarks-filter)))
        (pop-up-frames   t))
    (bmkp-jump-1 bookmark #'bmkp-select-buffer-other-window flip-use-region-p)))


;;; Bookmark annotation (tags + built-in details) ----------------------

(defun bmkp-gt-bookmark-location-default (bmk)
  "Return a display location string for bookmark record BMK, or nil.

The default reads BMK's `location' property.  URL bookmarks (and EWW,
W3M, and `browse-url' bookmarks) store the URL there; other bookmark
types that set `location' will also be picked up.  Returns nil when
no `location' is set, in which case `bmkp-gt-bookmark-annotation'
leaves marginalia's annotation as-is."
  (bookmark-prop-get bmk 'location))

(defcustom bmkp-gt-bookmark-location-function #'bmkp-gt-bookmark-location-default
  "Function returning a display location string for a bookmark, or nil.
Called with one argument: the bookmark record (the alist entry from
`bookmark-alist').  When the returned string is non-nil and
`marginalia-annotate-bookmark' rendered the bookmark with the
`bmkp-non-file-filename' marker (\"   - no file -\"), the marker is
replaced with the returned string in the annotation shown by
`bmkp-gt-bookmark-annotation' (consult / minibuffer path).  A nil
return preserves marginalia's original output.

The default, `bmkp-gt-bookmark-location-default', returns the
bookmark's `location' property.  Override to format additional types
(Info nodes, man pages, Gnus messages, etc.) or to customize the
rendering."
  :type 'function
  :group 'bookmark-plus-gt)

(defun bmkp-gt--tags-segment-raw (tags)
  "Return TAGS rendered as space-separated `;tag' tokens (a plain string)."
  (mapconcat (lambda (tag) (concat ";" (if (consp tag) (car tag) tag)))
             tags " "))

(defvar bmkp-gt--tags-segment-width-cache nil
  "Cache for `bmkp-gt--tags-segment-width': cons (BOOKMARK-ALIST . WIDTH).
Invalidated when `bookmark-alist' is replaced (identity changes).")

(defun bmkp-gt--tags-segment-width ()
  "Return the max width of the formatted tags segment across `bookmark-alist'.
Width is the maximum, over every bookmark, of the length of the
segment produced by `bmkp-gt--tags-segment-raw' for that bookmark's
tags.  Untagged bookmarks contribute 0.  Cached by alist identity."
  (let ((cached  (car bmkp-gt--tags-segment-width-cache)))
    (unless (eq cached bookmark-alist)
      (setq bmkp-gt--tags-segment-width-cache
            (cons bookmark-alist
                  (apply #'max 0
                         (mapcar (lambda (b)
                                   (let ((tags  (bookmark-prop-get (car b) 'tags)))
                                     (if tags (length (bmkp-gt--tags-segment-raw tags)) 0)))
                                 bookmark-alist))))))
  (cdr bmkp-gt--tags-segment-width-cache))

(defun bmkp-gt--marginalia-type-region (str)
  "Return (BEG . END) of the `marginalia-type'-faced region of STR, or nil.
Handles both a bare symbol and a list of faces in the `face' property."
  (let ((n (length str))
        (i 0)
        beg end)
    (while (< i n)
      (let ((f (get-text-property i 'face str)))
        (when (or (eq f 'marginalia-type)
                  (and (listp f) (memq 'marginalia-type f)))
          (unless beg (setq beg i))
          (setq end (1+ i))))
      (setq i (1+ i)))
    (and beg end (cons beg end))))

(defun bmkp-gt--rewrite-marginalia-type (annot bmk)
  "Return ANNOT with its `marginalia-type' column replaced by our label.
Uses `bmkp-gt-jump-candidate-type-name' to resolve the label for BMK
from `bmkp-gt-jump-narrow'.  Preserves the region's width (right-pads
or truncates our label to fit) and the `marginalia-type' face so the
column alignment marginalia set up is not disturbed.  Returns ANNOT
unchanged when no type is resolved or no marginalia-type region is
present."
  (let ((label (bmkp-gt-jump-candidate-type-name bmk))
        (span  (bmkp-gt--marginalia-type-region annot)))
    (if (not (and label span))
        annot
      (let* ((beg    (car span))
             (end    (cdr span))
             (width  (- end beg))
             (fit    (if (> (length label) width)
                         (substring label 0 width)
                       (concat label (make-string (- width (length label)) ?\ ))))
             (new    (propertize fit 'face 'marginalia-type)))
        (concat (substring annot 0 beg) new (substring annot end))))))

(defun bmkp-gt-bookmark-annotation (cand)
  "Return an annotation for bookmark candidate CAND.
Composes two parts:

  - A tags segment built from `bmkp-get-tags', formatted as
    space-separated `;tag' tokens and padded on the right to the
    width of the widest tags segment in `bookmark-alist' so that
    annotations form an aligned column.  Untagged bookmarks emit a
    blank segment of the same width.

  - The base annotation from `marginalia-annotate-bookmark' (type,
    file, location), when `marginalia' is loaded.  The type column
    is rewritten to use the group label from `bmkp-gt-jump-narrow'
    (e.g. \"Dired\" rather than marginalia's handler-derived
    \"Bmkp-Dired\"), preserving the column width, so what the user
    sees matches what `@Dired' matches.

A `marginalia--align' text property is placed at position 0 so the
tags column starts at a fixed minibuffer column regardless of the
candidate name's width (marginalia replaces that one char with a
`(space :align-to ...)' display at render time).

Either part may be missing.  Returns nil if both are missing."
  (let* ((width      (bmkp-gt--tags-segment-width))
         (name       (bmkp-gt--candidate-name cand))
         (bmk        (and (stringp name) (assoc name bookmark-alist)))
         (tags       (and bmk (bmkp-get-tags bmk)))
         (raw-tags   (if tags (bmkp-gt--tags-segment-raw tags) ""))
         (base-part  (and (fboundp 'marginalia-annotate-bookmark)
                          (marginalia-annotate-bookmark name)))
         (location   (and bmk
                          (functionp bmkp-gt-bookmark-location-function)
                          (funcall bmkp-gt-bookmark-location-function bmk))))
    (when (and (stringp location)
               (stringp base-part)
               (string-match-p (regexp-quote bmkp-non-file-filename) base-part))
      (setq base-part
            (replace-regexp-in-string
             (regexp-quote bmkp-non-file-filename)
             (concat "   " location)
             base-part t t)))
    (when (and (stringp base-part) bmk)
      (setq base-part (bmkp-gt--rewrite-marginalia-type base-part bmk)))
    (cond
     ;; Nothing to show.
     ((and (zerop width) (null base-part)) nil)
     ;; Tags-only (marginalia is not loaded).
     ((null base-part)
      (concat "   " (propertize raw-tags 'face 'completions-annotations)))
     ;; Both, with column alignment.
     (t
      (let* ((padded    (concat raw-tags
                                (make-string (max 0 (- width (length raw-tags))) ?\ )))
             (tags-fmt  (propertize padded 'face 'completions-annotations)))
        (concat (propertize " " 'marginalia--align t)
                tags-fmt
                "  "
                base-part))))))

;; When `marginalia' is loaded, register `bmkp-gt-bookmark-annotation'
;; as the primary annotator for the `bookmark' category so it fires for
;; `consult-bookmark' and any other bookmark completion.  The original
;; `marginalia-annotate-bookmark' is invoked from within our annotation
;; (we compose, not replace), and is also preserved as a `marginalia-cycle'
;; alternative.
(with-eval-after-load 'marginalia
  (let ((entry  (assq 'bookmark marginalia-annotators)))
    (if entry
        (unless (memq 'bmkp-gt-bookmark-annotation entry)
          (setcdr entry (cons #'bmkp-gt-bookmark-annotation (cdr entry))))
      (push '(bookmark bmkp-gt-bookmark-annotation builtin none)
            marginalia-annotators))))


(provide 'bookmark-plus-gt-jump)

;;; bookmark-plus-gt-jump.el ends here
