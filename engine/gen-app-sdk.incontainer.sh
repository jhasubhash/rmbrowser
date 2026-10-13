#!/bin/bash
# Runs INSIDE a debian:trixie (arm64) container. Generates the PUBLIC headers + pkg-config files of
# WPE WebKit 2.48.5 (wpe-webkit-2.0 / jsc / wpe-platform-2.0 + headless) from the source tarball,
# exactly as WebKit's own CMake install rules lay them out, plus libwpe 1.16 and libsoup 3.6 headers
# from Debian. Together with the release tarball's prebuilt .so files this is enough to compile and
# link engine/wpeqt WITHOUT the multi-hour WebKit build (see scripts/fast-build.sh).
#
# Output: /work/build/appsdk/usr/{include,lib/pkgconfig}
set -euo pipefail
VER=2.48.5; MAJ=2; MIN=48; MIC=5
SRC=/work/build/src/wpesrc/Source        # extracted by scripts/fast-build.sh
OUT=/work/build/appsdk/usr
INC="$OUT/include/wpe-webkit-2.0"
rm -rf "$OUT"; mkdir -p "$INC/wpe" "$INC/jsc" "$INC/wpe-platform/wpe/headless" "$OUT/lib/pkgconfig"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq python3 unifdef libglib2.0-dev-bin >/dev/null 2>&1

GEN="$SRC/WebKit/Scripts/glib/generate-api-header.py"
# Template list = the set() block named $2 in cmake file $1, plus any ENABLE_2022_GLIB_API
# list(APPEND $2 ...) additions — the same files WebKit's GENERATE_GLIB_API_HEADERS processes.
templates() {
  awk -v name="$2" '
    !grab && ($0 ~ "set\\(" name "$" || $0 ~ "list\\(APPEND " name "$") { grab = 1; next }
    grab && /\)/ { grab = 0; next }
    grab { print }' "$1" | sed -e 's/^ *//' -e "s#\${WEBKIT_DIR}#$SRC/WebKit#" -e "s#\${JAVASCRIPTCORE_DIR}#$SRC/JavaScriptCore#"
}
gen() {   # gen <outdir> <port> <template> <unifdef -D args...>
  local out="$1" port="$2" t="$3"; shift 3
  python3 "$GEN" "$port" "$t" "$out/$(basename "${t%.in}")" "$(command -v unifdef)" "$@"
}
subst_ver() { sed -e "s/@PROJECT_VERSION_MAJOR@/$MAJ/; s/@PROJECT_VERSION_MINOR@/$MIN/; s/@PROJECT_VERSION_MICRO@/$MIC/" "$1"; }

# ---- wpe/ (WebKit UI-process API, 2022 GLib API = wpe-webkit-2.0) ----
WPE_DEFS=(-DWTF_PLATFORM_GTK=0 -DWTF_PLATFORM_WPE=1 -DUSE_GTK4=0 -DENABLE_2022_GLIB_API=1
          -DENABLE_WPE_PLATFORM=1 -DUSE_GI_FINISH_FUNC_ANNOTATION=0)
n=0
for t in $(templates "$SRC/WebKit/PlatformWPE.cmake" WPE_API_HEADER_TEMPLATES); do
  gen "$INC/wpe" WPE "$t" "${WPE_DEFS[@]}"; n=$((n+1))
done
echo "[appsdk] wpe/: $n API headers generated"
for h in WebKitColor.h WebKitRectangle.h WebKitWebViewBackend.h; do
  cp "$SRC/WebKit/UIProcess/API/wpe/$h" "$INC/wpe/"
done
subst_ver "$SRC/WebKit/UIProcess/API/wpe/WebKitVersion.h.in" > "$INC/wpe/WebKitVersion.h"
# WebKitEnumTypes.h: glib-mkenums over every installed header except itself (PlatformWPE.cmake).
( cd "$INC/wpe" && glib-mkenums --template "$SRC/WebKit/UIProcess/API/wpe/WebKitEnumTypes.h.in" \
    $(ls *.h | grep -v '^WebKitEnumTypes\.h$') | sed s/web_kit/webkit/ | sed s/WEBKIT_TYPE_KIT/WEBKIT_TYPE/ \
    > WebKitEnumTypes.h )

# ---- jsc/ (JavaScriptCore GLib API) ----
for t in $(templates "$SRC/JavaScriptCore/GLib.cmake" JavaScriptCore_HEADER_TEMPLATES); do
  gen "$INC/jsc" WPE "$t" -DENABLE_2022_GLIB_API=1
