#!/system/bin/sh
MODDIR=${0%/*}

# ── defaults (override in $MODDIR/config) ──────────────────────────────────
ENABLE_LOG=""
ADB_PORT=""
STATUS_CHK_FREQUENCY=""

# ── constants ───────────────────────────────────────────────────────────────
DEFAULT_ADB_PORT="5555"
DEFAULT_STATUS_CHK_FREQUENCY="3"
ADB_PORT_PATTERN='^([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$'
STATUS_CHK_FREQUENCY_PATTERN='^([1-9]|10)$'

# ── helpers ──────────────────────────────────────────────────────────────────
print_log() {
    [ "$ENABLE_LOG" != "1" ] && return
    echo "$(date '+[%Y-%m-%d %I:%M:%S]') $1" >> /data/local/tmp/wifiadb.log
}

# Enable TCP ADB + wireless-debugging settings so they survive reboots.
start_adb() {
    # Persist TCP port across reboots
    setprop persist.adb.tcp.port "$ADB_PORT"
    setprop service.adb.tcp.port "$ADB_PORT"

    # Keep the "Wireless debugging" Developer-Options toggle ON in settings DB
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

# Returns 0 if ADB needs (re)starting, 1 if everything is fine.
check_adb_status() {
    # adbd must be running
    [ "$(getprop init.svc.adbd)" = "running" ] || return 0

    # Either classic TCP port is set OR TLS wireless-debug server is active
    local tcp
    tcp="$(getprop service.adb.tcp.port)"
    local tls
    tls="$(getprop persist.adb.tls_server.enable)"

    [ "$tcp" = "$ADB_PORT" ] && return 1   # classic TCP — OK
    [ "$tls" = "1" ]         && return 1   # TLS wireless debugging — OK

    return 0  # neither active → needs start
}

maintain_adb_availability() {
    while true; do
        if [ -e "${MODDIR}/disable" ]; then
            check_adb_status
            if [ $? -eq 1 ]; then
                print_log "Module disabled — stopping ADB"
                stop_adb
            fi
        else
            check_adb_status
            if [ $? -eq 0 ]; then
                print_log "ADB not ready — starting"
                start_adb
            fi
        fi
        sleep $STATUS_CHK_FREQUENCY
    done
}

load_config() {
    local cfg="${MODDIR}/config"
    [ -f "$cfg" ] && . "$cfg" && print_log "Config loaded"
}

parse_config() {
    echo "$ADB_PORT" | grep -Eq "$ADB_PORT_PATTERN" || {
        print_log "ADB_PORT invalid — using default"
        ADB_PORT=$DEFAULT_ADB_PORT
    }
    print_log "ADB_PORT=$ADB_PORT"

    echo "$STATUS_CHK_FREQUENCY" | grep -Eq "$STATUS_CHK_FREQUENCY_PATTERN" || {
        print_log "STATUS_CHK_FREQUENCY invalid — using default"
        STATUS_CHK_FREQUENCY=$DEFAULT_STATUS_CHK_FREQUENCY
    }
    print_log "STATUS_CHK_FREQUENCY=$STATUS_CHK_FREQUENCY"
}

# ── main (late_start service) ─────────────────────────────────────────────
(
    until [ "$(getprop sys.boot_completed)" = "1" ]; do
        sleep 1
    done

    load_config
    parse_config

    print_log "---- magisk-wifiadb started ----"

    # Immediately apply settings without waiting for first check cycle
    if [ ! -e "${MODDIR}/disable" ]; then
        settings put global adb_wifi_enabled 1
        setprop persist.adb.tcp.port "$ADB_PORT"
        print_log "Boot-time: adb_wifi_enabled=1 persist.adb.tcp.port=$ADB_PORT"
    fi

    maintain_adb_availability
) &
