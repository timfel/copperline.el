;;; copperline.el --- Debug Amiga 68k C programs in Copperline -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Tim Felgentreff

;; Author: Tim Felgentreff
;; URL: https://github.com/timfel/copperline.el
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes, convenience

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Installs the Copperline Amiga emulator and Bartman's m68k-amiga-elf
;; toolchain under ~/.emacs.d/.cache/copperline, puts them on your PATH,
;; and registers a dape configuration, so an Amiga game built with CMake
;; can be debugged from Emacs with source breakpoints and locals.  dape
;; (MELPA) is not required to install, only to debug.
;;
;;     M-x copperline-install    ; once, about 200 MB
;;     M-x copperline-mode       ; per project: cmake build + toolchain in PATH
;;     M-x copperline-run        ; in a C buffer; offers the newest *.exe
;;
;; `copperline-mode' is the build half: it sets `compile-command' and
;; `compilation-environment' buffer-locally from the project's CMake cache,
;; so M-x compile configures and builds with the same toolchain environment
;; the VS Code cmake kits use, without touching the rest of your Emacs.
;; Add
;;     :hook ((c-mode-local-vars-hook c++-mode-local-vars-hook) . copperline-mode)
;; to your use-package form to get it in every C buffer.
;;
;; You get breakpoints, stepping, typed locals, a call stack through ACE's
;; own sources, the 68k register file and a Chipset scope full of custom
;; registers.  C-x X a c continues, C-x X a n steps, C-x X a q quits.
;; Booting the bundled AROS ROM takes about 30 seconds; that is the guest
;; booting, not a hang.
;;
;; Drop :headless from `copperline--dap-config' to see the emulator
;; window.  Copperline's own Debug workspace - the Frame Analyzer, Copper
;; and Video tabs, sprite and bitplane isolation, Copper stepping, beam
;; traps - only exists in that window, and this package does not pretend
;; to reproduce it inside Emacs.
;;
;; ** Building something the adapter can use **
;;
;; The adapter debugs a hunk executable together with the ELF it was made
;; from.  With AmigaCMakeCrossToolchains' m68k-bartman.cmake and a project
;; that runs elf2hunk after linking (greatflight does):
;;
;; `copperline-mode' generates
;;
;;     cmake -S . -B build -G Ninja \
;;       -DCMAKE_TOOLCHAIN_FILE=deps/AmigaCMakeCrossToolchains/m68k-bartman.cmake \
;;       -DTOOLCHAIN_PREFIX=m68k-amiga-elf \
;;       -DTOOLCHAIN_PATH=~/.emacs.d/.cache/copperline/toolchain/opt \
;;       -DM68K_CPU=68000 -DCMAKE_BUILD_TYPE=Debug \
;;       -DCMAKE_EXPORT_COMPILE_COMMANDS=ON ; then cmake --build build
;;
;; for an unconfigured tree, and `cmake --build build' once it is, with the
;; cross compiler, elf2hunk and vasmm68k_mot on PATH.  clangd then reads
;; build/compile_commands.json.
;;
;; Three things to remember:
;;
;;  1. TOOLCHAIN_PATH names the `opt' directory, and elf2hunk has to live
;;     beside opt/: the toolchain file looks for ${TOOLCHAIN_PATH}/../elf2hunk.
;;     Copying only opt/ gives you a confusing ELF2HUNK-NOTFOUND.
;;  2. The adapter looks for DWARF at <program> with ".elf" appended, i.e.
;;     `game.exe.elf'.  For a `game.exe' / `game.elf' pair you have to name
;;     the ELF in :symbolFile, which `copperline-run' does for you.
;;     Without it you get symbols but no lines: frames read `main ?:0',
;;     Locals is empty and breakpoints say "no line information for game.c".
;;  3. Line breakpoints only bind after the adapter relocates the program's
;;     debug info by the hunk addresses the guest reports at LoadSeg, and
;;     fetching loaded sources is what triggers that.
;;     `copperline--prime' does it on the first stop; a breakpoint that is
;;     still unverified just needs toggling off and on.
;;
;; m68k-bartman.cmake puts -flto -fwhole-program into every build type,
;; Debug included.  Source lines survive that, inlined locals do not.  For
;; a debugging build replace the flag set (repeating the machine flags,
;; since you are replacing them):
;;
;;     -DCMAKE_C_FLAGS="-g -O0 -m68000 -fomit-frame-pointer -nostdlib \
;;       -fdata-sections -ffunction-sections -MP"
;;
;; and keep the LTO build for measuring the code you ship.
;;
;; ** Profiling, coverage, sizes **
;;
;; `M-x copperline-profile' samples FRAMES from the stopped session and
;; opens a source-mapped Chrome .cpuprofile whose [Bus wait] child shows
;; time lost to chip DMA.  The per-frame bus story is a shell job:
;;
;;     copperline-ctl --info /tmp/ccp.json profile.start \
;;       '{\"path\":\"out/p\",\"frames\":300,\"slots\":true,\"samples\":true}'
;;     copperline-ctl --info /tmp/ccp.json profile.stop
;;     copperline-ctl profile-report out/p --program build/game.exe \
;;       --elf build/game.elf --out game.cpuprofile
;;
;; Guest line and function coverage, in lcov format for genhtml or an
;; Emacs coverage gutter:
;;
;;     copperline --factory --noaudio --run build/game.exe \
;;       --coverage build/lcov.info
;;
;; Static footprint, weighted in bytes per hunk, section and function:
;;
;;     copperline-ctl size-report build/game.exe --elf build/game.elf

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'project)
(require 'subr-x)

;; Dape's own, declared rather than required: see `with-eval-after-load' below.
(defvar dape-configs)
(declare-function dape "dape" (config &optional skip-compile))
(declare-function dape-request "dape" (conn command arguments &optional cb))
(declare-function dape--live-connections "dape")
(declare-function dape--breakpoint-notify-all "dape")

