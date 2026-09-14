# shellcheck shell=bash
#
# wizard.sh - the interactive scenario that prepares a copy run.
#
# Nothing here changes anything on either Disk: it only collects credentials,
# validates them, measures the source tree and asks for a confirmation.

WIZARD_LOGIN_SRC=''
WIZARD_LOGIN_DST=''
WIZARD_AVAIL_DST=0

# wizard_config_path - where the optional config file lives.
wizard_config_path() {
  if [[ -n "${VOLOK_CONFIG:-}" ]]; then
    printf '%s' "$VOLOK_CONFIG"
    return 0
  fi
  printf '%s/volok/config' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# wizard_load_config - read a small key=value file, no sourcing, no eval.
# Only known keys are accepted, and a value already set by a flag wins.
wizard_load_config() {
  local file
  file="$(wizard_config_path)"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  local perms rest
  perms="$(ls -ld -- "$file" 2>/dev/null | cut -c1-10 || printf '')"
  rest="${perms:4:6}"
  if [[ "$rest" == *r* || "$rest" == *w* ]]; then
    ui_warn "Файл $file доступен не только вам. Выполните: chmod 600 «$file»"
  fi
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ -z "$line" || "${line:0:1}" == '#' || "$line" != *=* ]]; then
      continue
    fi
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      value="${value:1:${#value}-2}"
    fi
    case "$key" in
      YANDEX_TOKEN_SRC) if [[ -z "$VOLOK_TOKEN_SRC" ]]; then VOLOK_TOKEN_SRC="$value"; fi ;;
      YANDEX_TOKEN_DST) if [[ -z "$VOLOK_TOKEN_DST" ]]; then VOLOK_TOKEN_DST="$value"; fi ;;
      VOLOK_SRC_PATH)   if [[ -z "$VOLOK_SRC_PATH" ]]; then VOLOK_SRC_PATH="$value"; fi ;;
      VOLOK_DST_PATH)   if [[ -z "$VOLOK_DST_PATH" ]]; then VOLOK_DST_PATH="$value"; fi ;;
      VOLOK_ON_CONFLICT) if [[ -z "$VOLOK_ON_CONFLICT" ]]; then VOLOK_ON_CONFLICT="$value"; fi ;;
      VOLOK_LOG_LEVEL)  if [[ -z "$VOLOK_LOG_LEVEL_OPT" ]]; then VOLOK_LOG_LEVEL_OPT="$value"; fi ;;
      VOLOK_ALLOW_FALLBACK)
        if [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" ]]; then
          VOLOK_ALLOW_FALLBACK=1
        fi
        ;;
      *)
        ui_warn "Неизвестный ключ в конфиге: $key"
        ;;
    esac
  done < "$file"
  return 0
}

# wizard_get_token <slot> <env_name> <prompt> - env, then config, then ask.
wizard_get_token() {
  local slot="$1"
  local env_name="$2"
  local prompt="$3"
  local token=''
  local from_env="${!env_name:-}"

  case "$slot" in
    src) token="$VOLOK_TOKEN_SRC" ;;
    dst) token="$VOLOK_TOKEN_DST" ;;
  esac
  if [[ -n "$from_env" ]]; then
    token="$from_env"
    ui_hint "Токен взят из переменной окружения $env_name."
  elif [[ -n "$token" ]]; then
    ui_hint "Токен взят из файла конфигурации ($env_name)."
  else
    if ! token="$(ui_ask_secret "$prompt")"; then
      volok_die "$EX_ABORT" 'Ввод прерван.'
    fi
  fi
  if [[ -z "$token" ]]; then
    volok_die "$EX_AUTH" "Пустой токен для $slot."
  fi
  case "$slot" in
    src) VOLOK_TOKEN_SRC="$token" ;;
    dst) VOLOK_TOKEN_DST="$token" ;;
  esac
  http_set_auth "$slot" "$token"
  return 0
}

# wizard_check_access <slot> - login and free space, or a hard stop.
wizard_check_access() {
  local slot="$1"
  local label="$2"
  local login quota total used available
  if ! login="$(provider_call "$slot" auth_check)"; then
    ui_err "$label: доступ не получен ($PROVIDER_STATUS $PROVIDER_MESSAGE)"
    volok_die "$EX_AUTH" 'Проверьте токен и его права: cloud_api:disk.read, cloud_api:disk.write.'
  fi
  if ! quota="$(provider_call "$slot" quota)"; then
    ui_err "$label: не удалось узнать квоту ($PROVIDER_STATUS $PROVIDER_MESSAGE)"
    volok_die "$EX_AUTH" 'Проверьте права токена.'
  fi
  IFS=$'\t' read -r total used available <<< "$quota"
  ui_ok "$label: $login, свободно $(ui_human_size "$available") из $(ui_human_size "$total")"
  log_info "$slot: login=$login total=$total used=$used available=$available"
  case "$slot" in
    src) WIZARD_LOGIN_SRC="$login" ;;
    dst) WIZARD_LOGIN_DST="$login"; WIZARD_AVAIL_DST="$available" ;;
  esac
  return 0
}

