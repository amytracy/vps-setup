#!/usr/bin/env bash
# install.sh — загрузчик vps-setup для запуска одной командой через curl.
#
#   curl -fsSL https://raw.githubusercontent.com/amytracy/vps-setup/main/install.sh \
#     | sudo bash -s -- 05-full --allow 80,443
#
# Первый аргумент — какой скрипт запустить: 01, 02, 03, 04, 05
# (можно с суффиксом: 01-basic, 01-basic.sh). Остальные аргументы
# передаются выбранному скрипту без изменений.
#
# Переменные окружения:
#   VPS_SETUP_REPO  репозиторий на GitHub (по умолчанию amytracy/vps-setup)
#   VPS_SETUP_REF   ветка, тег или коммит (по умолчанию main)
set -Eeuo pipefail

REPO=${VPS_SETUP_REPO:-amytracy/vps-setup}
REF=${VPS_SETUP_REF:-main}

die() { printf '[x] %s\n' "$*" >&2; exit 1; }
log() { printf '[+] %s\n' "$*"; }

usage() {
  cat <<'EOF'
Использование:
  curl -fsSL https://raw.githubusercontent.com/amytracy/vps-setup/main/install.sh \
    | sudo bash -s -- [СКРИПТ] [опции]

СКРИПТ (необязательно, по умолчанию 01-basic):
  01-basic      SSH на случайный порт + fail2ban
  02-firewall   то же + UFW
  03-logging    то же + постоянные логи и ежедневный отчёт
  04-tarpit     то же + ловушка endlessh на 22
  05-full       всё сразу

Опции передаются скрипту как есть:
  --port N         порт SSH вручную (1024-65535)
  --allow LIST     открыть порты в UFW: 80,443,51820/udp (только 02 и 05)
  --timeout MIN    автооткат через MIN минут (по умолчанию 10)
  --no-confirm     без подтверждения и автоотката (для автоматизации)
  -h, --help       эта справка

Примеры:
  ... | sudo bash
  ... | sudo bash -s -- 05-full --allow 80,443
  ... | sudo bash -s -- 02-firewall --port 2222 --allow 443

Переменные окружения (ставятся перед bash):
  sudo VPS_SETUP_REF=v1.0.0 bash -s -- 05-full
  sudo VPS_SETUP_REPO=user/fork bash -s -- 05-full
EOF
}

SCRIPT=01-basic.sh

if (($#)); then
  case $1 in
    -h|--help) usage; exit 0 ;;
    -*)        ;;   # сразу опции — запускаем скрипт по умолчанию
    *)
      case $1 in
        01|01-basic|01-basic.sh) SCRIPT=01-basic.sh ;;
        02|02-firewall|02-firewall.sh) SCRIPT=02-firewall.sh ;;
        03|03-logging|03-logging.sh) SCRIPT=03-logging.sh ;;
        04|04-tarpit|04-tarpit.sh) SCRIPT=04-tarpit.sh ;;
        05|05-full|05-full.sh) SCRIPT=05-full.sh ;;
        *) usage >&2; die "Неизвестный скрипт: $1" ;;
      esac
      shift
      ;;
  esac
fi

[[ $EUID -eq 0 ]] || die "Запустите через sudo: curl ... | sudo bash -s -- $SCRIPT"

# Локальный запуск из клонированного репозитория — без скачивания.
self=${BASH_SOURCE[0]:-}
if [[ -n $self && $self != /dev/* && -f $self ]]; then
  self_dir=$(cd -- "$(dirname -- "$self")" && pwd)
  if [[ -f $self_dir/$SCRIPT && -f $self_dir/lib/common.sh ]]; then
    log "Локальная копия: $self_dir/$SCRIPT"
    bash "$self_dir/$SCRIPT" "$@"
    exit $?
  fi
fi

command -v curl >/dev/null 2>&1 || die "Нужен curl. Установите: apt-get update && apt-get install -y curl"
command -v tar  >/dev/null 2>&1 || die "Нужен tar"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/vps-setup.XXXXXX") || die "Не удалось создать временный каталог"
trap 'rm -rf -- "$tmp"' EXIT

archive=$tmp/vps-setup.tar.gz
url="https://github.com/${REPO}/archive/${REF}.tar.gz"

log "Скачиваю ${REPO}@${REF}"
curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$archive" "$url" \
  || die "Не удалось скачать $url (проверьте сеть, REPO и REF)"
tar -xzf "$archive" -C "$tmp" || die "Не удалось распаковать архив"
rm -f -- "$archive"

src=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n $src && -f $src/$SCRIPT ]] || die "В архиве нет $SCRIPT"
[[ -f $src/lib/common.sh ]] || die "В архиве нет lib/common.sh"

log "Запускаю $SCRIPT $*"
set +e
bash "$src/$SCRIPT" "$@"
rc=$?
set -e
exit "$rc"
