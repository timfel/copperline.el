;;; copperline.el --- Run and debug Amiga 68k programs in Copperline -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Tim Felgentreff

;; Author: Tim Felgentreff
;; URL: https://github.com/timfel/copperline.el
;; Version: 0.5.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: tools, processes

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Run and debug Amiga programs built by amiga-cmake.el (same repository).
;;
;;     M-x copperline-download   ; once, the emulator and its CLI
;;     M-x copperline            ; run the program in the emulator window
;;     M-x copperline-debug      ; run it under dape
;;     M-x copperline-profile    ; profile a stopped debug session
;;
;; dape (MELPA) is needed for the debug commands alone. The adapter debugs the
;; hunk executable together with the ELF it was made from: `copperline-debug'
;; passes `<program>.elf' as :symbolFile, and line breakpoints bind once loaded
;; sources are fetched (`copperline--prime'). Profiling, coverage and size
;; reports from the shell: see the README.

;;; Code:

(require 'project)
(require 'subr-x)

(declare-function dape "dape" (config &optional skip-compile))
(declare-function dape-request "dape" (conn command arguments &optional cb))
(declare-function dape--live-connections "dape")
(declare-function dape--breakpoint-notify-all "dape")
(defvar dape-configs)

(defgroup copperline nil
  "Amiga 68k development and debugging with the Copperline emulator."
  :group 'tools
  :link '(url-link "https://github.com/CopperlineHQ/Copperline"))

(defconst copperline-cache-dir (locate-user-emacs-file ".cache/copperline"))

(defconst copperline-copperline-repo "CopperlineHQ/Copperline")

(defconst copperline-architecture
  (if (string-match-p "\\`a\\(?:arch64\\|rm64\\)\\'"
                      (string-trim (shell-command-to-string "uname -m")))
      "aarch64"
    "x86_64"))

