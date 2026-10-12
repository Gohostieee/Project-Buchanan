#!/bin/sh
set -eu

umask 0027

SERVER_ROOT="${SERVER_ROOT:-/opt/reno}"
DMB="${DMB:-fortune13.dmb}"
PORT="${PORT:-54321}"
BYOND_TRUSTED="${BYOND_TRUSTED:-1}"
BYOND_PARAMS="${BYOND_PARAMS:-}"

case "$PORT" in
    ''|*[!0-9]*)
        echo "PORT must be a number between 1 and 65535; got: $PORT" >&2
        exit 64
        ;;
esac

if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "PORT must be between 1 and 65535; got: $PORT" >&2
    exit 64
fi

cd "$SERVER_ROOT"
mkdir -p config data

if [ ! -f "$DMB" ]; then
    echo "Compiled game file not found: $SERVER_ROOT/$DMB" >&2
    exit 66
fi

if [ ! -f config/config.txt ]; then
    echo "WARNING: config/config.txt is not mounted. The server may start with incomplete defaults." >&2
fi

# Supplying a normal command replaces DreamDaemon, which is useful for debugging.
if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
    exec "$@"
fi

# BYOND 516.1688 on Linux cannot read files from a read-only filesystem even
# when the Unix permissions allow it. Keep the operator's mount protected and
# give the engine a private, writable copy for this container's lifetime.
rm -rf runtime-config
mkdir -m 0750 runtime-config
cp -R config/. runtime-config/
chmod -R u+rwX runtime-config
startup_log_directory="container-$(date -u +%Y%m%dT%H%M%S%N)"
printf '%s\n' "$startup_log_directory" > .startup-log-directory
BYOND_PARAMS="${BYOND_PARAMS:+${BYOND_PARAMS}&}config-directory=runtime-config&log-directory=$startup_log_directory"

case "$BYOND_TRUSTED" in
    1|true|TRUE|yes|YES)
        if [ -n "$BYOND_PARAMS" ]; then
            exec DreamDaemon "$DMB" -port "$PORT" -public -trusted -close -verbose -params "$BYOND_PARAMS" "$@"
        fi
        exec DreamDaemon "$DMB" -port "$PORT" -public -trusted -close -verbose "$@"
        ;;
    0|false|FALSE|no|NO)
        if [ -n "$BYOND_PARAMS" ]; then
            exec DreamDaemon "$DMB" -port "$PORT" -public -close -verbose -params "$BYOND_PARAMS" "$@"
        fi
        exec DreamDaemon "$DMB" -port "$PORT" -public -close -verbose "$@"
        ;;
    *)
        echo "BYOND_TRUSTED must be 1/0, true/false, or yes/no; got: $BYOND_TRUSTED" >&2
        exit 64
        ;;
esac
