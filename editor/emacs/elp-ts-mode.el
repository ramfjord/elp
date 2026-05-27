;;; elp-ts-mode.el --- Tree-sitter mode for ELP templates -*- lexical-binding: t; -*-

;; Author: Thomas Ramfjord
;; URL: https://github.com/ramfjord/elp
;; Version: 0.2.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Tree-sitter major mode for `.elp' ERB-style templates.  Pairs
;; with the grammar at editor/tree-sitter-elp/ in the elp repo.
;;
;; Multi-language by construction:
;;
;;   - `(code)' regions inside <% %> always inject `commonlisp'
;;     (if that grammar is installed).
;;   - `(content)' regions outside the tags inject a host language
;;     resolved from the filename via `elp-ts-mode-host-language-alist'
;;     (service.yml.elp → yaml, Makefile.elp → make, …).
;;
;; Host-language font-lock is lifted from the host's own
;; `*-ts-mode--font-lock-settings' variable when that mode is
;; loadable.  No reimplementation of yaml/bash/json/etc. highlighting.

;;; Code:

(require 'treesit)

(defvar elp-ts-mode--root
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this file, captured at load time.
Used to locate the bundled `queries/' tree regardless of where the
mode is later activated.  Computing this at activation time would
pick up the user's `.elp' buffer's directory instead.")

;; Self-register the elp grammar source so users get
;; `M-x treesit-install-language-grammar RET elp' for free without
;; copying the URL into their own config.  Only adds the entry if
;; none exists already.
(unless (assq 'elp treesit-language-source-alist)
  (add-to-list 'treesit-language-source-alist
               '(elp "https://github.com/ramfjord/elp" "main"
                     "editor/tree-sitter-elp/src")))

(defgroup elp nil
  "ELP template editing."
  :group 'languages
  :prefix "elp-ts-mode-")

(defcustom elp-ts-mode-host-language-alist
  '(("yml"        . yaml)
    ("rb"         . ruby)
    ("js"         . javascript)
    ("ts"         . typescript)
    ("md"         . markdown)
    ("htm"        . html)
    ("sh"         . bash)
    ("bash"       . bash)
    ("zsh"        . bash)
    ("env"        . bash)
    ("tf"         . terraform)
    ("tfvars"     . terraform)
    ("Makefile"   . make)
    ("Dockerfile" . dockerfile)
    ;; No upstream tree-sitter "systemd" grammar; ini is the
    ;; closest passable fit.
    ("service"    . ini)
    ("timer"      . ini)
    ("socket"     . ini)
    ("mount"      . ini)
    ("path"       . ini)
    ("target"     . ini))
  "Filename token → tree-sitter language for outer-text injection.
Tokens that already match a tree-sitter language name (json, yaml,
toml, lua, …) resolve via fallthrough — no entry needed."
  :type '(alist :key-type string :value-type symbol)
  :group 'elp)

(defun elp-ts-mode--host-language ()
  "Tree-sitter language symbol for this buffer's outer text, or nil."
  (let* ((name (or (buffer-file-name) (buffer-name)))
         (base (file-name-nondirectory name))
         (token (cond
                 ((string-match "\\.\\([A-Za-z]+\\)\\.elp\\'" base)
                  (match-string 1 base))
                 ((string-match "\\`\\([A-Za-z]+\\)\\.elp\\'" base)
                  (match-string 1 base)))))
    (when token
      (or (cdr (assoc-string token elp-ts-mode-host-language-alist))
          (intern (downcase token))))))

