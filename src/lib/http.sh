# shellcheck shell=bash
#
# http.sh - the only place that talks to curl.
#
# Responsibilities:
#   * keep OAuth tokens out of the process table (curl config files, mode 600);
#   * retry transient failures with exponential backoff and jitter;
#   * expose the result through HTTP_STATUS / HTTP_BODY / HTTP_ERROR.

HTTP_STATUS=0
HTTP_BODY=''
HTTP_ERROR=''
HTTP_RETRY_AFTER=''
HTTP_MAX_ATTEMPTS=5
HTTP_CONNECT_TIMEOUT=20
HTTP_MAX_TIME=600
HTTP_TMPDIR=''
HTTP_REQUEST_COUNT=0

# url_encode <string> - percent-encode every byte that is not unreserved.
# Byte oriented on purpose: Cyrillic names are UTF-8 and must be encoded per
# byte, not per character.
url_encode() {
  local raw="$1"
  local LC_ALL=C
  local out=''
  local len=${#raw}
  local idx char code hex
  for (( idx = 0; idx < len; idx++ )); do
    char="${raw:idx:1}"
    case "$char" in
      [a-zA-Z0-9.~_-])
        out+="$char"
        ;;
      *)
        printf -v code '%d' "'$char"
        printf -v hex '%%%02X' "$(( code & 0xFF ))"
        out+="$hex"
        ;;
    esac
  done
  printf '%s' "$out"
}

# http_init - private scratch directory for auth configs and response bodies.
http_init() {
  HTTP_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/volok.XXXXXXXX")"
  chmod 700 "$HTTP_TMPDIR"
  return 0
}

# http_cleanup - shred the auth configs; called from the EXIT trap.
http_cleanup() {
  if [[ -n "$HTTP_TMPDIR" && -d "$HTTP_TMPDIR" ]]; then
    rm -rf -- "$HTTP_TMPDIR"
  fi
  HTTP_TMPDIR=''
  return 0
}

# http_set_auth <slot> <token> - store the Authorization header in a file.
# The token is never passed as an argv element, so `ps` cannot see it.
http_set_auth() {
  local slot="$1"
  local token="$2"
  local config="$HTTP_TMPDIR/auth.$slot"
  : > "$config"
  chmod 600 "$config"
  printf 'header = "Authorization: OAuth %s"\n' "$token" >> "$config"
  log_register_secret "$token"
  return 0
}

# http_has_auth <slot> - whether a token was configured for this slot.
http_has_auth() {
  [[ -n "$HTTP_TMPDIR" && -f "$HTTP_TMPDIR/auth.$1" ]]
}

# _http_is_retriable_status <code>
_http_is_retriable_status() {
  case "$1" in
    429|500|502|503|504) return 0 ;;
    *) return 1 ;;
  esac
}

# _http_is_retriable_curl <exit_code> - network level failures only.
_http_is_retriable_curl() {
  case "$1" in
    # 6 dns, 7 connect, 16 http/2, 18 partial, 28 timeout, 35/52/55/56 tls+io,
    # 92 stream error.
    5|6|7|16|18|28|35|52|55|56|92) return 0 ;;
    *) return 1 ;;
  esac
}

# _http_backoff <attempt> - 1,2,4,8,16 seconds plus up to one second of jitter.
_http_backoff() {
  local attempt="$1"
  local base=1
  local idx
  for (( idx = 1; idx < attempt; idx++ )); do
    base=$(( base * 2 ))
  done
  if (( base > 16 )); then
    base=16
  fi
  printf '%d.%03d' "$base" "$(( RANDOM % 1000 ))"
}

# _http_retry_after <headers_file> - seconds requested by the server, if any.
_http_retry_after() {
  local headers="$1"
  local line value
  line="$(grep -i '^retry-after:' -- "$headers" 2>/dev/null | tail -n 1 || printf '')"
  if [[ -z "$line" ]]; then
    printf ''
    return 0
  fi
  value="${line#*:}"
  value="${value//$'\r'/}"
  value="${value// /}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  else
    printf ''
  fi
  return 0
}

