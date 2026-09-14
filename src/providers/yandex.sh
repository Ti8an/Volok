# shellcheck shell=bash
#
# yandex.sh - Yandex Disk provider.
#
# Server side copy works through a temporary public link:
#   1. publish the source resource            PUT  /resources/publish
#   2. read its public_key                    GET  /resources
#   3. save it into the target account        POST /public/resources/save-to-disk
#   4. poll the returned operation            GET  <href>
#   5. unpublish the source resource          PUT  /resources/unpublish
#
# Step 5 is not optional: until it runs, the file is reachable by anyone who
# holds the link. Every publish is recorded in the run state so that the EXIT
# trap can finish the job even when the process dies in the middle.

YANDEX_API='https://cloud-api.yandex.net/v1/disk'
YANDEX_PAGE_SIZE=200
YANDEX_OP_TIMEOUT=3600
YANDEX_LIST_FIELDS='_embedded.total,_embedded.items.name,_embedded.items.path,_embedded.items.type,_embedded.items.size'

# yandex_url <endpoint> [key value ...] - build an encoded API URL.
yandex_url() {
  local url="$YANDEX_API"
  if [[ -n "${1:-}" ]]; then
    url="$url/$1"
  fi
  shift || true
  local sep='?' key value
  while (( $# >= 2 )); do
    key="$1"
    value="$2"
    shift 2
    url="${url}${sep}${key}=$(url_encode "$value")"
    sep='&'
  done
  printf '%s' "$url"
}

# yandex_norm_path <path> - absolute, no trailing slash, no disk: prefix.
yandex_norm_path() {
  local path="$1"
  path="${path#disk:}"
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
}

# yandex_normpath <slot> <path> - contract wrapper around yandex_norm_path.
yandex_normpath() {
  yandex_norm_path "$2"
}

# _yandex_fail_from_http - copy the last HTTP outcome into the provider error.
_yandex_fail_from_http() {
  PROVIDER_STATUS="$HTTP_STATUS"
  PROVIDER_MESSAGE="$HTTP_ERROR"
  return 1
}

# yandex_auth_check <slot> - prints the account login.
yandex_auth_check() {
  local slot="$1"
  if ! http_request "$slot" GET "$(yandex_url '')"; then
    _yandex_fail_from_http
    return 1
  fi
  local login
  login="$(http_json "$HTTP_BODY" '.user.login')"
  if [[ -z "$login" ]]; then
    login="$(http_json "$HTTP_BODY" '.user.display_name')"
  fi
  if [[ -z "$login" ]]; then
    login='неизвестен'
  fi
  printf '%s' "$login"
  return 0
}

# yandex_quota <slot> - prints "total<TAB>used<TAB>available" in bytes.
yandex_quota() {
  local slot="$1"
  if ! http_request "$slot" GET "$(yandex_url '')"; then
    _yandex_fail_from_http
    return 1
  fi
  local total used available
  total="$(http_json "$HTTP_BODY" '.total_space')"
  used="$(http_json "$HTTP_BODY" '.used_space')"
  total="${total:-0}"
  used="${used:-0}"
  available=$(( total - used ))
  if (( available < 0 )); then
    available=0
  fi
  printf '%s\t%s\t%s' "$total" "$used" "$available"
  return 0
}

# yandex_list_dir <slot> <path> - one directory, all pages.
# Output: type<TAB>path<TAB>size, escaped the way jq @tsv escapes.
yandex_list_dir() {
  local slot="$1"
  local path
  path="$(yandex_norm_path "$2")"
  local offset=0
  local total=0
  local url page_total
  while :; do
    url="$(yandex_url 'resources' \
      path "$path" \
      limit "$YANDEX_PAGE_SIZE" \
      offset "$offset" \
      fields "$YANDEX_LIST_FIELDS" \
      sort 'name')"
    if ! http_request "$slot" GET "$url"; then
      _yandex_fail_from_http
      return 1
    fi
    page_total="$(http_json "$HTTP_BODY" '._embedded.total')"
    if [[ -n "$page_total" ]]; then
      total="$page_total"
    fi
    if ! printf '%s' "$HTTP_BODY" | jq -r '
        ._embedded.items // []
        | .[]
        | [.type, (.path | sub("^disk:"; "")), (.size // 0)]
        | @tsv'; then
      provider_fail "$HTTP_STATUS" 'не удалось разобрать ответ API (jq)'
      return 1
    fi
    offset=$(( offset + YANDEX_PAGE_SIZE ))
    if (( offset >= total )); then
      break
    fi
  done
  return 0
}

# yandex_exists <slot> <path> - exit code only.
yandex_exists() {
  local slot="$1"
  local path
  path="$(yandex_norm_path "$2")"
  if http_request "$slot" GET "$(yandex_url 'resources' path "$path" fields 'type')"; then
    return 0
  fi
  if [[ "$HTTP_STATUS" == "404" ]]; then
    return 1
  fi
  _yandex_fail_from_http
  return 1
}

# yandex_mkdir <slot> <path> - idempotent directory creation.
yandex_mkdir() {
  local slot="$1"
  local path
  path="$(yandex_norm_path "$2")"
  if [[ "$path" == '/' ]]; then
    return 0
  fi
  if (( VOLOK_DRY_RUN )); then
    log_info "dry-run: mkdir $path"
    return 0
  fi
  if http_request "$slot" PUT "$(yandex_url 'resources' path "$path")"; then
    return 0
  fi
  if [[ "$HTTP_STATUS" == "409" ]]; then
    # Already there, which is exactly what we wanted.
    return 0
  fi
  _yandex_fail_from_http
  return 1
}

# yandex_publish <slot> <path> - share the resource and remember it.
yandex_publish() {
  local slot="$1"
  local path
  path="$(yandex_norm_path "$2")"
  if ! http_request "$slot" PUT "$(yandex_url 'resources/publish' path "$path")"; then
    _yandex_fail_from_http
    return 1
  fi
  state_publish_add "$slot" "$path"
  log_debug "published $path"
  return 0
}

# yandex_unpublish <slot> <path> - stop sharing, then forget it.
yandex_unpublish() {
  local slot="$1"
  local path
  path="$(yandex_norm_path "$2")"
  local saved_status="$HTTP_STATUS"
  local saved_error="$HTTP_ERROR"
  local rc=0
  if ! http_request "$slot" PUT "$(yandex_url 'resources/unpublish' path "$path")"; then
    # A resource that is already gone cannot stay published either.
    if [[ "$HTTP_STATUS" != "404" ]]; then
      rc=1
    fi
  fi
  if (( rc == 0 )); then
    state_publish_del "$slot" "$path"
    log_debug "unpublished $path"
  fi
  HTTP_STATUS="$saved_status"
  HTTP_ERROR="$saved_error"
  return "$rc"
}

# yandex_cleanup <slot> <path> - EXIT trap hook, see provider_cleanup_shares.
yandex_cleanup() {
  local slot="$1"
  local path="$2"
  if ! yandex_unpublish "$slot" "$path"; then
    PROVIDER_STATUS="$HTTP_STATUS"
    PROVIDER_MESSAGE="$HTTP_ERROR"
    return 1
  fi
  return 0
}

# yandex_public_key <slot> <path> - public_key of a published resource.
yandex_public_key() {
  local slot="$1"
  local path
  path="$(yandex_norm_path "$2")"
  if ! http_request "$slot" GET "$(yandex_url 'resources' path "$path" fields 'public_key')"; then
    _yandex_fail_from_http
    return 1
  fi
  local key
  key="$(http_json "$HTTP_BODY" '.public_key')"
  if [[ -z "$key" ]]; then
    provider_fail "$HTTP_STATUS" 'API не вернул public_key'
    return 1
  fi
  printf '%s' "$key"
  return 0
}

# yandex_wait_operation <slot> <href> - poll an async operation to the end.
yandex_wait_operation() {
  local slot="$1"
  local href="$2"
  local waited=0
  local delay=1
  local status
  while :; do
    if ! http_request "$slot" GET "$href"; then
      _yandex_fail_from_http
      return 1
    fi
    status="$(http_json "$HTTP_BODY" '.status')"
    case "$status" in
      success)
        return 0
        ;;
      failure|failed)
        provider_fail 500 'операция на стороне Яндекса завершилась ошибкой'
        return 1
        ;;
      in-progress|'')
        : # keep waiting
        ;;
      *)
        provider_fail 500 "неизвестный статус операции: $status"
        return 1
        ;;
    esac
    if (( waited >= YANDEX_OP_TIMEOUT )); then
      provider_fail 0 "операция не завершилась за ${YANDEX_OP_TIMEOUT} с"
      return 1
    fi
    sleep "$delay"
    waited=$(( waited + delay ))
    if (( delay < 10 )); then
      delay=$(( delay * 2 ))
    fi
  done
}