done
cp "$SRC/JavaScriptCore/API/glib/JSCOptions.h" "$INC/jsc/"
subst_ver "$SRC/JavaScriptCore/API/glib/JSCVersion.h.in" > "$INC/jsc/JSCVersion.h"

# ---- wpe-platform/wpe (+ headless) ----
P="$SRC/WebKit/WPEPlatform/wpe"
for h in WPEEvent WPEBuffer WPEBufferDMABuf WPEBufferDMABufFormats WPEBufferSHM WPEColor WPEDefines \
         WPEDisplay WPEEGLError WPEInputMethodContext WPEKeyUnicode WPEKeymap WPEKeymapXKB WPEKeysyms \
         WPEGestureController WPERectangle WPEScreen WPESettings WPEToplevel WPEView wpe-platform; do
  cp "$P/$h.h" "$INC/wpe-platform/wpe/"
done
# WPEConfig.h: #cmakedefine -> our build options (HEADLESS on, DRM/Wayland off — engine/build-wpe.incontainer.sh).
sed -e 's|#cmakedefine WPE_PLATFORM_HEADLESS|#define WPE_PLATFORM_HEADLESS|' \
    -e 's|#cmakedefine \(WPE_PLATFORM_[A-Z]*\)|/* #undef \1 */|' "$P/WPEConfig.h.in" > "$INC/wpe-platform/wpe/WPEConfig.h"
subst_ver "$P/WPEVersion.h.in" > "$INC/wpe-platform/wpe/WPEVersion.h"
( cd "$INC/wpe-platform/wpe" && glib-mkenums --template "$P/WPEEnumTypes.h.in" \
    $(ls *.h | grep -v '^WPEEnumTypes\.h$') | sed s/w_pe/wpe/ | sed s/WPE_TYPE_PE/WPE_TYPE/ \
    | sed s/WPE_TYPEEGL/WPE_TYPE_EGL/ | sed s/wpeegl/wpe_egl/ > WPEEnumTypes.h )
for h in wpe-headless WPEDisplayHeadless WPEToplevelHeadless WPEViewHeadless; do
  cp "$P/headless/$h.h" "$INC/wpe-platform/wpe/headless/"
done

# ---- libwpe 1.16 + libsoup 3.6 + xkbcommon headers (Debian trixie; ABI-matches the bundle's .so) ----
TMP=$(mktemp -d); ( cd "$TMP" && apt-get download -qq libwpe-1.0-dev libsoup-3.0-dev libxkbcommon-dev >/dev/null )
for d in "$TMP"/*.deb; do dpkg-deb -x "$d" "$TMP/x"; done
cp -a "$TMP/x/usr/include/wpe-1.0" "$TMP/x/usr/include/libsoup-3.0" "$TMP/x/usr/include/xkbcommon" "$OUT/include/"

# ---- pkg-config (prefix=/usr; the build seeds these into the SDK sysroot) ----
pc() { printf 'prefix=/usr\nexec_prefix=${prefix}\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: %s\nDescription: %s\nVersion: %s\nRequires: %s\nLibs: %s\nCflags: %s\n' "$@"; }
pc "WPE WebKit" "rmweb app SDK (headers only)" $VER "glib-2.0 gio-2.0 libsoup-3.0 wpe-1.0 wpe-platform-2.0" \
   '-L${libdir} -lWPEWebKit-2.0' '-I${includedir}/wpe-webkit-2.0' > "$OUT/lib/pkgconfig/wpe-webkit-2.0.pc"
pc "WPE Platform" "rmweb app SDK (headers only)" $VER "glib-2.0 gobject-2.0 gio-2.0" \
   '-L${libdir} -lWPEPlatform-2.0' '-I${includedir}/wpe-webkit-2.0/wpe-platform' > "$OUT/lib/pkgconfig/wpe-platform-2.0.pc"
pc "wpe" "libwpe (headers only)" 1.16.2 "" '-L${libdir} -lwpe-1.0' '-I${includedir}/wpe-1.0' > "$OUT/lib/pkgconfig/wpe-1.0.pc"
pc "libsoup" "libsoup (headers only)" 3.6.5 "glib-2.0 gobject-2.0 gio-2.0" '-L${libdir} -lsoup-3.0' \
   '-I${includedir}/libsoup-3.0' > "$OUT/lib/pkgconfig/libsoup-3.0.pc"

echo "[appsdk] done: $(find "$OUT/include" -name '*.h' | wc -l) headers in $OUT"
