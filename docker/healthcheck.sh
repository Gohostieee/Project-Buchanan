#!/bin/sh
set -eu
cd "${SERVER_ROOT:-/opt/reno}"
nc -z 127.0.0.1 "${PORT:-54321}"
startup_log_directory=$(cat .startup-log-directory)
runtime_log="data/logs/$startup_log_directory/runtime.log"
# Read only this process's startup log, never a previous round's saved log.
grep -qF 'Initializations complete within ' "$runtime_log"
if grep -qE 'RED ALERT!.*map files failed to load|ERROR: Station areas list failed' "$runtime_log"; then
    exit 1
fi
