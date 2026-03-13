#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# SentinelX Agent - incremental uploader (inode+offset) + spool
# Ajustado para:
# - Enviar SOLO logs de correo
# - Primer run: mandar TODO el archivo desde byte 0
# - Siguientes corridas: incremental desde offset guardado
# - Mantener mismo flujo de chunks + gzip + multipart que ya funcionaba
#
# Fuentes:
# - /var/log/exim_mainlog
# - /var/log/maillog
# - /var/log/mail.log
#
# Notas:
# - NO SAR
# - NO apache/system/secure/lfd
# ------------------------------------------------------------

ENV_FILE="${ENV_FILE:-/etc/sentinelx-agent.env}"
[[ -f "$ENV_FILE" ]] && # shellcheck disable=SC1090
  source "$ENV_FILE"

: "${SENTINELX_INGEST_URL:?Falta SENTINELX_INGEST_URL}"
: "${SENTINELX_API_KEY:?Falta SENTINELX_API_KEY}"

MODE="${SENTINELX_MODE:-auto}"

# Red / performance
CHUNK_MB="${SENTINELX_CHUNK_MB:-50}"                 # chunk base por iteración
LIMIT_RATE="${SENTINELX_LIMIT_RATE:-}"               # ej: 2m, 500k. Vacío=sin límite
CONNECT_TIMEOUT="${SENTINELX_CONNECT_TIMEOUT:-10}"
MAX_TIME="${SENTINELX_MAX_TIME:-7200}"               # segundos por request
SLEEP_BETWEEN="${SENTINELX_SLEEP_BETWEEN_SENDS:-0}"

# Corte por tiempo de corrida
MAX_SECONDS_PER_RUN="${SENTINELX_MAX_SECONDS_PER_RUN:-3300}" # 55 min

# Primer run
FIRST_RUN_CONTEXT_LINES="${SENTINELX_FIRST_RUN_CONTEXT_LINES:-200}"
FIRST_RUN_BACKFILL_MB="${SENTINELX_FIRST_RUN_BACKFILL_MB:-200}"
FIRST_RUN_SCAN_MB="${SENTINELX_FIRST_RUN_SCAN_MB:-256}"
SEND_FULL_ON_FIRST_RUN="${SENTINELX_SEND_FULL_ON_FIRST_RUN:-1}"

STATE_DIR="${STATE_DIR:-/var/lib/sentinelx-agent}"
SPOOL_DIR="${SPOOL_DIR:-/var/spool/sentinelx-agent}"
TMP_DIR="${TMP_DIR:-/tmp/sentinelx-agent}"

LOCK_FILE="${SENTINELX_LOCK_FILE:-/var/lock/sentinelx-agent.lock}"

# Escaneos newline
MAX_NEWLINE_SCAN_BYTES="${SENTINELX_MAX_NEWLINE_SCAN_BYTES:-1048576}"     # busca '\n' hacia atrás dentro de este window
MAX_FORWARD_SCAN_BYTES="${SENTINELX_MAX_FORWARD_SCAN_BYTES:-8388608}"     # busca '\n' hacia adelante (líneas largas) hasta este límite

# Python (recomendado)
PYTHON_BIN="${SENTINELX_PYTHON_BIN:-python3}"

# Si el backend está caído (sin HTTP) o devuelve 5xx/429:
# 1 = reset (purga spool + borra states) y sale sin encolar
RESET_ON_BACKEND_DOWN="${SENTINELX_RESET_ON_BACKEND_DOWN:-1}"

# Si cualquier envío falla:
# 1 = reset (purga spool + borra states) y termina corrida
RESET_ON_SEND_FAILURE="${SENTINELX_RESET_ON_SEND_FAILURE:-1}"

mkdir -p "$STATE_DIR" "$SPOOL_DIR" "$TMP_DIR" "$(dirname "$LOCK_FILE")"
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
    log "ERROR: se requiere $PYTHON_BIN para garantizar chunks alineados a newline."
    exit 2
  fi
}

# ------------------------------------------------------------
# Lock
# ------------------------------------------------------------
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

detect_mode() {
  if [[ "$MODE" != "auto" ]]; then
    echo "$MODE"; return
  fi
  if [[ -d /usr/local/cpanel ]]; then
    echo "cpanel"; return
  fi
  if [[ -d /usr/local/directadmin ]]; then
    echo "directadmin"; return
  fi
  echo "auto"
}

purge_spool() {
  rm -rf "${SPOOL_DIR:?}/"* 2>/dev/null || true
}

