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

Requires Docker with linux/arm64 (Apple Silicon is native). See `toolchain/README.md`.

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
- **Faster path, not yet implemented:** WPE stays 2.48.5 and the runtime `.so` files ship in the
  release tarball, so we could seed a stage dir from the release `lib/` plus WPE 2.48.5 headers and
  rebuild only `rmweb-wpeqt`. If you build this, document it here.
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
  `systemctl reset-failed xochitl`. Never leave xochitl stopped: wrap test scripts in
  `trap "systemctl start xochitl" EXIT HUP INT TERM`.
- **Never `kill -9` the launcher** (`/home/root/rmweb/rmweb`). Its trap is what restores xochitl.
- **JIT is broken** on this toolchain; the JS interpreter is the default. Heavy SPAs are out of
  scope.
- **`qEnvironmentVariableIntValue` returns 0 when unset.** Check `qEnvironmentVariableIsSet` first.
- **Don't pass JS containing `%` through `g_strdup_printf`** (double it as `%%`).
- **Restart xochitl only via `/home/root/xovi/start`.** A bare `systemctl restart xochitl` drops
  xovi's tmpfs drop-in.

## Roadmap (fork)

1. **Landscape mode** (next). Today everything assumes portrait: the web viewport is the panel size
   from `primaryScreen()->size()` (1620×2160, logical 810×1080 at DPR 2); `TouchReader` maps raw →
   panel without rotation; chrome zones (`barZone`/`kbZone`/…) and `keyboard.h` are portrait
   layouts. Plan: a rotation setting (0/90/270, later following the orientation sensor). Size the
   WPE view to the rotated logical size, rotate the frame in `WpeView::paint` (or the canvas)
   before present, rotate touch coordinates in `TouchReader`, and reflow the chrome and keyboard
   for the wide aspect. Keep present-gate semantics unchanged, and verify with `RMWEB_GRAB_MS`
   grabs plus real taps.
2. The fast app-only build path described under Build.
3. Merge upstream releases: `git fetch upstream && git merge upstream/master`.

## Working agreement

- Respond in English.
- Keep a rollback: the last known-good tarball goes back on with `setup-device.sh rmweb`.
- When you learn a new device fact, add it to `docs/upstream-agent-notes.md` (dated) or to this
  file's gotchas, and update `docs/paper-pro-setup.md` if it changes install or recovery.
