# shellcheck shell=bash
#
# log.sh - leveled logging with mandatory secret masking and size rotation.
#
# Nothing in this project writes to the log directly: everything goes through
# log_* so that a token can never reach the disk by accident.

LOG_LEVEL='info'
LOG_FILE=''
LOG_MAX_BYTES=$(( 1024 * 1024 ))
LOG_KEEP=3
LOG_SECRETS=()
LOG_MASK='<токен скрыт>'

# log_level_num <name> - numeric weight of a level name.
log_level_num() {
  case "$1" in
    debug) printf '10' ;;
    info)  printf '20' ;;
    warn)  printf '30' ;;
    error) printf '40' ;;
    *)     printf '20' ;;
  esac
}

# log_set_level <name> - change verbosity, fail on an unknown name.
log_set_level() {
  case "$1" in
    debug|info|warn|error)
      LOG_LEVEL="$1"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# log_register_secret <value> - value is replaced by a placeholder everywhere.
log_register_secret() {
  local value="${1:-}"
  if [[ ${#value} -lt 6 ]]; then
    return 0
  fi
  LOG_SECRETS+=("$value")
}

# log_mask <text> - strip every known secret and anything shaped like one.
log_mask() {
  local text="$1"
  local secret
  for secret in ${LOG_SECRETS[@]+"${LOG_SECRETS[@]}"}; do
    text="${text//"$secret"/$LOG_MASK}"
  done
  # Catch credentials that were never registered, e.g. a pasted header.
  text="$(printf '%s' "$text" \
    | sed -E "s/(OAuth|Bearer|oauth_token=|access_token=)[[:space:]]*[A-Za-z0-9._~+-]{6,}=*/\1 ${LOG_MASK}/g")"
  printf '%s' "$text"
}

# log_rotate - keep the log file below LOG_MAX_BYTES, LOG_KEEP generations.
log_rotate() {
  if [[ -z "$LOG_FILE" || ! -f "$LOG_FILE" ]]; then
    return 0
  fi
  local size idx
  size="$(wc -c < "$LOG_FILE" 2>/dev/null || printf '0')"
  size="${size//[^0-9]/}"
  if [[ -z "$size" ]] || (( size < LOG_MAX_BYTES )); then
    return 0
  fi
  for (( idx = LOG_KEEP - 1; idx >= 1; idx-- )); do
    if [[ -f "$LOG_FILE.$idx" ]]; then
      mv -f "$LOG_FILE.$idx" "$LOG_FILE.$(( idx + 1 ))"
    fi
  done
  mv -f "$LOG_FILE" "$LOG_FILE.1"
  return 0
}

# log_init <path> - open the log file with private permissions.
log_init() {
  LOG_FILE="$1"
  local dir
  dir="$(dirname -- "$LOG_FILE")"
  mkdir -p -- "$dir"
  log_rotate
  : >> "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  return 0
}

# _log_emit <level> <message...> - one masked, single-line record.
_log_emit() {
  local level="$1"
  shift
  local want have
  want="$(log_level_num "$level")"
  have="$(log_level_num "$LOG_LEVEL")"
  if (( want < have )); then
    return 0
  fi
  local message="$*"
  message="${message//$'\n'/ }"
  message="${message//$'\r'/ }"
  message="${message//$'\t'/ }"
  message="$(log_mask "$message")"
  local stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\t%s\t%s\n' "$stamp" "$level" "$message" >> "$LOG_FILE"
  fi
  if [[ "${LOG_ECHO:-0}" == "1" ]]; then
    printf '%s %s %s\n' "$stamp" "$level" "$message" >&2
  fi
  return 0
}

log_debug() { _log_emit debug "$@"; }
log_info()  { _log_emit info  "$@"; }
log_warn()  { _log_emit warn  "$@"; }
log_error() { _log_emit error "$@"; }

# log_path - where the current log lives, for the final report.
log_path() {
  printf '%s' "$LOG_FILE"
}
