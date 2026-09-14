# shellcheck shell=bash
#
# ui.sh - everything the user sees: colors, messages, prompts, menus, progress.
#
# Messages are Russian on purpose: the interface language of Volok is Russian,
# the code and comments are English.

UI_RESET=''
UI_BOLD=''
UI_DIM=''
UI_RED=''
UI_GREEN=''
UI_YELLOW=''
UI_BLUE=''
UI_PROGRESS_ACTIVE=0

# ui_init [force_plain] - enable colors only on a real terminal.
ui_init() {
  local plain="${1:-0}"
  if [[ "$plain" == "0" && -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    UI_RESET=$'\033[0m'
    UI_BOLD=$'\033[1m'
    UI_DIM=$'\033[2m'
    UI_RED=$'\033[31m'
    UI_GREEN=$'\033[32m'
    UI_YELLOW=$'\033[33m'
    UI_BLUE=$'\033[34m'
  else
    UI_RESET=''
    UI_BOLD=''
    UI_DIM=''
    UI_RED=''
    UI_GREEN=''
    UI_YELLOW=''
    UI_BLUE=''
  fi
}

# ui_is_tty - true when stdout is an interactive terminal.
ui_is_tty() {
  [[ -t 1 ]]
}

# ui_term_width - usable terminal width, with a sane fallback.
ui_term_width() {
  local cols="${COLUMNS:-}"
  if [[ -z "$cols" ]] && command -v tput >/dev/null 2>&1; then
    cols="$(tput cols 2>/dev/null || printf '')"
  fi
  if [[ ! "$cols" =~ ^[0-9]+$ ]] || (( cols < 20 )); then
    cols=80
  fi
  printf '%s' "$cols"
}

# _ui_clear_progress - make sure a message never lands on the progress line.
_ui_clear_progress() {
  if (( UI_PROGRESS_ACTIVE )); then
    if ui_is_tty; then
      printf '\r\033[K'
    fi
    UI_PROGRESS_ACTIVE=0
  fi
}

ui_say() {
  _ui_clear_progress
  printf '%s\n' "$*"
}

ui_title() {
  _ui_clear_progress
  printf '\n%s%s%s\n' "$UI_BOLD" "$*" "$UI_RESET"
}

ui_info() {
  _ui_clear_progress
  printf '%s->%s %s\n' "$UI_BLUE" "$UI_RESET" "$*"
}

ui_ok() {
  _ui_clear_progress
  printf '%s[ok]%s %s\n' "$UI_GREEN" "$UI_RESET" "$*"
}

ui_warn() {
  _ui_clear_progress
  printf '%s[!]%s %s\n' "$UI_YELLOW" "$UI_RESET" "$*" >&2
}

ui_err() {
  _ui_clear_progress
  printf '%s[x]%s %s\n' "$UI_RED" "$UI_RESET" "$*" >&2
}

ui_hint() {
  _ui_clear_progress
  printf '%s%s%s\n' "$UI_DIM" "$*" "$UI_RESET"
}

ui_hr() {
  _ui_clear_progress
  local width line
  width="$(ui_term_width)"
  printf -v line '%*s' "$width" ''
  printf '%s%s%s\n' "$UI_DIM" "${line// /-}" "$UI_RESET"
}

# ui_human_size <bytes> - human readable size, Russian units.
ui_human_size() {
  local bytes="${1:-0}"
  if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
    printf '0 Б'
    return 0
  fi
  local units=(Б КиБ МиБ ГиБ ТиБ ПиБ)
  local idx=0
  local value="$bytes"
  while (( value >= 1024 && idx < ${#units[@]} - 1 )); do
    value=$(( value / 1024 ))
    idx=$(( idx + 1 ))
  done
  if (( idx == 0 )); then
    printf '%d %s' "$bytes" "${units[idx]}"
    return 0
  fi
  # One decimal digit, computed with integer math to avoid depending on awk.
  local divisor=1
  local i
  for (( i = 0; i < idx; i++ )); do
    divisor=$(( divisor * 1024 ))
  done
  local whole=$(( bytes / divisor ))
  local frac=$(( (bytes % divisor) * 10 / divisor ))
  printf '%d,%d %s' "$whole" "$frac" "${units[idx]}"
}

# ui_plural <count> <one> <few> <many> - Russian number agreement,
# e.g. ui_plural 21 ошибка ошибки ошибок -> ошибка.
ui_plural() {
  local count="$1"
  local one="$2"
  local few="$3"
  local many="$4"
  local mod100=$(( count % 100 ))
  local mod10=$(( count % 10 ))
  if (( mod100 >= 11 && mod100 <= 14 )); then
    printf '%s' "$many"
  elif (( mod10 == 1 )); then
    printf '%s' "$one"
  elif (( mod10 >= 2 && mod10 <= 4 )); then
    printf '%s' "$few"
  else
    printf '%s' "$many"
  fi
}

# ui_truncate <text> <max> - shorten from the left, paths keep their tail.
ui_truncate() {
  local text="$1"
  local max="$2"
  if (( max <= 0 )); then
    printf ''
    return 0
  fi
  if (( ${#text} <= max )); then
    printf '%s' "$text"
    return 0
  fi
  if (( max <= 3 )); then
    printf '%s' "${text:0:max}"
    return 0
  fi
  local tail="${text: -$(( max - 3 ))}"
  # In a byte oriented locale the cut can land inside a UTF-8 sequence; drop
  # the dangling continuation bytes so the terminal never sees a broken char.
  local code
  while [[ -n "$tail" ]]; do
    printf -v code '%d' "'${tail:0:1}"
    if (( code >= 128 && code < 192 )); then
      tail="${tail:1}"
    else
      break
    fi
  done
  printf '...%s' "$tail"
}

# ui_progress <current> <total> <text> - single updating progress line.
ui_progress() {
  local current="$1"
  local total="$2"
  local text="$3"
  local prefix width avail
  printf -v prefix '[ %*d / %d ] ' "${#total}" "$current" "$total"
  # Only a terminal needs the line to fit; a redirected log keeps it whole.
  if ui_is_tty; then
    width="$(ui_term_width)"
    avail=$(( width - ${#prefix} - 1 ))
    if (( avail < 12 )); then
      avail=12
    fi
    text="$(ui_truncate "$text" "$avail")"
    printf '\r\033[K%s%s' "$prefix" "$text"
    UI_PROGRESS_ACTIVE=1
  else
    printf '%s%s\n' "$prefix" "$text"
  fi
}

# ui_progress_done - terminate the progress line, if any.
ui_progress_done() {
  if (( UI_PROGRESS_ACTIVE )); then
    if ui_is_tty; then
      printf '\r\033[K'
    fi
    UI_PROGRESS_ACTIVE=0
  fi
}

# ui_status <text> - transient one line status, overwritten on every call.
ui_status() {
  local text="$1"
  local width
  # Only a terminal needs the line to fit; a redirected log keeps it whole.
  if ui_is_tty; then
    width="$(ui_term_width)"
    text="$(ui_truncate "$text" "$(( width - 1 ))")"
    printf '\r\033[K%s' "$text"
    UI_PROGRESS_ACTIVE=1
  else
    printf '%s\n' "$text"
  fi
}

# ui_status_done - close a status line.
ui_status_done() {
  ui_progress_done
}

# _ui_readline [-s] - one line of input, echoed on stdout.
# Standard input comes first, so the wizard can be answered from a pipe or a
# here-document; /dev/tty is the fallback when standard input is exhausted.
_ui_readline() {
  local silent="${1:-}"
  local line=''
  local rc=0
  if [[ "$silent" == "-s" ]]; then
    IFS= read -r -s line || rc=$?
  else
    IFS= read -r line || rc=$?
  fi
  if (( rc != 0 )) && [[ -r /dev/tty ]]; then
    rc=0
    if [[ "$silent" == "-s" ]]; then
      IFS= read -r -s line 2>/dev/null < /dev/tty || rc=$?
    else
      IFS= read -r line 2>/dev/null < /dev/tty || rc=$?
    fi
  fi
  if (( rc != 0 )); then
    return 1
  fi
  line="${line%$'\r'}"
  printf '%s' "$line"
}

# ui_ask <prompt> [default] - free form question, answer on stdout.
ui_ask() {
  local prompt="$1"
  local default="${2:-}"
  local answer
  _ui_clear_progress
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  if ! answer="$(_ui_readline)"; then
    printf '\n' >&2
    return 1
  fi
  if [[ -z "$answer" ]]; then
    answer="$default"
  fi
  printf '%s' "$answer"
}

# ui_ask_secret <prompt> - read without echo, value on stdout.
ui_ask_secret() {
  local prompt="$1"
  local answer
  _ui_clear_progress
  printf '%s: ' "$prompt" >&2
  if ! answer="$(_ui_readline -s)"; then
    printf '\n' >&2
    return 1
  fi
  printf '\n' >&2
  printf '%s' "$answer"
}

# ui_confirm <prompt> - y/N question, default is always "no".
ui_confirm() {
  local prompt="$1"
  local answer
  _ui_clear_progress
  printf '%s [y/N]: ' "$prompt" >&2
  if ! answer="$(_ui_readline)"; then
    printf '\n' >&2
    return 1
  fi
  case "$answer" in
    y|Y|yes|YES|Yes|д|Д|да|ДА|Да) return 0 ;;
    *) return 1 ;;
  esac
}

# ui_ask_word <prompt> <word> - confirmation that requires an exact word.
ui_ask_word() {
  local prompt="$1"
  local word="$2"
  local answer
  _ui_clear_progress
  printf '%s: ' "$prompt" >&2
  if ! answer="$(_ui_readline)"; then
    printf '\n' >&2
    return 1
  fi
  [[ "$answer" == "$word" ]]
}

# ui_menu <title> <default_index> <option...> - numbered menu, index on stdout.
ui_menu() {
  local title="$1"
  local default="$2"
  shift 2
  local options=("$@")
  local count="${#options[@]}"
  local idx answer
  _ui_clear_progress
  printf '%s%s%s\n' "$UI_BOLD" "$title" "$UI_RESET" >&2
  for (( idx = 0; idx < count; idx++ )); do
    printf '  [%d] %s\n' "$(( idx + 1 ))" "${options[idx]}" >&2
  done
  while :; do
    printf 'Выбор [%s]: ' "$default" >&2
    if ! answer="$(_ui_readline)"; then
      printf '\n' >&2
      return 1
    fi
    if [[ -z "$answer" ]]; then
      answer="$default"
    fi
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= count )); then
      printf '%s' "$answer"
      return 0
    fi
    printf 'Введите число от 1 до %d.\n' "$count" >&2
  done
}
