# MagiskWiFiADB

Magisk module that automatically enables WiFi ADB on boot. Fork of [mrh929/magisk-wifiadb](https://github.com/mrh929/magisk-wifiadb) with Android 14+ fixes.

## What it does

- Sets `persist.adb.tcp.port` and `adb_wifi_enabled` at boot — ADB starts over WiFi automatically
- Monitors `adbd` and restarts it if it goes down
- No fingerprint prompt on reconnect (single adbd start, no restart loop)
- Disabling via Magisk Manager does not interfere with USB ADB

## Install

Download `magisk-wifiadb-x.x.x.zip` from [Releases](https://github.com/alt-fox/magisk-wifiadb/releases) and flash via Magisk Manager.

Or via CLI:
```
adb push magisk-wifiadb-1.2.1.zip /data/local/tmp/
adb shell su -c "magisk --install-module /data/local/tmp/magisk-wifiadb-1.2.1.zip"
```
Reboot to activate.

## Configuration

Edit `/data/adb/modules/magisk-wifiadb/config`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ADB_PORT` | 5555 | TCP port (1-65535) |
| `STATUS_CHK_FREQUENCY` | 5 | Check interval in seconds (1-10) |
| `ENABLE_LOG` | (empty) | Set to `1` to enable logging |

## Logging

When `ENABLE_LOG=1`, log is written to `/data/local/tmp/wifiadb.log`. Log is cleared on each reboot.

## Connect

```
adb connect <device-ip>:5555
```

## Changes from upstream

- `persist.adb.tcp.port` instead of `service.adb.tcp.port` — survives reboots
- `adb_wifi_enabled=1` at boot — proper AdbService network init on Android 14+
- Fixed fingerprint prompt (adbd was restarting every 1s)
- Module disable = do nothing (no `stop_adb` call)
- Default check interval 5s instead of 1s
- Config file shipped with module
- `customize.sh` with install info
- Log auto-cleanup on reboot

## Building

Reproducible and cross-platform — normalizes line endings to LF and sets the
unix exec bit, so the packaged zip is correct regardless of host OS:

```
python build.py            # produces magisk-wifiadb-<version>.zip
python build.py --push     # also push to a connected device via adb
```

## Releasing

Push a `vX.Y.Z` tag — the GitHub Actions workflow builds via `build.py`,
independently verifies the zip (no CRLF, exec bit present), and publishes it to
the release. Do not hand-pack the zip: that reintroduces CRLF and drops the exec
bit (the v1.2.0 asset bug).

## Tested on

- Pixel, Android 14, Magisk 28