# wizard_ask_src_path - existing source directory.
wizard_ask_src_path() {
  local path
  while :; do
    if [[ -n "$VOLOK_SRC_PATH" ]]; then
      path="$VOLOK_SRC_PATH"
    elif ! path="$(ui_ask 'Исходная папка' '/')"; then
      volok_die "$EX_ABORT" 'Ввод прерван.'
    fi
    if provider_call src exists "$path"; then
      VOLOK_SRC_PATH="$(provider_normalize_path src "$path")"
      return 0
    fi
    if [[ "$PROVIDER_STATUS" != "0" ]]; then
      volok_die "$EX_ENV" "Не удалось проверить «$path»: $PROVIDER_STATUS $PROVIDER_MESSAGE"
    fi
    ui_err "Папка «$path» не найдена на исходном Диске."
    if [[ -n "$VOLOK_SRC_PATH" ]]; then
      volok_die "$EX_ENV" 'Исходная папка не существует.'
    fi
  done
}

# wizard_ask_dst_path - target directory, offered for creation when missing.
wizard_ask_dst_path() {
  local path
  while :; do
    if [[ -n "$VOLOK_DST_PATH" ]]; then
      path="$VOLOK_DST_PATH"
    elif ! path="$(ui_ask 'Целевая папка' '/')"; then
      volok_die "$EX_ABORT" 'Ввод прерван.'
    fi
    path="$(provider_normalize_path dst "$path")"
    if provider_call dst exists "$path"; then
      VOLOK_DST_PATH="$path"
      return 0
    fi
    if [[ "$PROVIDER_STATUS" != "0" ]]; then
      volok_die "$EX_ENV" "Не удалось проверить «$path»: $PROVIDER_STATUS $PROVIDER_MESSAGE"
    fi
    ui_warn "Папка «$path» на целевом Диске не существует."
    if (( VOLOK_ASSUME_YES )) || ui_confirm "Создать её?"; then
      if (( VOLOK_DRY_RUN )); then
        ui_hint 'Пробный запуск: папка не создаётся.'
        VOLOK_DST_PATH="$path"
        return 0
      fi
      if provider_call dst mkdir "$path"; then
        ui_ok "Папка создана: $path"
        VOLOK_DST_PATH="$path"
        return 0
      fi
      volok_die "$EX_ENV" "Не удалось создать «$path»: $PROVIDER_STATUS $PROVIDER_MESSAGE"
    fi
    if [[ -n "$VOLOK_DST_PATH" ]]; then
      volok_die "$EX_ABORT" 'Целевая папка не выбрана.'
    fi
  done
}

# wizard_check_same_account - both tokens pointing at one Disk is almost always
# a mistake, and it is the one case where a copy can eat its own tail.
wizard_check_same_account() {
  if [[ "$WIZARD_LOGIN_SRC" != "$WIZARD_LOGIN_DST" ]]; then
    return 0
  fi
  ui_warn "Оба токена принадлежат одному аккаунту: $WIZARD_LOGIN_SRC."
  ui_hint 'Копирование пойдёт внутри одного Диска, а не между двумя аккаунтами.'
  local src="${VOLOK_SRC_PATH%/}/"
  local dst="${VOLOK_DST_PATH%/}/"
  if [[ "$dst" == "$src"* ]]; then
    volok_die "$EX_ENV" 'Целевая папка находится внутри исходной: копирование зациклится.'
  fi
  if (( VOLOK_ASSUME_YES )); then
    return 0
  fi
  if ! ui_confirm 'Продолжить?'; then
    volok_die "$EX_ABORT" 'Отменено пользователем.'
  fi
  return 0
}

# wizard_scan - measure the source tree, or reuse the scan of a resumed run.
wizard_scan() {
  if [[ -n "$VOLOK_RESUME_ID" && -s "$STATE_SCAN_FILES" ]]; then
    copy_scan_load
    ui_info "Использую результаты сканирования запуска $VOLOK_RESUME_ID."
  else
    ui_info 'Считаю объём исходной папки...'
    if ! copy_scan src "$VOLOK_SRC_PATH"; then
      volok_die "$EX_ENV" 'Сканирование не завершилось.'
    fi
  fi
  ui_ok "Найдено: папок $COPY_TOTAL_DIRS, файлов $COPY_TOTAL_FILES, объём $(ui_human_size "$COPY_TOTAL_BYTES")"
  if (( COPY_TOTAL_FILES == 0 && COPY_TOTAL_DIRS == 0 )); then
    ui_warn 'Копировать нечего: исходная папка пуста.'
  fi
  if (( COPY_TOTAL_BYTES > WIZARD_AVAIL_DST )); then
    ui_err "На целевом Диске свободно $(ui_human_size "$WIZARD_AVAIL_DST"), нужно $(ui_human_size "$COPY_TOTAL_BYTES")."
    volok_die "$EX_ENV" 'Не хватает места на приёмнике, копирование не начато.'
  fi
  return 0
}

