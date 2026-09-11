#!/system/bin/sh
# Magisk runs this when the module is removed. Undo the persistent props the
# module set: persist.adb.tcp.port lives in Android's persistent storage and
# survives reboots, so without this it would stay set forever after uninstall
# (adbd would keep listening on TCP with the module gone). Revert to stock =
# TCP ADB off.
MAGISK="$(command -v magisk || echo /system_ext/bin/magisk)"

"$MAGISK" resetprop -p --delete persist.adb.tcp.port 2>/dev/null
"$MAGISK" resetprop --delete service.adb.tcp.port 2>/dev/null
settings put global adb_wifi_enabled 0 2>/dev/null

# If adbd is already up (immediate uninstall via Magisk app, not a reboot),
# restart it so the live TCP socket is dropped now instead of at next boot.
[ "$(getprop init.svc.adbd)" = "running" ] && { stop adbd; start adbd; }
