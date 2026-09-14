# shellcheck shell=bash
#
# provider.sh - the storage provider contract and its dispatcher.
#
# A provider is a plain bash file in src/providers/ that defines functions
# named <provider>_<operation>. Adding Google Drive, OneDrive, Dropbox or S3
# means dropping a new file here and listing its name in PROVIDER_KNOWN -
# no change anywhere in the core is required.
#
# An "account" is addressed by a slot name (src, dst). The slot carries both
# the provider name and the HTTP credentials, so a single provider file can
# serve two accounts of the same service at once.
#
# Required operations. Every one of them takes the slot as its first argument.
#
#   <p>_auth_check   <slot>
#       Validates the credentials. Prints the account login on stdout.
#
#   <p>_quota        <slot>
#       Prints "total<TAB>used<TAB>available" in bytes.
#
#   <p>_list_dir     <slot> <path>
#       Lists one directory, following pagination internally.
#       Prints "type<TAB>path<TAB>size" per entry, type is dir or file,
#       path is absolute, fields are escaped the way jq's @tsv escapes them.
#
#   <p>_mkdir        <slot> <path>
#       Creates a directory. Idempotent: an existing directory is success.
#
#   <p>_server_copy  <src_slot> <src_path> <dst_slot> <dst_path>
#       Copies on the provider side, without moving bytes through this machine.
#
#   <p>_download     <slot> <path>
#       Streams the file content to stdout.
#
#   <p>_upload       <slot> <path> <overwrite>
#       Streams stdin into the file at path. overwrite is 0 or 1.
#
#   <p>_delete       <slot> <path> [permanently]
#       Deletes a resource, to the trash unless permanently is 1.
#
# Optional operations, called only when the provider defines them:
#
#   <p>_exists       <slot> <path>      exit code 0 when the resource exists
#   <p>_normpath     <slot> <path>      provider specific path normalisation
#   <p>_cleanup      <slot> <path>      undo a temporary share left behind
#
# Every operation reports its failure through two globals, so the caller can
# apply the retry and conflict policy without parsing text:
#
#   PROVIDER_STATUS    HTTP status code, or 0 for a network level failure
#   PROVIDER_MESSAGE   human readable message from the service

PROVIDER_STATUS=0
PROVIDER_MESSAGE=''

PROVIDER_KNOWN=(yandex)

PROVIDER_REQUIRED_OPS=(
  auth_check
  quota
  list_dir
  mkdir
  server_copy
  download
  upload
  delete
)

# provider_reset_error - clear the per-operation error globals.
provider_reset_error() {
  PROVIDER_STATUS=0
  PROVIDER_MESSAGE=''
  return 0
}

# provider_fail <status> <message> - record a failure and return 1.
provider_fail() {
  PROVIDER_STATUS="${1:-0}"
  PROVIDER_MESSAGE="${2:-}"
  return 1
}

# provider_is_known <name>
provider_is_known() {
  local name="$1"
  local known
  for known in "${PROVIDER_KNOWN[@]}"; do
    if [[ "$known" == "$name" ]]; then
      return 0
    fi
  done
  return 1
}

# provider_check_contract <name> - every required operation must exist.
provider_check_contract() {
  local name="$1"
  local op missing=()
  for op in "${PROVIDER_REQUIRED_OPS[@]}"; do
    if ! declare -F "${name}_${op}" >/dev/null 2>&1; then
      missing+=("${name}_${op}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    PROVIDER_MESSAGE="провайдер $name не реализует: ${missing[*]}"
    return 1
  fi
  return 0
}

# provider_register <slot> <name> - bind an account slot to a provider.
provider_register() {
  local slot="$1"
  local name="$2"
  if [[ ! "$slot" =~ ^[a-z][a-z0-9_]*$ ]]; then
    PROVIDER_MESSAGE="недопустимое имя слота: $slot"
    return 1
  fi
  if ! provider_is_known "$name"; then
    PROVIDER_MESSAGE="неизвестный провайдер: $name"
    return 1
  fi
  provider_check_contract "$name" || return 1
  printf -v "PROVIDER_OF_${slot}" '%s' "$name"
  return 0
}

# provider_of <slot> - provider name bound to this slot.
provider_of() {
  local var="PROVIDER_OF_${1}"
  printf '%s' "${!var:-}"
}

# provider_call <slot> <operation> [args...] - indirect call, no eval.
provider_call() {
  local slot="$1"
  local op="$2"
  shift 2
  local var="PROVIDER_OF_${slot}"
  local name="${!var:-}"
  if [[ -z "$name" ]]; then
    provider_fail 0 "слот $slot не привязан к провайдеру"
    return 1
  fi
  local fn="${name}_${op}"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    provider_fail 0 "провайдер $name не умеет $op"
    return 1
  fi
  provider_reset_error
  "$fn" "$slot" "$@"
}

# provider_has <slot> <operation> - whether an optional operation exists.
provider_has() {
  local name
  name="$(provider_of "$1")"
  if [[ -z "$name" ]]; then
    return 1
  fi
  declare -F "${name}_${2}" >/dev/null 2>&1
}

# provider_normalize_path <slot> <path> - absolute path in provider form.
# Providers may override the generic rules with a <p>_normpath operation.
provider_normalize_path() {
  local slot="$1"
  local path="$2"
  if provider_has "$slot" normpath; then
    provider_call "$slot" normpath "$path"
    return $?
  fi
  if [[ -z "$path" ]]; then
    path='/'
  fi
  if [[ "${path:0:1}" != '/' ]]; then
    path="/$path"
  fi
  while [[ "${#path}" -gt 1 && "${path: -1}" == '/' ]]; do
    path="${path%/}"
  done
  printf '%s' "$path"
  return 0
}

# provider_cleanup_shares - drop every temporary share recorded for this run.
# Called from the EXIT trap: user data must never stay reachable by a link.
provider_cleanup_shares() {
  local lines=()
  local line slot path_escaped path left=0
  # Snapshot first: the providers rewrite the list file while we work on it.
  mapfile -t lines < <(state_published_each)
  for line in ${lines[@]+"${lines[@]}"}; do
    if [[ -z "$line" ]]; then
      continue
    fi
    slot="${line%%$'\t'*}"
    path_escaped="${line#*$'\t'}"
    path="$(tsv_unescape "$path_escaped")"
    if ! provider_has "$slot" cleanup; then
      continue
    fi
    if provider_call "$slot" cleanup "$path"; then
      log_info "публикация снята: $path"
    else
      left=$(( left + 1 ))
      log_error "не удалось снять публикацию: $path ($PROVIDER_STATUS $PROVIDER_MESSAGE)"
      ui_err "Не удалось снять публикацию с «$path». Снимите её вручную на Яндекс Диске."
    fi
  done
  if (( left == 0 )) && [[ -n "$STATE_PUBLISHED" ]]; then
    : > "$STATE_PUBLISHED"
  fi
  return 0
}
