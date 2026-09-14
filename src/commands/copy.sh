# shellcheck shell=bash
#
# copy.sh - tree walk and copying.
#
# Order of work is breadth first: the whole directory tree is recreated on the
# target first, and only then files are copied. A file copy therefore never
# has to create its parent directory, which keeps the retry logic simple.

COPY_TOTAL_DIRS=0
COPY_TOTAL_FILES=0
COPY_TOTAL_BYTES=0
COPY_OK=0
COPY_SKIPPED=0
COPY_FAILED=0
COPY_ABORTED=0
COPY_LAST_NOTE=''

# path_join <base> <relative> - join two path parts into an absolute path.
path_join() {
  local base="${1%/}"
  local rel="$2"
  if [[ -z "$rel" ]]; then
    if [[ -z "$base" ]]; then
      printf '/'
    else
      printf '%s' "$base"
    fi
    return 0
  fi
  printf '%s/%s' "$base" "$rel"
}

# path_rel <root> <path> - path as seen from root, empty when they are equal.
path_rel() {
  local root="${1%/}"
  local path="$2"
  if [[ "$path" == "$root" ]]; then
    printf ''
    return 0
  fi
  printf '%s' "${path#"$root"/}"
}

# copy_scan <slot> <root> - walk the source tree into the run state files.
# Fills STATE_SCAN_DIRS and STATE_SCAN_FILES and the COPY_TOTAL_* counters.
copy_scan() {
  local slot="$1"
  local root="$2"
  local queue=("$root")
  local listing="$HTTP_TMPDIR/listing"
  local current entry_type entry_path entry_size rel

  : > "$STATE_SCAN_DIRS"
  : > "$STATE_SCAN_FILES"
  COPY_TOTAL_DIRS=0
  COPY_TOTAL_FILES=0
  COPY_TOTAL_BYTES=0

  while (( ${#queue[@]} > 0 )); do
    current="${queue[0]}"
    queue=(${queue[@]+"${queue[@]:1}"})

    if ! provider_call "$slot" list_dir "$current" > "$listing"; then
      ui_err "Не удалось прочитать «$current»: $PROVIDER_STATUS $PROVIDER_MESSAGE"
      log_error "list_dir $current: $PROVIDER_STATUS $PROVIDER_MESSAGE"
      return 1
    fi

    while IFS=$'\t' read -r entry_type entry_path entry_size || [[ -n "$entry_type" ]]; do
      if [[ -z "$entry_type" ]]; then
        continue
      fi
      entry_path="$(tsv_unescape "$entry_path")"
      rel="$(path_rel "$root" "$entry_path")"
      if [[ -z "$rel" ]]; then
        continue
      fi
      if [[ "$entry_type" == "dir" ]]; then
        COPY_TOTAL_DIRS=$(( COPY_TOTAL_DIRS + 1 ))
        printf '%s\n' "$(tsv_escape "$rel")" >> "$STATE_SCAN_DIRS"
        queue+=("$entry_path")
      else
        entry_size="${entry_size//[^0-9]/}"
        entry_size="${entry_size:-0}"
        COPY_TOTAL_FILES=$(( COPY_TOTAL_FILES + 1 ))
        COPY_TOTAL_BYTES=$(( COPY_TOTAL_BYTES + entry_size ))
        printf '%s\t%s\n' "$(tsv_escape "$rel")" "$entry_size" >> "$STATE_SCAN_FILES"
      fi
    done < "$listing"

    ui_status "Сканирую: найдено файлов $COPY_TOTAL_FILES, папок $COPY_TOTAL_DIRS - $current"
  done
  ui_status_done
  return 0
}

# copy_scan_load - recount totals from an existing scan, used by --resume.
copy_scan_load() {
  local rel size
  COPY_TOTAL_DIRS=0
  COPY_TOTAL_FILES=0
  COPY_TOTAL_BYTES=0
  if [[ -s "$STATE_SCAN_DIRS" ]]; then
    while IFS= read -r rel || [[ -n "$rel" ]]; do
      if [[ -n "$rel" ]]; then
        COPY_TOTAL_DIRS=$(( COPY_TOTAL_DIRS + 1 ))
      fi
    done < "$STATE_SCAN_DIRS"
  fi
  if [[ -s "$STATE_SCAN_FILES" ]]; then
    while IFS=$'\t' read -r rel size || [[ -n "$rel" ]]; do
      if [[ -n "$rel" ]]; then
        size="${size//[^0-9]/}"
        COPY_TOTAL_FILES=$(( COPY_TOTAL_FILES + 1 ))
        COPY_TOTAL_BYTES=$(( COPY_TOTAL_BYTES + ${size:-0} ))
      fi
    done < "$STATE_SCAN_FILES"
  fi
  return 0
}

# copy_free_name <slot> <path> - "name (2).ext" and so on, for --on-conflict=rename.
copy_free_name() {
  local slot="$1"
  local path="$2"
  local dir="${path%/*}"
  local base="${path##*/}"
  local stem="$base"
  local ext=''
  local candidate idx
  if [[ -z "$dir" ]]; then
    dir='/'
  fi
  if [[ "$base" == *.* && "${base:0:1}" != '.' ]]; then
    stem="${base%.*}"
    ext=".${base##*.}"
  fi
  for (( idx = 2; idx <= 99; idx++ )); do
    candidate="$(path_join "$dir" "${stem} (${idx})${ext}")"
    if provider_call "$slot" exists "$candidate"; then
      continue
    fi
    # A clean "not found" leaves the provider status at zero; anything else
    # means the check itself failed and the name cannot be trusted.
    if [[ "$PROVIDER_STATUS" == "0" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
    return 1
  done
  return 1
}

# copy_make_dirs <src_slot> <dst_slot> - recreate the directory tree first.
copy_make_dirs() {
  local dst_slot="$2"
  local rel dst index=0
  if [[ ! -s "$STATE_SCAN_DIRS" ]]; then
    return 0
  fi
  ui_info "Создаю структуру папок: $COPY_TOTAL_DIRS шт."
  while IFS= read -r rel || [[ -n "$rel" ]]; do
    if [[ -z "$rel" ]]; then
      continue
    fi
    rel="$(tsv_unescape "$rel")"
    dst="$(path_join "$VOLOK_DST_PATH" "$rel")"
    index=$(( index + 1 ))
    ui_progress "$index" "$COPY_TOTAL_DIRS" "$rel"
    if ! provider_call "$dst_slot" mkdir "$dst"; then
      ui_progress_done
      ui_err "Не удалось создать папку «$dst»: $PROVIDER_STATUS $PROVIDER_MESSAGE"
      log_error "mkdir $dst: $PROVIDER_STATUS $PROVIDER_MESSAGE"
      state_record_error "$dst" "$PROVIDER_STATUS" "$PROVIDER_MESSAGE"
      if [[ "$PROVIDER_STATUS" == "507" ]]; then
        COPY_ABORTED=1
        return 1
      fi
      COPY_FAILED=$(( COPY_FAILED + 1 ))
    fi
  done < "$STATE_SCAN_DIRS"
  ui_progress_done
  return 0
}

# _copy_attempt <src_slot> <src_path> <dst_slot> <dst_path>
_copy_attempt() {
  provider_call "$1" server_copy "$2" "$3" "$4"
}

# _copy_fallback <src_slot> <src_path> <dst_slot> <dst_path>
# Traffic consuming path: down to this machine and straight back up.
_copy_fallback() {
  local src_slot="$1"
  local src_path="$2"
  local dst_slot="$3"
  local dst_path="$4"
  if (( VOLOK_DRY_RUN )); then
    log_info "dry-run: fallback $src_path -> $dst_path"
    return 0
  fi
  log_warn "fallback download/upload: $src_path"
  ui_progress_done
  ui_warn "Серверное копирование не сработало, качаю через себя: $src_path"
  if provider_call "$src_slot" download "$src_path" \
      | provider_call "$dst_slot" upload "$dst_path" 1; then
    return 0
  fi
  PROVIDER_STATUS="${PROVIDER_STATUS:-0}"
  PROVIDER_MESSAGE="резервное копирование через download/upload не удалось"
  return 1
}

# copy_one <src_slot> <src_path> <dst_slot> <dst_path>
# Returns: 0 copied, 2 skipped, 3 fatal (no space left), 1 failed.
copy_one() {
  local src_slot="$1"
  local src_path="$2"
  local dst_slot="$3"
  local dst_path="$4"
  local status message alt
  COPY_LAST_NOTE=''

  if _copy_attempt "$src_slot" "$src_path" "$dst_slot" "$dst_path"; then
    return 0
  fi
  status="$PROVIDER_STATUS"
  message="$PROVIDER_MESSAGE"

  if [[ "$status" == "507" ]]; then
    COPY_LAST_NOTE="на целевом Диске закончилось место"
    return 3
  fi

  if [[ "$status" == "409" ]]; then
    case "$VOLOK_ON_CONFLICT" in
      overwrite)
        if provider_call "$dst_slot" delete "$dst_path" 0 \
            && _copy_attempt "$src_slot" "$src_path" "$dst_slot" "$dst_path"; then
          return 0
        fi
        status="$PROVIDER_STATUS"
        message="$PROVIDER_MESSAGE"
        ;;
      rename)
        alt=''
        if provider_has "$dst_slot" exists; then
          alt="$(copy_free_name "$dst_slot" "$dst_path" || printf '')"
        fi
        if [[ -n "$alt" ]] \
            && _copy_attempt "$src_slot" "$src_path" "$dst_slot" "$alt"; then
          COPY_LAST_NOTE="сохранено как $alt"
          return 0
        fi
        status="$PROVIDER_STATUS"
        message="$PROVIDER_MESSAGE"
        ;;
      *)
        COPY_LAST_NOTE="уже существует в приёмнике"
        return 2
        ;;
    esac
  fi

  case "$status" in
    401|403)
      COPY_LAST_NOTE="$message"
      PROVIDER_STATUS="$status"
      PROVIDER_MESSAGE="$message"
      return 1
      ;;
  esac

  if (( VOLOK_ALLOW_FALLBACK )); then
    if _copy_fallback "$src_slot" "$src_path" "$dst_slot" "$dst_path"; then
      COPY_LAST_NOTE="скопировано через download/upload"
      return 0
    fi
    message="$PROVIDER_MESSAGE"
  fi

  PROVIDER_STATUS="$status"
  PROVIDER_MESSAGE="$message"
  COPY_LAST_NOTE="$message"
  return 1
}

# copy_files <src_slot> <dst_slot> - the main loop.
copy_files() {
  local src_slot="$1"
  local dst_slot="$2"
  local rel size src dst index=0 rc
  if [[ ! -s "$STATE_SCAN_FILES" ]]; then
    return 0
  fi
  ui_info "Копирую файлы: $COPY_TOTAL_FILES шт., $(ui_human_size "$COPY_TOTAL_BYTES")"
  while IFS=$'\t' read -r rel size || [[ -n "$rel" ]]; do
    if [[ -z "$rel" ]]; then
      continue
    fi
    rel="$(tsv_unescape "$rel")"
    size="${size//[^0-9]/}"
    size="${size:-0}"
    src="$(path_join "$VOLOK_SRC_PATH" "$rel")"
    dst="$(path_join "$VOLOK_DST_PATH" "$rel")"
    index=$(( index + 1 ))

    if state_is_done "$src"; then
      log_debug "resume: пропускаю уже скопированный $src"
      COPY_OK=$(( COPY_OK + 1 ))
      continue
    fi

    ui_progress "$index" "$COPY_TOTAL_FILES" "$rel"

    rc=0
    copy_one "$src_slot" "$src" "$dst_slot" "$dst" || rc=$?
    case "$rc" in
      0)
        COPY_OK=$(( COPY_OK + 1 ))
        if (( ! VOLOK_DRY_RUN )); then
          state_record copied "$src" "$size"
        fi
        log_info "copied $src -> $dst"
        ;;
      2)
        COPY_SKIPPED=$(( COPY_SKIPPED + 1 ))
        if (( ! VOLOK_DRY_RUN )); then
          state_record skipped "$src" "$size"
        fi
        log_info "skipped $src: $COPY_LAST_NOTE"
        ;;
      3)
        COPY_ABORTED=1
        ui_progress_done
        state_record_error "$dst" 507 "$COPY_LAST_NOTE"
        if (( ! VOLOK_DRY_RUN )); then
          state_record failed "$src" "$size"
        fi
        ui_err "Остановка: $COPY_LAST_NOTE."
        log_error "abort 507 on $dst"
        return 1
        ;;
      *)
        COPY_FAILED=$(( COPY_FAILED + 1 ))
        if (( ! VOLOK_DRY_RUN )); then
          state_record failed "$src" "$size"
        fi
        state_record_error "$src" "$PROVIDER_STATUS" "$PROVIDER_MESSAGE"
        log_error "failed $src: $PROVIDER_STATUS $PROVIDER_MESSAGE"
        ;;
    esac
  done < "$STATE_SCAN_FILES"
  ui_progress_done
  return 0
}

# copy_run <src_slot> <dst_slot> - directories first, then files.
copy_run() {
  local src_slot="$1"
  local dst_slot="$2"
  state_load_done
  if ! copy_make_dirs "$src_slot" "$dst_slot"; then
    return 1
  fi
  if ! copy_files "$src_slot" "$dst_slot"; then
    return 1
  fi
  return 0
}
