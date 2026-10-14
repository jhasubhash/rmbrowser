# Paper Pro setup — tested install & recovery runbook

How this fork's maintainer got rmweb running on a reMarkable Paper Pro, including the failures hit
along the way. Use it to set up another tablet or to recover after an OS update.

**Last verified:** 2026-10-13 on a Paper Pro (Ferrari), OS **3.28.0.172**, with rmweb **0.9.7**,
xovi bundle **v19-23052026** and AppLoad **v0.6.0**.

Most steps are automated by [`scripts/setup-device.sh`](../scripts/setup-device.sh). The manual
commands below show what that script runs and why.

---

## 0. Version requirements (read first)

| Component | Requirement | What happens if it's wrong |
|---|---|---|
| reMarkable OS | **≥ 3.28** | On 3.27.x rmweb draws one frame, then the GUI thread deadlocks in the vendor e-ink present (`abi=legacy` in the log). After 12 s the watchdog exits with `rc=63` and the lock screen comes back. Nothing in the launch environment fixes it; update the OS. |
| AppLoad | **≥ v0.6.0** on OS 3.28+ | v0.5.3 crash-loops xochitl on 3.28 ("Couldn't resolve the hashed identifier … AppLoad hooks"). xochitl has `StartLimitBurst=4` + `OnFailure=emergency.target`, so a crash loop ends in an emergency reboot. |
| remagic one-line installer | **Don't re-run it** on 3.28+ | It pins AppLoad v0.5.3 (see above). Use `setup-device.sh` instead. |
| Qt resource hashtable | Rebuild after **every** OS update | AppLoad can't hook the new xochitl build. |