(defvar elp-ts-mode--elp-font-lock-rules
  (treesit-font-lock-rules
   :language 'elp
   :feature 'delimiter
   :override t
   '(["<%" "<%-" "<%=" "<%-=" "<%#" "<%-#" "%>" "-%>"] @font-lock-keyword-face)

   :language 'elp
   :feature 'comment
   '((comment_directive (comment) @font-lock-comment-face)))
  "Font-lock rules for the ELP tags themselves.")

;; nvim-treesitter capture names → Emacs font-lock faces.  Ordered
;; longest-first so dotted forms (`@variable.builtin') get replaced
;; before their bare prefixes (`@variable').
(defconst elp-ts-mode--commonlisp-capture-map
  '(("@variable.builtin"      . "@font-lock-variable-name-face")
    ("@variable.parameter"    . "@font-lock-variable-name-face")
    ("@variable"              . "@font-lock-variable-name-face")
    ("@function.macro"        . "@font-lock-keyword-face")
    ("@function.builtin"      . "@font-lock-builtin-face")
    ("@function"              . "@font-lock-function-name-face")
    ("@string.special.symbol" . "@font-lock-builtin-face")
    ("@string.escape"         . "@font-lock-escape-face")
    ("@string"                . "@font-lock-string-face")
    ("@punctuation.special"   . "@font-lock-delimiter-face")
    ("@punctuation.bracket"   . "@font-lock-bracket-face")
    ("@constant.builtin"      . "@font-lock-constant-face")
    ("@constant"              . "@font-lock-constant-face")
    ("@number"                . "@font-lock-number-face")
    ("@boolean"               . "@font-lock-constant-face")
    ("@character"             . "@font-lock-constant-face")
    ("@comment"               . "@font-lock-comment-face")
    ("@module"                . "@font-lock-type-face")
    ("@operator"              . "@font-lock-operator-face")
    ("@type"                  . "@font-lock-type-face")
    ;; `@spell' is an nvim concept (spell-check inside captures); we
    ;; just strip it.  Tree-sitter accepts multi-tag captures so the
    ;; remaining face still applies cleanly.
    ("@spell"                 . "")))

(defun elp-ts-mode--double-backslashes (s)
  "Double every backslash in S.
Tree-sitter's query string parser collapses `\\X' → `X' for
unknown escapes, so to land a single `\\' at the regex engine we
have to emit `\\\\' in the .scm source."
  (replace-regexp-in-string "\\\\" "\\\\\\\\" s t t))

(defun elp-ts-mode--any-of-to-match (s)
  "Rewrite each `(#any-of? @CAP \"a\" \"b\" …)' in S to an
equivalent `(#match? @CAP \"\\\\`\\\\(?:a\\\\|b\\\\|…\\\\)\\\\'\")'.
Emacs treesit only supports `equal', `match', and `pred'
predicates at query-execution time, even though it accepts
`#any-of?' at compile-time as a no-op.  Backslashes are doubled
because tree-sitter's string parser eats one level."
  (with-temp-buffer
    (insert s)
    (goto-char (point-min))
    (while (re-search-forward "(#any-of\\?[ \t\n]+" nil t)
      (let ((open  (match-beginning 0))
            (close (save-excursion
                     (goto-char (match-beginning 0))
                     (forward-list 1)
                     (point))))
        (re-search-forward "@\\([A-Za-z._-]+\\)" close)
        (let ((cap (match-string 1))
              strings)
          (while (re-search-forward "\"\\([^\"]*\\)\"" close t)
            (push (match-string 1) strings))
          (let* ((quoted (mapcar (lambda (str)
                                   (elp-ts-mode--double-backslashes
                                    (regexp-quote str)))
                                 (nreverse strings)))
                 (alts (mapconcat #'identity quoted "\\\\|")))
            (delete-region open close)
            (goto-char open)
            (insert (format "(#match? @%s \"\\\\`\\\\(?:%s\\\\)\\\\'\")"
                            cap alts))))))
    (buffer-string)))