reset_states() {
  rm -f "${STATE_DIR:?}/"*.state 2>/dev/null || true
}

reset_for_next_run_due_to_failure() {
  log "WARN reset_queue: purga spool y resetea states."
  purge_spool
  reset_states
}

# ------------------------------------------------------------
# Preflight backend
# ------------------------------------------------------------
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
  if [[ "$http_code" == 429 || "$http_code" =~ ^5 ]]; then
    return 1
  fi
  return 0
}

# ------------------------------------------------------------
# curl uploader (multipart)
# ------------------------------------------------------------
curl_upload_file() {
  local tag="$1"
  local filepath="$2"
  local filename="$3"

  local curl_args=(
    -sS
    --connect-timeout "$CONNECT_TIMEOUT"
    --max-time "$MAX_TIME"
    -H "X-API-Key: ${SENTINELX_API_KEY}"
    -F "tag=${tag}"
    -F "file=@${filepath};filename=${filename}"
    -o /dev/null
    -w "%{http_code}"
  )

  if [[ -n "$LIMIT_RATE" ]]; then
    curl_args+=(--limit-rate "$LIMIT_RATE")
  fi

  local http_code
  http_code="$(curl "${curl_args[@]}" "$SENTINELX_INGEST_URL" || true)"

  if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "202" ]]; then
    return 0
  fi

  log "ERROR upload tag=${tag} file=${filename} http_code=${http_code}"
  return 1
}

# ------------------------------------------------------------
# state: inode + offset
# ------------------------------------------------------------
state_key_from_path() {
  local path="$1"
  echo "$(echo "$path" | sed 's#[^a-zA-Z0-9._-]#_#g')"
}
state_file_for_path() {
  local path="$1"
  echo "${STATE_DIR}/$(state_key_from_path "$path").state"
}
read_state() {
  local path="$1"
  local sf
  sf="$(state_file_for_path "$path")"
  if [[ -f "$sf" ]]; then
    cat "$sf"
  else
    echo "0 0"
  fi
}
write_state() {
  local path="$1"
  local inode="$2"
  local offset="$3"
  local sf
  sf="$(state_file_for_path "$path")"
  printf "%s %s\n" "$inode" "$offset" > "$sf"
}

# ------------------------------------------------------------
# Python helpers: alineación a newline sin modificar bytes
# ------------------------------------------------------------
py_align_cursor() {
  local path="$1"
  local off="$2"
  local scan_back="$3"

  "$PYTHON_BIN" - "$path" "$off" "$scan_back" <<'PY'
import sys
p = sys.argv[1]
off = int(sys.argv[2])
scan = int(sys.argv[3])

if off <= 0:
    print(0); raise SystemExit

with open(p, "rb") as f:
    f.seek(off-1)
    prev = f.read(1)

if prev == b"\n":
    print(off); raise SystemExit

start = max(0, off - scan)
with open(p, "rb") as f:
    f.seek(start)
    data = f.read(off - start)

idx = data.rfind(b"\n")
if idx == -1:
    print(0)
else:
    print(start + idx + 1)
PY
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
    print(cursor); raise SystemExit

win_start = max(cursor, proposed_end - scan_back)
with open(p, "rb") as f:
    f.seek(win_start)
    data = f.read(proposed_end - win_start)

idx = data.rfind(b"\n")
if idx != -1:
    end = win_start + idx + 1
    if end > cursor:
        print(end); raise SystemExit

fwd_end = min(target_size, proposed_end + scan_fwd)
if fwd_end > proposed_end:
    with open(p, "rb") as f:
        f.seek(proposed_end)
        data2 = f.read(fwd_end - proposed_end)
    j = data2.find(b"\n")
    if j != -1:
        print(proposed_end + j + 1); raise SystemExit

print(cursor)
PY
}

# ------------------------------------------------------------
# Primer run (TAIL): últimas N líneas
# ------------------------------------------------------------
initial_offset_for_first_run() {
  local path="$1"
  local size
  size="$(stat -c '%s' "$path" 2>/dev/null || echo 0)"
  (( size > 0 )) || { echo 0; return; }

  local scan_bytes=$(( FIRST_RUN_SCAN_MB * 1024 * 1024 ))
  local fallback_bytes=$(( FIRST_RUN_BACKFILL_MB * 1024 * 1024 ))

  "$PYTHON_BIN" - "$path" "$size" "$FIRST_RUN_CONTEXT_LINES" "$scan_bytes" "$fallback_bytes" <<'PY'
import sys

p = sys.argv[1]
size = int(sys.argv[2])
context_lines = int(sys.argv[3])
scan_bytes = int(sys.argv[4])
fallback_bytes = int(sys.argv[5])

start = max(0, size - scan_bytes)
with open(p, "rb") as f:
    f.seek(start)
    buf = f.read(size - start)

if b"\n" not in buf:
    print(max(0, size - fallback_bytes))
    raise SystemExit

newline_positions = [i for i,b in enumerate(buf) if b == 10]

if len(newline_positions) <= context_lines:
    print(start)
    raise SystemExit

cut_nl_idx = newline_positions[-(context_lines+1)]
out = start + cut_nl_idx + 1
print(out)
PY
}

