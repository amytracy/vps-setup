#!/usr/bin/env bash
# Общие функции vps-setup. Не запускается напрямую — подключается скриптами 0X-*.sh.
# shellcheck disable=SC2034

[[ -n ${_VPS_COMMON_LOADED:-} ]] && return 0
_VPS_COMMON_LOADED=1

# ---------------------------------------------------------------- константы
VPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE=/etc/vps-setup.conf
SSH_DROPIN=/etc/ssh/sshd_config.d/10-vps-port.conf
SSH_LOG_DROPIN=/etc/ssh/sshd_config.d/11-vps-logging.conf
F2B_JAIL=/etc/fail2ban/jail.d/zz-vps-setup.local
F2B_CONF=/etc/fail2ban/fail2ban.d/zz-vps-setup.local
ENDLESSH_CONF=/etc/endlessh/config
ENDLESSH_OVERRIDE=/etc/systemd/system/endlessh.service.d/vps-setup.conf
PORT_MARK='#vps-setup# '          # так помечаются закомментированные нами строки Port
RUN_TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=/root/vps-setup-backup/$RUN_TS
SBIN=/usr/local/sbin
PORT_MIN=10000                     # ниже эфемерного диапазона Linux (32768+)
PORT_MAX=32000

# ---------------------------------------------------------------- флаги / опции
WITH_UFW=0
WITH_TARPIT=0
WITH_LOGGING=0
OPT_PORT=""
OPT_ALLOW=""
OPT_CONFIRM=1
ROLLBACK_MIN=10
SSH_PORT=""
PREV_SSH_PORT=""
ROLLBACK_ARMED_AT=0

