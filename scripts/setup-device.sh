#!/usr/bin/env bash
# setup-device.sh — install rmweb + the AppLoad home-screen icon on a reMarkable Paper Pro, or
# re-wire everything after an OS update. Runs on the HOST (macOS/Linux) and drives the tablet over SSH.
#
# Mirrors the exact sequence verified on a Paper Pro (Ferrari) on OS 3.28.0.172, 2026-10-13.
# See docs/paper-pro-setup.md for the why behind each step.
#
#   ./scripts/setup-device.sh all        # fresh device: rmweb + xovi + AppLoad + tripletap
#   ./scripts/setup-device.sh rmweb      # only (re)install the rmweb release tarball
#   ./scripts/setup-device.sh xovi       # only xovi + AppLoad + hashtable + start
#   ./scripts/setup-device.sh tripletap  # only the power-button triple-press toggle (+ SSH repair)
#   ./scripts/setup-device.sh post-ota   # after a reMarkable OS update: hashtable, xovi, tripletap, icon
#   ./scripts/setup-device.sh check      # print device/OS/xovi/rmweb state, change nothing
#
# Env overrides: RM_HOST (default 10.11.99.1 = USB), RMWEB_TARBALL (use a local build instead of
# downloading the release), RMWEB_VERSION, XOVI_TAG, APPLOAD_TAG.
#
# Prerequisites: developer mode ON and key-based SSH working (ssh-copy-id root@10.11.99.1 once).
set -euo pipefail

RM_HOST="${RM_HOST:-10.11.99.1}"
RMWEB_VERSION="${RMWEB_VERSION:-0.9.7}"
XOVI_TAG="${XOVI_TAG:-v19-23052026}"     # asivery/rm-xovi-extensions (loader + qt-resource-rebuilder)
APPLOAD_TAG="${APPLOAD_TAG:-v0.6.0}"      # asivery/rm-appload — >= v0.6.0 is REQUIRED on OS 3.28+
MIN_OS="3.28"                              # rmweb's e-ink present path hangs on 3.27.x (abi=legacy)