(defgroup copperline nil
  "Amiga 68k development and debugging with the Copperline emulator."
  :group 'tools
  :link '(url-link "https://github.com/CopperlineHQ/Copperline"))

(defcustom copperline-cache-dir (locate-user-emacs-file ".cache/copperline")
  "Directory holding the downloaded emulator, tools and toolchain."
  :type 'directory)

(defcustom copperline-copperline-repo "CopperlineHQ/Copperline"
  "GitHub repository whose latest release provides the emulator and CLI tools."
  :type 'string)

(defcustom copperline-toolchain-repo "BartmanAbyss/vscode-amiga-debug"
  "GitHub repository whose latest release provides the m68k-amiga-elf VSIX."
  :type 'string)

(defcustom copperline-local-toolchain-globs
  '("~/.vscode/extensions/bartmanabyss.amiga-debug-*/bin/linux"
    "~/.vscode-server/extensions/bartmanabyss.amiga-debug-*/bin/linux")
  "Globs for an installed Bartman toolchain to copy rather than download."
  :type '(repeat string))

(defcustom copperline-architecture "x86_64"
  "Release-asset architecture to install: `x86_64' or `aarch64'."
  :type 'string)

(defcustom copperline-machine '(:model "A500" :chip "1M")
  "Machine plist merged into the launch request.
Examples: (quote (:model \"A1200\" :fast \"8M\")), or add
\\='(:rom \"/path/KICK31.ROM\") to debug against Kickstart instead of
the bundled AROS ROM."
  :type '(plist :key-type (choice (const :model) (const :chip) (const :fast)
                                  (const :slow) (const :rom) (const :cpu))
                :value-type string))

(defcustom copperline-cmake-kit (list :cpu "68000" :prefix "m68k-amiga-elf"
                                      :build-type "Debug")
  "Initial cache values for a fresh configure, as the VS Code cmake kit uses them.
Keys :cpu (an `M68K_CPU' value), :prefix (`TOOLCHAIN_PREFIX') and
:build-type.  A project that is already configured overrides all of them
from its own CMake cache."
  :type '(plist :key-type (choice (const :cpu) (const :prefix) (const :build-type))
                :value-type string))

(defvar copperline--primed nil
  "Connections whose loaded sources have been requested already.")

(defconst copperline--dap-config
  '(copperline
    :major-modes (c-mode c-mode-common c++-mode)
    :types ("copperline")
    :type "copperline"
    :request "launch"
    :entryPoint "main"
    :stopOnEntry t
    :headless t
    :noAudio t
    :factory t)
  "Template dape config; `copperline-run' fills the per-program keys.")

(defun copperline--toolchain-dir () (expand-file-name "toolchain" copperline-cache-dir))
(defun copperline--tools-dir () (expand-file-name "tools" copperline-cache-dir))
(defun copperline--releases-dir () (expand-file-name "releases" copperline-cache-dir))

(defun copperline-ctl ()
  "Absolute path of the installed copperline-ctl, or nil when not installed."
  (car (file-expand-wildcards (expand-file-name "copperline-ctl"
                                                (copperline--tools-dir)))))

(defun copperline-emulator ()
  "Absolute path of the installed Copperline AppImage, or nil."
  (car (file-expand-wildcards
        (expand-file-name (format "Copperline-*-%s.AppImage" copperline-architecture)
                          (copperline--releases-dir)))))

(defun copperline--latest-assets (repo)
  "Return (NAME . URL) pairs for the latest release of GitHub REPO."
  ;; `process-file' would hand curl a pty, which makes it download nothing,
  ;; and its progress output would mix into the JSON, so write to a file.
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

(defun copperline--fetch (url dest)
  "Download URL to DEST with curl, failing loudly."
  (let ((inhibit-message t))
    (message "copperline: downloading %s" (file-name-nondirectory dest))
    (unless (zerop (call-process "curl" nil nil nil "-sSfL" "--retry" "2"
                                 "--output" dest url))
      (error "copperline: could not download %s" url))))

(defun copperline--extract-tools (tarball)
  "Unpack the copperline-ctl TARBALL into `copperline--tools-dir'."
  (let ((default-directory (copperline--tools-dir)))
    ;; `process-file' would give tar a pty; see `copperline--fetch'.
    (unless (zerop (call-process "tar" nil nil nil "-xzf" tarball
                                 "--strip-components=1"))
      (error "copperline: could not unpack %s (incomplete download?)" tarball))
    (dolist (f (file-expand-wildcards "copperline-*"))
      (set-file-modes f #o755))))

(defun copperline--install-emulator (&optional force)
  "Install the emulator and CLI from GitHub unless they are already there."
  (make-directory (copperline--releases-dir) t)
  (make-directory (copperline--tools-dir) t)
  (unless (and (copperline-emulator) (copperline-ctl) (not force))
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

(defun copperline--install-toolchain (&optional force)
  "Install the m68k-amiga-elf toolchain, preferring a local VS Code install."
  (let ((marker (expand-file-name "opt/bin" (copperline--toolchain-dir)))
        (target (copperline--toolchain-dir)))
    (unless (and (file-directory-p marker) (not force))
      (if-let* ((src (car (delq nil (mapcar (lambda (glob)
                                              (car (file-expand-wildcards glob t)))
                                            copperline-local-toolchain-globs))))
                ((progn (delete-directory target 'recursive)
                        ;; `target' must not exist: cp then creates it as a
                        ;; copy of SRC rather than a subdirectory of it.
                        (zerop (call-process "cp" nil nil nil "-a" src target)))))
          (message "copperline: copied toolchain from %s" src)
      (let* ((assets (copperline--latest-assets copperline-toolchain-repo))
             (vsix (seq-find (lambda (a) (string-suffix-p ".vsix" (car a))) assets))
             (archive (expand-file-name (or (car vsix) "amiga-debug.vsix")
                                        temporary-file-directory)))
        (unless vsix
          (error "copperline: no VSIX in the latest %s release" copperline-toolchain-repo))
        (message "copperline: no local toolchain found, unpacking %s from its VSIX"
                 (car vsix))
        (copperline--fetch (cdr vsix) archive)
        (let ((staging (make-temp-file "copperline-vsix" t))
              (default-directory temporary-file-directory))
          ;; VSIX archives everything under `extension/'.
          (unless (zerop (call-process "unzip" nil nil nil "-q" "-o" archive
                                       "-d" staging "extension/bin/linux/*"))
            (error "copperline: could not unpack %s" archive))
          (delete-directory target t)
          (copy-directory (expand-file-name "extension/bin/linux" staging)
                          target nil nil t)
          (delete-directory staging t))
        ;; elf2hunk and friends keep their executable bit through the copy.
        (delete-file archive)))
    (let ((elf2hunk (expand-file-name "elf2hunk" (copperline--toolchain-dir))))
      (when (file-exists-p elf2hunk) (set-file-modes elf2hunk #o755))))))

(defun copperline--register-dape-config ()
  "Add, or refresh, the `copperline' entry in `dape-configs'."
  (let ((cell (assq 'copperline dape-configs))
        (plist (append (cdr (copy-sequence copperline--dap-config))
                       copperline-machine)))
    (if cell (setcdr cell plist) (push (cons 'copperline plist) dape-configs))))

;; Everything dape-facing is deferred: none of this runs unless dape loads.
(with-eval-after-load 'dape
  (copperline--register-dape-config)
  (add-hook 'dape-stopped-hook #'copperline--prime))

;;;###autoload
(defun copperline-install (&optional force)
  "Download Copperline and the Bartman m68k toolchain into `copperline-cache-dir'.
With a prefix argument FORCE, refetch what is already there.  A locally
installed vscode-amiga-debug extension is copied rather than downloading
its 200 MB VSIX; see the Commentary for what to do next: enabling
`copperline-mode' to build, and the three things to remember."
  (interactive "P")
  (make-directory copperline-cache-dir t)
  (condition-case-unless-debug err
      (progn (copperline--install-emulator force)
             (copperline--install-toolchain force)
             (message "copperline: installed in %s -- `M-x copperline-mode' builds, `M-x copperline-run' debugs"
                      (file-truename copperline-cache-dir)))
    (error (user-error "copperline-install failed: %s" (error-message-string err)))))

;;;; Building

(defun copperline--project-root ()
  "The current project root, or `default-directory'."
  (file-truename
   (or (when-let* ((p (project-current))) (expand-file-name (project-root p)))
       (locate-dominating-file default-directory ".git")
       default-directory)))

(defun copperline--cache-value (build-dir key)
  "Value of cache KEY in build directory BUILD-DIR, or nil."
  (let ((file (expand-file-name "CMakeCache.txt" build-dir)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (when (re-search-forward
               (format "^%s:[A-Za-z]+=\\(.+\\)$" (regexp-quote key)) nil t)
          (substring-no-properties (match-string 1)))))))

(defun copperline--build-dir ()
  "The project's CMake build directory, or nil when it is not configured.
Of several build directories, the most recently configured one wins."
  (let ((root (copperline--project-root))
        (default-directory (copperline--project-root)))
    (and-let* ((lines (ignore-errors
                       (process-lines "find" "." "-maxdepth" "3" "-name" "CMakeCache.txt"
                                      "-not" "-path" "./.git/*" "-printf" "%T@\t%h\n")))
               (hits (mapcar (lambda (l)
                               (pcase (split-string l "\t" t)
                                 (`(,mtime ,dir) (cons (string-to-number mtime)
                                                       (file-truename (expand-file-name dir root))))
                                 (_ nil)))
                             lines))
               (newest (car (last (sort (delq nil hits) #'<)))))
      (cdr newest))))

(defun copperline--toolchain-tree (build-dir)
  "Root of the toolchain tree BUILD-DIR was configured against.
That is the directory holding `opt', which also holds `elf2hunk' and the
other host tools; the package's own install if BUILD-DIR is nil or its
cache says nothing useful."
  (or (and-let* ((opt (and build-dir (copperline--cache-value build-dir "TOOLCHAIN_PATH")))
                 ((file-directory-p opt)))
        (file-name-directory (directory-file-name opt)))
      (copperline--toolchain-dir)))

(defun copperline--compilation-environment (build-dir)
  "Environment for building BUILD-DIR, as the VS Code cmake kit sets it.
<tree>/opt/bin, <tree>, and <tree>/opt/<prefix>/bin in front of `PATH', plus
`COPPERLINE_BIN' so the installed CLI tools can start the emulator."
  (let* ((tree (copperline--toolchain-tree build-dir))
         (prefix (or (and build-dir (copperline--cache-value build-dir "TOOLCHAIN_PREFIX"))
                     (plist-get copperline-cmake-kit :prefix)
                     "m68k-amiga-elf"))
         (path (mapconcat (lambda (d) (file-truename (expand-file-name d tree)))
                          (list "opt/bin" "." (format "opt/%s/bin" prefix))
                          path-separator)))
    (cons (format "PATH=%s%s%s" path path-separator (getenv "PATH"))
          (when-let* ((emu (copperline-emulator)))
            (list (format "COPPERLINE_BIN=%s" emu))))))

(defun copperline--compile-command (build-dir)
  "`cmake --build' for BUILD-DIR, else the kit's configure command.
Both are absolute, so they work from any buffer of the project."
  (let ((root (copperline--project-root)))
    (if build-dir
        (format "cmake --build %s" (shell-quote-argument build-dir))
      ;; Expanded against the root: the buffer may sit anywhere in the tree.
      (when-let* ((toolchain (car (last (file-expand-wildcards
                                           (expand-file-name "deps/*/m68k-*.cmake" root)
                                           t)))))
        (format "cmake -S %s -B %s -G Ninja -DCMAKE_TOOLCHAIN_FILE=%s -DTOOLCHAIN_PREFIX=%s -DTOOLCHAIN_PATH=%s -DM68K_CPU=%s -DCMAKE_BUILD_TYPE=%s -DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
                (shell-quote-argument root)
                (shell-quote-argument (expand-file-name "build" root))
                (shell-quote-argument toolchain)
                (plist-get copperline-cmake-kit :prefix)
                (shell-quote-argument (expand-file-name "opt" (copperline--toolchain-dir)))
                (plist-get copperline-cmake-kit :cpu)
                (plist-get copperline-cmake-kit :build-type))))))

;;;###autoload
(define-minor-mode copperline-mode
  "Build Amiga CMake projects from Emacs with the m68k toolchain in PATH.
Sets `compile-command' and `compilation-environment' buffer-locally: a
`cmake --build' for the project's CMake build directory, or the configure
command the VS Code cmake kit would use for a tree that has none (see
`copperline-cmake-kit').  The environment comes from the project's own
CMake cache once it is configured, so a project configured against another
toolchain copy builds against that one.  Assumes a Ninja generator, as the
kits do; see the Commentary for the resulting command lines."
  :lighter " Copperline"
  (if (not copperline-mode)
      (progn (kill-local-variable 'compile-command)
             (kill-local-variable 'compilation-environment))
    (let* ((build-dir (copperline--build-dir))
           (command (copperline--compile-command build-dir)))
      (if (not (or build-dir command))
          (message "copperline: no CMake cache and no deps/*/m68k-*.cmake in %s"
                   (copperline--project-root))
        (setq-local compilation-environment (copperline--compilation-environment build-dir))
        (setq-local compile-command command)
        (message "copperline: %s" command)))))

;;;; Debugging

(defun copperline--executables ()
  "Hunk executables under the current project, newest first."
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

(defun copperline--read-program ()
  "Completing-read over the project's hunk executables, else a file name."
  (let ((found (copperline--executables)))
    (if found
        (expand-file-name (completing-read "Amiga program: " found nil nil
                                           (car (last found))))
      (read-file-name "Amiga hunk executable: " nil nil t))))

;;;###autoload
(defun copperline-run (program)
  "Debug hunk executable PROGRAM in Copperline through dape.
PROGRAM defaults to the newest `*.exe' under the project.  Its sibling
`<stem>.elf' is passed as `symbolFile' when present, which is what gives
the adapter source lines and locals; see the Commentary for how to build
that pair with CMake, and `copperline-machine' for the machine to boot."
  (interactive (list (copperline--read-program)))
  (unless (require 'dape nil t)
    (user-error "dape is not installed: M-x package-install RET dape RET"))
  (unless (copperline-ctl)
    (user-error "Nothing installed yet: run M-x copperline-install"))
  (unless (file-exists-p program)
    (user-error "No such program: %s" program))
  (unless (assq 'copperline dape-configs)
    (copperline--register-dape-config))
  (let* ((program (file-truename program))
         (elf (concat (file-name-sans-extension program) ".elf"))
         (elf (and (file-exists-p elf) (file-truename elf)))
         (config (cdr (assq 'copperline dape-configs))))
    (plist-put config :command (copperline-ctl))
    (plist-put config :command-args (list "--dap"))
    ;; Absolute: outside `copperline-mode' nothing has the emulator on PATH.
    (plist-put config :copperline (or (copperline-emulator) :null))
    (plist-put config :program program)
    (plist-put config :symbolFile (or elf :null))
    (dape "copperline")
    (message "copperline: booting %s%s"
             (file-name-nondirectory program)
             (if elf " (DWARF sibling found)"
               " -- no .elf sibling, so no source lines or locals"))))

(defun copperline--prime (&rest _)
  "Fetch the session's loaded sources, then re-send breakpoints.
Copperline relocates a program's debug info by the hunk addresses the
guest reports at LoadSeg; until that happens line breakpoints report
\"no line information\".  Runs once per connection, on the first stop."
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
The adapter derives a call-frame unwind table from the program's DWARF,
records every retired instruction, and returns a merged Chrome CPU
profile whose `[Bus wait]' child shows time lost to chip DMA.  Programs
whose first code hunk holds more than about 1 MB of text cannot be
profiled (the unwind table travels in one 4 MB request)."
  (interactive "p")
  (require 'dape)
  (let ((conn (and (fboundp 'dape--live-connections) (car (dape--live-connections)))))
    (unless conn
      (user-error "No live session: M-x copperline-run first, and stop it at a breakpoint"))
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
