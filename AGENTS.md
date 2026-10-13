# AGENTS.md — rmweb fork (WPE WebKit browser for the reMarkable Paper Pro)

Guide for coding agents (Claude Code, Codex, etc.) working in this repo. Read it before changing
anything.

## What this is

A native web browser that runs **on** a reMarkable Paper Pro over its own Wi-Fi. It uses WPE WebKit
2.48.5, renders entirely on the CPU (Skia raster + Mesa llvmpipe; the stock OS has no GPU driver),
and presents through Qt6 + the vendor `epaper` QPA with xochitl (the stock UI) stopped.

- **Upstream:** <https://github.com/exp78/rmweb> (MIT, by Eugene Tarakanov), tracked as the git
  remote `upstream`. This fork started at upstream `v0.9.7` (`15398f6`).
- **Fork goals:** keep a reproducible setup for our own tablets (`docs/paper-pro-setup.md`,
  `scripts/setup-device.sh`), then add features. The first one is **landscape mode** (see Roadmap).
- **Deep history:** `docs/upstream-agent-notes.md` is upstream's original CLAUDE.md, a phase-by-phase
  log of every hard-won device fact (touch, presents, JIT, deadlocks, OTA recovery). Search it before
  debugging anything in the display or input path. Ignore its "working agreement" section: it's
  upstream's (Russian replies, their commit trailer) and doesn't apply here.

## Repo map

