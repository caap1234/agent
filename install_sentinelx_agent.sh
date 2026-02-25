#!/usr/bin/env bash
set -euo pipefail

AGENT_URL="https://raw.githubusercontent.com/caap1234/agent/refs/heads/main/sentinelx-agent.sh"
AGENT_BIN="/usr/local/bin/sentinelx-agent.sh"
ENV_FILE="/etc/sentinelx-agent.env"

# Log principal del agent
LOG_FILE="/var/log/sentinelx-agent.log"

# Rotación
LOGROTATE_FILE="/etc/logrotate.d/sentinelx-agent"
ROTATE_DAYS="${ROTATE_DAYS:-14}"     # cuántos archivos rotados conservar
ROTATE_SIZE="${ROTATE_SIZE:-50M}"    # rota si crece más de esto (además del daily)

# Cron: usar flock para evitar overlaps y mandar todo al LOG_FILE (rotará con logrotate)
CRON_EXPR="*/30 * * * *"
CRON_CMD="flock -n /var/lock/sentinelx-agent.cron.lock ENV_FILE=/etc/sentinelx-agent.env /usr/local/bin/sentinelx-agent.sh >> /var/log/sentinelx-agent.log 2>&1"

echo "== SentinelX Agent reinstall / reset =="

# -------------------------------------------------------------------
# 1) Quitar cron si existe y limpiar logs heredados por cron previo
# -------------------------------------------------------------------
echo "[1/10] Revisando cron y limpiando logs heredados..."
TMP_CRON="$(mktemp)"
crontab -l 2>/dev/null | grep -v "sentinelx-agent.sh" > "$TMP_CRON" || true
crontab "$TMP_CRON"
rm -f "$TMP_CRON"
echo "  - Cron eliminado (si existía)"

# Borrar logs ya existentes (de cron anterior) y recrear limpio
rm -f "$LOG_FILE" 2>/dev/null || true
touch "$LOG_FILE"
chmod 0640 "$LOG_FILE"
chown root:root "$LOG_FILE"
echo "  - Log heredado eliminado y recreado: $LOG_FILE"

# -------------------------------------------------------------------
# 2) Matar ejecuciones activas
# -------------------------------------------------------------------
echo "[2/10] Deteniendo ejecuciones activas..."
pkill -f sentinelx-agent.sh 2>/dev/null || true

# -------------------------------------------------------------------
# 3) Descargar agent nuevo
# -------------------------------------------------------------------
echo "[3/10] Descargando agent nuevo..."
TMP_AGENT="$(mktemp)"
curl -fsSL "$AGENT_URL" -o "$TMP_AGENT"

# -------------------------------------------------------------------
# 4) Reemplazar agent existente
# -------------------------------------------------------------------
echo "[4/10] Instalando agent en $AGENT_BIN ..."
rm -f "$AGENT_BIN"
mv "$TMP_AGENT" "$AGENT_BIN"
chmod 0755 "$AGENT_BIN"
chown root:root "$AGENT_BIN"

# -------------------------------------------------------------------
# 5) Limpiar basura generada por el agent
# -------------------------------------------------------------------
echo "[5/10] Limpiando spool / state / tmp / lock..."
rm -rf \
  /var/spool/sentinelx-agent/* \
  /var/lib/sentinelx-agent/* \
  /tmp/sentinelx-agent/* \
  /var/lock/sentinelx-agent.lock* \
  /var/lock/sentinelx-agent.cron.lock 2>/dev/null || true

# Asegurar directorios base
mkdir -p /var/spool/sentinelx-agent /var/lib/sentinelx-agent /tmp/sentinelx-agent /var/lock
chmod 0750 /var/spool/sentinelx-agent /var/lib/sentinelx-agent /tmp/sentinelx-agent

# -------------------------------------------------------------------
# 6) Instalar/actualizar logrotate para logs futuros
# -------------------------------------------------------------------
echo "[6/10] Configurando logrotate..."
cat > "$LOGROTATE_FILE" <<EOF
${LOG_FILE} {
  daily
  rotate ${ROTATE_DAYS}
  size ${ROTATE_SIZE}
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
  create 0640 root root
}
EOF
chmod 0644 "$LOGROTATE_FILE"
chown root:root "$LOGROTATE_FILE"
echo "  - Logrotate instalado: $LOGROTATE_FILE"

# -------------------------------------------------------------------
# 7) Pedir API KEY
# -------------------------------------------------------------------
echo "[7/10] Configuración"
read -rsp "Ingresa SENTINELX_API_KEY: " SENTINELX_API_KEY
echo
if [[ -z "$SENTINELX_API_KEY" ]]; then
  echo "ERROR: API KEY vacía"
  exit 1
fi

# -------------------------------------------------------------------
# 8) Crear env nuevo
# -------------------------------------------------------------------
echo "[8/10] Generando $ENV_FILE ..."
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
# Primer run SAR (sin marker) manda SOLO el día actual
SENTINELX_SAR_FIRST_RUN_ONLY_TODAY="1"

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
# 9) Reinstalar cron
# -------------------------------------------------------------------
echo "[9/10] Instalando cron..."
(
  crontab -l 2>/dev/null
  echo "${CRON_EXPR} ${CRON_CMD}"
) | crontab -

# -------------------------------------------------------------------
# 10) Resumen
# -------------------------------------------------------------------
echo "[10/10] Instalación completada"
echo "  - Agent:      $AGENT_BIN (755)"
echo "  - Env:        $ENV_FILE (600)"
echo "  - Cron:       ${CRON_EXPR} ${CRON_CMD}"
echo "  - Log:        $LOG_FILE (rotará por logrotate)"
echo "  - Logrotate:  $LOGROTATE_FILE"
echo
echo "Puedes probar manualmente con:"
echo "  ENV_FILE=/etc/sentinelx-agent.env /usr/local/bin/sentinelx-agent.sh"
