#!/usr/bin/env bash
#
# Volok - copy files and folders between two cloud accounts without
# downloading the data to this machine.
#
# The copy itself is performed by the storage service: the source resource is
# published for a moment, the target account saves it by its public link, and
# the publication is revoked immediately afterwards.
#
# Exit codes:
#   0  success
#   1  environment problem (dependencies, paths, not enough space)
#   2  authorization problem
#   3  copying finished, but some files failed
#   4  interrupted by the user
#
# License: MIT.

set -euo pipefail
IFS=$'\n\t'

VOLOK_VERSION='1.0.0'

readonly EX_OK=0
readonly EX_ENV=1
readonly EX_AUTH=2
readonly EX_COPY=3
readonly EX_ABORT=4

# Resolve the directory of the real script, even when started through a
# symlink, so that the modules below are always found.
volok_root() {
  local source="${BASH_SOURCE[0]}"
  local dir
  while [ -L "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" > /dev/null 2>&1 && pwd)"
    source="$(readlink "$source")"
    case "$source" in
      /*) ;;
      *) source="$dir/$source" ;;
    esac
  done
  cd -P "$(dirname "$source")" > /dev/null 2>&1 && pwd
}

VOLOK_ROOT="$(volok_root)"

# Dependencies first: this module is the one that still runs on bash 3.2.
# shellcheck source=src/lib/deps.sh
. "$VOLOK_ROOT/src/lib/deps.sh"
deps_check_bash || exit 1

# shellcheck source=src/lib/log.sh
. "$VOLOK_ROOT/src/lib/log.sh"
# shellcheck source=src/lib/ui.sh
. "$VOLOK_ROOT/src/lib/ui.sh"
# shellcheck source=src/lib/http.sh
. "$VOLOK_ROOT/src/lib/http.sh"
# shellcheck source=src/lib/state.sh
. "$VOLOK_ROOT/src/lib/state.sh"
# shellcheck source=src/providers/provider.sh
. "$VOLOK_ROOT/src/providers/provider.sh"
# shellcheck source=src/providers/yandex.sh
. "$VOLOK_ROOT/src/providers/yandex.sh"
# shellcheck source=src/commands/copy.sh
. "$VOLOK_ROOT/src/commands/copy.sh"
# shellcheck source=src/commands/wizard.sh
. "$VOLOK_ROOT/src/commands/wizard.sh"
# shellcheck source=src/commands/cleanup.sh
. "$VOLOK_ROOT/src/commands/cleanup.sh"

VOLOK_PROVIDER='yandex'
VOLOK_SRC_PATH=''
VOLOK_DST_PATH=''
VOLOK_TOKEN_SRC=''
VOLOK_TOKEN_DST=''
VOLOK_ON_CONFLICT=''
VOLOK_LOG_LEVEL_OPT=''
VOLOK_RESUME_ID=''
VOLOK_DRY_RUN=0
VOLOK_ALLOW_FALLBACK=0
VOLOK_ASSUME_YES=0
VOLOK_NO_COLOR=0
VOLOK_EXIT_CODE=0
VOLOK_RC=0

volok_usage() {
  cat <<'USAGE'
Volok - копирование между двумя аккаунтами Яндекс Диска без скачивания данных.

Использование:
  volok.sh [флаги]

Флаги:
  --src-path ПУТЬ        исходная папка (по умолчанию спрашивается, корень /)
  --dst-path ПУТЬ        целевая папка (по умолчанию спрашивается, корень /)
  --on-conflict РЕЖИМ    что делать, если файл уже есть в приёмнике:
                         skip (по умолчанию), overwrite, rename
  --allow-fallback       разрешить резервный путь download/upload, если
                         серверное копирование отказало. Расходует ваш трафик,
                         по умолчанию выключено
  --dry-run              пройти весь сценарий без единого изменяющего запроса
  --resume ИД            продолжить прерванный запуск, пропустив скопированное
  --log-level УРОВЕНЬ    debug, info (по умолчанию), warn, error
  --verbose              дублировать журнал в stderr
  --yes                  не задавать вопрос перед копированием
                         (на удаление исходных данных не влияет)
  --no-color             вывод без цветов
  --config ФАЙЛ          путь к файлу конфигурации
  -h, --help             эта справка
  -v, --version          версия

Токены читаются из переменных окружения YANDEX_TOKEN_SRC и YANDEX_TOKEN_DST
или из ~/.config/volok/config, иначе запрашиваются без эха.

Коды возврата: 0 успех, 1 ошибка окружения, 2 ошибка авторизации,
3 копирование завершилось с ошибками, 4 прервано пользователем.
USAGE
}

# volok_need_value <flag> <value...> - a flag that requires an argument.
volok_need_value() {
  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    printf 'Volok: флаг %s требует значения\n' "$1" >&2
    exit 1
  fi
  return 0
}

volok_parse_args() {
  local arg value
  while (( $# > 0 )); do
    arg="$1"
    value=''
    case "$arg" in
      --*=*)
        value="${arg#*=}"
        arg="${arg%%=*}"
        ;;
    esac
    case "$arg" in
      -h|--help)
        volok_usage
        exit "$EX_OK"
        ;;
      -v|--version)
        printf 'Volok %s\n' "$VOLOK_VERSION"
        exit "$EX_OK"
        ;;
      --src-path)
        if [[ -z "$value" ]]; then volok_need_value "$arg" "${2:-}"; value="$2"; shift; fi
        VOLOK_SRC_PATH="$value"
        ;;
      --dst-path)
        if [[ -z "$value" ]]; then volok_need_value "$arg" "${2:-}"; value="$2"; shift; fi
        VOLOK_DST_PATH="$value"
        ;;
      --on-conflict)
        if [[ -z "$value" ]]; then volok_need_value "$arg" "${2:-}"; value="$2"; shift; fi
        VOLOK_ON_CONFLICT="$value"
        ;;
      --log-level)
        if [[ -z "$value" ]]; then volok_need_value "$arg" "${2:-}"; value="$2"; shift; fi
        VOLOK_LOG_LEVEL_OPT="$value"
        ;;
      --resume)
        if [[ -z "$value" ]]; then volok_need_value "$arg" "${2:-}"; value="$2"; shift; fi
        VOLOK_RESUME_ID="$value"
        ;;
      --config)
        if [[ -z "$value" ]]; then volok_need_value "$arg" "${2:-}"; value="$2"; shift; fi
        VOLOK_CONFIG="$value"
        ;;
      --allow-fallback)
        VOLOK_ALLOW_FALLBACK=1
        ;;
      --dry-run)
        VOLOK_DRY_RUN=1
        ;;
      --yes)
        VOLOK_ASSUME_YES=1
        ;;
      --verbose)
        LOG_ECHO=1
        ;;
      --no-color)
        VOLOK_NO_COLOR=1
        ;;
      --)
        shift
        break
        ;;
      *)
        printf 'Volok: неизвестный флаг: %s\n' "$arg" >&2
        printf 'Подсказка: volok.sh --help\n' >&2
        exit 1
        ;;
    esac
    shift
  done
  return 0
}

# volok_die <code> <message> - report and leave; the EXIT trap still runs.
volok_die() {
  local code="$1"
  shift
  ui_err "$*"
  log_error "$*"
  exit "$code"
}

# volok_report - the summary required after every copy.
volok_report() {
  ui_title 'Итог копирования'
  ui_say "Успешно:   $COPY_OK"
  ui_say "Пропущено: $COPY_SKIPPED"
  ui_say "Ошибок:    $COPY_FAILED"
  if (( COPY_ABORTED )); then
    ui_err 'Копирование остановлено досрочно: на целевом Диске кончилось место.'
  fi
  local errors
  errors="$(state_error_count)"
  if (( errors > 0 )); then
    ui_say "Журнал ошибок: $STATE_ERRORS ($errors $(ui_plural "$errors" запись записи записей))"
  else
    ui_say "Журнал ошибок: $STATE_ERRORS (пуст)"
  fi
  ui_say "Манифест:      $STATE_MANIFEST"
  ui_say "Журнал:        $(log_path)"
  if (( COPY_FAILED > 0 || COPY_ABORTED )); then
    ui_hint "Продолжить позже: volok.sh --resume $STATE_RUN_ID"
  fi
  return 0
}

volok_main() {
  volok_parse_args "$@"
  ui_init "$VOLOK_NO_COLOR"

  if ! deps_check_binaries; then
    exit "$EX_ENV"
  fi

  if [[ -n "$VOLOK_RESUME_ID" ]] && ! state_run_exists "$VOLOK_RESUME_ID"; then
    ui_err "Запуск «$VOLOK_RESUME_ID» не найден."
    ui_hint "Каталог запусков: ${XDG_STATE_HOME:-$HOME/.local/state}/volok"
    local known=()
    mapfile -t known < <(state_list_runs)
    if (( ${#known[@]} > 0 )); then
      ui_hint 'Известные запуски:'
      local run_id
      for run_id in "${known[@]}"; do
        ui_hint "  $run_id"
      done
    fi
    exit "$EX_ENV"
  fi

  http_init
  state_init "$VOLOK_RESUME_ID"
  log_init "$STATE_RUN_DIR/volok.log"
  # Cleanup is wired straight to the modules that own each resource: the
  # publications must be revoked and the token files wiped even if the process
  # dies here. VOLOK_RC keeps the exit code the script was leaving with.
  trap 'VOLOK_RC=$?; set +e; ui_progress_done; provider_cleanup_shares; http_cleanup; exit "$VOLOK_RC"' EXIT
  trap 'ui_progress_done; ui_warn "Прервано пользователем."; log_warn "interrupted by user"; exit "$EX_ABORT"' INT TERM

  log_info "volok $VOLOK_VERSION run=$STATE_RUN_ID dry_run=$VOLOK_DRY_RUN"
  if (( VOLOK_DRY_RUN )); then
    ui_warn 'Пробный запуск: ни одного изменяющего запроса отправлено не будет.'
  fi

  wizard_run

  ui_title 'Копирование'
  if ! copy_run src dst; then
    VOLOK_EXIT_CODE="$EX_COPY"
  fi

  volok_report

  cleanup_run src

  if (( COPY_FAILED > 0 || COPY_ABORTED )); then
    VOLOK_EXIT_CODE="$EX_COPY"
  fi
  if (( CLEANUP_FAILED > 0 )) && (( VOLOK_EXIT_CODE == EX_OK )); then
    VOLOK_EXIT_CODE="$EX_COPY"
  fi

  if (( VOLOK_EXIT_CODE == EX_OK )); then
    ui_ok 'Готово.'
  fi
  exit "$VOLOK_EXIT_CODE"
}

volok_main "$@"
