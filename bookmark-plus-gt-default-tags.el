;;; bookmark-plus-gt-default-tags.el --- Default tags on create + jump seed -*- lexical-binding:t -*-
;;
;; Filename:    bookmark-plus-gt-default-tags.el
;; Description: Automatically tag every new bookmark, and seed the
;;              `bmkp-gt-jump' filter with those tags at read time.
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
;; Two independent tag policies, controlled by one mode:
;;
;;   `bmkp-gt-default-tags-on-create'  — tags appended to every new
;;       bookmark set with `bookmark-set' (and its keybound frontends).
;;       Runs via `bmkp-after-set-hook', so it fires only for
;;       interactive-shape `bookmark-set' calls; bookmark loads and
;;       direct `bookmark-store' calls (e.g. from `browsel-tabs') are
;;       not affected.
;;
;;   `bmkp-gt-default-tags-on-jump'    — tags pre-seeded into the
;;       `bmkp-gt-jump' filter set at the start of every read session.
;;       The user sees them in the prompt as `[;tag]', can remove any
;;       with `M-D', clear the whole set with `M-T', or add more with
;;       `M-t' — the seed is not distinguishable from a filter the user
;;       typed by hand.  Escape hatch: `M-T' inside the minibuffer
;;       clears the seeded defaults and re-enters with the full list.
;;
;; `bmkp-gt-default-tags-on-create' — simple, no DSL:
;;
;;   nil                    — do nothing.
;;   "work"                 — one tag.
;;   '("work" "home")       — a list of tags (nils in the list are
;;                            silently dropped).
;;   a nullary function     — called at set time; must return one of
;;                            the above.
;;
;; The alist form accepted by the jump side has no meaning here; it
;; triggers a warning and no tag is applied.
;;
;; `bmkp-gt-default-tags-on-jump' — a small DSL:
;;
;;   nil                    — no filter.
;;   "work"                 — one tag (bare string).
;;   '("work" "home")       — flat list; OR of the listed tags.
;;   '("work" nil)          — flat list with the `untagged' sentinel:
;;                            `work' OR bookmarks with no tags.
;;   '(nil)                 — only untagged bookmarks.
;;   '((tag . "work")
;;     (tag-any . ("a" "b"))) — a raw filter alist, used verbatim as
;;                            the seed.  Entries compose as AND;
;;                            supported facets are `tag' (single
;;                            string, bookmark has that tag) and
;;                            `tag-any' (list of strings and/or nils,
;;                            OR'd internally; nil matches untagged).
;;   a nullary function     — called at read time; must return one of
;;                            the above.
;;
;; The jump-side value is normalized to `bmkp-gt-jump--active-filters':
;;   bare string   → `((tag-any . (STRING)))'
;;   flat list     → `((tag-any . VALUES))'
;;   alist form    → used verbatim
;;
;; The interactive setters (`bmkp-gt-default-tags-set-on-create',
;; `bmkp-gt-default-tags-set-on-jump') always write the flat-list
;; form.  Use `setq' or Customize to set the string or alist form
;; directly.
;;
;; The function form lets you compute the value per machine, per
;; project, per time of day, etc.  It is called with no arguments so
;; it must read whatever context it needs from dynamic bindings or
;; globals.
;;
;; Activation: `(bmkp-gt-default-tags-mode 1)'.  The mode is off by
;; default and attaches no side effects at load time.  Setting the
;; variables while the mode is off is inert; turning the mode on
;; activates them, off disables them.

;;; Code:

(require 'bookmark)
(require 'bookmark+)
(require 'cl-lib)

(declare-function bmkp-add-tags             "bookmark+-1")
(declare-function bmkp-read-tags-completing "bookmark+-1")
(declare-function bmkp-tags-list            "bookmark+-1")

(defvar bookmark-current-bookmark)              ; In `bookmark'.
(defvar bmkp-gt-jump-default-filters-function)  ; In `bookmark-plus-gt-jump'.


;;; Customization -------------------------------------------------------

(defgroup bookmark-plus-gt-default-tags nil
  "Default tags on bookmark creation and jump filter seeding."
  :group 'bookmark-plus-gt)

(defcustom bmkp-gt-default-tags-on-create nil
  "Tags to append after every interactive `bookmark-set'.

Value shape (simple — no DSL on this side):
  - nil                : do nothing (default).
  - a string           : that single tag.
  - a list of strings  : each string is added.
  - a nullary function : called at set time; must return one of the
                         above.  Errors are caught and demoted to a
                         warning; nothing is applied.

Nil elements inside a list are silently dropped.  The alist form
accepted by `bmkp-gt-default-tags-on-jump' has no meaning here (there
is no filter engine at set time); setting one triggers a warning and
no tag is applied.

Tags are appended on top of anything the user already provided via
`bmkp-prompt-for-tags-flag'; duplicates are deduped by
`bmkp-add-tags'.

Effective only while `bmkp-gt-default-tags-mode' is on."
  :type '(choice (const  :tag "None"          nil)
                 (string :tag "Single tag")
                 (repeat :tag "List of tags"  string)
                 (function :tag "Function returning any of the above"))
  :group 'bookmark-plus-gt-default-tags)

(defcustom bmkp-gt-default-tags-on-jump nil
  "Filter seeded into every `bmkp-gt-jump' session.

The value is a small DSL for expressing \"which bookmarks appear\":

  - nil                    : no filter (policy off).
  - a string, e.g. `\"work\"'
                           : one tag; seeded as `((tag-any . (\"work\")))'.
  - a list of strings
    and/or nils:
    - `\\='(\"work\")'            → seed `((tag-any . (\"work\")))'.
    - `\\='(\"work\" \"home\")'   → OR: bookmarks tagged `work' or `home'.
    - `\\='(\"work\" nil)'       → OR: `work' or untagged bookmarks
                             (nil is the untagged sentinel).
    - `\\='(nil)'               → only untagged bookmarks.
  - a list of `(FACET . VALUE)'
    cons cells             : a raw filter alist, seeded verbatim into
                             `bmkp-gt-jump--active-filters'.  Entries
                             compose as AND; supported facets today
                             are `tag' (VALUE is a string) and
                             `tag-any' (VALUE is a list of strings
                             and/or nils).  Use this shape to express
                             AND across tags or a mix of AND-of-ORs.
                             Example: `\\='((tag . \"work\")
                                         (tag-any . (\"a\" \"b\")))'
                             seeds `work AND (a OR b)'.
  - a nullary function     : called at read time; expected to return
                             one of the above shapes.  Errors are
                             caught and demoted to a warning; the
                             session starts empty.

The seeded entries render in the prompt (`;tag' for a single-tag
narrowing entry, `;(a|b|—)' for a `tag-any' OR-group, with `—' the
untagged sentinel) and can be removed with `M-D', cleared with
`M-T', or added to (as narrowing AND filters) with `M-t'.

Interactive setter (`bmkp-gt-default-tags-set-on-jump') always writes
the flat-list form.  Use `setq' / Customize to set the string or
alist form directly.

Effective only while `bmkp-gt-default-tags-mode' is on."
  :type '(choice (const  :tag "None"       nil)
                 (string :tag "Single tag")
                 (repeat :tag "List of tags (nil = untagged)"
                         (choice (string :tag "Tag")
                                 (const  :tag "Untagged (matches no-tag bookmarks)" nil)))
                 (alist :tag "Raw filter alist"
                        :key-type   symbol
                        :value-type sexp)
                 (function :tag "Function returning any of the above"))
  :group 'bookmark-plus-gt-default-tags)

(defcustom bmkp-gt-default-tags-confirm-set t
  "Non-nil means the interactive setters confirm before overwriting.
Applies to `bmkp-gt-default-tags-set-on-create' and
`bmkp-gt-default-tags-set-on-jump'.  When the current value of the
target variable is non-nil, the command shows the newly chosen
list and asks a yes/no question before replacing it.  When the
current value is nil, no confirmation is asked — there is nothing
to protect.  Set this to nil to skip the confirmation
unconditionally."
  :type 'boolean
  :group 'bookmark-plus-gt-default-tags)


;;; Resolver ------------------------------------------------------------

(defun bmkp-gt-default-tags--kind (val)
  "Classify VAL as one of the DSL shapes.  Returns:

  `empty' — nil (no policy).
  `bare'  — a string; represents a single tag.
  `flat'  — a list of strings and/or nils; the DSL shorthand for an
            OR-group.  A nil element is the `untagged' sentinel.
  `alist' — a list of (SYMBOL . ANYTHING) cons cells; a raw filter
            alist for the jump-side engine, used verbatim.  Not
            valid on the create side.
  `unknown' — anything else (shape error)."
  (cond
   ((null val)         'empty)
   ((stringp val)      'bare)
   ((not (listp val))  'unknown)
   ((cl-every (lambda (x) (or (null x) (stringp x))) val) 'flat)
   ((cl-every (lambda (x) (and (consp x) (symbolp (car x)))) val) 'alist)
   (t                  'unknown)))

(defun bmkp-gt-default-tags--resolve (source-var)
  "Return the raw value of SOURCE-VAR after evaluating the function form.
SOURCE-VAR is a defcustom symbol — one of
`bmkp-gt-default-tags-on-create' or `bmkp-gt-default-tags-on-jump'.

The variable's value may be:

  - nil                          : no policy.
  - a string                     : a single tag.
  - a list of strings and nils   : an OR-group in the jump-side DSL;
                                   a plain tag list on the create
                                   side (nils dropped).
  - a list of (FACET . VALUE)
    cons cells                   : a raw filter alist, used verbatim
                                   as the jump-side seed.  Not
                                   meaningful on the create side.
  - a nullary function           : called at policy time; expected to
                                   return one of the above shapes.

Returns the raw value (post-function-call) or nil on failure.  Errors
from the function form and unknown shapes are demoted to a warning
that names SOURCE-VAR.  Never signals.  Callers classify the shape
via `bmkp-gt-default-tags--kind' and interpret it per policy."
  (let* ((raw (symbol-value source-var))
         (val (if (functionp raw)
                  (condition-case err
                      (funcall raw)
                    (error
                     (display-warning
                      'bookmark-plus-gt-default-tags
                      (format
                       "`%s' function (%s) signaled: %s.  No tags applied."
                       source-var raw (error-message-string err))
                      :warning)
                     nil))
                raw)))
    (if (eq 'unknown (bmkp-gt-default-tags--kind val))
        (progn
          (display-warning
           'bookmark-plus-gt-default-tags
           (format
            "`%s' resolved to %S, which is not a recognized DSL shape.  No tags applied."
            source-var val)
           :warning)
          nil)
      val)))


;;; Create side ---------------------------------------------------------

(defun bmkp-gt-default-tags--current-create-tags ()
  "Return the create-side defaults as a normalized list of tag strings.
Accepts the `empty', `bare', or `flat' shape (nils in a flat list are
dropped).  The `alist' shape is not valid on the create side; on
encountering it, returns nil and issues a warning."
  (let* ((raw  (bmkp-gt-default-tags--resolve
                'bmkp-gt-default-tags-on-create))
         (kind (bmkp-gt-default-tags--kind raw)))
    (pcase kind
      ('empty nil)
      ('bare  (list raw))
      ('flat  (delq nil raw))
      ('alist (display-warning
               'bookmark-plus-gt-default-tags
               "`bmkp-gt-default-tags-on-create' resolved to an alist form; the alist form is meaningful only on the jump side.  No tags applied."
               :warning)
              nil))))

(defvar bmkp-gt-default-tags--in-bookmark-set nil
  "Dynamic marker: non-nil while a `bookmark-set' call is on the stack.
Set by our `:around' advice on `bookmark-set'.  Consulted by the
advice on `bmkp-read-tags-completing' to decide whether to substitute
the tags-with-defaults reader.")

(defvar bmkp-gt-default-tags--custom-reader-ran nil
  "Dynamic flag: non-nil once the tags-with-defaults reader has fired
within the current `bookmark-set' call.  Consulted by
`bmkp-gt-default-tags--apply-on-create' — when set, the after-set
hook skips the auto-append (the tags were already applied inside
`bookmark-set' via bookmark-plus's own `bmkp-add-tags' call).")

(defun bmkp-gt-default-tags--apply-on-create ()
  "Apply `bmkp-gt-default-tags-on-create' to the just-set bookmark.
Attached to `bmkp-after-set-hook' while `bmkp-gt-default-tags-mode'
is on.  When the tags-with-defaults reader already ran in this
`bookmark-set' (i.e. `bmkp-prompt-for-tags-flag' was on and the user
was shown the pre-populated tags), this hook does nothing — the tags
were already applied by bookmark-plus's own `bmkp-add-tags' call.
Otherwise, appends the resolved defaults."
  (unless bmkp-gt-default-tags--custom-reader-ran
    (let ((tags (bmkp-gt-default-tags--current-create-tags))
          (name (and (boundp 'bookmark-current-bookmark)
                     bookmark-current-bookmark)))
      (when (and tags name)
        (bmkp-add-tags name tags 'NO-UPDATE-P)
        ;; Refresh the tag-completion cache so tags we just applied are
        ;; offered at future tag prompts (Bookmark+'s own tag commands and
        ;; our `bmkp-gt-default-tags-set-on-jump' reader both consult
        ;; `bmkp-tags-alist').  `bmkp-add-tags' skips this update under
        ;; NO-UPDATE-P, so do it explicitly here.
        (bmkp-tags-list)))))


;;; Tags-with-defaults reader (mirrors the jump-side pattern) ----------

(defvar bmkp-gt-default-tags--edit-state nil
  "Current tag list inside `bmkp-gt-default-tags--edit-with-defaults'.
Bound dynamically by the reader loop; mutated by the action commands
`bmkp-gt-default-tags--edit-add' / `--edit-pop' / `--edit-clear'.")

(defvar bmkp-gt-default-tags--edit-restart nil
  "Non-nil signals the tags-with-defaults reader loop to re-enter after
an action command (M-t / M-D / M-T) quit the minibuffer.  Mirrors
`bmkp-gt-jump--restart-flag'.")

(defun bmkp-gt-default-tags--edit-add ()
  "Add a tag to the tags-with-defaults reader.
Reads via `completing-read' against every tag currently in use.
`C-g' inside the read cancels the add without terminating the outer
reader.  Bound to `M-t' in `bmkp-gt-default-tags--edit-map'."
  (interactive)
  (condition-case _
      (let* ((all (mapcar (lambda (x) (if (consp x) (car x) x))
                          (bmkp-tags-list)))
             (tag (completing-read "Tag: " all nil nil nil 'bmkp-tag-history)))
        (when (and tag (not (string-empty-p tag)))
          (setq bmkp-gt-default-tags--edit-state
                (append bmkp-gt-default-tags--edit-state (list tag)))))
    (quit nil))
  (setq bmkp-gt-default-tags--edit-restart t)
  (abort-minibuffers))

(defun bmkp-gt-default-tags--edit-pop ()
  "Pop the last tag from the tags-with-defaults reader.
Bound to `M-D' in `bmkp-gt-default-tags--edit-map'."
  (interactive)
  (when bmkp-gt-default-tags--edit-state
    (setq bmkp-gt-default-tags--edit-state
          (butlast bmkp-gt-default-tags--edit-state)))
  (setq bmkp-gt-default-tags--edit-restart t)
  (abort-minibuffers))

(defun bmkp-gt-default-tags--edit-clear ()
  "Clear every tag from the tags-with-defaults reader.
Bound to `M-T' in `bmkp-gt-default-tags--edit-map'."
  (interactive)
  (setq bmkp-gt-default-tags--edit-state nil)
  (setq bmkp-gt-default-tags--edit-restart t)
  (abort-minibuffers))

(defvar-keymap bmkp-gt-default-tags--edit-map
  :doc "Keymap layered onto the current minibuffer's local map inside
`bmkp-gt-default-tags--edit-with-defaults'.  Composed with the
`completing-read' map (via `minibuffer-with-setup-hook') so TAB
completion works as usual.  Same bindings as the jump-side filter
minibuffer for consistency."
  "M-t" #'bmkp-gt-default-tags--edit-add
  "M-D" #'bmkp-gt-default-tags--edit-pop
  "M-T" #'bmkp-gt-default-tags--edit-clear)

(defun bmkp-gt-default-tags--edit-read-once ()
  "One pass of the tags-with-defaults reader.
Displays the current `bmkp-gt-default-tags--edit-state' in the prompt
and reads via `completing-read' against every tag currently in use,
with the edit-map keys layered onto the completion keymap so the
user can complete (TAB) and act (M-t / M-D / M-T) in the same
minibuffer.  Returns the typed string (which may be empty)."
  (let* ((state    bmkp-gt-default-tags--edit-state)
         (state-s  (if state
                       (propertize
                        (format "[%s]" (mapconcat #'identity state ", "))
                        'face 'completions-annotations)
                     ""))
         (prompt   (format "Tags %s(RET commit, TAB complete, M-t add, M-D pop, M-T clear): "
                           (if (string-empty-p state-s)
                               ""
                             (concat state-s " "))))
         (all      (mapcar (lambda (x) (if (consp x) (car x) x))
                           (bmkp-tags-list))))
    (minibuffer-with-setup-hook
        (lambda ()
          (use-local-map (make-composed-keymap
                          bmkp-gt-default-tags--edit-map
                          (current-local-map))))
      (completing-read prompt all nil nil nil 'bmkp-tag-history))))

(defun bmkp-gt-default-tags--edit-with-defaults (defaults)
  "Read a tag list, pre-populated with DEFAULTS.
The prompt shows the current tag set; bindings inside the prompt are:

  M-t    add a tag via `completing-read'.
  M-D    pop the last tag from the set.
  M-T    clear the whole set.
  RET    on empty input: commit and return the current set.
  RET    on typed input: append the input as a tag and continue.
  C-g    quit — propagates as usual (aborts the containing command).

Returns the resulting list of tag strings (possibly empty)."
  (let ((bmkp-gt-default-tags--edit-state defaults)
        done)
    (while (not done)
      (setq bmkp-gt-default-tags--edit-restart nil)
      (condition-case _
          (let ((input (bmkp-gt-default-tags--edit-read-once)))
            (cond
             (bmkp-gt-default-tags--edit-restart nil) ; loop
             ((string-empty-p input) (setq done t))    ; commit
             (t (setq bmkp-gt-default-tags--edit-state
                      (append bmkp-gt-default-tags--edit-state
                              (list input))))))
        (quit
         ;; An `abort-minibuffers' by an action (M-t/M-D/M-T) sets the
         ;; restart flag first, so we treat that as a loop.  A user C-g
         ;; leaves the flag nil, and we propagate the quit as usual —
         ;; C-g must always abort.
         (unless bmkp-gt-default-tags--edit-restart
           (signal 'quit nil)))))
    bmkp-gt-default-tags--edit-state))


;;; Advice — substitute the reader inside `bookmark-set' ---------------

(defun bmkp-gt-default-tags--bookmark-set-around (orig-fn &rest args)
  "Around advice on `bookmark-set'.
Establishes the dynamic markers our `bmkp-read-tags-completing' advice
consults to decide whether to substitute the tags-with-defaults reader
and whether the after-set hook should skip its auto-append."
  (let ((bmkp-gt-default-tags--in-bookmark-set t)
        (bmkp-gt-default-tags--custom-reader-ran nil))
    (apply orig-fn args)))

(defun bmkp-gt-default-tags--read-tags-around (orig-fn &rest args)
  "Around advice on `bmkp-read-tags-completing'.
When called from inside `bookmark-set' with the mode on and defaults
configured, substitute the tags-with-defaults reader (pre-populated
with the resolved defaults) and record that fact for the after-set
hook.  Otherwise pass through to ORIG-FN."
  (let ((defaults (and bmkp-gt-default-tags--in-bookmark-set
                       bmkp-gt-default-tags-mode
                       (bmkp-gt-default-tags--current-create-tags))))
    (if (null defaults)
        (apply orig-fn args)
      (let ((tags (bmkp-gt-default-tags--edit-with-defaults defaults)))
        (setq bmkp-gt-default-tags--custom-reader-ran t)
        tags))))


;;; Jump side -----------------------------------------------------------

(defun bmkp-gt-default-tags--seed-jump-filters ()
  "Return the initial `bmkp-gt-jump--active-filters' alist.
Installed as `bmkp-gt-jump-default-filters-function' while
`bmkp-gt-default-tags-mode' is on.

Interprets `bmkp-gt-default-tags-on-jump' per its DSL shape (see
`bmkp-gt-default-tags--kind'):

  `empty' → nil (no seed).
  `bare'  → `((tag-any . (STRING)))'.
  `flat'  → `((tag-any . VALUES))' — a single OR-group.
  `alist' → used verbatim as the seed."
  (let* ((raw  (bmkp-gt-default-tags--resolve
                'bmkp-gt-default-tags-on-jump))
         (kind (bmkp-gt-default-tags--kind raw)))
    (pcase kind
      ('empty nil)
      ('bare  (list (cons 'tag-any (list raw))))
      ('flat  (list (cons 'tag-any raw)))
      ('alist raw))))


;;; Mode ----------------------------------------------------------------

;;;###autoload
(define-minor-mode bmkp-gt-default-tags-mode
  "Toggle automatic tagging on create and filter seeding on jump.

When on:

  - `bmkp-after-set-hook' gains a handler that appends
    `bmkp-gt-default-tags-on-create' (or the result of calling it,
    if it is a function) to every just-set bookmark whose tags prompt
    was not shown (see below).
  - `bookmark-set' and `bmkp-read-tags-completing' are advised so
    that, when `bmkp-prompt-for-tags-flag' is on, the tags prompt
    fires with the defaults pre-populated.  The reader is
    interactive: `M-t' adds a tag, `M-D' pops the last, `M-T' clears
    all — same keys as the jump-side filter minibuffer.  Empty RET
    commits the current set.
  - `bmkp-gt-jump-default-filters-function' is set so every
    `bmkp-gt-jump' session opens with `bmkp-gt-default-tags-on-jump'
    pre-seeded into `bmkp-gt-jump--active-filters'.  The seeded tags
    are visible in the prompt and removable with `M-D' / `M-T' like
    any user-added filter.

Both variables default to nil (no effect) even when the mode is
on; set at least one to get behavior."
  :init-value nil :global t :group 'bookmark-plus-gt-default-tags
  (cond
   (bmkp-gt-default-tags-mode
    (add-hook 'bmkp-after-set-hook #'bmkp-gt-default-tags--apply-on-create)
    (advice-add 'bookmark-set :around
                #'bmkp-gt-default-tags--bookmark-set-around)
    (advice-add 'bmkp-read-tags-completing :around
                #'bmkp-gt-default-tags--read-tags-around)
    (setq bmkp-gt-jump-default-filters-function
          #'bmkp-gt-default-tags--seed-jump-filters))
   (t
    (remove-hook 'bmkp-after-set-hook #'bmkp-gt-default-tags--apply-on-create)
    (advice-remove 'bookmark-set
                   #'bmkp-gt-default-tags--bookmark-set-around)
    (advice-remove 'bmkp-read-tags-completing
                   #'bmkp-gt-default-tags--read-tags-around)
    (when (eq bmkp-gt-jump-default-filters-function
              #'bmkp-gt-default-tags--seed-jump-filters)
      (setq bmkp-gt-jump-default-filters-function nil)))))



;;; Interactive setters ------------------------------------------------

(defun bmkp-gt-default-tags--require-mode ()
  "Signal `user-error' when `bmkp-gt-default-tags-mode' is off.
The setters gate on this so the user is not asked to configure
policies that would be ignored."
  (unless bmkp-gt-default-tags-mode
    (user-error
     "`bmkp-gt-default-tags-mode' is off; enable it before setting defaults")))

(defun bmkp-gt-default-tags--format-list (tags)
  "Format TAGS (a DSL list) for display.
Renders each element as its printed representation, so nil (the
`untagged' sentinel) shows as `nil'.  Empty list → `nil (no default
tags)'.  Used in prompts and messages."
  (if tags
      (concat "("
              (mapconcat (lambda (x) (if (null x) "nil" (format "%S" x)))
                         tags " ")
              ")")
    "nil (no default tags)"))

(defun bmkp-gt-default-tags--confirm-overwrite-p (source-var new-tags)
  "Ask whether to overwrite SOURCE-VAR (whose current value is non-nil).
NEW-TAGS is the tag list the user just typed.  Returns non-nil on
yes.  Caller must have already checked that SOURCE-VAR's current
value is non-nil and that `bmkp-gt-default-tags-confirm-set' is
non-nil — this is purely the y/n prompt."
  (y-or-n-p
   (format "Replace `%s' (currently %s) with %s? "
           source-var
           (bmkp-gt-default-tags--format-list (symbol-value source-var))
           (bmkp-gt-default-tags--format-list new-tags))))

(defun bmkp-gt-default-tags--read-interactive (source-var &optional ask-untagged-p)
  "Read new tags for SOURCE-VAR and confirm the overwrite when needed.
Signals `user-error' immediately if `bmkp-gt-default-tags-mode' is
off — the user is not prompted for input that would be ignored.

Reads via `bmkp-read-tags-completing' (the same reader Bookmark+
uses at the `bmkp-prompt-for-tags-flag' prompt during
`bookmark-set').

When ASK-UNTAGGED-P is non-nil, follow the tag reader with a y/n
prompt `Also match untagged bookmarks?'.  On yes, `nil' is appended
to the returned list (the `untagged' sentinel used by the jump-side
DSL).  The follow-up is skipped when ASK-UNTAGGED-P is nil — nil
elements are meaningless on the create side.

When the current value of SOURCE-VAR is non-nil and
`bmkp-gt-default-tags-confirm-set' is non-nil, ask a y/n before
returning; the user answering `n' signals `user-error' so the
containing command aborts cleanly.  Returns the new tag list
(possibly nil)."
  (bmkp-gt-default-tags--require-mode)
  ;; Pass UPDATE-TAGS-ALIST-P non-nil so the completion candidates come
  ;; from a fresh scan of `bookmark-alist' rather than a possibly stale
  ;; `bmkp-tags-alist' cache — tags added via our own hook (or any other
  ;; NO-UPDATE-P caller of `bmkp-add-tags') would otherwise be missing.
  (let* ((tags (bmkp-read-tags-completing nil nil 'UPDATE-TAGS-ALIST-P))
         (new  (if (and ask-untagged-p
                        (y-or-n-p "Also match untagged bookmarks? "))
                   (append tags (list nil))
                 tags)))
    (when (and bmkp-gt-default-tags-confirm-set
               (symbol-value source-var)
               (not (bmkp-gt-default-tags--confirm-overwrite-p source-var new)))
      (user-error "Cancelled"))
    new))

;;;###autoload
(defun bmkp-gt-default-tags-set-on-create (tags)
  "Set `bmkp-gt-default-tags-on-create' to TAGS.
Signals `user-error' when `bmkp-gt-default-tags-mode' is off —
the setters refuse to write policies that would be inert.

Interactively, read tags with `bmkp-read-tags-completing' — the
same one-tag-at-a-time reader Bookmark+ shows at the
`bmkp-prompt-for-tags-flag' prompt.  Enter tags one by one, RET
after each; RET on empty input finishes.  Finishing with no tags
clears the default (sets it to nil).

When `bmkp-gt-default-tags-confirm-set' is non-nil AND the current
value is non-nil, confirm the overwrite before applying.  A nil
current value is applied without prompting — there is nothing to
protect.

The value is stored in the current session only; add a `setq' to
your init file or use Customize for persistence."
  (interactive
   (list (bmkp-gt-default-tags--read-interactive
          'bmkp-gt-default-tags-on-create)))
  (bmkp-gt-default-tags--require-mode)
  (setq bmkp-gt-default-tags-on-create tags)
  (message "Default tags on create: %s"
           (bmkp-gt-default-tags--format-list tags)))

;;;###autoload
(defun bmkp-gt-default-tags-set-on-jump (tags)
  "Set `bmkp-gt-default-tags-on-jump' to TAGS.
Signals `user-error' when `bmkp-gt-default-tags-mode' is off —
the setters refuse to write policies that would be inert.

Interactively:
  1. Read tags with `bmkp-read-tags-completing' — the same
     one-tag-at-a-time reader Bookmark+ shows at the
     `bmkp-prompt-for-tags-flag' prompt.  Enter tags one by one, RET
     after each; RET on empty input finishes.
  2. Follow-up: `Also match untagged bookmarks?' (y/n).  Answering
     yes appends the `untagged' sentinel (nil) to the list, so the
     seeded filter matches bookmarks with no tags in addition to
     the tags you typed.
  3. Finishing step 1 with no tags AND answering `n' at step 2
     clears the default (sets it to nil).

When `bmkp-gt-default-tags-confirm-set' is non-nil AND the current
value is non-nil, confirm the overwrite before applying.  A nil
current value is applied without prompting — there is nothing to
protect.

The value is stored in the current session only; add a `setq' to
your init file or use Customize for persistence."
  (interactive
   (list (bmkp-gt-default-tags--read-interactive
          'bmkp-gt-default-tags-on-jump 'ask-untagged)))
  (bmkp-gt-default-tags--require-mode)
  (setq bmkp-gt-default-tags-on-jump tags)
  (message "Default tags on jump: %s"
           (bmkp-gt-default-tags--format-list tags)))


(provide 'bookmark-plus-gt-default-tags)
;;; bookmark-plus-gt-default-tags.el ends here
