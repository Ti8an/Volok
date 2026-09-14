# shellcheck shell=bash
#
# cleanup.sh - optional deletion of the source data, after the copy.
#
# The rules here are deliberately strict, because this is the only part of
# Volok that destroys something:
#   * "only copied" deletes exactly the manifest rows marked copied, and never
#     walks the source tree again;
#   * "everything" is refused while a single error is recorded;
#   * both need the word УДАЛИТЬ typed in full, y/N is not accepted;
#   * deletion goes to the trash, so there is still a way back;
#   * a dry run never deletes anything.

CLEANUP_DELETED=0
CLEANUP_FAILED=0

# cleanup_confirm_word - the second, deliberately inconvenient confirmation.
cleanup_confirm_word() {
  ui_warn 'Это действие удаляет данные на исходном Диске.'
  ui_hint 'Файлы уйдут в Корзину Яндекс Диска, оттуда их можно вернуть.'
  if ui_ask_word 'Введите слово УДАЛИТЬ, чтобы подтвердить' 'УДАЛИТЬ'; then
    return 0
  fi
  ui_info 'Не подтверждено, ничего не удалено.'
  return 1
}

# cleanup_delete_one <slot> <path>
cleanup_delete_one() {
  local slot="$1"
  local path="$2"
  if provider_call "$slot" delete "$path" 0; then
    CLEANUP_DELETED=$(( CLEANUP_DELETED + 1 ))
    log_info "deleted $path"
    return 0
  fi
  CLEANUP_FAILED=$(( CLEANUP_FAILED + 1 ))
  log_error "delete $path: $PROVIDER_STATUS $PROVIDER_MESSAGE"
  state_record_error "$path" "$PROVIDER_STATUS" "$PROVIDER_MESSAGE"
  ui_err "Не удалось удалить «$path»: $PROVIDER_STATUS $PROVIDER_MESSAGE"
  return 1
}

# cleanup_delete_copied <slot> - strictly what the manifest calls copied.
cleanup_delete_copied() {
  local slot="$1"
  local escaped path index=0 total
  declare -A seen=()
  local paths=()
  local unique=()
  mapfile -t paths < <(state_copied_paths)
  # A resumed run can list the same file twice; delete it once.
  for escaped in ${paths[@]+"${paths[@]}"}; do
    if [[ -z "$escaped" ]]; then
      continue
    fi
    path="$(tsv_unescape "$escaped")"
    if [[ -n "${seen[$path]:-}" ]]; then
      continue
    fi
    seen["$path"]=1
    unique+=("$path")
  done
  total="${#unique[@]}"
  if (( total == 0 )); then
    ui_info 'В манифесте нет успешно скопированных файлов, удалять нечего.'
    return 0
  fi
  ui_info "Удаляю успешно скопированные файлы: $total шт."
  for path in ${unique[@]+"${unique[@]}"}; do
    index=$(( index + 1 ))
    ui_progress "$index" "$total" "$path"
    cleanup_delete_one "$slot" "$path" || true
  done
  ui_progress_done
  return 0
}

# cleanup_delete_all <slot> <root> - every entry inside the source folder.
cleanup_delete_all() {
  local slot="$1"
  local root="$2"
  local listing="$HTTP_TMPDIR/cleanup-listing"
  local entries=()
  local entry_size entry_type entry_path index=0 total
  if ! provider_call "$slot" list_dir "$root" > "$listing"; then
    ui_err "Не удалось прочитать «$root»: $PROVIDER_STATUS $PROVIDER_MESSAGE"
    return 1
  fi
  while IFS=$'\t' read -r entry_type entry_path entry_size || [[ -n "$entry_type" ]]; do
    if [[ -z "$entry_type" ]]; then
      continue
    fi
    entries+=("$(tsv_unescape "$entry_path")")
  done < "$listing"
  total="${#entries[@]}"
  if (( total == 0 )); then
    ui_info 'Исходная папка уже пуста.'
    return 0
  fi
  ui_info "Удаляю содержимое «$root»: $total объектов верхнего уровня."
  for entry_path in ${entries[@]+"${entries[@]}"}; do
    index=$(( index + 1 ))
    ui_progress "$index" "$total" "$entry_path"
    cleanup_delete_one "$slot" "$entry_path" || true
  done
  ui_progress_done
  return 0
}

# cleanup_run <slot> - the post copy menu.
cleanup_run() {
  local slot="$1"
  local errors choice
  errors="$(state_error_count)"

  ui_title 'Удаление исходных данных'
  if (( VOLOK_DRY_RUN )); then
    ui_info 'Пробный запуск: удаление недоступно.'
    return 0
  fi
  if (( COPY_OK == 0 )); then
    ui_info 'Ничего не скопировано, удалять нечего.'
    return 0
  fi

  local options=(
    'Нет, ничего не удалять'
    'Да, удалить только успешно скопированные файлы'
    'Да, удалить всё содержимое исходной папки'
  )
  if ! choice="$(ui_menu 'Удалить исходные данные?' 1 "${options[@]}")"; then
    ui_info 'Ввод прерван, ничего не удалено.'
    return 0
  fi

  case "$choice" in
    1)
      ui_info 'Исходные данные оставлены без изменений.'
      return 0
      ;;
    2)
      if ! cleanup_confirm_word; then
        return 0
      fi
      cleanup_delete_copied "$slot"
      ;;
    3)
      if (( errors > 0 )); then
        ui_err "Вариант 3 недоступен: в журнале $errors ошибок."
        ui_hint 'Полное удаление разрешено только после запуска без единой ошибки,'
        ui_hint 'иначе можно стереть то, что так и не доехало до приёмника.'
        ui_hint "Ошибки: $STATE_ERRORS"
        return 0
      fi
      if (( COPY_SKIPPED > 0 )); then
        ui_warn "Пропущено файлов: $COPY_SKIPPED. Они не были скопированы, но будут удалены."
      fi
      if ! cleanup_confirm_word; then
        return 0
      fi
      cleanup_delete_all "$slot" "$VOLOK_SRC_PATH"
      ;;
  esac

  ui_say ''
  ui_ok "Удалено объектов: $CLEANUP_DELETED"
  if (( CLEANUP_FAILED > 0 )); then
    ui_err "Не удалось удалить: $CLEANUP_FAILED, подробности в $STATE_ERRORS"
  fi
  return 0
}