# http_request <slot> <method> <url> [curl args...]
# Sets HTTP_STATUS (0 on network failure), HTTP_BODY and HTTP_ERROR.
# Returns 0 when the status is 2xx, 1 otherwise.
http_request() {
  local slot="$1"
  local method="$2"
  local url="$3"
  shift 3

  # Scratch files are per process: a fallback copy runs a download and an
  # upload in parallel, and they must not overwrite each other responses.
  local body="$HTTP_TMPDIR/body.$BASHPID"
  local headers="$HTTP_TMPDIR/headers.$BASHPID"
  local stderr="$HTTP_TMPDIR/stderr.$BASHPID"
  local args=()
  if [[ -n "$slot" ]] && http_has_auth "$slot"; then
    args+=(--config "$HTTP_TMPDIR/auth.$slot")
  fi
  args+=(
    --silent --show-error --location
    --request "$method"
    --connect-timeout "$HTTP_CONNECT_TIMEOUT"
    --max-time "$HTTP_MAX_TIME"
    --dump-header "$headers"
    --output "$body"
    --write-out '%{http_code}'
  )

  local attempt=1
  local code rc delay
  while :; do
    HTTP_STATUS=0
    HTTP_BODY=''
    HTTP_ERROR=''
    HTTP_RETRY_AFTER=''
    : > "$headers"
    : > "$body"
    : > "$stderr"
    HTTP_REQUEST_COUNT=$(( HTTP_REQUEST_COUNT + 1 ))

    rc=0
    code="$(curl "${args[@]}" "$@" -- "$url" 2>"$stderr")" || rc=$?

    if (( rc == 0 )); then
      HTTP_STATUS="$code"
      HTTP_BODY="$(cat -- "$body")"
      HTTP_RETRY_AFTER="$(_http_retry_after "$headers")"
      if (( HTTP_STATUS >= 200 && HTTP_STATUS < 300 )); then
        log_debug "http $method $url -> $HTTP_STATUS"
        return 0
      fi
      HTTP_ERROR="$(http_api_message "$HTTP_BODY")"
      if ! _http_is_retriable_status "$HTTP_STATUS" || (( attempt >= HTTP_MAX_ATTEMPTS )); then
        log_warn "http $method $url -> $HTTP_STATUS ${HTTP_ERROR}"
        return 1
      fi
      delay="$HTTP_RETRY_AFTER"
      if [[ -z "$delay" ]]; then
        delay="$(_http_backoff "$attempt")"
      fi
    else
      HTTP_STATUS=0
      HTTP_ERROR="сетевая ошибка curl ($rc): $(head -n 1 -- "$stderr" 2>/dev/null || printf '')"
      if ! _http_is_retriable_curl "$rc" || (( attempt >= HTTP_MAX_ATTEMPTS )); then
        log_warn "http $method $url -> curl rc=$rc"
        return 1
      fi
      delay="$(_http_backoff "$attempt")"
    fi

    log_warn "http $method $url: попытка $attempt из $HTTP_MAX_ATTEMPTS, повтор через ${delay}s (${HTTP_STATUS:-net})"
    sleep "$delay"
    attempt=$(( attempt + 1 ))
  done
}

# http_api_message <json> - human readable error text from an API reply.
http_api_message() {
  local payload="$1"
  local message=''
  if [[ -n "$payload" ]]; then
    message="$(printf '%s' "$payload" \
      | jq -r 'if type == "object" then (.message // .description // .error // empty) else empty end' \
      2>/dev/null || printf '')"
  fi
  if [[ -z "$message" ]]; then
    message="${payload:0:200}"
  fi
  message="${message//$'\n'/ }"
  message="${message//$'\t'/ }"
  printf '%s' "$message"
}

# http_json <json> <jq filter> - read one value, empty string when absent.
http_json() {
  local payload="$1"
  local filter="$2"
  printf '%s' "$payload" | jq -r "$filter // empty" 2>/dev/null || printf ''
}

# http_stream_download <slot> <url> - response body straight to stdout.
# Used only by the opt-in traffic consuming fallback.
http_stream_download() {
  local slot="$1"
  local url="$2"
  local args=()
  if [[ -n "$slot" ]] && http_has_auth "$slot"; then
    args+=(--config "$HTTP_TMPDIR/auth.$slot")
  fi
  args+=(
    --silent --show-error --location --fail
    --connect-timeout "$HTTP_CONNECT_TIMEOUT"
    --speed-limit 1024 --speed-time 120
  )
  curl "${args[@]}" -- "$url"
}

# http_stream_upload <url> - stdin is PUT to a pre-signed upload href.
http_stream_upload() {
  local url="$1"
  local code rc=0
  code="$(curl --silent --show-error \
    --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
    --speed-limit 1024 --speed-time 120 \
    --request PUT --upload-file - \
    --output /dev/null --write-out '%{http_code}' -- "$url")" || rc=$?
  if (( rc != 0 )); then
    HTTP_STATUS=0
    HTTP_ERROR="сетевая ошибка curl ($rc) при загрузке"
    return 1
  fi
  HTTP_STATUS="$code"
  HTTP_BODY=''
  HTTP_ERROR=''
  if (( HTTP_STATUS >= 200 && HTTP_STATUS < 300 )); then
    return 0
  fi
  HTTP_ERROR="загрузка вернула код $HTTP_STATUS"
  return 1
}