(defun elp-ts-mode--translate-commonlisp-query (s)
  "Translate nvim-treesitter captures and predicates in S.
Applies `elp-ts-mode--commonlisp-capture-map' longest-first,
rewrites `#lua-match?' → `#match?' (the upstream's three lua
patterns happen to be valid Emacs regex too), and expands
`#any-of?' into a `#match?' alternation."
  (let ((result s))
    (dolist (mapping elp-ts-mode--commonlisp-capture-map)
      (setq result (replace-regexp-in-string
                    (regexp-quote (car mapping))
                    (cdr mapping)
                    result t t)))
    (setq result (replace-regexp-in-string "#lua-match\\?" "#match?"
                                           result t t))
    ;; Upstream's lone PCRE-style #match? regex for operator-leading
    ;; lists.  Convert to Emacs regex syntax (escape group/alternation).
    (setq result (replace-regexp-in-string
                  (regexp-quote "\"^([+*-+=<>]|<=|>=|/=)$\"")
                  "\"\\\\`\\\\(?:[+*=<>]\\\\|<=\\\\|>=\\\\|/=\\\\)\\\\'\""
                  result t t))
    (elp-ts-mode--any-of-to-match result)))

(defun elp-ts-mode--split-commonlisp-rules (body)
  "Split BODY into (MAIN . NOISY) where NOISY carries the two
catch-all rules whose default presence would over-paint Lisp
regions: `(sym_lit) @variable' and `[\"(\" \")\"] @punctuation.bracket'.
Falls back to leaving them in MAIN if upstream changes them."
  (let ((noisy "")
        (main body))
    (when (string-match "^(sym_lit) @variable\n" main)
      (setq noisy (concat noisy (match-string 0 main))
            main (replace-match "" t t main)))
    (when (string-match "\\[\n[ \t]*\"(\"\n[ \t]*\")\"\n\\] @punctuation\\.bracket\n"
                        main)
      (setq noisy (concat noisy "\n" (match-string 0 main))
            main (replace-match "" t t main)))
    (cons main noisy)))

(defun elp-ts-mode--load-commonlisp-rules ()
  "Build treesit font-lock rules from the vendored highlights.scm.
Returns nil if the `commonlisp' grammar isn't available."
  (when (treesit-language-available-p 'commonlisp)
    (let* ((file (expand-file-name "queries/commonlisp/highlights.scm"
                                    elp-ts-mode--root))
           (body (with-temp-buffer
                   (insert-file-contents file)
                   (buffer-string)))
           (split (elp-ts-mode--split-commonlisp-rules body))
           (main  (elp-ts-mode--translate-commonlisp-query (car split)))
           (noisy (elp-ts-mode--translate-commonlisp-query (cdr split))))
      ;; `:override t' on both groups because templated `.elp' code
      ;; often sits inside a host-language string scalar; yaml's
      ;; (double_quote_scalar) node spans across our excluded tag
      ;; ranges and would otherwise paint over the Lisp content.
      (append
       (treesit-font-lock-rules
        :language 'commonlisp :feature 'commonlisp :override t main)
       (when (> (length (string-trim noisy)) 0)
         (treesit-font-lock-rules
          :language 'commonlisp :feature 'commonlisp-noisy :override t
          noisy))))))

(defun elp-ts-mode--host-font-lock-rules (host)
  "Font-lock rules for HOST language.
Lifted from HOST's `\\=`*-ts-mode--font-lock-settings'\\=`
variable, if loadable.  This is how we get yaml/bash/json/etc.
highlighting without reimplementing it."
  (let* ((mode (intern (format "%s-ts-mode" host)))
         (var  (intern (format "%s-ts-mode--font-lock-settings" host))))
    (when (and (treesit-language-available-p host)
               (or (boundp var)
                   (ignore-errors (require mode nil t))))
      (and (boundp var) (symbol-value var)))))

(defvar elp-ts-mode--feature-list
  '(;; level 1: bare minimum
    (comment delimiter definition)
    ;; level 2: strings + keywords
    (string keyword constant number type)
    ;; level 3: defaults — full Common Lisp coverage from vendored
    ;; highlights.scm goes here so users at the default level 3 see
    ;; defun-name highlighting, builtin/macro recognition, etc.
    (commonlisp property assignment bracket function variable
                misc-punctuation escape-sequence)
    ;; level 4: noisy — sym_lit catch-all + every paren.  Opt in via
    ;; `(setq treesit-font-lock-level 4)' if you want it.
    (commonlisp-noisy error operator builtin))
  "Combined feature list for the ELP + embedded languages.
