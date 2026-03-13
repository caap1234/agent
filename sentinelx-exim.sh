#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# SentinelX Agent - envío completo de EXIM snapshot actual
#
# Comportamiento:
# - SOLO procesa el log de Exim
# - En cada ejecución manda TODO lo que exista en el log en ese momento
# - NO usa state, NO usa spool, NO usa SAR, NO es incremental
# - Si el log es grande, lo divide en partes sin cortar líneas
# - Cada parte se envía comprimida en gzip
# ------------------------------------------------------------

ENV_FILE="${ENV_FILE:-/etc/sentinelx-agent.env}"
[[ -f "$ENV_FILE" ]] && # shellcheck disable=SC1090
  source "$ENV_FILE"

: "${SENTINELX_INGEST_URL:?Falta SENTINELX_INGEST_URL}"
: "${SENTINELX_API_KEY:?Falta SENTINELX_API_KEY}"

EXIM_LOG_PATH="${SENTINELX_EXIM_LOG_PATH:-/var/log/exim_mainlog}"
EXIM_TAG="${SENTINELX_EXIM_TAG:-exim_mainlog}"
CHUNK_MB="${SENTINELX_CHUNK_MB:-50}"
LIMIT_RATE="${SENTINELX_LIMIT_RATE:-}"
CONNECT_TIMEOUT="${SENTINELX_CONNECT_TIMEOUT:-10}"
MAX_TIME="${SENTINELX_MAX_TIME:-7200}"
SLEEP_BETWEEN="${SENTINELX_SLEEP_BETWEEN_SENDS:-0}"
MAX_SECONDS_PER_RUN="${SENTINELX_MAX_SECONDS_PER_RUN:-3300}"

LOCK_FILE="${SENTINELX_LOCK_FILE:-/var/lock/sentinelx-agent.lock}"
TMP_DIR="${TMP_DIR:-/tmp/sentinelx-agent}"

MAX_NEWLINE_SCAN_BYTES="${SENTINELX_MAX_NEWLINE_SCAN_BYTES:-1048576}"
MAX_FORWARD_SCAN_BYTES="${SENTINELX_MAX_FORWARD_SCAN_BYTES:-8388608}"

PYTHON_BIN="${SENTINELX_PYTHON_BIN:-python3}"

mkdir -p "$TMP_DIR" "$(dirname "$LOCK_FILE")"
umask 027

RUN_START_EPOCH="$(date -u +%s)"

log() { echo "[$(date -u +"%Y-%m-%d %H:%M:%S") UTC] $*"; }

time_exceeded() {
  local now
  now="$(date -u +%s)"
  (( now - RUN_START_EPOCH >= MAX_SECONDS_PER_RUN ))
}

need_python() {
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    log "ERROR: se requiere $PYTHON_BIN para alinear chunks por newline."
    exit 2
  fi
}

acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
      log "INFO: ya hay una corrida en progreso, saliendo."
      exit 0
    fi
  else
    if [[ -f "${LOCK_FILE}.pid" ]] && kill -0 "$(cat "${LOCK_FILE}.pid")" 2>/dev/null; then
      log "INFO: ya hay una corrida en progreso (pidfile), saliendo."
      exit 0
    fi
    echo $$ > "${LOCK_FILE}.pid"
    trap 'rm -f "${LOCK_FILE}.pid" 2>/dev/null || true' EXIT
  fi
}

backend_reachable() {
  local http_code
  http_code="$(
    curl -sS \
      --connect-timeout "$CONNECT_TIMEOUT" \
      --max-time "$CONNECT_TIMEOUT" \
      -H "X-API-Key: ${SENTINELX_API_KEY}" \
      -o /dev/null \
      -w "%{http_code}" \
      -I \
      "$SENTINELX_INGEST_URL" || true
  )"

  if [[ -z "$http_code" || "$http_code" == "000" ]]; then
    return 1
  fi

  if [[ "$http_code" == "429" || "$http_code" =~ ^5 ]]; then
    return 1
  fi

  return 0
}

curl_upload_file() {
  local tag="$1"
  local filepath="$2"
  local filename="$3"

  local resp_file
  resp_file="$(mktemp /tmp/sentinelx-upload-response.XXXXXX)"

  local curl_args=(
    -sS
    --connect-timeout "$CONNECT_TIMEOUT"
    --max-time "$MAX_TIME"
    -H "X-API-Key: ${SENTINELX_API_KEY}"
    -F "tag=${tag}"
    -F "file=@${filepath};filename=${filename}"
    -o "$resp_file"
    -w "%{http_code}"
  )

  if [[ -n "$LIMIT_RATE" ]]; then
    curl_args+=(--limit-rate "$LIMIT_RATE")
  fi

  local http_code
  http_code="$(curl "${curl_args[@]}" "$SENTINELX_INGEST_URL" || true)"

  if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "202" ]]; then
    rm -f "$resp_file"
    return 0
  fi

  log "ERROR upload tag=${tag} file=${filename} http_code=${http_code}"
  if [[ -s "$resp_file" ]]; then
    log "ERROR response_body=$(tr '\n' ' ' < "$resp_file" | sed 's/[[:space:]]\+/ /g')"
  fi
  rm -f "$resp_file"
  return 1
}

