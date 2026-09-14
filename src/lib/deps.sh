# shellcheck shell=bash
#
# deps.sh - runtime prerequisites.
#
# This file must stay parseable and runnable by bash 3.2, because it is the
# module that reports "your bash is too old" on stock macOS.

# deps_check_bash - refuse to run on bash older than 4.0.
deps_check_bash() {
  if [ -z "${BASH_VERSINFO+x}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    printf 'Volok: нужен bash 4.0 или новее, текущая версия: %s\n' \
      "${BASH_VERSION:-неизвестна}" >&2
    printf 'macOS: brew install bash, затем запускайте новый bash:\n' >&2
    printf '  /opt/homebrew/bin/bash volok.sh\n' >&2
    return 1
  fi
  return 0
}

# deps_install_hint <binary> - print a platform specific install command.
deps_install_hint() {
  local bin="$1"
  local uname_s
  uname_s="$(uname -s 2>/dev/null || printf 'unknown')"
  case "$uname_s" in
    Darwin)
      printf '  brew install %s\n' "$bin"
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        printf '  sudo apt-get install -y %s\n' "$bin"
      elif command -v dnf >/dev/null 2>&1; then
        printf '  sudo dnf install -y %s\n' "$bin"
      elif command -v yum >/dev/null 2>&1; then
        printf '  sudo yum install -y %s\n' "$bin"
      elif command -v pacman >/dev/null 2>&1; then
        printf '  sudo pacman -S --noconfirm %s\n' "$bin"
      elif command -v apk >/dev/null 2>&1; then
        printf '  sudo apk add %s\n' "$bin"
      elif command -v zypper >/dev/null 2>&1; then
        printf '  sudo zypper install -y %s\n' "$bin"
      else
        printf '  установите пакет %s средствами вашего дистрибутива\n' "$bin"
      fi
      ;;
    *)
      printf '  установите %s: https://command-not-found.com/%s\n' "$bin" "$bin"
      ;;
  esac
}

# deps_check_binaries - verify every external command Volok relies on.
deps_check_binaries() {
  local missing=()
  local bin
  for bin in curl jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      missing+=("$bin")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi

  printf 'Volok: не хватает программ: %s\n' "${missing[*]}" >&2
  printf 'Установите их командой:\n' >&2
  for bin in "${missing[@]}"; do
    deps_install_hint "$bin" >&2
  done
  return 1
}