RMWEB_URL="https://github.com/exp78/rmweb/releases/download/v${RMWEB_VERSION}/rmweb-${RMWEB_VERSION}.tar.gz"
XOVI_URL="https://github.com/asivery/rm-xovi-extensions/releases/download/${XOVI_TAG}/xovi-aarch64.tar.gz"
APPLOAD_URL="https://github.com/asivery/rm-appload/releases/download/${APPLOAD_TAG}/appload-aarch64.tar.gz"
TRIPLETAP_URL="https://raw.githubusercontent.com/rmitchellscott/xovi-tripletap/main/install.sh"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes)
rm_ssh() { ssh "${SSH_OPTS[@]}" "root@$RM_HOST" "$@"; }
rm_scp() { scp -q "${SSH_OPTS[@]}" "$@"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fetch() { curl -fL --retry 3 -o "$2" "$1" || die "download failed: $1"; }

preflight() {
  say "Checking $RM_HOST"
  rm_ssh true 2>/dev/null || die "no key-based SSH to root@$RM_HOST. Enable developer mode, then: ssh-copy-id root@$RM_HOST"
  rm_ssh 'grep -qE "reMarkable (Ferrari|Chiappa|Tatsu)" /proc/device-tree/model' \
    || die "not a Paper Pro family device — refusing"
  OS="$(rm_ssh '. /etc/os-release; printf %s "$IMG_VERSION"')"
  ok "Paper Pro, OS $OS"
  if [ "$(printf '%s\n%s\n' "$MIN_OS" "$OS" | sort -V | head -n 1)" != "$MIN_OS" ]; then
    die "OS $OS < $MIN_OS: rmweb freezes on the 2nd frame there. Update the tablet first (Settings → General → Software)."
  fi
}

install_rmweb() {
  say "Installing rmweb ${RMWEB_TARBALL:-release v$RMWEB_VERSION}"
  local tb="${RMWEB_TARBALL:-}"
  if [ -z "$tb" ]; then tb="$WORK/rmweb.tar.gz"; fetch "$RMWEB_URL" "$tb"; fi
  rm_ssh 'pidof rmweb-wpeqt >/dev/null && { echo "quit rmweb on the tablet first (⏻)" >&2; exit 1; }; true' \
    || die "rmweb is running"
  rm_scp "$tb" "root@$RM_HOST:/home/root/rmweb.tar.gz"
  # Wipe the app dir (profile lives in /home/root/.rmweb and survives), then extract + install.
  rm_ssh 'set -e; rm -rf /home/root/rmweb; mkdir -p /home/root/rmweb
          tar -xzf /home/root/rmweb.tar.gz -C /home/root/rmweb; rm -f /home/root/rmweb.tar.gz
          sh /home/root/rmweb/install.sh'
  ok "rmweb installed (launch over SSH: /home/root/rmweb/rmweb [URL])"
}

install_xovi() {
  say "Installing xovi ($XOVI_TAG) + AppLoad ($APPLOAD_TAG)"
  fetch "$XOVI_URL" "$WORK/xovi.tar.gz"
  fetch "$APPLOAD_URL" "$WORK/appload.tar.gz"
  rm_scp "$WORK/xovi.tar.gz" "$WORK/appload.tar.gz" "root@$RM_HOST:/tmp/"
  rm_ssh 'set -e
    tar -xzf /tmp/xovi.tar.gz -C /home/root
    [ -f /home/root/xovi/inactive-extensions/xovi-message-broker.so ] && \
      mv -f /home/root/xovi/inactive-extensions/xovi-message-broker.so /home/root/xovi/extensions.d/ || true
    rm -rf /tmp/al && mkdir /tmp/al && tar -xzf /tmp/appload.tar.gz -C /tmp/al
    cp -f /tmp/al/appload.so /home/root/xovi/extensions.d/
    mkdir -p /home/root/xovi/exthome/appload && cp -rf /tmp/al/shims /home/root/xovi/exthome/appload/
    rm -rf /tmp/al /tmp/xovi.tar.gz /tmp/appload.tar.gz'
  ok "xovi + AppLoad copied"
  rebuild_and_start
}

# The QML hashtable is per-OS-build: required on first install and after EVERY OS update, otherwise
# AppLoad crash-loops xochitl. rebuild_hashtable leaves xochitl STOPPED — xovi/start brings it back.
rebuild_and_start() {
  say "Rebuilding the Qt resource hashtable (screen goes blank ~1 min)"
  rm_ssh 'pidof rmweb-wpeqt >/dev/null && { echo "quit rmweb on the tablet first (⏻)" >&2; exit 1; }; true' \
    || die "rmweb is running"
  rm_ssh 'echo | /home/root/xovi/rebuild_hashtable 2>&1 | grep -E "Hashtab saved|rebuilt" | tail -n 2'
  say "Starting xovi"
  rm_ssh 'systemctl reset-failed xochitl; systemd-run --unit=xovi-start-$$ --collect --service-type=oneshot /home/root/xovi/start' >/dev/null
  sleep 30
  local state
  state="$(rm_ssh 'systemctl is-active xochitl; systemctl show xochitl -p NRestarts --value;
                   tr "\0" "\n" < /proc/$(pidof xochitl)/environ | grep -c xovi.so || true')"
  # shellcheck disable=SC2086
  set -- $state
  [ "${1:-}" = active ] || die "xochitl not active after xovi start — run: ssh root@$RM_HOST /home/root/xovi/stock"
  [ "${2:-0}" = 0 ] || warn "xochitl restarted ${2} times — possible AppLoad/OS mismatch; check: journalctl -u xochitl"
  [ "${3:-0}" -ge 1 ] && ok "xovi loaded into xochitl" || warn "xochitl running WITHOUT xovi"
  rm_ssh '[ -x /home/root/rmweb/install.sh ] && sh /home/root/rmweb/install.sh | head -n 1; true'
}

# Power-button triple-press toggles xovi — no computer needed after a reboot. Its enable.sh does
# `umount -R /etc`, which also drops the dropbear host-key bind mount and kills NEW SSH logins until
# reboot; the repair block below (same as remagic's repair_ssh_keystore) restores it in-band.
install_tripletap() {
  say "Installing xovi-tripletap"
  rm_ssh "set -e
    if [ -x /home/root/xovi-tripletap/enable.sh ]; then bash /home/root/xovi-tripletap/enable.sh
    else wget -qO- '$TRIPLETAP_URL' | bash; fi
    if ! mountpoint -q /etc; then
      mount -t overlay overlay -o lowerdir=/etc,upperdir=/var/volatile/etc,workdir=/var/volatile/.etc-work,uuid=on /etc \
      || mount -t overlay overlay -o lowerdir=/etc,upperdir=/var/volatile/etc,workdir=/var/volatile/.etc-work /etc
    fi
    [ -e /etc/dropbear/dropbear_ed25519_host_key ] || systemctl restart etc-dropbear.mount 2>/dev/null || true
    if [ ! -e /etc/dropbear/dropbear_ed25519_host_key ] && [ -e /home/root/.dropbear/dropbear_ed25519_host_key ]; then
      mount --bind /home/root/.dropbear /etc/dropbear
    fi
    mount -o remount,ro / 2>/dev/null || true" | tail -n 2
  rm_ssh 'systemctl is-enabled xovi-tripletap' >/dev/null && ok "tripletap enabled" || warn "tripletap not enabled"
  ssh -S none -o BatchMode=yes -o ConnectTimeout=8 "root@$RM_HOST" true \
    && ok "fresh SSH login still works" || warn "new SSH logins failing — reboot the tablet once to fix"
}

check() {
  rm_ssh '. /etc/os-release; echo "OS:        $IMG_VERSION"
    echo "rmweb:     $(cat /home/root/rmweb/VERSION 2>/dev/null || echo not installed)"
    echo "xochitl:   $(systemctl is-active xochitl)"
    P=$(pidof xochitl); echo "xovi:      $( [ -n "$P" ] && tr "\0" "\n" < /proc/$P/environ | grep -q xovi.so && echo loaded || echo not loaded)"
    echo "appload:   $(ls /home/root/xovi/extensions.d/appload.so 2>/dev/null || echo missing)"
    echo "icon:      $(ls /home/root/xovi/exthome/appload/rmweb/external.manifest.json 2>/dev/null || echo missing)"
    echo "tripletap: $(systemctl is-enabled xovi-tripletap 2>/dev/null || echo missing)"'
}

case "${1:-}" in
  all)       preflight; install_rmweb; install_xovi; install_tripletap ;;
  rmweb)     preflight; install_rmweb ;;
  xovi)      preflight; install_xovi ;;
  tripletap) preflight; install_tripletap ;;
  post-ota)  preflight; rebuild_and_start; install_tripletap ;;
  check)     check ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
say "Done."