py_choose_end_aligned() {
  local path="$1"
  local cursor="$2"
  local proposed_end="$3"
  local target_size="$4"
  local scan_back="$5"
  local scan_fwd="$6"

  "$PYTHON_BIN" - "$path" "$cursor" "$proposed_end" "$target_size" "$scan_back" "$scan_fwd" <<'PY'
import sys

p = sys.argv[1]
cursor = int(sys.argv[2])
proposed_end = int(sys.argv[3])
target_size = int(sys.argv[4])
scan_back = int(sys.argv[5])
scan_fwd = int(sys.argv[6])

if proposed_end > target_size:
    proposed_end = target_size
if proposed_end <= cursor:
    print(cursor)
    raise SystemExit

win_start = max(cursor, proposed_end - scan_back)
with open(p, "rb") as f:
    f.seek(win_start)
    data = f.read(proposed_end - win_start)

idx = data.rfind(b"\n")
if idx != -1:
    end = win_start + idx + 1
    if end > cursor:
        print(end)
        raise SystemExit

fwd_end = min(target_size, proposed_end + scan_fwd)
if fwd_end > proposed_end:
    with open(p, "rb") as f:
        f.seek(proposed_end)
        data2 = f.read(fwd_end - proposed_end)
    j = data2.find(b"\n")
    if j != -1:
        print(proposed_end + j + 1)
        raise SystemExit

if proposed_end == target_size:
    print(target_size)
else:
    print(cursor)
PY
}

send_exim_snapshot() {
  local path="$1"
  local tag="$2"

  [[ -f "$path" ]] || {
    log "WARN no existe el archivo: $path"
    return 0
  }

  local target_size
  target_size="$(stat -c '%s' "$path" 2>/dev/null || echo 0)"
  (( target_size > 0 )) || {
    log "INFO archivo vacío: $path"
    return 0
  }

  local chunk_bytes=$((CHUNK_MB * 1024 * 1024))
  local cursor_off=0
  local part=1
  local base_name
  base_name="$(basename "$path")"
  local stamp
  stamp="$(date -u +"%Y%m%dT%H%M%SZ")"

  log "INFO enviando snapshot completo de ${path} size=${target_size} bytes chunk_mb=${CHUNK_MB}"

  while (( cursor_off < target_size )); do
    time_exceeded && {
      log "STOP time_exceeded mientras se enviaba ${path}"
      return 1
    }

    local proposed_end=$((cursor_off + chunk_bytes))
    (( proposed_end > target_size )) && proposed_end="$target_size"

    local end_off
    end_off="$(py_choose_end_aligned "$path" "$cursor_off" "$proposed_end" "$target_size" "$MAX_NEWLINE_SCAN_BYTES" "$MAX_FORWARD_SCAN_BYTES" || echo "$cursor_off")"
    [[ "$end_off" =~ ^[0-9]+$ ]] || end_off="$cursor_off"

    if (( end_off <= cursor_off )); then
      log "ERROR no fue posible alinear chunk path=${path} cursor=${cursor_off} proposed_end=${proposed_end}"
      return 1
    fi

    local bytes=$((end_off - cursor_off))
    local tmp_gz="${TMP_DIR}/${base_name}.${stamp}.part$(printf '%04d' "$part").gz"
    local remote_name="${base_name}.${stamp}.part$(printf '%04d' "$part")_${cursor_off}_${end_off}.gz"

    if ! dd if="$path" iflag=skip_bytes,count_bytes skip="$cursor_off" count="$bytes" status=none \
      | gzip -c > "$tmp_gz"; then
      rm -f "$tmp_gz"
      log "ERROR no se pudo generar chunk path=${path} part=${part}"
      return 1
    fi

    if ! curl_upload_file "$tag" "$tmp_gz" "$remote_name"; then
      rm -f "$tmp_gz"
      log "ERROR fallo envío path=${path} part=${part}"
      return 1
    fi

    rm -f "$tmp_gz"
    log "OK sent part=${part} off=${cursor_off}-${end_off} bytes=${bytes}"

    cursor_off="$end_off"
    part=$((part + 1))

    [[ "$SLEEP_BETWEEN" != "0" ]] && sleep "$SLEEP_BETWEEN"
  done

  log "INFO snapshot completo enviado path=${path}"
  return 0
}

main() {
  acquire_lock
  need_python

  renice +10 $$ >/dev/null 2>&1 || true
  ionice -c2 -n7 -p $$ >/dev/null 2>&1 || true

  log "START exim_only path=${EXIM_LOG_PATH} chunk_mb=${CHUNK_MB} max_seconds=${MAX_SECONDS_PER_RUN} python=$("$PYTHON_BIN" -V 2>&1 | tr -d '\r')"

  if ! backend_reachable; then
    log "WARN backend_unhealthy: no se enviará nada"
    log "END (backend unhealthy)"
    return 0
  fi

  if ! send_exim_snapshot "$EXIM_LOG_PATH" "$EXIM_TAG"; then
    log "END (send failed)"
    return 1
  fi

  log "END"
}

main "$@"