Before updating the OS in future, check that the new version is supported by the
[rm-appload releases/commits](https://github.com/asivery/rm-appload/commits) and by rmweb.

## 1. Developer mode + SSH key (on the tablet, once)

1. Sync your notebooks to the cloud. **Enabling developer mode factory-resets the tablet.**
2. Go to Settings → General → Software → Advanced → Developer mode.
3. Plug in USB. The tablet is `10.11.99.1` and your host gets `10.11.99.x`.
4. Find the SSH password under Settings → General → About → *Copyrights and licenses* (bottom of
   *General information*). It's a random string of about 10 characters. **It is not your 6-digit
   lock-screen passcode.**
5. Install your key: `ssh-copy-id root@10.11.99.1`. Everything after this uses key auth.

## 2. Install everything

```sh
./scripts/setup-device.sh check   # read-only state dump
./scripts/setup-device.sh all     # rmweb + xovi + AppLoad + tripletap
```

What `all` does, in order:

1. **rmweb**: downloads the release tarball (~107 MB), or uses a local build via
   `RMWEB_TARBALL=dist/rmweb-x.y.z.tar.gz`. It extracts to `/home/root/rmweb` and runs `install.sh`.
   The browser profile lives in `/home/root/.rmweb` and survives reinstalls.
2. **xovi + AppLoad**: extracts the xovi bundle into `/home/root/xovi`, enables the message broker,
   copies `appload.so` into `extensions.d/` and the `shims/` folder into `exthome/appload/`.
3. **Hashtable rebuild**: runs `echo | /home/root/xovi/rebuild_hashtable`. The screen goes blank for
   about a minute, and **xochitl is left stopped** afterwards.
4. **Start xovi**: `systemd-run … /home/root/xovi/start`. The script checks that xochitl is active,
   has `NRestarts=0` and has `LD_PRELOAD=/home/root/xovi/xovi.so`. It then re-runs rmweb's
   `install.sh`, which registers the icon in `exthome/appload/rmweb/`; this only works once
   `/home/root/xovi` exists.
5. **tripletap**: installs the power-button triple-press toggle, then **repairs SSH**. Its
   `enable.sh` runs `umount -R /etc`, which also unmounts the dropbear host key, so new SSH logins
   fail until a reboot. The script remounts the `/etc` overlay, rebinds `/etc/dropbear` and
   verifies with a fresh connection.

## 3. Using it (no computer needed)

- Connect to Wi-Fi in the normal reMarkable settings.
- Open AppLoad from the sidebar, then tap **rmweb**. The browser stops xochitl and takes the panel.
- Tap **⏻** twice to quit. xochitl comes back with xovi.
- **Rotation** (this fork): by default the browser follows the tablet. Turn it, hold still for
  about a second, and it restarts into the new orientation on the same page. It doesn't rotate
  while you type, lie it flat, or hold it upside-down, or if rotation is locked in the
  reMarkable's quick settings. Start page → Open settings → Display → *Screen orientation* cycles
  auto → portrait → landscape (right edge on top) → landscape flipped (left edge on top) to pin
  one instead.
- **While the browser is open** the power button sleeps and wakes it, so triple-press does nothing
  there. Quit the browser (⏻ in its toolbar) first.
- **After a reboot** xovi is off (it's tethered by design). Triple-press the power button to bring
  AppLoad back.

## 4. After a reMarkable OS update

An OTA swaps the A/B rootfs. `/home` survives (rmweb, xovi, AppLoad, the tripletap files), but `/etc`
and `/usr` are replaced, so the tripletap systemd unit is gone. xovi won't start by itself, which
makes the update safe.

1. Check that AppLoad supports the new OS (see §0). If not, upgrade it first:
   `APPLOAD_TAG=vX.Y.Z ./scripts/setup-device.sh xovi`.
2. Run `./scripts/setup-device.sh post-ota`. It rebuilds the hashtable, starts xovi, re-registers
   the icon, re-enables tripletap and repairs SSH.
3. Smoke-test the browser over SSH before relying on it (§5).

## 5. Debugging

```sh
# launch over SSH (detached so an ssh drop can't strand xochitl), then read the log
ssh root@10.11.99.1 'systemd-run --unit=rmweb-test --quiet /home/root/rmweb/rmweb https://en.wikipedia.org'
ssh root@10.11.99.1 'tail -n 40 /home/root/rmweb/rmweb.log'
```

Useful launch env (pass with `systemd-run --setenv=K=V`):
`QT_LOGGING_RULES=rmweb.engine.debug=true` (verbose engine log), `RMWEB_SETTLE_FULL_MS=0`,
`RMWEB_PRESENT_DWELL=<ms>`, `RMWEB_BW_HOOK=0`, `RMWEB_PANEL=WxH`. The full list is in
`docs/upstream-agent-notes.md`.

| Symptom | Cause / fix |
|---|---|
| Screen blanks and you're back at the lock screen; log ends `[watchdog] GUI loop silent >12 s … rc=63` | Vendor e-ink present hang. On OS 3.27.x (`abi=legacy`) it happens every time: update to 3.28+. |
| xochitl keeps restarting after `xovi/start` | AppLoad doesn't match the OS, or the hashtable is stale. `ssh root@10.11.99.1 /home/root/xovi/stock`, then fix AppLoad and rebuild the hashtable. |
| New SSH logins reset at key exchange | tripletap's `enable.sh` took the host key mount down. Reboot the tablet, or run the repair block in `setup-device.sh`. |
| Tablet emergency-reboots during testing | Either too many xochitl stop/starts in 10 min (`StartLimitBurst=4`), or rmweb stopped xochitl while it was still starting (it SEGVs, then `OnFailure` reboots). Before each launch, wait until xochitl has been active for ≥ 15 s; `systemctl reset-failed xochitl`. |
| AppLoad icon gone after a reboot | xovi is tethered: triple-press power (or `ssh root@10.11.99.1 /home/root/xovi/start`). |
| `head: invalid option -- '2'` | The device shell is BusyBox: use `head -n N`. |

## 6. Uninstall

```sh
ssh root@10.11.99.1 '/home/root/xovi/stock; systemctl disable --now xovi-tripletap;
  rm -rf /home/root/rmweb /home/root/.rmweb /home/root/xovi /home/root/xovi-tripletap'
```

A factory reset or turning off developer mode also removes everything.