# wizard_summary - the last screen before anything is written.
wizard_summary() {
  ui_hr
  ui_say "Откуда: $WIZARD_LOGIN_SRC : $VOLOK_SRC_PATH"
  ui_say "Куда:   $WIZARD_LOGIN_DST : $VOLOK_DST_PATH"
  ui_say "Объём:  файлов $COPY_TOTAL_FILES, папок $COPY_TOTAL_DIRS, $(ui_human_size "$COPY_TOTAL_BYTES")"
  ui_say "При конфликте имён: $VOLOK_ON_CONFLICT"
  if (( VOLOK_ALLOW_FALLBACK )); then
    ui_say 'Резервный режим: разрешён (расходует ваш трафик)'
  fi
  if (( VOLOK_DRY_RUN )); then
    ui_say 'Режим: пробный запуск, изменяющих запросов не будет'
  fi
  ui_say "Журнал запуска: $STATE_RUN_DIR"
  ui_hr
  ui_hint 'На время копирования каждый файл ненадолго становится доступен по публичной ссылке.'
  if (( VOLOK_ASSUME_YES )); then
    return 0
  fi
  if ! ui_confirm 'Начинать копирование?'; then
    volok_die "$EX_ABORT" 'Отменено пользователем.'
  fi
  return 0
}

# wizard_save_conf - everything --resume needs later.
wizard_save_conf() {
  state_save_conf provider "$VOLOK_PROVIDER"
  state_save_conf src_path "$VOLOK_SRC_PATH"
  state_save_conf dst_path "$VOLOK_DST_PATH"
  state_save_conf on_conflict "$VOLOK_ON_CONFLICT"
  state_save_conf src_login "$WIZARD_LOGIN_SRC"
  state_save_conf dst_login "$WIZARD_LOGIN_DST"
  return 0
}

# wizard_resume_conf - restore the parameters of the run being continued.
wizard_resume_conf() {
  if [[ -z "$VOLOK_RESUME_ID" ]]; then
    return 0
  fi
  local saved
  saved="$(state_read_conf src_path)"
  if [[ -n "$saved" && -z "$VOLOK_SRC_PATH" ]]; then
    VOLOK_SRC_PATH="$saved"
  fi
  saved="$(state_read_conf dst_path)"
  if [[ -n "$saved" && -z "$VOLOK_DST_PATH" ]]; then
    VOLOK_DST_PATH="$saved"
  fi
  saved="$(state_read_conf on_conflict)"
  if [[ -n "$saved" && -z "$VOLOK_ON_CONFLICT" ]]; then
    VOLOK_ON_CONFLICT="$saved"
  fi
  ui_info "Продолжаю запуск $VOLOK_RESUME_ID: $VOLOK_SRC_PATH -> $VOLOK_DST_PATH"
  return 0
}

# wizard_run - steps 1..8 of the interactive scenario.
wizard_run() {
  ui_title 'Volok: копирование между аккаунтами Яндекс Диска'

  wizard_load_config
  if [[ -n "$VOLOK_LOG_LEVEL_OPT" ]]; then
    if ! log_set_level "$VOLOK_LOG_LEVEL_OPT"; then
      volok_die "$EX_ENV" "Неизвестный уровень журнала: $VOLOK_LOG_LEVEL_OPT"
    fi
  fi
  if [[ -z "$VOLOK_ON_CONFLICT" ]]; then
    VOLOK_ON_CONFLICT='skip'
  fi
  case "$VOLOK_ON_CONFLICT" in
    skip|overwrite|rename) : ;;
    *) volok_die "$EX_ENV" "Недопустимое значение --on-conflict: $VOLOK_ON_CONFLICT" ;;
  esac

  if ! provider_register src "$VOLOK_PROVIDER" || ! provider_register dst "$VOLOK_PROVIDER"; then
    volok_die "$EX_ENV" "$PROVIDER_MESSAGE"
  fi

  wizard_resume_conf

  ui_title 'Шаг 1. Доступ к Дискам'
  wizard_get_token src YANDEX_TOKEN_SRC 'Токен исходного Диска (ввод не отображается)'
  wizard_get_token dst YANDEX_TOKEN_DST 'Токен целевого Диска (ввод не отображается)'
  wizard_check_access src 'Источник'
  wizard_check_access dst 'Приёмник'

  ui_title 'Шаг 2. Папки'
  wizard_ask_src_path
  wizard_ask_dst_path
  wizard_check_same_account

  ui_title 'Шаг 3. Оценка объёма'
  wizard_scan
  wizard_save_conf

  ui_title 'Шаг 4. Подтверждение'
  wizard_summary
  return 0
}