# ------------------------------------------------------------
# spool jobs
# ------------------------------------------------------------
spool_job_dir() {
  local tag="$1"
  local name="$2"
  local ts
  ts="$(date -u +%s)"
  local h
  h="$(echo "${tag}:${name}:${ts}:$$" | sha1sum | awk '{print $1}')"
  echo "${SPOOL_DIR}/${ts}__${tag}__${h}"
}

enqueue_payload_file() {
  local tag="$1"
  local src_path="$2"
  local orig_name="$3"
  local inode="$4"
  local start_off="$5"
  local end_off="$6"
  local raw_bytes="$7"
  local payload_path="$8"

  local job
  job="$(spool_job_dir "$tag" "$orig_name")"
  mkdir -p "$job"

  local payload_size
  payload_size="$(stat -c '%s' "$payload_path" 2>/dev/null || echo 0)"

  cat > "${job}/meta.env" <<EOF
TAG=$(printf '%q' "$tag")
ORIG_NAME=$(printf '%q' "$orig_name")
SRC_PATH=$(printf '%q' "$src_path")
INODE=$(printf '%q' "$inode")
START_OFF=$(printf '%q' "$start_off")
END_OFF=$(printf '%q' "$end_off")
RAW_BYTES=$(printf '%q' "$raw_bytes")
BYTES=$(printf '%q' "$payload_size")
EOF

  mv "$payload_path" "${job}/payload.gz"
  log "ENQUEUE tag=${tag} name=${orig_name} payload_bytes=${payload_size} raw_bytes=${raw_bytes} off=${start_off}-${end_off} job=$(basename "$job")"
}

