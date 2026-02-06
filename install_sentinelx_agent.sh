#!/usr/bin/env bash
set -euo pipefail

AGENT_URL="https://raw.githubusercontent.com/caap1234/agent/refs/heads/main/sentinelx-agent.sh"
AGENT_BIN="/usr/local/bin/sentinelx-agent.sh"
ENV_FILE="/etc/sentinelx-agent.env"
CRON_CMD="ENV_FILE=/etc/sentinelx-agent.env /usr/local/bin/sentinelx-agent.sh >> /var/log/sentinelx-agent.log 2>&1"
CRON_EXPR="*/30 * * * *"

echo "== SentinelX Agent reinstall / reset =="

# -------------------------------------------------------------------
# 1) Quitar cron si existe
# -------------------------------------------------------------------
echo "[1/9] Revisando cron..."
TMP_CRON="$(mktemp)"
crontab -l 2>/dev/null | grep -v "sentinelx-agent.sh" > "$TMP_CRON" || true
crontab "$TMP_CRON"
rm -f "$TMP_CRON"
echo "  - Cron eliminado (si existía)"

# -------------------------------------------------------------------
# 2) Matar ejecuciones activas
# -------------------------------------------------------------------
echo "[2/9] Deteniendo ejecuciones activas..."
pkill -f sentinelx-agent.sh 2>/dev/null || true

# -------------------------------------------------------------------
# 3) Descargar agent nuevo
# -------------------------------------------------------------------
echo "[3/9] Descargando agent nuevo..."
TMP_AGENT="$(mktemp)"
curl -fsSL "$AGENT_URL" -o "$TMP_AGENT"

# -------------------------------------------------------------------
# 4) Reemplazar agent existente
# -------------------------------------------------------------------
echo "[4/9] Instalando agent en $AGENT_BIN ..."
rm -f "$AGENT_BIN"
mv "$TMP_AGENT" "$AGENT_BIN"
chmod 0750 "$AGENT_BIN"
chown root:root "$AGENT_BIN"

# -------------------------------------------------------------------
# 5) Limpiar basura generada por el agent
# -------------------------------------------------------------------
echo "[5/9] Limpiando spool / state / tmp / lock / logs..."
rm -rf \
  /var/spool/sentinelx-agent/* \
  /var/lib/sentinelx-agent/* \
  /tmp/sentinelx-agent/* \
  /var/lock/sentinelx-agent.lock* \
  /var/log/sentinelx-agent.log 2>/dev/null || true

# Asegurar directorios base
mkdir -p /var/spool/sentinelx-agent /var/lib/sentinelx-agent /tmp/sentinelx-agent
chmod 0750 /var/spool/sentinelx-agent /var/lib/sentinelx-agent /tmp/sentinelx-agent

# -------------------------------------------------------------------
# 6) Pedir API KEY
# -------------------------------------------------------------------
echo "[6/9] Configuración"
read -rsp "Ingresa SENTINELX_API_KEY: " SENTINELX_API_KEY
echo
if [[ -z "$SENTINELX_API_KEY" ]]; then
  echo "ERROR: API KEY vacía"
  exit 1
fi

# -------------------------------------------------------------------
# 7) Crear env nuevo
# -------------------------------------------------------------------
echo "[7/9] Generando $ENV_FILE ..."
rm -f "$ENV_FILE"
cat > "$ENV_FILE" <<EOF
# /etc/sentinelx-agent.env
# URL completa al endpoint
SENTINELX_INGEST_URL="https://api.sentinelx.tokyo-03.com/logs/ingest"

# API KEY
SENTINELX_API_KEY="${SENTINELX_API_KEY}"

# Opcional: forzar modo ("cpanel" | "directadmin" | "auto")
SENTINELX_MODE="cpanel"

# Primer run
SENTINELX_FIRST_RUN_BACKFILL_DAYS="3"
SENTINELX_FIRST_RUN_CONTEXT_LINES="200"
SENTINELX_FIRST_RUN_BACKFILL_MB="50"
SENTINELX_FIRST_RUN_SCAN_MB="64"

# Chunk base
SENTINELX_CHUNK_MB="50"

# Rate limit (vacío = sin límite)
SENTINELX_LIMIT_RATE=""

# Timeouts
SENTINELX_CONNECT_TIMEOUT="10"
SENTINELX_MAX_TIME="7200"

# Tiempo máximo por corrida
SENTINELX_MAX_SECONDS_PER_RUN="3300"

# Pausa entre envíos
SENTINELX_SLEEP_BETWEEN_SENDS="0"

# SAR
SENTINELX_SAR_BACKFILL_DAYS="3"

# Newline scan
SENTINELX_MAX_NEWLINE_SCAN_BYTES="1048576"
SENTINELX_MAX_FORWARD_SCAN_BYTES="8388608"

# Python
SENTINELX_PYTHON_BIN="python3"

# Reset agresivo
SENTINELX_RESET_ON_BACKEND_DOWN="1"
SENTINELX_RESET_ON_SEND_FAILURE="1"
EOF

chmod 0600 "$ENV_FILE"
chown root:root "$ENV_FILE"

# -------------------------------------------------------------------
# 8) Reinstalar cron
# -------------------------------------------------------------------
echo "[8/9] Instalando cron..."
(
  crontab -l 2>/dev/null
  echo "${CRON_EXPR} ${CRON_CMD}"
) | crontab -

# -------------------------------------------------------------------
# 9) Resumen
# -------------------------------------------------------------------
echo "[9/9] Instalación completada"
echo "  - Agent: $AGENT_BIN"
echo "  - Env:   $ENV_FILE"
echo "  - Cron:  ${CRON_EXPR} ${CRON_CMD}"
echo
echo "Puedes probar manualmente con:"
echo "  ENV_FILE=/etc/sentinelx-agent.env /usr/local/bin/sentinelx-agent.sh"
