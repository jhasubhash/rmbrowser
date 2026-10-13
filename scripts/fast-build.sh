#!/usr/bin/env bash
# fast-build.sh — rebuild ONLY the app (engine/wpeqt -> rmweb-wpeqt) in minutes, reusing the prebuilt
# WPE WebKit / Mesa / soup runtime from an upstream release tarball instead of the multi-hour engine
# build (scripts/build-wpe.sh). Valid while engine/wpeqt keeps targeting WPE WebKit 2.48.x — the
# engine itself is NOT rebuilt, so engine changes still need the full build.
#
#   ./scripts/fast-build.sh sdk       # once: fetch release + WPE 2.48.5 source, generate headers (build/appsdk)
#   ./scripts/fast-build.sh app       # compile build/rmweb-wpeqt in the rmweb-sdk container
#   ./scripts/fast-build.sh package   # dist/rmweb-<VERSION>.tar.gz = release runtime + our app + device/ files
#   ./scripts/fast-build.sh all       # sdk (if missing) + app + package
#
# Then install:  RMWEB_TARBALL=dist/rmweb-<VERSION>.tar.gz ./scripts/setup-device.sh rmweb
# Prereqs: Docker (linux/arm64) and the rmweb-sdk image (toolchain/README.md).
set -euo pipefail
cd "$(dirname "$0")/.."

BASE_VER="${BASE_VER:-0.9.7}"     # upstream release whose runtime libs we reuse
BASE_SHA256="${BASE_SHA256:-}"    # optional pin for the release tarball
WPE_VER=2.48.5
WPE_SHA256=01f36010705adb14404c56baf033147f7927cc7c6badec81bb141266fcdd8d0b   # = scripts/build-wpe.sh
REL=build/release/rmweb-$BASE_VER

sdk() {
  mkdir -p build/src build/release
  if [ ! -d "$REL/lib" ]; then
    local tb="build/release/rmweb-$BASE_VER.tar.gz"
    [ -f "$tb" ] || curl -fL -o "$tb" "https://github.com/exp78/rmweb/releases/download/v$BASE_VER/rmweb-$BASE_VER.tar.gz"
    [ -z "$BASE_SHA256" ] || echo "$BASE_SHA256  $tb" | shasum -a 256 -c -
    mkdir -p "$REL" && tar -xzf "$tb" -C "$REL"
  fi
  local src="build/src/wpewebkit-$WPE_VER.tar.xz"
  [ -f "$src" ] || curl -fL -o "$src" "https://wpewebkit.org/releases/wpewebkit-$WPE_VER.tar.xz"
  echo "$WPE_SHA256  $src" | shasum -a 256 -c -
  rm -rf build/src/wpesrc && mkdir -p build/src/wpesrc
  tar -xJf "$src" -C build/src/wpesrc --strip-components=1 \
      "wpewebkit-$WPE_VER/Source/WebKit/UIProcess/API" "wpewebkit-$WPE_VER/Source/WebKit/WPEPlatform" \
      "wpewebkit-$WPE_VER/Source/WebKit/Scripts/glib" "wpewebkit-$WPE_VER/Source/WebKit/PlatformWPE.cmake" \
      "wpewebkit-$WPE_VER/Source/JavaScriptCore/API/glib" "wpewebkit-$WPE_VER/Source/JavaScriptCore/GLib.cmake"
  docker run --rm --platform linux/arm64 -v "$PWD":/work debian:trixie bash /work/engine/gen-app-sdk.incontainer.sh
}

app() {
  [ -d build/appsdk/usr/include ] || { echo "[fast] no build/appsdk — run: $0 sdk" >&2; exit 1; }
  docker run --rm -v "$PWD":/work -w /work -e REL="/work/$REL" rmweb-sdk bash -lc '
    set -e
    . /opt/rmpp-sdk/environment-setup-cortexa53-crypto-remarkable-linux
    SR=$SDKTARGETSYSROOT
    cp -a /work/build/appsdk/usr/. "$SR/usr/"
    # Link against the release runtime: the libs we have headers for go into the sysroot (never
    # clobbering an SDK lib); the whole bundle lib/ is the rpath-link for their transitive deps.
    for l in libWPEWebKit-2.0 libWPEPlatform-2.0 libsoup-3.0 libwpe-1.0; do cp -an "$REL/lib/$l".so* "$SR/usr/lib/"; done
    rm -rf /work/build/wpeqt
    cmake -S /work/engine/wpeqt -B /work/build/wpeqt -G Ninja -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath-link,$REL/lib"
    cmake --build /work/build/wpeqt -j"$(nproc)"
    cp -f /work/build/wpeqt/rmweb-wpeqt /work/build/rmweb-wpeqt
    ls -l /work/build/rmweb-wpeqt'
}

package() {
  [ -f build/rmweb-wpeqt ] || { echo "[fast] build/rmweb-wpeqt missing — run: $0 app" >&2; exit 1; }
  local ver; ver="$(cat VERSION)"
  local b=build/fastbundle
  rm -rf "$b" && cp -a "$REL" "$b"
  cp -f build/rmweb-wpeqt "$b/bin/rmweb-wpeqt"
  # Device-side files come from THIS tree (launcher/env/installer/icon), like scripts/bundle.sh.
  cp -f device/rmweb device/rmweb-env.sh device/install.sh device/appload-entry.sh "$b/"
  mkdir -p "$b/appload/rmweb" && cp -f device/appload/rmweb/* "$b/appload/rmweb/"
  mkdir -p "$b/share/reader" && cp -f engine/wpeqt/reader/Readability.js engine/wpeqt/reader/Readability-readerable.js "$b/share/reader/"
  cp -f device/icon.svg "$b/"
  chmod +x "$b/rmweb" "$b/install.sh" "$b/appload-entry.sh" "$b/bin/rmweb-wpeqt"
  echo "$ver" > "$b/VERSION"
  mkdir -p dist
  find "$b" -name "._*" -delete            # macOS AppleDouble litter (upstream 0.9.7 shipped one)
  COPYFILE_DISABLE=1 tar -czf "dist/rmweb-$ver.tar.gz" -C "$b" .
  echo "[fast] dist/rmweb-$ver.tar.gz ($(du -h "dist/rmweb-$ver.tar.gz" | cut -f1)) — install: RMWEB_TARBALL=dist/rmweb-$ver.tar.gz ./scripts/setup-device.sh rmweb"
}

case "${1:-}" in
  sdk) sdk ;;
  app) app ;;
  package) package ;;
  all) [ -d build/appsdk/usr/include ] || sdk; app; package ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
