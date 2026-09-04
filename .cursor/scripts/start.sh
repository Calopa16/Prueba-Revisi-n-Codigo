#!/usr/bin/env bash
#
# Cloud Agent start script.
#
# Launches the provisioned SQL Server instance in the background on every boot
# and waits until it accepts connections. Idempotent: if an instance is already
# listening it returns immediately instead of starting a duplicate.
#
set -euo pipefail

MSSQL_BIN="/opt/mssql/bin/sqlservr"
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
SA_PASSWORD="${MSSQL_SA_PASSWORD:-Dev_Pass123!}"
LOG_FILE="/var/opt/mssql/log/sqlservr-cloud-agent.log"

log() { echo "[start] $*"; }

is_up() {
    "$SQLCMD" -S localhost -U sa -P "$SA_PASSWORD" -C -N -l 3 \
        -Q "SELECT 1" >/dev/null 2>&1
}

if is_up; then
    log "SQL Server already running"
    exit 0
fi

log "Starting SQL Server"
sudo -u mssql bash -c "MSSQL_SA_PASSWORD='$SA_PASSWORD' '$MSSQL_BIN' >>'$LOG_FILE' 2>&1" &

log "Waiting for SQL Server to accept connections"
for _ in $(seq 1 60); do
    if is_up; then
        log "SQL Server is ready on localhost:1433"
        exit 0
    fi
    sleep 2
done

log "ERROR: SQL Server did not become ready in time"
sudo tail -n 40 "$LOG_FILE" 2>/dev/null || true
exit 1
