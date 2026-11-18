# copperline.el

Develop and debug Amiga 68k C programs - ACE, vasm, WHDLoad-style CMake
projects - inside the [Copperline](https://github.com/CopperlineHQ/Copperline)
emulator, with [dape](https://github.com/svaante/dape) as the Emacs
front end.

One command fetches Copperline and Bartman's `m68k-amiga-elf` toolchain
(gcc, gdb, `elf2hunk`, `vasmm68k_mot`, `exe2adf`, Shrinkler) into
`~/.emacs.d/.cache/copperline`, puts them on your `PATH`, and registers a
dape configuration.

## Install

```elisp
(use-package copperline
  :vc (:url "https://github.com/timfel/copperline.el" :branch "main" :rev :newest)
  :commands (copperline-install copperline-setup copperline-run copperline-profile))
```

## Use

    M-x copperline-install    ; once, about 200 MB
    M-x copperline-run        ; in a C buffer; offers the newest *.exe

Source breakpoints, stepping, typed locals, a call stack through ACE's own
sources, the 68k registers, and a Chipset scope of custom registers, all in
dape's ordinary UI (`C-x X a c` continue, `C-x X a n` step, `C-x X a q`
quit). Booting the bundled AROS ROM takes ~30 s - that is the guest, not a
hang. Remove `:headless` from `copperline--dap-config` to see the emulator.

Build with the toolchain package's `m68k-bartman.cmake`:

```sh
cmake -S . -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=deps/AmigaCMakeCrossToolchains/m68k-bartman.cmake \
  -DTOOLCHAIN_PREFIX=m68k-amiga-elf \
  -DTOOLCHAIN_PATH=~/.emacs.d/.cache/copperline/toolchain/opt \
  -DM68K_CPU=68000 -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
cmake --build build
```

Three things to remember:

1. `TOOLCHAIN_PATH` names the `opt` directory, and `elf2hunk` has to sit
   beside `opt/` - the toolchain file looks for `${TOOLCHAIN_PATH}/../elf2hunk`.
2. The adapter wants DWARF at `<program>.elf`, i.e. `game.exe.elf`; for a
   `game.exe` / `game.elf` pair pass `:symbolFile` (which
   `copperline-run` does). Without it you get symbols but no lines or locals.
3. Line breakpoints bind once the session's loaded sources have been
   fetched; `copperline--prime` arranges that on the first stop.

The toolchain file adds `-flto -fwhole-program` to every build type, Debug
included. Lines survive that; inlined locals do not, so a debug build wants
`-O0`:

```sh
-DCMAKE_C_FLAGS="-g -O0 -m68000 -fomit-frame-pointer -nostdlib \
  -fdata-sections -ffunction-sections -MP"
```

## Profiling, coverage, sizes

`M-x copperline-profile` samples frames from the stopped session into a
source-mapped `.cpuprofile` with a `[Bus wait]` child for chip-DMA stalls.
For the per-frame bus story:

```sh
copperline-ctl --info /tmp/ccp.json profile.start \
  '{"path":"out/p","frames":300,"slots":true,"samples":true}'
copperline-ctl --info /tmp/ccp.json profile.stop
copperline-ctl profile-report out/p --program build/game.exe \
  --elf build/game.elf --out game.cpuprofile
```

```sh
copperline --factory --noaudio --run build/game.exe --coverage build/lcov.info
copperline-ctl size-report build/game.exe --elf build/game.elf
```

## Not here

Copperline's own Debug workspace - Frame Analyzer, Copper and Video tabs,
sprite and bitplane isolation, Copper stepping, beam traps - only exists in
the emulator window, which `:headless nil` gives you.

## Requirements

Emacs 29.1+, `curl`, `tar`, `unzip`, `find`, and dape for debugging. Linux
x86_64 release assets (set `copperline-architecture` elsewhere); Windows and
macOS would need their own asset names and are untested.

GPL-3.0-or-later.