# ---------------------------------------------------------------- вывод
if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m' C_BOLD=$'\e[1m' C_RESET=$'\e[0m'
else
  C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_BOLD="" C_RESET=""
fi

log()  { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
step() { printf '\n%s%s==> %s%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; }

on_error() {
  local line=$1
  warn "Скрипт упал (строка $line)."
  if (( ROLLBACK_ARMED_AT > 0 )); then
    warn "Таймер автоотката активен: через ~${ROLLBACK_MIN} мин от старта SSH вернётся на 22."
    warn "Откатить прямо сейчас: sudo vps-rollback --emergency"
  fi
}

usage() {
  printf '%s\n' "${USAGE:-}"
  cat <<EOF
Опции:
  --port N         порт SSH вручную ($PORT_MIN-65535); по умолчанию случайный $PORT_MIN-$PORT_MAX
                   (при повторном запуске берётся уже назначенный порт)
  --allow LIST     только с UFW: открыть доп. порты, напр. 80,443,51820/udp,6000:6010/tcp
  --timeout MIN    через сколько минут откатить всё, если вход не подтверждён (по умолч. $ROLLBACK_MIN)
  --no-confirm     без подтверждения и без таймера автоотката (для автоматизации)
  -h, --help       эта справка
EOF
}

# ---------------------------------------------------------------- аргументы
parse_args() {
  while (($#)); do
    case $1 in
      --port)       [[ $# -ge 2 ]] || die "--port требует значение"; OPT_PORT=$2; shift 2 ;;
      --port=*)     OPT_PORT=${1#*=}; shift ;;
      --allow)      [[ $# -ge 2 ]] || die "--allow требует значение"; OPT_ALLOW=$2; shift 2 ;;
      --allow=*)    OPT_ALLOW=${1#*=}; shift ;;
      --timeout)    [[ $# -ge 2 ]] || die "--timeout требует значение"; ROLLBACK_MIN=$2; shift 2 ;;
      --timeout=*)  ROLLBACK_MIN=${1#*=}; shift ;;
      --no-confirm) OPT_CONFIRM=0; shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            usage >&2; die "Неизвестный аргумент: $1" ;;
    esac
  done

  if [[ -n $OPT_PORT ]]; then
    if ! [[ $OPT_PORT =~ ^[0-9]+$ ]] || (( OPT_PORT < 1024 || OPT_PORT > 65535 )); then
      die "--port: нужно число 1024-65535"
    fi
  fi
  if ! [[ $ROLLBACK_MIN =~ ^[0-9]+$ ]] || (( ROLLBACK_MIN < 2 || ROLLBACK_MIN > 120 )); then
    die "--timeout: нужно число минут 2-120"
  fi
  if [[ -n $OPT_ALLOW && $WITH_UFW != 1 ]]; then
    warn "--allow работает только с UFW (02-firewall.sh / 05-full.sh) — игнорирую"
  fi
}

# ---------------------------------------------------------------- проверки
require_root() {
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash $0"
}

check_os() {
  [[ -r /etc/os-release ]] || die "Не найден /etc/os-release"
  local id like pretty
  # shellcheck disable=SC1091
  id=$(. /etc/os-release; echo "${ID:-}")
  # shellcheck disable=SC1091
  like=$(. /etc/os-release; echo "${ID_LIKE:-}")
  # shellcheck disable=SC1091
  pretty=$(. /etc/os-release; echo "${PRETTY_NAME:-$id}")
  case " $id $like " in
    *" debian "*|*" ubuntu "*) ;;
    *) die "Поддерживаются только Debian/Ubuntu (найдено: $pretty)" ;;
  esac
  command -v systemctl >/dev/null || die "Нужен systemd"
  log "Система: $pretty"
}

check_tty() {
  if [[ $OPT_CONFIRM == 1 ]] && ! { true </dev/tty; } 2>/dev/null; then
    die "Нет терминала для подтверждения входа. Запустите интерактивно или добавьте --no-confirm"
  fi
}

# ---------------------------------------------------------------- утилиты
install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  local p missing=()
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    log "Пакеты уже установлены: $*"
    return 0
  fi
  log "Устанавливаю: ${missing[*]}"
  apt-get update -qq
  if ! apt-get install -y -qq -o Dpkg::Options::=--force-confold "${missing[@]}" >/dev/null; then
    if [[ " ${missing[*]} " == *" endlessh "* ]]; then
      warn "endlessh лежит в репозитории universe (Ubuntu). Включите: add-apt-repository universe"
    fi
    die "Не удалось установить пакеты: ${missing[*]}"
  fi
}

backup_file() {
  local f
  for f in "$@"; do
    [[ -e $f ]] || continue
    mkdir -p "$BACKUP_DIR"
    cp -a --parents "$f" "$BACKUP_DIR/"
  done
}

state_get() {
  if [[ -r $STATE_FILE ]]; then
    sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1
  fi
}

# 1, если модуль включён сейчас или был включён прошлым запуском
merge_flag() {
  if [[ $1 == 1 || $(state_get "$2") == 1 ]]; then echo 1; else echo 0; fi
}

save_state() {
  local ufw tarpit logging
  ufw=$(merge_flag "$WITH_UFW" UFW)
  tarpit=$(merge_flag "$WITH_TARPIT" TARPIT)
  logging=$(merge_flag "$WITH_LOGGING" LOGGING)
  cat >"$STATE_FILE" <<EOF
# vps-setup: состояние (читают vps-status, vps-rollback и повторные запуски)
SSH_PORT=$SSH_PORT
UFW=$ufw
TARPIT=$tarpit
LOGGING=$logging
UPDATED=$(date -Is)
EOF
  chmod 600 "$STATE_FILE"
}

port_in_use() { [[ -n $(ss -Htln "sport = :$1" 2>/dev/null) ]]; }

wait_listen() {
  local port=$1 i
  for (( i = 0; i < 20; i++ )); do
    port_in_use "$port" && return 0
    sleep 0.5
  done
  return 1
}

choose_port() {
  if [[ -n $OPT_PORT ]]; then
    SSH_PORT=$OPT_PORT
  elif [[ $PREV_SSH_PORT =~ ^[0-9]+$ && $PREV_SSH_PORT != 22 ]]; then
    SSH_PORT=$PREV_SSH_PORT
    log "Использую ранее назначенный порт SSH: $SSH_PORT"
    return 0
  else
    local i p
    for (( i = 0; i < 100; i++ )); do
      p=$(shuf -i "$PORT_MIN-$PORT_MAX" -n 1)
      if ! port_in_use "$p"; then SSH_PORT=$p; break; fi
    done
    [[ -n $SSH_PORT ]] || die "Не нашёл свободный порт"
    log "Случайный порт SSH: $SSH_PORT"
    return 0
  fi
  # порт задан вручную: он не должен быть занят чем-то кроме sshd
  if port_in_use "$SSH_PORT" && ! ss -Htlnp "sport = :$SSH_PORT" | grep -qE 'sshd|systemd'; then
    die "Порт $SSH_PORT уже занят другой программой"
  fi
  log "Порт SSH (задан вручную): $SSH_PORT"
}

client_ip() {
  local ip=${SSH_CONNECTION:-}
  ip=${ip%% *}
  if [[ -z $ip ]]; then
    ip=$(who -m 2>/dev/null | sed -nE 's/.*\(([^)]+)\).*/\1/p' | head -n1)
  fi
  if [[ $ip =~ ^[0-9a-fA-F:.]+$ ]]; then echo "$ip"; fi
}

server_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

ufw_active() {
  command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'
}

# Если файрвол уже был включён до нас (а мы его не настраиваем) — открыть в нём порт.
open_in_existing_firewall() {
  local port=$1
  if ufw_active; then
    ufw allow "$port/tcp" comment 'vps-setup' >/dev/null
    log "UFW уже был включён — открыл в нём $port/tcp"
  fi
  if command -v iptables >/dev/null && iptables -S INPUT 2>/dev/null | grep -q -- '-P INPUT DROP'; then
    warn "Политика iptables INPUT = DROP. Убедитесь, что порт $port/tcp открыт в ваших правилах!"
  fi
}

# ---------------------------------------------------------------- ssh
sshd_test() {
  mkdir -p /run/sshd && chmod 0755 /run/sshd   # без него sshd -t падает при socket activation
  sshd -t
}

sshd_ports() {
  mkdir -p /run/sshd
  sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -un | xargs
}

restart_ssh() {
  systemctl daemon-reload
  if systemctl is-active --quiet ssh.socket; then
    # Ubuntu 22.10+/24.04: порт слушает ssh.socket (генерируется из sshd_config).
    # Текущие сессии не рвутся: у ssh.service KillMode=process.
    systemctl stop ssh.service 2>/dev/null || true
    systemctl restart ssh.socket
    systemctl start ssh.service 2>/dev/null || true
  else
    systemctl restart ssh.service
  fi
}

reload_ssh() {
  if systemctl is-active --quiet ssh.service; then
    systemctl reload ssh.service
  fi
}

restore_ssh_port_config() {
  rm -f "$SSH_DROPIN"
  local f
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    if [[ -f $f ]]; then sed -i "s/^${PORT_MARK}//" "$f"; fi
  done
  return 0
}

setup_ssh_port() {
  local port=$1 main=/etc/ssh/sshd_config f
  step "SSH → порт $port"

  [[ -f $main ]] || die "Нет $main — установлен ли openssh-server?"
  mkdir -p /etc/ssh/sshd_config.d
  backup_file "$main"

  # Подключаем sshd_config.d, если вдруг не подключён (старые/кастомные образы)
  if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main"; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$main"
    log "Добавил Include sshd_config.d в $main"
  fi

  # Директивы Port суммируются, поэтому все чужие Port комментируем (с меткой для отката)
  for f in "$main" /etc/ssh/sshd_config.d/*.conf; do
    [[ -f $f && $f != "$SSH_DROPIN" ]] || continue
    if grep -qiE '^[[:space:]]*Port[[:space:]]' "$f"; then
      backup_file "$f"
      sed -i -E "s/^([[:space:]]*[Pp][Oo][Rr][Tt][[:space:]].*)$/${PORT_MARK}\1/" "$f"
      log "Закомментировал старый Port в $f"
    fi
  done

  printf '# Управляется vps-setup. Откат: sudo vps-rollback\nPort %s\n' "$port" >"$SSH_DROPIN"

  if ! sshd_test; then
    restore_ssh_port_config
    die "sshd -t: ошибка конфигурации, изменения отменены"
  fi

  local ports
  ports=$(sshd_ports)
  [[ $ports == "$port" ]] || warn "sshd будет слушать порты: $ports (ожидался только $port). Проверьте ListenAddress."

  restart_ssh
  if ! wait_listen "$port"; then
    warn "sshd не слушает порт $port — откатываю"
    restore_ssh_port_config
    restart_ssh
    die "Не удалось перевести SSH на порт $port"
  fi
  log "sshd слушает порт $port"

  if [[ $WITH_UFW != 1 ]]; then
    open_in_existing_firewall "$port"
  fi
}

# ---------------------------------------------------------------- автооткат
disarm_rollback() {
  systemctl stop vps-rollback.timer 2>/dev/null || true
  systemctl reset-failed vps-rollback.timer vps-rollback.service 2>/dev/null || true
  ROLLBACK_ARMED_AT=0
}

arm_rollback() {
  [[ $OPT_CONFIRM == 1 ]] || return 0
  disarm_rollback
  systemd-run --quiet --unit=vps-rollback \
    --description="vps-setup: автооткат SSH на 22" \
    --on-active="${ROLLBACK_MIN}min" \
    "$SBIN/vps-rollback" --emergency
  ROLLBACK_ARMED_AT=$(date +%s)
  log "Таймер автоотката взведён на $ROLLBACK_MIN мин (vps-rollback.timer)"
}

confirm_access() {
  [[ $OPT_CONFIRM == 1 ]] || return 0
  local ip user deadline remaining ans rc
  ip=$(server_ip)
  user=${SUDO_USER:-root}
  deadline=$(( ROLLBACK_ARMED_AT + ROLLBACK_MIN * 60 - 15 ))

  printf '\n%s%s' "$C_BOLD" "$C_YELLOW"
  cat <<EOF
╔══════════════════════════════════════════════════════════════════╗
  НЕ ЗАКРЫВАЙТЕ ЭТУ СЕССИЮ!

  Откройте НОВЫЙ терминал и проверьте вход:

      ssh -p $SSH_PORT $user@${ip:-<IP сервера>}

  Если в панели хостера есть свой файрвол / Security Group —
  откройте там TCP $SSH_PORT.

  Без подтверждения через ~$(( (deadline - $(date +%s)) / 60 )) мин всё откатится (SSH снова на 22).
╚══════════════════════════════════════════════════════════════════╝
EOF
  printf '%s' "$C_RESET"

  while true; do
    remaining=$(( deadline - $(date +%s) ))
    if (( remaining <= 0 )); then
      warn "Время вышло — откатываю"
      "$SBIN/vps-rollback" --emergency
      die "Изменения откатаны. SSH снова на 22."
    fi
    rc=0
    read -r -t "$remaining" -p "Вход по порту $SSH_PORT работает? [yes/no]: " ans </dev/tty || rc=$?
    if (( rc != 0 )); then
      echo
      (( rc > 128 )) || sleep 1   # >128 — таймаут; иначе EOF, не крутимся вхолостую
      continue
    fi
    case ${ans,,} in
      yes|y|да|д)
        disarm_rollback
        log "Подтверждено, таймер автоотката снят"
        return 0 ;;
      no|n|нет|н)
        "$SBIN/vps-rollback" --emergency
        die "Изменения откатаны. SSH снова на 22." ;;
      *) echo "Введите yes или no" ;;
    esac
  done
}

# ---------------------------------------------------------------- fail2ban
setup_fail2ban() {
  local port=$1 banaction banaction_all myip ignore
  step "fail2ban"

  if ufw_active; then
    banaction=ufw; banaction_all=ufw
  elif command -v nft >/dev/null; then
    banaction=nftables-multiport; banaction_all=nftables-allports
  elif command -v iptables >/dev/null; then
    banaction=iptables-multiport; banaction_all=iptables-allports
  else
    install_packages nftables
    banaction=nftables-multiport; banaction_all=nftables-allports
  fi

  myip=$(client_ip)
  ignore="127.0.0.1/8 ::1${myip:+ $myip}"
  [[ -n $myip ]] && log "Ваш IP $myip добавлен в ignoreip (не будет забанен)"

  mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/fail2ban.d
  backup_file "$F2B_JAIL" "$F2B_CONF"

  cat >"$F2B_JAIL" <<EOF
# Создано vps-setup ($(date -Is)). Повторный запуск скрипта перезапишет файл.
[DEFAULT]
ignoreip           = $ignore
banaction          = $banaction
banaction_allports = $banaction_all
bantime            = 1h
# повторным нарушителям бан растёт: 1ч → 2ч → 4ч ... до 4 недель
bantime.increment  = true
bantime.maxtime    = 4w
findtime           = 10m
maxretry           = 3

[sshd]
enabled = true
backend = systemd
mode    = aggressive
port = $port

# Тех, кого банили 5 раз за сутки, — на неделю по всем портам
[recidive]
enabled   = true
backend   = auto
logpath   = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime   = 1w
findtime  = 1d
maxretry  = 5
EOF

  cat >"$F2B_CONF" <<EOF
# Создано vps-setup: храним историю банов 30 дней (нужно для bantime.increment и recidive)
[Definition]
dbpurgeage = 30d
EOF

  touch /var/log/fail2ban.log   # без файла recidive не стартует

  if ! fail2ban-client -t >/dev/null 2>&1; then
    fail2ban-client -t || true
    die "Ошибка конфигурации fail2ban (см. выше)"
  fi
  systemctl enable --quiet fail2ban
  systemctl restart fail2ban

  local i
  for (( i = 0; i < 30; i++ )); do
    fail2ban-client ping >/dev/null 2>&1 && break
    sleep 0.5
  done
  if fail2ban-client status sshd >/dev/null 2>&1; then
    log "fail2ban работает: jail sshd (порт $port) + recidive, banaction=$banaction"
  else
    warn "fail2ban не отвечает — проверьте: systemctl status fail2ban"
  fi
}

# ---------------------------------------------------------------- UFW
setup_ufw() {
  local port=$1 p item
  step "UFW (файрвол)"

  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  ufw limit "$port/tcp" comment 'SSH (vps-setup)' >/dev/null
  log "SSH $port/tcp: открыт (limit — не больше 6 подключений за 30 с с одного IP)"

  # Убираем правило старого порта, если порт менялся
  if [[ $PREV_SSH_PORT =~ ^[0-9]+$ && $PREV_SSH_PORT != "$port" && $PREV_SSH_PORT != 22 ]]; then
    ufw delete limit "$PREV_SSH_PORT/tcp" >/dev/null 2>&1 || true
    ufw delete allow "$PREV_SSH_PORT/tcp" >/dev/null 2>&1 || true
    log "Удалил правило старого порта $PREV_SSH_PORT"
  fi

  if [[ $WITH_TARPIT == 1 || $(state_get TARPIT) == 1 ]]; then
    ufw allow 22/tcp comment 'endlessh tarpit' >/dev/null
    log "22/tcp: открыт для ловушки"
  else
    for item in "22/tcp" "22" "OpenSSH"; do
      ufw delete allow "$item" >/dev/null 2>&1 || true
      ufw delete limit "$item" >/dev/null 2>&1 || true
    done
    log "22/tcp: закрыт"
  fi

  if [[ -n $OPT_ALLOW ]]; then
    local -a extra
    IFS=',' read -ra extra <<<"$OPT_ALLOW"
    for p in "${extra[@]}"; do
      p=${p//[[:space:]]/}
      [[ -n $p ]] || continue
      [[ $p =~ ^[0-9]{1,5}(:[0-9]{1,5})?(/(tcp|udp))?$ ]] || die "--allow: не понял '$p' (пример: 80,443/tcp,51820/udp)"
      [[ $p == *:* && $p != */* ]] && die "--allow: для диапазона '$p' укажите протокол (/tcp или /udp)"
      ufw allow "$p" comment 'vps-setup --allow' >/dev/null
      log "Открыт $p"
    done
  fi

  ufw logging low >/dev/null
  ufw --force enable >/dev/null
  log "UFW включён: всё входящее запрещено, кроме разрешённого выше"
  if command -v docker >/dev/null; then
    warn "Найден Docker: опубликованные порты контейнеров (-p) обходят UFW! См. README."
  fi
}

# ---------------------------------------------------------------- endlessh
setup_tarpit() {
  step "Ловушка endlessh на 22 порту"

  if [[ " $(sshd_ports) " == *" 22 "* ]]; then
    die "sshd всё ещё слушает 22 — ловушку ставить нельзя"
  fi

  mkdir -p /etc/endlessh "$(dirname "$ENDLESSH_OVERRIDE")"
  backup_file "$ENDLESSH_CONF"
  cat >"$ENDLESSH_CONF" <<'EOF'
# Создано vps-setup. Ловушка: бесконечно и медленно отдаёт «SSH-баннер».
Port 22
# пауза между строками баннера, мс
Delay 10000
MaxLineLength 32
MaxClients 4096
# 0 = тихо, 1 = логировать подключения (ACCEPT/CLOSE), 2 = отладка
LogLevel 1
# 0 = IPv4 + IPv6
BindFamily 0
EOF

  # Пакетный юнит не может занять порт < 1024 (PrivateUsers=true). Даём ровно одно право.
  cat >"$ENDLESSH_OVERRIDE" <<'EOF'
# Создано vps-setup
[Service]
PrivateUsers=false
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=8192
EOF

  systemctl daemon-reload
  systemctl enable --quiet endlessh
  systemctl restart endlessh

  if wait_listen 22 && ss -Htlnp 'sport = :22' | grep -q endlessh; then
    log "endlessh слушает 22 — боты будут висеть часами"
  else
    warn "endlessh не слушает 22. Смотрите: journalctl -u endlessh -n 50"
  fi

  if [[ $WITH_UFW != 1 ]]; then
    open_in_existing_firewall 22
  fi
  log "На 22 порт fail2ban не вешается специально: бан освободил бы бота из ловушки"
}

# ---------------------------------------------------------------- логи
setup_logging() {
  step "Логи: хранение, архив, ежедневный отчёт"

  mkdir -p /etc/systemd/journald.conf.d /var/log/journal
  cat >/etc/systemd/journald.conf.d/90-vps-setup.conf <<'EOF'
# Создано vps-setup: журнал на диске (переживает перезагрузку), до 500 МБ / 3 месяцев
[Journal]
Storage=persistent
SystemMaxUse=500M
MaxRetentionSec=3month
EOF
  systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
  systemctl restart systemd-journald
  journalctl --flush >/dev/null 2>&1 || true
  log "journald: постоянное хранение, лимит 500M / 3 мес"

  # VERBOSE: в логе будут отпечатки ключей, которыми входили
  printf '# Управляется vps-setup\nLogLevel VERBOSE\n' >"$SSH_LOG_DROPIN"
  if sshd_test; then
    reload_ssh
    log "sshd: LogLevel VERBOSE"
  else
    rm -f "$SSH_LOG_DROPIN"
    warn "sshd не принял LogLevel VERBOSE — пропускаю"
  fi

  install -m 0755 "$VPS_ROOT/tools/report.sh" "$SBIN/vps-report"
  mkdir -p /var/log/vps-report /var/log/vps-archive
  chmod 750 /var/log/vps-report /var/log/vps-archive

  cat >/etc/systemd/system/vps-report.service <<EOF
[Unit]
Description=vps-setup: дневной отчёт и архив логов

[Service]
Type=oneshot
ExecStart=$SBIN/vps-report
Nice=10
EOF
  cat >/etc/systemd/system/vps-report.timer <<'EOF'
[Unit]
Description=vps-setup: ежедневный отчёт

[Timer]
OnCalendar=*-*-* 00:15:00
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now --quiet vps-report.timer
  log "Ежедневный отчёт: /var/log/vps-report/ГГГГ-ММ-ДД.txt, архив логов: /var/log/vps-archive/ (180 дней)"
}

# ---------------------------------------------------------------- инструменты
install_tools() {
  install -m 0755 "$VPS_ROOT/tools/rollback.sh" "$SBIN/vps-rollback"
  install -m 0755 "$VPS_ROOT/tools/status.sh"   "$SBIN/vps-status"
}

print_summary() {
  local ip user
  ip=$(server_ip)
  user=${SUDO_USER:-root}
  step "Готово"
  cat <<EOF
  SSH:        порт ${C_BOLD}$SSH_PORT${C_RESET}   →   ssh -p $SSH_PORT $user@${ip:-<IP>}
  fail2ban:   sshd + recidive        (fail2ban-client status sshd)
EOF
  [[ $WITH_UFW == 1 ]]     && echo "  UFW:        включён                (ufw status verbose)"
  [[ $WITH_TARPIT == 1 ]]  && echo "  Ловушка:    endlessh на 22         (journalctl -u endlessh -f)"
  [[ $WITH_LOGGING == 1 ]] && echo "  Логи:       /var/log/vps-report/, /var/log/vps-archive/  (sudo vps-report — отчёт за вчера)"
  cat <<EOF

  Статус:     sudo vps-status
  Откат:      sudo vps-rollback        (SSH обратно на 22)
  Бэкапы:     $BACKUP_DIR

  ${C_YELLOW}Запишите порт $SSH_PORT! Удобно добавить в ~/.ssh/config:${C_RESET}
      Host myvps
          HostName ${ip:-<IP>}
          Port $SSH_PORT
          User $user
EOF
}

# ---------------------------------------------------------------- главный сценарий
run_setup() {
  set -E
  trap 'on_error $LINENO' ERR

  require_root
  check_os
  check_tty
  PREV_SSH_PORT=$(state_get SSH_PORT)

  step "Пакеты"
  local pkgs=(openssh-server fail2ban python3-systemd)
  if [[ $WITH_UFW == 1 ]];    then pkgs+=(ufw); fi
  if [[ $WITH_TARPIT == 1 ]]; then pkgs+=(endlessh); fi
  install_packages "${pkgs[@]}"
  install_tools

  choose_port
  arm_rollback

  setup_ssh_port "$SSH_PORT"
  if [[ $WITH_UFW == 1 ]];     then setup_ufw "$SSH_PORT"; fi
  setup_fail2ban "$SSH_PORT"
  if [[ $WITH_TARPIT == 1 ]];  then setup_tarpit; fi
  if [[ $WITH_LOGGING == 1 ]]; then setup_logging; fi

  save_state
  confirm_access
  print_summary
}
