# copperline.el

Two libraries for Amiga 68k development:

- **amiga-cmake.el** - build C programs with CMake and [Bartman's
  toolchain](https://github.com/BartmanAbyss/vscode-amiga-debug).
- **copperline.el** - run and debug the result in the
  [Copperline](https://github.com/CopperlineHQ/Copperline) emulator.

## Install

```elisp
(use-package amiga-cmake
  :vc (:url "https://github.com/timfel/copperline.el" :branch "main" :rev :newest)
  :commands (amiga-cmake-toolchain-download amiga-cmake-add-dirlocals))
(use-package copperline
  :vc (:url "https://github.com/timfel/copperline.el" :branch "main" :rev :newest)
  :commands (copperline-download copperline copperline-debug
             copperline-profile))
```

## Use

    M-x amiga-cmake-toolchain-download  ; once: m68k toolchain + CMake files
    M-x amiga-cmake-add-dirlocals       ; per project: edits .dir-locals.el
    M-x copperline-download             ; once: the emulator and its CLI
    M-x copperline                      ; run the built program
    M-x copperline-debug                ; debug it under dape
    M-x copperline-profile              ; profile a stopped session

In a project, `amiga-cmake-add-dirlocals` adds this stanza to the
tracked `.dir-locals.el`, merging into one that already exists. The
stanza contains nothing machine-specific, so the file is committable:
pushed to the repo, a fresh clone is set up as is. (Emacs asks once per
project whether the `eval` is OK.)

```elisp
((nil . ((eval . (progn
                (setq-local compile-command (amiga-cmake-compile-command))
                (setq-local compilation-environment
                            (amiga-cmake-compilation-environment))
                (when (boundp 'eglot-server-programs)
                  (setq-local eglot-server-programs
                              (cons (cons '(c-mode c-ts-mode c++-mode c++-ts-mode)
                                          #'amiga-cmake-clangd)
                                    (default-value 'eglot-server-programs))))))))
```

`M-x compile` then configures with AmigaCMakeCrossToolchains and builds,
showing the command for review; Eglot starts clangd with
`--query-driver` on the cross compiler, so it parses the project as m68k
code without a `.clangd` file. Everything is derived from
`amiga-cmake-cmake-kit` and the packages' cache dirs under
`~/.emacs.d/.cache`, and nothing is exported to `exec-path` or
`process-environment`.

`copperline-debug` gives source breakpoints, stepping, typed locals, a
call stack through ACE's own sources, the 68k registers and a Chipset
scope, all in dape's UI (`C-x X a c` continue, `C-x X a n` step, `C-x X a
q` quit). Booting the bundled AROS ROM takes ~30 s - that is the guest.
The session is headless; the screen is `copperline`, which uses the same
`copperline-machine`.

## Remember

1. The toolchain file wants `elf2hunk` beside `opt/`:
   `${TOOLCHAIN_PATH}/../elf2hunk`. The download places it there; a
   hand-copied `opt/` gives a confusing ELF2HUNK-NOTFOUND.
2. `m68k-bartman.cmake` adds `-flto -fwhole-program` to every build
   type, Debug included. Lines survive that, inlined locals do not; a
   debugging build wants `-DCMAKE_C_FLAGS="-g -O0 -m68000
   -fomit-frame-pointer -nostdlib -fdata-sections -ffunction-sections
   -MP"`.
3. The adapter reads DWARF from `<program>.elf` next to the `.exe`
   (`copperline-debug` passes it); without it you get symbols but no
   lines or locals. Line breakpoints bind on the first stop, when the
   session's loaded sources have been fetched.

## Profiling, coverage, sizes

`copperline-profile` samples the stopped session into a source-mapped
`.cpuprofile` with a `[Bus wait]` child for chip-DMA stalls. The
per-frame bus story, coverage and static sizes are shell jobs:

```sh
copperline-ctl --info /tmp/ccp.json profile.start \
  '{"path":"out/p","frames":300,"slots":true,"samples":true}'
copperline-ctl --info /tmp/ccp.json profile.stop
copperline-ctl profile-report out/p --program build/game.exe \
  --elf build/game.elf --out game.cpuprofile
copperline --factory --noaudio --run build/game.exe --coverage build/lcov.info
copperline-ctl size-report build/game.exe --elf build/game.elf
```

## Requirements

Emacs 29.1+, `curl`, `tar`, `unzip`, `find`, and dape for the debug
commands. x86_64 and aarch64 emulator assets; Windows and macOS untested.

GPL-3.0-or-later.
