#!/system/bin/sh
MODDIR=${0%/*}

# ── defaults (override in $MODDIR/config) ──────────────────────────────────
ENABLE_LOG=""
ADB_PORT=""
STATUS_CHK_FREQUENCY=""

# ── constants ───────────────────────────────────────────────────────────────
DEFAULT_ADB_PORT="5555"
DEFAULT_STATUS_CHK_FREQUENCY="5"
ADB_PORT_PATTERN='^([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$'
STATUS_CHK_FREQUENCY_PATTERN='^([1-9]|10)$'

# ── helpers ──────────────────────────────────────────────────────────────────
print_log() {
    [ "$ENABLE_LOG" != "1" ] && return
    echo "$(date '+[%Y-%m-%d %I:%M:%S]') $1" >> /data/local/tmp/wifiadb.log
}

# Enable TCP ADB + wireless-debugging settings so they survive reboots, then
# restart adbd so it re-reads the port and actually opens the TCP socket.
start_adb() {
    print_log "start_adb: setting tcp port $ADB_PORT + restarting adbd"
    setprop persist.adb.tcp.port "$ADB_PORT"
    setprop service.adb.tcp.port "$ADB_PORT"
    settings put global adb_wifi_enabled 1
    stop adbd
    start adbd
}

stop_adb() {
    setprop persist.adb.tcp.port ""
    setprop service.adb.tcp.port ""
    settings put global adb_wifi_enabled 0
    stop adbd
    start adbd
}

# True if adbd is actually LISTENING on TCP port $1. Reads /proc/net (IPv4+IPv6)
# directly — no dependency on ss/netstat, which may be absent on Android. Port is
# matched in hex; state 0A = TCP_LISTEN.
is_listening() {
    local p
    p=$(printf ':%04X' "$1")
    awk -v p="$p" '$2 ~ p"$" && $4 == "0A" { found=1 } END { exit !found }' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# Returns 0 if ADB needs (re)starting, 1 if everything is fine.
# Judge by whether adbd is REALLY listening on the TCP port, not by whether
# persist.adb.tcp.port is set: a set persist prop only takes effect on adbd's
# NEXT start, so "prop set" != "listening". On a USB boot adbd starts before
# service.sh sets the prop and never re-reads it — persist reads 5555 while the
# socket stays closed. Checking the real socket makes start_adb restart adbd
# once; then it listens and the check stays quiet (no restart spam).
check_adb_status() {
    [ "$(getprop init.svc.adbd)" = "running" ] || { print_log "adbd not running — restarting"; return 0; }
    is_listening "$ADB_PORT" && return 1
    print_log "tcp port $ADB_PORT not open (adbd up, not listening) — restarting adbd"
    return 0
}

maintain_adb_availability() {
    # Restart adbd AT MOST ONCE per boot. Without this latch a slow/failed bind
    # (or a flaky is_listening check) would make the monitor stop/start adbd on
    # every cycle — the same restart storm as the old 1s-restart bug, just at the
    # check interval. After the single restart we only observe; if it still isn't
    # listening we log and leave it (recovery is a reboot, not a restart loop).
    restart_done=0
    while true; do
        # pause while disabled, and stop touching props once the module is gone
        # (uninstall.sh cleared them — a live monitor must not reapply them).
        if [ ! -d "$MODDIR" ]; then
            return
        fi
        if [ -e "${MODDIR}/disable" ]; then
            sleep "$STATUS_CHK_FREQUENCY"
            continue
        fi
        # check_adb_status returns 0 when adbd needs (re)starting, 1 when fine.
        if check_adb_status; then
            if [ "$restart_done" = 0 ]; then
                restart_done=1
                start_adb
                # poll for readiness, but never issue a second restart this boot
                i=0
                while [ "$i" -lt 30 ]; do
                    if is_listening "$ADB_PORT"; then
                        print_log "adbd now listening on tcp $ADB_PORT — ok"
                        break
                    fi
                    sleep 1
                    i=$((i + 1))
                done
                is_listening "$ADB_PORT" || \
                    print_log "adbd still not listening after one restart — leaving it (reboot to retry)"
            else
                print_log "tcp port $ADB_PORT still not open, but adbd already restarted this boot — not restarting again"
            fi
        fi
        sleep "$STATUS_CHK_FREQUENCY"
    done
}

load_config() {
    local cfg="${MODDIR}/config"
    [ -f "$cfg" ] && . "$cfg"
}

parse_config() {
    if [ -z "$ADB_PORT" ]; then
        ADB_PORT=$DEFAULT_ADB_PORT
    elif ! echo "$ADB_PORT" | grep -Eq "$ADB_PORT_PATTERN"; then
        print_log "ADB_PORT invalid — using default"
        ADB_PORT=$DEFAULT_ADB_PORT
    fi
    print_log "ADB_PORT=$ADB_PORT"

    if [ -z "$STATUS_CHK_FREQUENCY" ]; then
        STATUS_CHK_FREQUENCY=$DEFAULT_STATUS_CHK_FREQUENCY
    elif ! echo "$STATUS_CHK_FREQUENCY" | grep -Eq "$STATUS_CHK_FREQUENCY_PATTERN"; then
        print_log "STATUS_CHK_FREQUENCY invalid — using default"
        STATUS_CHK_FREQUENCY=$DEFAULT_STATUS_CHK_FREQUENCY
    fi
    print_log "STATUS_CHK_FREQUENCY=$STATUS_CHK_FREQUENCY"
}

# ── main (late_start service) ─────────────────────────────────────────────
(
    # single-instance guard: if a monitor from a previous launch is still alive
    # (e.g. after a module update without reboot) two loops would fight over
    # adbd. mkdir is atomic; the second instance exits.
    LOCK="${MODDIR}/.monitor.lock"
    mkdir "$LOCK" 2>/dev/null || exit 0
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT

    until [ "$(getprop sys.boot_completed)" = "1" ]; do
        sleep 1
    done

    rm -f /data/local/tmp/wifiadb.log
    load_config
    _ver=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
    print_log "---- MagiskWiFiADB ${_ver} started ----"
    parse_config

    # Enable wireless ADB — AdbService will properly init network stack and start adbd
    if [ ! -e "${MODDIR}/disable" ]; then
        setprop persist.adb.tcp.port "$ADB_PORT"
        settings put global adb_wifi_enabled 1
        print_log "Boot-time: persist.adb.tcp.port=$ADB_PORT, adb_wifi_enabled=1"
    fi
    print_log "Entering monitor loop"

    maintain_adb_availability
) &