(defcustom copperline-machine '(:model "A500" :chip "1M")
  "Machine to run and debug on.
An AGA example is (quote (:model \"A1200\" :fast \"8M\")), and
(quote (:rom \"/path/KICK31.ROM\")) boots Kickstart instead of the
bundled AROS ROM."
  :type '(plist :key-type (choice (const :model) (const :chip) (const :fast)
                                  (const :slow) (const :rom) (const :cpu))
                :value-type string))

(defvar copperline--primed nil
  "Connections whose loaded sources have been requested already.")

(defconst copperline--dap-config
  '(copperline
    :name "copperline"
    ;; No :major-modes or :types: dape forwards every keyword key to the
    ;; adapter as a launch argument, and turns symbol lists into null.
    :type "copperline"
    :request "launch"
    :entryPoint "main"
    :stopOnEntry t
    :factory t
    ;; `command' and `command-args' are dape's own symbol-keyed properties:
    ;; how to start the adapter, not launch arguments for Copperline.
    command-args ("--dap"))
  "Template dape config; `copperline-debug' fills the per-program keys.")

(defun copperline--tools-dir () (expand-file-name "tools" copperline-cache-dir))
(defun copperline--releases-dir () (expand-file-name "releases" copperline-cache-dir))

(defun copperline-ctl ()
  "Absolute path of the installed copperline-ctl, or nil."
  (car (file-expand-wildcards (expand-file-name "copperline-ctl"
                                                (copperline--tools-dir)))))

(defun copperline-emulator ()
  "Absolute path of the installed Copperline AppImage, or nil."
  (car (file-expand-wildcards
        (expand-file-name (format "Copperline-*-%s.AppImage" copperline-architecture)
                          (copperline--releases-dir)))))

(defun copperline-installed-p ()
  "Non-nil when the emulator and its CLI are installed."
  (and (copperline-emulator) (copperline-ctl)))

(defun copperline--fetch (url dest)
  "Download URL to DEST with curl, failing loudly.
`process-file' would hand curl a pty, which makes it download nothing."
  (let ((inhibit-message t))
    (message "copperline: downloading %s" (file-name-nondirectory dest))
    (unless (zerop (call-process "curl" nil nil nil "-sSfL" "--retry" "2"
                                 "--output" dest url))
      (error "copperline: could not download %s" url))))

(defun copperline--latest-assets (repo)
  "Return (NAME . URL) pairs for the latest release of GitHub REPO."
  (let ((json-file (make-temp-file "copperline-release-" nil ".json")))
    (unwind-protect
        (progn
          (unless (zerop (call-process "curl" nil nil nil "-sSfL" "--retry" "2"
                                       "--output" json-file
                                       (format "https://api.github.com/repos/%s/releases/latest"
                                               repo)))
            (error "copperline: could not read the latest %s release" repo))
          (with-temp-buffer
            (insert-file-contents json-file)
            (let ((assets (plist-get (json-parse-buffer :object-type 'plist) :assets)))
              (seq-map (lambda (a) (cons (plist-get a :name) (plist-get a :browser_download_url)))
                       (append assets nil)))))
      (delete-file json-file))))

(defun copperline--extract-tools (tarball)
  "Unpack the copperline-ctl TARBALL into `copperline--tools-dir'."
  (let ((default-directory (copperline--tools-dir)))
    (unless (zerop (call-process "tar" nil nil nil "-xzf" tarball
                                 "--strip-components=1"))
      (error "copperline: could not unpack %s (incomplete download?)" tarball))
    (dolist (f (file-expand-wildcards "copperline-*"))
      (set-file-modes f #o755))))

(defun copperline--download-emulator (&optional force)
  "Install the emulator and CLI from GitHub unless they are already there."
  (make-directory (copperline--releases-dir) t)
  (make-directory (copperline--tools-dir) t)
  (unless (and (copperline-installed-p) (not force))
    (let* ((assets (copperline--latest-assets copperline-copperline-repo))
           (appimage (seq-find (lambda (a) (string-match-p
                                              (format "-%s\\.AppImage\\'" copperline-architecture)
                                              (car a)))
                               assets))
           (tools (seq-find (lambda (a) (string-match-p
                                           (format "-%s-tools\\.tar\\.gz\\'"
                                                   copperline-architecture)
                                           (car a)))
                            assets)))
      (unless (and appimage tools)
        (error "copperline: no %s assets in the latest %s release"
               copperline-architecture copperline-copperline-repo))
      (let ((appimage-dest (expand-file-name (car appimage) (copperline--releases-dir)))
            (tools-dest (expand-file-name (car tools) (copperline--releases-dir))))
        (copperline--fetch (cdr appimage) appimage-dest)
        (set-file-modes appimage-dest #o755)
        (copperline--fetch (cdr tools) tools-dest)
        (copperline--extract-tools tools-dest)))))

;;;###autoload
(defun copperline-download (&optional force)
  "Download the Copperline emulator and CLI into `copperline-cache-dir'.
With a prefix argument FORCE, refetch what is already there.  Build with
amiga-cmake.el, in the same repository."
  (interactive "P")
  (make-directory copperline-cache-dir t)
  (condition-case-unless-debug err
      (progn
        (copperline--download-emulator force)
        (message "copperline: installed in %s -- `M-x copperline' runs, `M-x copperline-debug' debugs"
                 (file-truename copperline-cache-dir)))
    (error (user-error "copperline-download failed: %s" (error-message-string err)))))

(defun copperline--machine-args ()
  "`copperline-machine' as emulator command-line arguments.
`:rom' is Copperline's positional ROM argument, the rest are flags."
  (let ((args (and-let* ((rom (plist-get copperline-machine :rom))) (list rom))))
    (dolist (spec (list (cons :model "--model") (cons :chipset "--chipset")
                        (cons :cpu "--cpu") (cons :chip "--chip")
                        (cons :fast "--fast") (cons :slow "--slow")))
      (when-let* ((value (plist-get copperline-machine (car spec))))
        (setq args (append args (list (cdr spec) value)))))
    args))

(defun copperline--register-dape-config ()
  "Add, or refresh, the `copperline' entry in `dape-configs'."
  (let ((cell (assq 'copperline dape-configs))
        (plist (append (cdr (copy-sequence copperline--dap-config))
                       copperline-machine)))
    (if cell (setcdr cell plist) (push (cons 'copperline plist) dape-configs))))

(with-eval-after-load 'dape
  (copperline--register-dape-config)
  (add-hook 'dape-stopped-hook #'copperline--prime))

(defun copperline--project-root ()
  "The current project's root, as project.el finds it.
Outside a project that is `default-directory'."
  (expand-file-name (project-root (project-current t))))

(defun copperline--executables ()
  "Hunk executables under the current project, oldest first."
  (let ((root (copperline--project-root)))
    (when-let* ((default-directory root)
                (lines (ignore-errors
                         (process-lines "find" "." "-name" "*.exe"
                                        "-not" "-path" "./.git/*" "-printf"
                                        "%T@\t%p\n"))))
      (let ((hits (mapcar (lambda (l)
                            (pcase (split-string l "\t" t)
                              (`(,mtime ,path) (cons (string-to-number mtime)
                                                     (string-remove-prefix "./" path)))
                              (_ nil)))
                          lines)))
        (mapcar (lambda (hit) (expand-file-name (cdr hit) root))
                (sort (delq nil hits) #'<))))))

(defun copperline--read-program (prompt)
  "Completing-read PROMPT over the project's hunk executables, else a file."
  (let ((found (copperline--executables)))
    (if found
        (expand-file-name (completing-read prompt found nil nil (car (last found))))
      (read-file-name "Amiga hunk executable: " nil nil t))))

(defun copperline--check-program (program)
  "Error unless PROGRAM exists and Copperline is there to run it."
  (unless (or (copperline-emulator) (executable-find "copperline"))
    (user-error "Copperline is not installed: M-x copperline-download"))
  (unless (file-exists-p program)
    (user-error "No such program: %s" program)))

;;;###autoload
(defun copperline (program)
  "Run hunk executable PROGRAM in the Copperline emulator, no debugger.
PROGRAM defaults to the newest `*.exe' under the project and the emulator
starts on `copperline-machine'; its log is displayed in `*copperline*',
and the way to stop the emulator is `M-x list-processes'.  Returns the
emulator process."
  (interactive (list (copperline--read-program "Amiga program to run: ")))
  (copperline--check-program program)
  (let ((process-connection-type nil)
        (bin (or (copperline-emulator) (executable-find "copperline"))))
    (let ((proc (apply #'start-file-process "copperline" (get-buffer-create "*copperline*")
                       bin (append (copperline--machine-args) (list "--run" program)))))
      (display-buffer (process-buffer proc))
      (message "copperline: running %s in the emulator" (file-name-nondirectory program))
      proc)))

;;;###autoload
(defun copperline-debug (program)
  "Debug hunk executable PROGRAM in Copperline through dape.
PROGRAM defaults to the newest `*.exe' under the project; its sibling
`<stem>.elf' is passed as `symbolFile', which is what gives the adapter
source lines and locals.  Booting the bundled AROS ROM takes ~30 s."
  (interactive (list (copperline--read-program "Amiga program to debug: ")))
  (unless (require 'dape nil t)
    (user-error "dape is not installed: M-x package-install RET dape RET"))
  (unless (copperline-ctl)
    (user-error "Nothing installed yet: run M-x copperline-download"))
  (copperline--check-program program)
  (unless (assq 'copperline dape-configs)
    (copperline--register-dape-config))
  (let* ((program (file-truename program))
         (elf (concat (file-name-sans-extension program) ".elf"))
         (elf (and (file-exists-p elf) (file-truename elf)))
         (config (cdr (assq 'copperline dape-configs))))
    (plist-put config (quote command) (copperline-ctl))
    (plist-put config :copperline (or (copperline-emulator) :null))
    (plist-put config :program program)
    (plist-put config :symbolFile (or elf :null))
    (dape (copy-sequence config))
    (message "copperline: booting %s%s"
             (file-name-nondirectory program)
             (if elf " (DWARF sibling found)"
               " -- no .elf sibling, so no source lines or locals"))))

(defun copperline--prime (&rest _)
  "Fetch the session's loaded sources, then re-send breakpoints.
The adapter relocates a program's debug info by the hunk addresses the
guest reports at LoadSeg; until then line breakpoints report \"no line
information\".  Runs once per connection, on the first stop."
  (when-let* ((conn (and (fboundp 'dape--live-connections)
                         (car (dape--live-connections)))))
    (unless (memq conn copperline--primed)
      (push conn copperline--primed)
      (condition-case nil
          (dape-request conn :loadedSources nil
                        (lambda (&rest _)
                          (ignore-errors (dape--breakpoint-notify-all))))
        (error nil)))))

;;;###autoload
(defun copperline-profile (frames)
  "Sample the stopped Copperline session for FRAMES into a .cpuprofile.
The profile is source-mapped and carries a `[Bus wait]' child for
time lost to chip DMA."
  (interactive "p")
  (unless (require 'dape nil t)
    (user-error "dape is not installed: M-x package-install RET dape RET"))
  (let ((conn (and (fboundp 'dape--live-connections) (car (dape--live-connections)))))
    (unless conn
      (user-error "No live session: M-x copperline-debug first, and stop it at a breakpoint"))
    (message "copperline: sampling %d frames, this takes a moment..." frames)
    (dape-request conn :copperline/profile `(:frames ,frames)
      (lambda (body error)
        (if error
            (message "copperline: profiling failed: %s" error)
          (let ((path (plist-get body :path)))
            (if path
                (progn (message "copperline: profile -> %s" path)
                       (unless noninteractive (find-file path)))
              (message "copperline: no profile path in reply: %S" body))))))))

(provide 'copperline)
;;; copperline.el ends here
