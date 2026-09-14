# shellcheck shell=bash
#
# state.sh - run manifest, error journal, resume support.
#
# Layout of a run directory:
#   ~/.local/state/volok/<run-id>/
#     manifest.tsv     status <TAB> path <TAB> size <TAB> iso8601
#     errors.log       iso8601 <TAB> path <TAB> http code <TAB> api message
#     published.list   slot <TAB> path, resources currently shared by a link
#     scan.dirs        source directories, one escaped relative path per line
#     scan.files       relative path <TAB> size
#     run.conf         parameters of the run, used by --resume
#     volok.log        the log file
#
# Every path written to these files is TSV-escaped, so names containing tabs
# or newlines survive a round trip.

STATE_ROOT=''
STATE_RUN_ID=''
STATE_RUN_DIR=''
STATE_MANIFEST=''
STATE_ERRORS=''
STATE_PUBLISHED=''
STATE_SCAN_DIRS=''
STATE_SCAN_FILES=''
STATE_CONF=''
declare -A STATE_DONE=()

# tsv_escape <text> - make a value safe for one TSV field.
tsv_escape() {
  local text="$1"
  text="${text//\\/\\\\}"
  text="${text//$'\t'/\\t}"
  text="${text//$'\n'/\\n}"
  text="${text//$'\r'/\\r}"
  printf '%s' "$text"
}

# tsv_unescape <text> - inverse of tsv_escape.
tsv_unescape() {
  local text="$1"
  local out=''
  local len=${#text}
  local idx=0
  local char next
  local backslash=$'\\'
  while (( idx < len )); do
    char="${text:idx:1}"
    if [[ "$char" == "$backslash" ]] && (( idx + 1 < len )); then
      next="${text:idx+1:1}"
      case "$next" in
        t) out+=$'\t' ;;
        n) out+=$'\n' ;;
        r) out+=$'\r' ;;
        "$backslash") out+="$backslash" ;;
        *) out+="$char$next" ;;
      esac
      idx=$(( idx + 2 ))
    else
      out+="$char"
      idx=$(( idx + 1 ))
    fi
  done
  printf '%s' "$out"
}

# state_now - ISO 8601 timestamp in UTC.
state_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# state_list_runs - known run ids, newest last.
state_list_runs() {
  local root="${XDG_STATE_HOME:-$HOME/.local/state}/volok"
  if [[ ! -d "$root" ]]; then
    return 0
  fi
  local entry
  for entry in "$root"/*; do
    if [[ -d "$entry" ]]; then
      printf '%s\n' "${entry##*/}"
    fi
  done
  return 0
}

# state_init [run_id] - create or reopen a run directory.
state_init() {
  local run_id="${1:-}"
  STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/volok"
  if [[ -z "$run_id" ]]; then
    run_id="$(date -u +%Y%m%d-%H%M%S)-$$"
  fi
  STATE_RUN_ID="$run_id"
  STATE_RUN_DIR="$STATE_ROOT/$STATE_RUN_ID"
  mkdir -p -- "$STATE_RUN_DIR"
  chmod 700 -- "$STATE_RUN_DIR" 2>/dev/null || true
  STATE_MANIFEST="$STATE_RUN_DIR/manifest.tsv"
  STATE_ERRORS="$STATE_RUN_DIR/errors.log"
  STATE_PUBLISHED="$STATE_RUN_DIR/published.list"
  STATE_SCAN_DIRS="$STATE_RUN_DIR/scan.dirs"
  STATE_SCAN_FILES="$STATE_RUN_DIR/scan.files"
  STATE_CONF="$STATE_RUN_DIR/run.conf"
  : >> "$STATE_MANIFEST"
  : >> "$STATE_ERRORS"
  : >> "$STATE_PUBLISHED"
  return 0
}

# state_run_exists <run_id>
state_run_exists() {
  local root="${XDG_STATE_HOME:-$HOME/.local/state}/volok"
  [[ -d "$root/$1" ]]
}