flush_spool() {
  shopt -s nullglob
  local jobs=( "${SPOOL_DIR}"/* )
  shopt -u nullglob

  [[ ${#jobs[@]} -eq 0 ]] && return 0
  IFS=$'\n' jobs=( $(printf "%s\n" "${jobs[@]}" | sort) ); unset IFS

  for job in "${jobs[@]}"; do
    [[ -d "$job" ]] || continue
    # shellcheck disable=SC1090
    source "${job}/meta.env"

    local payload="${job}/payload.gz"
    if [[ ! -f "$payload" ]]; then
      log "WARN spool job without payload: $job"
      rm -rf "$job"
      continue
    fi

    if time_exceeded; then
      log "STOP flush_spool time_exceeded"
      return 0
    fi

    local fname="${ORIG_NAME}.part_${START_OFF}_${END_OFF}.gz"

    if curl_upload_file "$TAG" "$payload" "$fname"; then
      if [[ -n "${SRC_PATH:-}" && "$SRC_PATH" != "/dev/null" ]]; then
        local cur_inode cur_off
        read -r cur_inode cur_off < <(read_state "$SRC_PATH")

        if [[ "$cur_inode" == "$INODE" ]]; then
          if (( END_OFF > cur_off )); then
            write_state "$SRC_PATH" "$INODE" "$END_OFF"
          fi
        else
          write_state "$SRC_PATH" "$INODE" "$END_OFF"
        fi
      fi

      rm -rf "$job"
      [[ "$SLEEP_BETWEEN" != "0" ]] && sleep "$SLEEP_BETWEEN"
    else
      log "STOP flush_spool due to send failure"
      if [[ "$RESET_ON_SEND_FAILURE" == "1" ]]; then
        reset_for_next_run_due_to_failure
      fi
      return 1
    fi
  done
}

# ------------------------------------------------------------
# Encola chunks alineados a newline, hasta target_size (snapshot)
# ------------------------------------------------------------
process_file_up_to_target() {
  local path="$1"
  local tag="$2"
  local name="$3"

  [[ -f "$path" ]] || return 0

  local target_size
  target_size="$(stat -c '%s' "$path" 2>/dev/null || echo 0)"
  (( target_size > 0 )) || return 0

  local inode
  inode="$(stat -c '%i' "$path" 2>/dev/null || echo 0)"

  local st_inode st_off
  read -r st_inode st_off < <(read_state "$path")

  local cursor_off
  if [[ "$st_inode" == "0" && "$st_off" == "0" ]]; then
    if [[ "$SEND_FULL_ON_FIRST_RUN" == "1" ]]; then
      cursor_off=0
    else
      cursor_off="$(initial_offset_for_first_run "$path")"
    fi
  else
    if [[ "$inode" != "$st_inode" || "$target_size" -lt "$st_off" ]]; then
      cursor_off=0
    else
      cursor_off="$st_off"
    fi
  fi

  (( cursor_off >= target_size )) && return 0

  cursor_off="$(py_align_cursor "$path" "$cursor_off" "$MAX_NEWLINE_SCAN_BYTES" || echo 0)"
  [[ "$cursor_off" =~ ^[0-9]+$ ]] || cursor_off=0
  (( cursor_off >= target_size )) && return 0

  local chunk_bytes=$((CHUNK_MB * 1024 * 1024))

  while (( cursor_off < target_size )); do
    time_exceeded && { log "STOP time_exceeded while enqueuing $path"; return 0; }

    local proposed_end=$((cursor_off + chunk_bytes))
    (( proposed_end > target_size )) && proposed_end="$target_size"

    local end_off
    end_off="$(py_choose_end_aligned "$path" "$cursor_off" "$proposed_end" "$target_size" "$MAX_NEWLINE_SCAN_BYTES" "$MAX_FORWARD_SCAN_BYTES" || echo "$cursor_off")"
    [[ "$end_off" =~ ^[0-9]+$ ]] || end_off="$cursor_off"

    if (( end_off <= cursor_off )); then
      return 0
    fi

    local bytes=$((end_off - cursor_off))
    (( bytes > 0 )) || return 0

    local tmp_gz="${TMP_DIR}/$(basename "$path").${cursor_off}-${end_off}.gz"

    if ! dd if="$path" iflag=skip_bytes,count_bytes skip="$cursor_off" count="$bytes" status=none \
        | gzip -c > "$tmp_gz"; then
      rm -f "$tmp_gz"
      log "WARN enqueue failed path=$path"
      return 0
    fi

    enqueue_payload_file "$tag" "$path" "$name" "$inode" "$cursor_off" "$end_off" "$bytes" "$tmp_gz"
    cursor_off="$end_off"
  done
}

collect_log_sources() {
  local mode_detected="$1"

  echo "exim_mainlog:/var/log/exim_mainlog:exim_mainlog"
  echo "dovecot:/var/log/maillog:maillog"
  echo "dovecot:/var/log/mail.log:mail_log"
}

main() {
  acquire_lock
  need_python

  renice +10 $$ >/dev/null 2>&1 || true
  ionice -c2 -n7 -p $$ >/dev/null 2>&1 || true

  local mode_detected
  mode_detected="$(detect_mode)"

  log "START mode=${mode_detected} send_full_on_first_run=${SEND_FULL_ON_FIRST_RUN} chunk_mb=${CHUNK_MB} max_seconds=${MAX_SECONDS_PER_RUN} scan_back=${MAX_NEWLINE_SCAN_BYTES} scan_fwd=${MAX_FORWARD_SCAN_BYTES} reset_on_backend_down=${RESET_ON_BACKEND_DOWN} reset_on_send_failure=${RESET_ON_SEND_FAILURE} python=$("$PYTHON_BIN" -V 2>&1 | tr -d '\r')"

  if ! backend_reachable; then
    if [[ "$RESET_ON_BACKEND_DOWN" == "1" ]]; then
      log "WARN backend_unhealthy: no se encolará nada (preflight)."
      reset_for_next_run_due_to_failure
      log "END (backend unhealthy)"
      return 0
    fi
    log "WARN backend_unhealthy but RESET_ON_BACKEND_DOWN=0; continuará (podría encolar)."
  fi

  if ! flush_spool; then
    log "END (flush failed)"
    return 1
  fi

  while IFS=: read -r tag path name; do
    [[ -n "${tag:-}" && -n "${path:-}" && -n "${name:-}" ]] || continue
    [[ -f "$path" ]] || continue

    time_exceeded && { log "STOP time_exceeded before finishing sources"; break; }
    process_file_up_to_target "$path" "$tag" "$name"
  done < <(collect_log_sources "$mode_detected")

  if ! flush_spool; then
    log "END (flush failed final)"
    return 1
  fi

  log "END"
}

main "$@"
