;;; amiga-cmake.el --- Build Amiga 68k C programs with CMake -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Tim Felgentreff

;; Author: Tim Felgentreff
;; URL: https://github.com/timfel/copperline.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: tools, processes

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Build Amiga 68k C programs with CMake and Bartman's toolchain.
;;
;;     M-x amiga-cmake-toolchain-download  ; once
;;     M-x amiga-cmake-add-dirlocals       ; per project
;;
;; `amiga-cmake-add-dirlocals' appends a dir-local to the project's
;; untracked `.dir-locals-2.el': it sets `compile-command' and
;; `compilation-environment' from the toolchain, and points Eglot's
;; clangd at it with `--query-driver' so clangd parses the project as
;; m68k code without needing a .clangd file.  `M-x compile' shows the
;; command for review.
;;
;; elf2hunk must live beside the toolchain's `opt/': m68k-bartman.cmake
;; looks for ${TOOLCHAIN_PATH}/../elf2hunk.  That file adds
;; -flto -fwhole-program to every build type, Debug included; a
;; debugging build wants them replaced by -O0 -g, repeating the machine
;; flags.  Run and debug the result with copperline.el, same repository.

;;; Code:

(require 'project)
(require 'subr-x)

(defgroup amiga-cmake nil
  "Build Amiga 68k C programs with CMake and Bartman's toolchain."
  :group 'tools
  :link '(url-link "https://github.com/AmigaPorts/AmigaCMakeCrossToolchains"))

(defconst amiga-cmake-cache-dir (locate-user-emacs-file ".cache/amiga-cmake"))

(defconst amiga-cmake-toolchain-repo "BartmanAbyss/vscode-amiga-debug")

(defconst amiga-cmake-local-toolchain-globs
  '("~/.vscode/extensions/bartmanabyss.amiga-debug-*/bin/linux"
    "~/.vscode-server/extensions/bartmanabyss.amiga-debug-*/bin/linux"))

(defcustom amiga-cmake-cmake-kit (list :cpu "68000" :prefix "m68k-amiga-elf"
                                       :build-type "Debug")
  "CMake target to configure: :cpu, :prefix, :build-type."
  :type '(list :inline t
               (const :tag ":cpu" :cpu)
               (choice :tag "CPU"
                       (const "68000")
                       (const "68020")
                       (const "68040"))
               (const :tag ":prefix" :prefix)
               (string :tag "Toolchain prefix")
               (const :tag ":build-type" :build-type)
               (choice :tag "Build type"
                       (const "Debug")
                       (const "Release")
                       (const "RelWithDebInfo"))))

(defun amiga-cmake--toolchain-dir ()
  "The toolchain tree: holds `opt' and `elf2hunk'."
  (expand-file-name "toolchain" amiga-cmake-cache-dir))

(defun amiga-cmake--toolchain-file ()
  "The CMake toolchain file configuring a project."
  (expand-file-name "AmigaCMakeCrossToolchains/m68k-bartman.cmake"
                    amiga-cmake-cache-dir))

(defun amiga-cmake--toolchain-prefix ()
  "GCC program prefix, as a fresh configure would pass it."
  (or (plist-get amiga-cmake-cmake-kit :prefix) "m68k-amiga-elf"))

(defun amiga-cmake--project-root ()
  "The current project's root, as project.el finds it."
  (expand-file-name (project-root (project-current t))))

(defun amiga-cmake--fetch (url dest)
  "Download URL to DEST with curl, failing loudly.
`process-file' would hand curl a pty, which makes it download nothing."
  (let ((inhibit-message t))
    (message "amiga-cmake: downloading %s" (file-name-nondirectory dest))
    (unless (zerop (call-process "curl" nil nil nil "-sSfL" "--retry" "2"
                                 "--output" dest url))
      (error "amiga-cmake: could not download %s" url))))

(defun amiga-cmake--latest-assets (repo)
  "Return (NAME . URL) pairs for the latest release of GitHub REPO."
  (let ((json-file (make-temp-file "amiga-cmake-release-" nil ".json")))
    (unwind-protect
        (progn
          (unless (zerop (call-process "curl" nil nil nil "-sSfL" "--retry" "2"
                                       "--output" json-file
                                       (format "https://api.github.com/repos/%s/releases/latest"
                                               repo)))
            (error "amiga-cmake: could not read the latest %s release" repo))
          (with-temp-buffer
            (insert-file-contents json-file)
            (let ((assets (plist-get (json-parse-buffer :object-type 'plist) :assets)))
              (seq-map (lambda (a) (cons (plist-get a :name) (plist-get a :browser_download_url)))
                       (append assets nil)))))
      (delete-file json-file))))

;;;###autoload
(defun amiga-cmake-toolchain-download (&optional force)
  "Download Bartman's m68k toolchain and the AmigaCMakeCrossToolchains.
Both land under `amiga-cmake-cache-dir'; prefix argument FORCE refetches.
A locally installed vscode-amiga-debug extension is copied rather than
downloading its 200 MB VSIX."
  (interactive "P")
  (make-directory amiga-cmake-cache-dir t)
  (condition-case-unless-debug err
      (progn
        (amiga-cmake--download-toolchain force)
        (amiga-cmake--download-cmake-files force)
        (message "amiga-cmake: toolchain in %s -- `M-x amiga-cmake-add-dirlocals' wires up a project"
                 (file-truename amiga-cmake-cache-dir)))
    (error (user-error "amiga-cmake-toolchain-download failed: %s"
                       (error-message-string err)))))

(defun amiga-cmake--download-toolchain (force)
  "Install the toolchain tree, preferring a local VS Code install."
  (let ((marker (expand-file-name "opt/bin" (amiga-cmake--toolchain-dir)))
        (target (amiga-cmake--toolchain-dir)))
    (unless (and (file-directory-p marker) (not force))
      (if-let* ((src (car (delq nil (mapcar (lambda (glob)
                                              (car (file-expand-wildcards glob t)))
                                            amiga-cmake-local-toolchain-globs))))
                ((progn (when (file-directory-p target)
                          (delete-directory target 'recursive))
                        ;; `target' must not exist: cp then creates it as
                        ;; a copy of SRC, not a subdirectory of it.
                        (zerop (call-process "cp" nil nil nil "-a" src target)))))
          (message "amiga-cmake: copied toolchain from %s" src)
        (let* ((assets (amiga-cmake--latest-assets amiga-cmake-toolchain-repo))
               (vsix (seq-find (lambda (a) (string-suffix-p ".vsix" (car a))) assets))
               (archive (expand-file-name (or (car vsix) "amiga-debug.vsix")
                                          temporary-file-directory)))
          (unless vsix
            (error "amiga-cmake: no VSIX in the latest %s release"
                   amiga-cmake-toolchain-repo))
          (message "amiga-cmake: unpacking %s from its VSIX" (car vsix))
          (amiga-cmake--fetch (cdr vsix) archive)
          (let ((staging (make-temp-file "amiga-cmake-vsix" t)))
            (unless (zerop (call-process "unzip" nil nil nil "-q" "-o" archive
                                         "-d" staging "extension/bin/linux/*"))
              (error "amiga-cmake: could not unpack %s" archive))
            (delete-directory target 'recursive)
            (copy-directory (expand-file-name "extension/bin/linux" staging)
                            target nil nil t)
            (delete-directory staging t))
          (delete-file archive)))
      (let ((elf2hunk (expand-file-name "elf2hunk" (amiga-cmake--toolchain-dir))))
        (when (file-exists-p elf2hunk) (set-file-modes elf2hunk #o755))))))

(defun amiga-cmake--download-cmake-files (force)
  "Fetch the AmigaCMakeCrossToolchains master tarball unless present."
  (let ((dest (file-name-directory (directory-file-name (amiga-cmake--toolchain-file)))))
    (if (and (file-readable-p (amiga-cmake--toolchain-file)) (not force))
        (message "amiga-cmake: CMake toolchain files already in %s" dest)
      (let ((tarball (expand-file-name "amigacmake.tar.gz" temporary-file-directory)))
        (amiga-cmake--fetch
         "https://codeload.github.com/AmigaPorts/AmigaCMakeCrossToolchains/tar.gz/refs/heads/master"
         tarball)
        (delete-directory dest 'recursive)
        (make-directory dest t)
        (unless (zerop (call-process "tar" nil nil nil "-xzf" tarball "-C" dest
                                     "--strip-components=1"))
          (error "amiga-cmake: could not unpack %s (incomplete download?)" tarball))
        (delete-file tarball)))))

;;;###autoload
(defun amiga-cmake-compile-command ()
  "Configure the project with the Amiga kit and build it, as one command.
Both halves are absolute, so they work from any buffer of the project.
Nil until `amiga-cmake-toolchain-download' has run."
  (let* ((root (amiga-cmake--project-root))
         (build (expand-file-name "build" root))
         (toolchain (amiga-cmake--toolchain-file)))
    (when (file-readable-p toolchain)
      (format "cmake -S %s -B %s -G Ninja -DCMAKE_TOOLCHAIN_FILE=%s -DTOOLCHAIN_PREFIX=%s -DTOOLCHAIN_PATH=%s -DM68K_CPU=%s -DCMAKE_BUILD_TYPE=%s -DCMAKE_EXPORT_COMPILE_COMMANDS=ON && cmake --build %s"
              (shell-quote-argument root)
              (shell-quote-argument build)
              (shell-quote-argument toolchain)
              (amiga-cmake--toolchain-prefix)
              (shell-quote-argument (expand-file-name "opt" (amiga-cmake--toolchain-dir)))
              (plist-get amiga-cmake-cmake-kit :cpu)
              (plist-get amiga-cmake-cmake-kit :build-type)
              (shell-quote-argument build)))))

;;;###autoload
(defun amiga-cmake-compilation-environment ()
  "Build environment: the toolchain's bins on `PATH'."
  (let* ((tree (amiga-cmake--toolchain-dir))
         (path (mapconcat (lambda (d) (file-truename (expand-file-name d tree)))
                          (list "opt/bin" "." (format "opt/%s/bin" (amiga-cmake--toolchain-prefix)))
                          path-separator)))
    (list (format "PATH=%s%s%s" path path-separator (getenv "PATH")))))

;;;###autoload
(defun amiga-cmake-clangd (_interactive _project)
  "Eglot contact for clangd pointed at the Amiga toolchain.
`--query-driver' lets clangd take the target triple and the cross
compiler's own include paths from that compiler instead of parsing
Amiga code as host code.  Plain clangd when it is not installed, which
makes a dir-local registering this harmless in other projects."
  (let ((gcc (expand-file-name (format "opt/bin/%s-gcc" (amiga-cmake--toolchain-prefix))
                               (amiga-cmake--toolchain-dir))))
    (cons "clangd" (and (file-executable-p gcc)
                        (list (format "--query-driver=%s" gcc))))))

(defun amiga-cmake-dirlocals-form ()
  "The dir-local form `amiga-cmake-add-dirlocals' appends."
  `((nil . ((eval . (progn
                      (setq-local compile-command (amiga-cmake-compile-command))
                      (setq-local compilation-environment
                                  (amiga-cmake-compilation-environment))
                      (when (boundp (quote eglot-server-programs))
                        (setq-local eglot-server-programs
                                    (cons (cons (quote (c-mode c-ts-mode c++-mode c++-ts-mode))
                                                (function amiga-cmake-clangd))
                                          (default-value (quote eglot-server-programs)))))))))))

(defun amiga-cmake-dirlocals-stanza ()
  "`amiga-cmake-dirlocals-form' as dir-local file text."
  (require 'pp)
  (let ((s (pp-to-string (amiga-cmake-dirlocals-form))))
    (setq s (replace-regexp-in-string "(function " "#'" s))
    (setq s (replace-regexp-in-string "(quote " "'" s))
    (concat (string-trim-right s) "\n")))

;;;###autoload
(defun amiga-cmake-add-dirlocals ()
  "Append the Amiga CMake dir-local to the project's `.dir-locals-2.el'.
A no-op when that file mentions `amiga-cmake-compile-command' already."
  (interactive)
  (let ((file (expand-file-name ".dir-locals-2.el" (amiga-cmake--project-root))))
    (cond
     ((and (file-readable-p file)
           (with-temp-buffer (insert-file-contents file)
                             (progn (goto-char (point-min))
                                    (search-forward "amiga-cmake-compile-command" nil t))))
      (message "amiga-cmake: %s already sets it up" file))
     (t
      (with-temp-buffer
        (when (file-exists-p file) (insert-file-contents file))
        (unless (bolp) (insert "\n"))
        (insert (amiga-cmake-dirlocals-stanza))
        (write-region (point-min) (point-max) file))
      (message "amiga-cmake: added Amiga CMake dir-locals to %s" file)))))

(provide 'amiga-cmake)
;;; amiga-cmake.el ends here
