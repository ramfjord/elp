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

(defun elp-ts-mode--commonlisp-font-lock-rules ()
  "Minimal font-lock for Common Lisp inside <% %>.
Targets the node names of the `theHamsta/tree-sitter-commonlisp'
grammar.  No-op if that grammar isn't installed."
  (when (treesit-language-available-p 'commonlisp)
    ;; `:override t' on every CL rule because templated `.elp' code
    ;; often sits inside a host-language string scalar (yaml's
    ;; (double_quote_scalar) node spans across our excluded tag
    ;; ranges and would otherwise paint over the Lisp content).
    (treesit-font-lock-rules
     :language 'commonlisp
     :feature 'comment
     :override t
     '((comment) @font-lock-comment-face)

     :language 'commonlisp
     :feature 'string
     :override t
     '((str_lit) @font-lock-string-face)

     :language 'commonlisp
     :feature 'number
     :override t
     '([(num_lit) (char_lit)] @font-lock-number-face)

     :language 'commonlisp
     :feature 'keyword
     :override t
     '((kwd_lit) @font-lock-builtin-face))))

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
    ;; level 3: defaults
    (property assignment bracket function variable misc-punctuation
              escape-sequence)
    ;; level 4: noisy
    (error operator builtin))
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
                        (treesit-range-rules
                         :embed 'commonlisp :host 'elp :local t
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
                           (elp-ts-mode--commonlisp-font-lock-rules))
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
