#!/usr/bin/env bash
#
# Cloud Agent install script for the sp_GenerarScriptUsuarios repository.
#
# Provisions a local Microsoft SQL Server 2022 (Developer edition) instance and
# the sqlcmd client tools so the T-SQL stored procedure in this repo can be
# deployed and executed end to end.
#
# The script is idempotent: it can be re-run safely and converges to the same
# state without failing on already-installed packages or an existing instance.
#
set -euo pipefail

MSSQL_BIN="/opt/mssql/bin/sqlservr"
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
COMPAT_LIB_DIR="/opt/mssql-compat/lib"
SA_PASSWORD="${MSSQL_SA_PASSWORD:-Dev_Pass123!}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { echo "[install] $*"; }

# ---------------------------------------------------------------------------
# 1. Package repositories (Microsoft, Jammy channel — works on Ubuntu 24.04)
# ---------------------------------------------------------------------------
if [ ! -f /usr/share/keyrings/microsoft-prod.gpg ]; then
    log "Adding Microsoft package signing key"
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | sudo gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
fi

echo "deb [arch=amd64,armhf,arm64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/22.04/mssql-server-2022 jammy main" \
    | sudo tee /etc/apt/sources.list.d/mssql-server-2022.list >/dev/null
echo "deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/22.04/prod jammy main" \
    | sudo tee /etc/apt/sources.list.d/mssql-release.list >/dev/null

# ---------------------------------------------------------------------------
# 2. Install SQL Server engine + client tools
# ---------------------------------------------------------------------------
log "Updating apt and installing packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    mssql-server >/dev/null
sudo ACCEPT_EULA=Y DEBIAN_FRONTEND=noninteractive apt-get install -y \
    mssql-tools18 unixodbc-dev >/dev/null

# ---------------------------------------------------------------------------
# 3. Ubuntu 24.04 compatibility shim.
#    The mssql-server binary is built for Ubuntu 22.04 and links against the
#    OpenLDAP 2.5 runtime, which is not shipped on Noble (24.04 ships 2.6).
#    We extract just the two required .so files from the Jammy package and
#    register them with the dynamic loader, avoiding apt dependency conflicts.
# ---------------------------------------------------------------------------
if ldd "$MSSQL_BIN" 2>/dev/null | grep -q "not found"; then
    log "Installing OpenLDAP 2.5 compatibility libraries"
    LDAP_DEB="libldap-2.5-0_2.5.20+dfsg-0ubuntu0.22.04.1_amd64.deb"
    TMP_LDAP="$(mktemp -d)"
    curl -fsSL -o "$TMP_LDAP/$LDAP_DEB" \
        "http://archive.ubuntu.com/ubuntu/pool/main/o/openldap/$LDAP_DEB"
    dpkg-deb -x "$TMP_LDAP/$LDAP_DEB" "$TMP_LDAP/extracted"
    sudo mkdir -p "$COMPAT_LIB_DIR"
    sudo cp -a "$TMP_LDAP"/extracted/usr/lib/x86_64-linux-gnu/lib{lber,ldap}-2.5.so.0* "$COMPAT_LIB_DIR/"
    echo "$COMPAT_LIB_DIR" | sudo tee /etc/ld.so.conf.d/mssql-compat.conf >/dev/null
    sudo ldconfig
    rm -rf "$TMP_LDAP"
fi

if ldd "$MSSQL_BIN" 2>&1 | grep -q "not found"; then
    log "ERROR: sqlservr still has unresolved shared libraries:"
    ldd "$MSSQL_BIN" 2>&1 | grep "not found" || true
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Provision the instance (create system databases + set sa password).
#    Runs sqlservr once in the background; it self-provisions on first launch
#    from the ACCEPT_EULA / MSSQL_SA_PASSWORD / MSSQL_PID environment. If the
#    instance is already provisioned this is a no-op re-initialisation.
# ---------------------------------------------------------------------------
# Stop any instance already listening so provisioning owns port 1433 and we
# don't leave a duplicate process behind (makes re-runs idempotent).
for pid in $(pgrep -u mssql -x sqlservr 2>/dev/null | sort -n); do
    log "Stopping pre-existing sqlservr (pid $pid)"
    sudo kill -TERM "$pid" 2>/dev/null || true
done
for _ in $(seq 1 30); do
    pgrep -u mssql -x sqlservr >/dev/null 2>&1 || break
    sleep 1
done

if ! sudo test -f /var/opt/mssql/data/master.mdf; then
    log "Provisioning SQL Server (Developer edition)"
    sudo -u mssql bash -c "ACCEPT_EULA=Y MSSQL_SA_PASSWORD='$SA_PASSWORD' MSSQL_PID=Developer '$MSSQL_BIN' > /var/opt/mssql/log/sqlservr-provision.log 2>&1" &
    PROV_PID=$!
else
    log "Instance already provisioned; starting temporarily to deploy objects"
    sudo -u mssql bash -c "MSSQL_SA_PASSWORD='$SA_PASSWORD' '$MSSQL_BIN' > /var/opt/mssql/log/sqlservr-provision.log 2>&1" &
    PROV_PID=$!
fi

# Wait for the server to accept connections.
log "Waiting for SQL Server to become ready"
READY=0
for _ in $(seq 1 60); do
    if "$SQLCMD" -S localhost -U sa -P "$SA_PASSWORD" -C -N -l 3 \
        -Q "SELECT 1" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 2
done
if [ "$READY" -ne 1 ]; then
    log "ERROR: SQL Server did not become ready. Provision log:"
    sudo tail -n 40 /var/opt/mssql/log/sqlservr-provision.log || true
    exit 1
fi
log "SQL Server is accepting connections"

# ---------------------------------------------------------------------------
# 5. Deploy the repository stored procedure into master.
# ---------------------------------------------------------------------------
log "Deploying sp_GenerarScriptUsuarios"
"$SQLCMD" -S localhost -U sa -P "$SA_PASSWORD" -C -N -b \
    -i "$REPO_DIR/sp_GenerarScriptUsuarios.sql" >/dev/null
log "Stored procedure deployed"

# ---------------------------------------------------------------------------
# 6. Stop the temporary instance gracefully. The persistent instance is
#    launched by the start script on every boot. We signal the actual
#    sqlservr master process (not the wrapping sudo/bash) by PID.
# ---------------------------------------------------------------------------
log "Stopping temporary instance"
for pid in $(pgrep -u mssql -x sqlservr 2>/dev/null | sort -n); do
    sudo kill -TERM "$pid" 2>/dev/null || true
done
kill "$PROV_PID" 2>/dev/null || true
for _ in $(seq 1 30); do
    pgrep -u mssql -x sqlservr >/dev/null 2>&1 || break
    sleep 1
done

log "Install complete"