# yandex_server_copy <src_slot> <src_path> <dst_slot> <dst_path> [inner_path]
# Copies without moving a single byte through this machine.
yandex_server_copy() {
  local src_slot="$1"
  local src_path
  src_path="$(yandex_norm_path "$2")"
  local dst_slot="$3"
  local dst_path
  dst_path="$(yandex_norm_path "$4")"
  local inner="${5:-}"

  local name="${dst_path##*/}"
  local parent="${dst_path%/*}"
  if [[ -z "$parent" ]]; then
    parent='/'
  fi

  if (( VOLOK_DRY_RUN )); then
    log_info "dry-run: server_copy $src_path -> $dst_path"
    return 0
  fi

  if ! yandex_publish "$src_slot" "$src_path"; then
    return 1
  fi

  local public_key='' rc=0
  public_key="$(yandex_public_key "$src_slot" "$src_path")" || rc=$?
  if (( rc != 0 )); then
    yandex_unpublish "$src_slot" "$src_path" || true
    provider_fail "$HTTP_STATUS" "$HTTP_ERROR"
    return 1
  fi

  local args=(public_key "$public_key" name "$name" save_path "$parent" force_async 'true')
  if [[ -n "$inner" ]]; then
    args+=(path "$inner")
  fi

  local url href
  url="$(yandex_url 'public/resources/save-to-disk' "${args[@]}")"
  local status='' message=''
  if http_request "$dst_slot" POST "$url"; then
    if [[ "$HTTP_STATUS" == "202" ]]; then
      href="$(http_json "$HTTP_BODY" '.href')"
      if [[ -z "$href" ]]; then
        status=0
        message='API не вернул href операции'
        rc=1
      elif ! yandex_wait_operation "$dst_slot" "$href"; then
        status="$PROVIDER_STATUS"
        message="$PROVIDER_MESSAGE"
        rc=1
      fi
    fi
  else
    status="$HTTP_STATUS"
    message="$HTTP_ERROR"
    rc=1
  fi

  # Whatever happened above, the share must go away now.
  yandex_unpublish "$src_slot" "$src_path" || true

  if (( rc != 0 )); then
    provider_fail "$status" "$message"
    return 1
  fi
  return 0
}