| Path | What |
|---|---|
| `engine/wpeqt/main.cpp` | The whole app (~4000 lines): `WpeEngine` (WebKit on a worker thread), `WpeView` (QQuickPaintedItem that paints frame + chrome + keyboard), `TouchReader` (raw evdev), `EpaperRefresh` (dlopen'd `EPFramebuffer::swapBuffers`), `main()` |
| `engine/wpeqt/*.h` | Pure-logic headers with host unit tests: `gesture.h`, `keyboard.h` (on-screen keyboard layout), `tapzone.h`, `url.h`, `profile.h`, `startpage.h`, `fieldprobe.h`, `library.h` |
| `engine/wpeqt/reader/` | Vendored Mozilla Readability.js |
| `device/` | Files shipped to the tablet: `rmweb` (launcher; stops/restores xochitl), `rmweb-env.sh` (runtime env), `install.sh`, `appload-entry.sh`, `appload/rmweb/` (icon manifest) |
| `engine/*.incontainer.sh`, `engine/build-mesa.sh` | WPE WebKit / Mesa / deps cross-builds (run inside the SDK container) |
| `scripts/` | Build, bundle, package, deploy, on-device test runners, `setup-device.sh` (fork addition) |
| `tests/` | Host unit tests (`*_test.cpp`, `*_test.sh`) |
| `toolchain/` | Dockerfile for the reMarkable ferrari SDK image (`rmweb-sdk`) |
| `docs/` | Design specs, research, `install.md` (upstream), `paper-pro-setup.md` (this fork's tested runbook) |

## Device access

- USB: `ssh root@10.11.99.1` with key auth. If it fails, run `ssh-copy-id root@10.11.99.1` with the
  password from the tablet's About screen. **Never commit passwords**; `.env` is gitignored.
- Device userland is **BusyBox**: `head -n N`, not `head -N`.
- Install only under `/home/root` (rootfs `/` is read-only and ~91 % full; `/home` survives OTAs).
- Current device state: `./scripts/setup-device.sh check`.

## Build

Requires Docker with linux/arm64 (Apple Silicon is native) and the `rmweb-sdk` image. See
`toolchain/README.md`.

### Fast path: app only, minutes (use this for anything in `engine/wpeqt/`)

```sh
./scripts/fetch-sdk.sh && docker build -f toolchain/Dockerfile -t rmweb-sdk .   # once
./scripts/fast-build.sh all       # sdk (once) + app + package → dist/rmweb-<VERSION>.tar.gz
RMWEB_TARBALL=dist/rmweb-$(cat VERSION).tar.gz ./scripts/setup-device.sh rmweb  # install
```

- `fast-build.sh sdk` runs `engine/gen-app-sdk.incontainer.sh` in `debian:trixie`. It generates
  WPE WebKit 2.48.5's public headers (`wpe/`, `jsc/`, `wpe-platform/` + headless) from the
  checksum-pinned source tarball, using WebKit's own `generate-api-header.py` and `glib-mkenums`
  rules. libwpe, libsoup and xkbcommon headers come from Debian. Output: `build/appsdk/usr`.
- `fast-build.sh app` compiles `engine/wpeqt` in `rmweb-sdk` against those headers and links
  against the **prebuilt runtime from the upstream release tarball** (`build/release/`, default
  `BASE_VER=0.9.7`).
- `fast-build.sh package` = release runtime + our `rmweb-wpeqt` + `device/*` + Readability +
  `VERSION`.
- Limits: the engine itself (WPE, Mesa, soup) is **not** rebuilt. Engine changes or a WPE version
  bump need the full build below. Keep `VERSION` unique per build you install, so the tablet's
  `rmweb.log` shows which one ran.

### Full build (engine + app; hours, tens of GB)

```sh
./scripts/fetch-sdk.sh                                  # ~467 MB ferrari SDK installer (gitignored)
docker build -f toolchain/Dockerfile -t rmweb-sdk .     # SDK image (/opt/rmpp-sdk)
./scripts/build-wpe.sh deps && ./scripts/build-wpe.sh build   # WPE WebKit + Mesa llvmpipe → build/stage*  (HOURS, tens of GB)
./scripts/build-wpeqt.sh                                # the app → build/rmweb-wpeqt   (minutes)
./scripts/package.sh                                    # → dist/rmweb-<VERSION>.tar.gz (installable, no toolchain)
./scripts/run-tests.sh                                  # host unit tests (clang++, no SDK)
```

- `build-wpeqt.sh` links against `build/stage/usr` and `build/stage-mesa/usr`, the WPE/Mesa
  install prefixes produced by `build-wpe.sh`. Both are gitignored, so a fresh clone needs the
  multi-hour engine build once.
- `package.sh` refuses to package if `engine/wpeqt` sources are newer than the binary.

## Deploy & test on the device

```sh
RMWEB_TARBALL=dist/rmweb-<ver>.tar.gz ./scripts/setup-device.sh rmweb   # install a local build
ssh root@10.11.99.1 'systemd-run --unit=rmweb-test --quiet /home/root/rmweb/rmweb https://en.wikipedia.org'
ssh root@10.11.99.1 'tail -n 40 /home/root/rmweb/rmweb.log'
```

`scripts/bundle.sh` (dev bundle straight to the device) and `scripts/run-wpeqt-on-device.sh` (dev
runner with diag env forwarding) are upstream's inner loop. `RMWEB_GRAB_MS=<ms>` saves
`/home/root/rmweb/grab.png` (what Qt presented), which is how you *see* a result without looking
at the panel.

**Always verify on the real device.** Host tests cover only the pure-logic headers.

## Non-negotiable gotchas (condensed; details in `docs/upstream-agent-notes.md`)

- **Never overlap e-ink presents.** The vendor present holds the framebuffer mutex. `WpeView`'s
  gate (`m_inFlight` + `releaseGate()` + dwell) is load-bearing. Overlaps deadlock or SIGSEGV
  inside libqsgepaper.
- **`EPFramebuffer::swapBuffers` ABI differs by OS:** 3.28 exports `(QRect, EPScreenMode, QFlags)`
  ("abi=new"); 3.27 exports a 4-arg legacy form and **hangs every time** on our presents. Minimum
  supported OS is 3.28.
- **GUI watchdog:** 12 s without a GUI heartbeat → `_Exit(63)`, and the launcher restores xochitl.
  Never block the GUI thread for long.
- **Touch is raw evdev** (`Elan touch input`, EVIOCGRAB'd; the QPA's own touch path crashes
  WebKit). Coordinates are mapped by hand in `TouchReader`. There's a phantom-touch guard around
  presents.
- **xochitl restart limit:** `StartLimitBurst=4` per 10 min + `OnFailure=emergency.target`, so
  rapid stop/start cycles reboot the tablet. Space out test launches and use
  `systemctl reset-failed xochitl`.
- **Never stop xochitl while it's still starting.** Verified 2026-10-13: launching rmweb 13 s after
  xochitl (re)started made xochitl SEGV on stop, and `OnFailure` triggered an emergency reboot.
  Before each test launch, poll until `systemctl is-active xochitl` and the xochitl process is
  ≥ 15 s old (`/proc/<pid>/stat` field 22 vs `/proc/uptime`). Don't use a fixed sleep.
- **Frame dup test = exact row diff** (fixed 2026-10-13, fork.4). Upstream decided "new frame?"
  from a sparse fingerprint (1 pixel per 40×40 cell), which dropped small changes. Settings-page
  toggles flipped the value but never redrew it: the reloaded page hashed identical. The engine
  now uses `bufferDiffBBox`; changes confined to the right 16 px scrollbar gutter are ignored,
  because WebKit's scrollbar fade ticks every ~110 ms for ~2.5 s after each load. The sig stays
  for logging and blank-page detection only.
- **Page loads: chrome-only presents are regional; settle develop also runs in B&W mode**
  (fork.6, user-confirmed improvement 2026-10-13).
  - Before, a load cost ~5 full-panel updates: 2 content frames + ~3 full repaints for
    badge/address/reader-icon changes. Chrome-only changes now present just their zones.
  - Pages that shift after first paint (late JS layout changes) re-push every text pixel with
    the fast waveform, which underdraws black, so the final render looked paler than the first.
    The settle flash (one full develop once quiet) now also fixes this in B&W mode.
- **"Web fonts" setting** (`webFonts=`, default on) is a separate content filter
  (`kNoFontsRules`) that blocks all font loads. It made no difference on the page that motivated
  it; its benefit is unproven.
- **`RMWEB_DUMP_FRAMES`** now saves each delivered full frame (it used to save the lagging canvas,
  so the first frames were missing). Compare frames with Pillow in a venv; the tablet has no
  `timeout` command.
- **A grab can come out partly black** mid-refresh (seen in landscape). Retake it later before
  calling it a bug.
- **Debug env survives a relaunch.** After an exit-75 orientation restart, the relaunched app
  inherits `RMWEB_DEBUG_UITAP*`/`RMWEB_GRAB_MS` and replays them in the new orientation. Never leave xochitl stopped: wrap test scripts in
  `trap "systemctl start xochitl" EXIT HUP INT TERM`.
- **Never `kill -9` the launcher** (`/home/root/rmweb/rmweb`). Its trap is what restores xochitl.
- **JIT is broken** on this toolchain; the JS interpreter is the default. Heavy SPAs are out of
  scope.
- **`qEnvironmentVariableIntValue` returns 0 when unset.** Check `qEnvironmentVariableIsSet` first.
- **Don't pass JS containing `%` through `g_strdup_printf`** (double it as `%%`).
- **Restart xochitl only via `/home/root/xovi/start`.** A bare `systemctl restart xochitl` drops
  xovi's tmpfs drop-in.

## Roadmap (fork)

1. ✅ **Landscape mode** (0.9.7-fork.1, device-verified 2026-10-13 on OS 3.28.0.172).
   - Settings → Display → Screen orientation cycles portrait → landscape (90) → landscape flipped
     (270). It's persisted as `rotate=` in `settings.txt`; `RMWEB_ROTATE=0|90|270` overrides it
     per run.
   - Orientation is fixed per process. `kPanelW/H` becomes the logical 2160×1620 frame, so the
     engine viewport (1080×810 CSS), chrome, keyboard and hit-tests need no orientation-specific
     code.
   - Only three things rotate: `WpeView::paint` (painter transform for chrome; the page image is
     pre-rotated with `QImage::transformed`, Qt's exact 90° path), damage rects
     (`logicalRectToPhys` before `update()` / `presentFast`), and `TouchReader` (physical → logical
     at `SYN_REPORT`). Full-panel swaps use `kPhysW/H`. The maths lives in `rotate.h`
     (`tests/rotate_test.cpp`).
   - Changing orientation exits with code 75 (`kExitRestart`) after a drain and flush.
     `device/rmweb` relaunches without restoring xochitl (bounded to 5; `tests/launcher_test.sh`
     cases 11–12).
   - Not yet verified: a real finger on the rotated glass. Synthetic taps go through the router
     *after* the mapping, so `physToLogical` on device is covered only by the unit test.
2. ✅ **Auto-rotation** (0.9.7-fork.3, device-verified 2026-10-13: user-held rotations
   90→270→0→90, each resumed the same page).
   - Setting `rotate=-1` (auto) is the default; the cycle is auto → portrait → landscape →
     flipped.
   - Sensor: lis2dw12 via IIO sysfs (`in_accel_{x,y,z}_raw` + `in_accel_mount_matrix` → device
     frame); `rmweb::classifyOrientation` has a 30° flat cut-off, no 180° mode, and a diagonal dead
     band as hysteresis.
   - **sysfs reads block**: one one-shot measurement per read, about 670 ms/axis at the stock
     12 Hz. So the app sets 50 Hz, and `device/rmweb` restores the original rate on exit. Polling
     runs on a detached thread every 400 ms; the GUI rotates after 3 equal decisions in a row, and
     never while editing.
   - Rotation = exit 75 + relaunch. `resume.txt` (one-shot, <120 s old, http(s) only) reopens the
     page, and per-URL scroll restore does the rest. `orientation.txt` holds the last orientation
     (used when the tablet is flat at startup). xochitl's `OrientationLocked=true` disables auto.
   - The launcher allows unlimited rotations; only runs shorter than `RMWEB_RELAUNCH_MIN_S` (10 s)
     count, and it gives up after 3 in a row.
   - A first attempt read the sensor on the GUI thread and produced phantom rotations from a
     stationary tablet, with no recorded vector. The thread + 50 Hz path hasn't reproduced them.
     `[rotate] sensor (x, y, z) -> o` lines log every decision change.
   - Next: rotate live without restarting (resize the viewport, rebuild keyboard/zones).
3. Merge upstream releases: `git fetch upstream && git merge upstream/master`.

## Working agreement

- Respond in English.
- Keep a rollback: the last known-good tarball goes back on with `setup-device.sh rmweb`.
- When you learn a new device fact, add it to `docs/upstream-agent-notes.md` (dated) or to this
  file's gotchas, and update `docs/paper-pro-setup.md` if it changes install or recovery.