Union of features we expect across hosts; per-language rules just
ignore features they don't define.")

(defun elp-ts-mode--language-at-point (pos)
  "Resolve the tree-sitter language at POS.
Walks the ELP parse tree from POS upward: a `code' ancestor means
Common Lisp; any other directive node (delimiters, comment body)
stays in ELP; only the outer text (no directive ancestor) is host."
  (let ((p (treesit-node-at pos 'elp))
        (in-code nil)
        (in-directive nil))
    (while p
      (pcase (treesit-node-type p)
        ("code" (setq in-code t))
        ((or "directive" "output_directive" "comment_directive")
         (setq in-directive t)))
      (setq p (treesit-node-parent p)))
    (cond (in-code     'commonlisp)
          (in-directive 'elp)
          (t            (or (elp-ts-mode--host-language) 'elp)))))

;;;###autoload
(define-derived-mode elp-ts-mode prog-mode "ELP"
  "Major mode for editing ELP templates, powered by tree-sitter."
  (unless (treesit-ready-p 'elp)
    (error "Tree-sitter grammar for `elp' not installed; \
run M-x treesit-install-language-grammar"))

  (treesit-parser-create 'elp)

  (let* ((host       (elp-ts-mode--host-language))
         (cl-ready   (treesit-language-available-p 'commonlisp))
         (host-ready (and host (treesit-language-available-p host)))
         (ranges     (append
                      (when cl-ready
                        ;; Shared (non-`:local') parser for commonlisp
                        ;; across all (code) ranges — required for the
                        ;; vendored highlights.scm rules to see a
                        ;; persistent parser at fontification time.
                        (treesit-range-rules
                         :embed 'commonlisp :host 'elp
                         '((code) @cap)))
                      (when host-ready
                        ;; No `:local t' for the host — yaml/json/etc.
                        ;; recover block structure better with a single
                        ;; shared parser spanning all (content) ranges
                        ;; than with per-range local parsers.
                        (treesit-range-rules
                         :embed host :host 'elp
                         '((content) @cap)))))
         (font-lock  (append
                      ;; Host first, ELP last.  Later rules in
                      ;; `treesit-font-lock-settings' have higher
                      ;; precedence among :override t rules.  Yaml's
                      ;; (double_quote_scalar) node spans the buffer
                      ;; from `"' to `"' across our excluded tag
                      ;; ranges, so its :override string rule would
                      ;; otherwise paint the tag delimiters inside a
                      ;; templated string value.  Putting ELP's
                      ;; delimiter rule last lets it reclaim those
                      ;; bytes.
                      (and host-ready
                           (elp-ts-mode--host-font-lock-rules host))
                      (and cl-ready
                           (elp-ts-mode--load-commonlisp-rules))
                      elp-ts-mode--elp-font-lock-rules)))

    (setq-local treesit-range-settings        ranges
                treesit-font-lock-settings    font-lock
                treesit-font-lock-feature-list elp-ts-mode--feature-list
                treesit-language-at-point-function
                #'elp-ts-mode--language-at-point))

  (setq-local comment-start "<%# "
              comment-end   " %>")

  (treesit-major-mode-setup)
  ;; Drive an initial range update so embedded parsers exist with
  ;; the right included ranges before the first fontification pass.
  ;; `treesit-major-mode-setup' itself only hooks update-on-change.
  (when treesit-range-settings (treesit-update-ranges)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.elp\\'" . elp-ts-mode))

(provide 'elp-ts-mode)
;;; elp-ts-mode.el ends here