# yandex_download <slot> <path> - file content to stdout.
yandex_download() {
  local slot="$1"
  local path
  path="$(yandex_norm_path "$2")"
  if ! http_request "$slot" GET "$(yandex_url 'resources/download' path "$path")"; then
    _yandex_fail_from_http
    return 1
  fi
  local href
  href="$(http_json "$HTTP_BODY" '.href')"
  if [[ -z "$href" ]]; then
    provider_fail "$HTTP_STATUS" 'API не вернул ссылку на скачивание'
    return 1
  fi
  if ! http_stream_download "$slot" "$href"; then
    provider_fail 0 'обрыв при скачивании'
    return 1
  fi
  return 0
}

# yandex_upload <slot> <path> <overwrite> - stdin into the file at path.
yandex_upload() {
  local slot="$1"
  local path
  path="$(yandex_norm_path "$2")"
  local overwrite='false'
  if [[ "${3:-0}" == "1" ]]; then
    overwrite='true'
  fi
  if (( VOLOK_DRY_RUN )); then
    log_info "dry-run: upload $path"
    cat > /dev/null
    return 0
  fi
  if ! http_request "$slot" GET \
      "$(yandex_url 'resources/upload' path "$path" overwrite "$overwrite")"; then
    _yandex_fail_from_http
    return 1
  fi
  local href
  href="$(http_json "$HTTP_BODY" '.href')"
  if [[ -z "$href" ]]; then
    provider_fail "$HTTP_STATUS" 'API не вернул ссылку на загрузку'
    return 1
  fi
  if ! http_stream_upload "$href"; then
    provider_fail "$HTTP_STATUS" "$HTTP_ERROR"
    return 1
  fi
  return 0
}

# yandex_delete <slot> <path> [permanently] - trash by default.
yandex_delete() {
  local slot="$1"
  local path
  path="$(yandex_norm_path "$2")"
  local permanently='false'
  if [[ "${3:-0}" == "1" ]]; then
    permanently='true'
  fi
  if [[ "$path" == '/' ]]; then
    provider_fail 0 'удаление корня Диска запрещено'
    return 1
  fi
  if (( VOLOK_DRY_RUN )); then
    log_info "dry-run: delete $path"
    return 0
  fi
  if ! http_request "$slot" DELETE \
      "$(yandex_url 'resources' path "$path" permanently "$permanently")"; then
    _yandex_fail_from_http
    return 1
  fi
  if [[ "$HTTP_STATUS" == "202" ]]; then
    local href
    href="$(http_json "$HTTP_BODY" '.href')"
    if [[ -n "$href" ]] && ! yandex_wait_operation "$slot" "$href"; then
      return 1
    fi
  fi
  return 0
}