# state_save_conf <key> <value> - remember a run parameter for --resume.
state_save_conf() {
  local key="$1"
  local value="$2"
  local tmp="$STATE_CONF.tmp"
  : > "$tmp"
  if [[ -f "$STATE_CONF" ]]; then
    grep -v "^${key}=" -- "$STATE_CONF" >> "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$(tsv_escape "$value")" >> "$tmp"
  mv -f "$tmp" "$STATE_CONF"
  return 0
}

# state_read_conf <key> - value on stdout, empty when unknown.
state_read_conf() {
  local key="$1"
  if [[ ! -f "$STATE_CONF" ]]; then
    printf ''
    return 0
  fi
  local line
  line="$(grep -m 1 "^${key}=" -- "$STATE_CONF" || printf '')"
  if [[ -z "$line" ]]; then
    printf ''
    return 0
  fi
  tsv_unescape "${line#*=}"
}

# state_record <status> <path> <size> - append one manifest row.
state_record() {
  local status="$1"
  local path="$2"
  local size="${3:-0}"
  printf '%s\t%s\t%s\t%s\n' \
    "$status" "$(tsv_escape "$path")" "$size" "$(state_now)" >> "$STATE_MANIFEST"
  return 0
}

# state_record_error <path> <http code> <message> - append one error row.
state_record_error() {
  local path="$1"
  local code="$2"
  local message="$3"
  message="${message//$'\n'/ }"
  message="${message//$'\t'/ }"
  printf '%s\t%s\t%s\t%s\n' \
    "$(state_now)" "$(tsv_escape "$path")" "$code" "$message" >> "$STATE_ERRORS"
  return 0
}

# state_load_done - fill STATE_DONE with paths already marked copied.
state_load_done() {
  STATE_DONE=()
  if [[ ! -f "$STATE_MANIFEST" ]]; then
    return 0
  fi
  local status path
  while IFS=$'\t' read -r status path _ || [[ -n "$status" ]]; do
    if [[ "$status" == "copied" && -n "$path" ]]; then
      STATE_DONE["$(tsv_unescape "$path")"]=1
    fi
  done < "$STATE_MANIFEST"
  return 0
}

# state_is_done <path>
state_is_done() {
  [[ -n "${STATE_DONE[$1]:-}" ]]
}

# state_copied_paths - source paths marked copied, one per line, escaped.
state_copied_paths() {
  if [[ ! -f "$STATE_MANIFEST" ]]; then
    return 0
  fi
  local status path
  while IFS=$'\t' read -r status path _ || [[ -n "$status" ]]; do
    if [[ "$status" == "copied" && -n "$path" ]]; then
      printf '%s\n' "$path"
    fi
  done < "$STATE_MANIFEST"
  return 0
}

# state_error_count - number of rows in the error journal.
state_error_count() {
  local count=0
  if [[ -f "$STATE_ERRORS" ]]; then
    count="$(wc -l < "$STATE_ERRORS" 2>/dev/null || printf '0')"
    count="${count//[^0-9]/}"
  fi
  printf '%s' "${count:-0}"
}

# state_publish_add <slot> <path> - remember a resource that is shared now.
state_publish_add() {
  printf '%s\t%s\n' "$1" "$(tsv_escape "$2")" >> "$STATE_PUBLISHED"
  return 0
}

# state_publish_del <slot> <path> - forget a resource that was unshared.
state_publish_del() {
  local slot="$1"
  local path
  path="$(tsv_escape "$2")"
  local tmp="$STATE_PUBLISHED.tmp"
  if [[ ! -f "$STATE_PUBLISHED" ]]; then
    return 0
  fi
  local line_slot line_path
  : > "$tmp"
  while IFS=$'\t' read -r line_slot line_path || [[ -n "$line_slot" ]]; do
    if [[ "$line_slot" == "$slot" && "$line_path" == "$path" ]]; then
      continue
    fi
    if [[ -n "$line_slot" ]]; then
      printf '%s\t%s\n' "$line_slot" "$line_path" >> "$tmp"
    fi
  done < "$STATE_PUBLISHED"
  mv -f "$tmp" "$STATE_PUBLISHED"
  return 0
}

# state_published_each - slot <TAB> escaped path for everything still shared.
state_published_each() {
  if [[ -f "$STATE_PUBLISHED" ]]; then
    cat -- "$STATE_PUBLISHED"
  fi
  return 0
}
