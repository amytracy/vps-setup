#!/usr/bin/env bash
# vps-rollback — вернуть SSH на порт 22.
# Ставится в /usr/local/sbin/vps-rollback. Самодостаточный (не зависит от lib/),
# потому что его же запускает таймер автоотката.
#
#   sudo vps-rollback                 SSH → 22, endlessh выключен, 22 открыт в UFW
#   sudo vps-rollback --disable-ufw   то же + выключить UFW
#   sudo vps-rollback --emergency     аварийный режим (= --disable-ufw), его вызывает таймер
set -uo pipefail

STATE_FILE=/etc/vps-setup.conf
SSH_DROPIN=/etc/ssh/sshd_config.d/10-vps-port.conf
F2B_JAIL=/etc/fail2ban/jail.d/zz-vps-setup.local
PORT_MARK='#vps-setup# '
DISABLE_UFW=0

log()  { echo "[vps-rollback] $*"; }
warn() { echo "[vps-rollback] ВНИМАНИЕ: $*" >&2; }

for arg in "$@"; do
  case $arg in
    --emergency)   DISABLE_UFW=1 ;;
    --disable-ufw) DISABLE_UFW=1 ;;
    -h|--help)     sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "Неизвестный аргумент: $arg" >&2; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Запустите через sudo" >&2; exit 1; }

# Если нас запустили вручную — снять таймер автоотката, чтобы не сработал повторно
systemctl stop vps-rollback.timer 2>/dev/null || true

# 1. Ловушка занимает 22 — выключаем первой
if systemctl is-enabled --quiet endlessh 2>/dev/null || systemctl is-active --quiet endlessh 2>/dev/null; then
  systemctl disable --now endlessh >/dev/null 2>&1 || true
  log "endlessh остановлен и выключен"
fi

# 2. Конфиг sshd: убрать наш Port, вернуть закомментированные строки
rm -f "$SSH_DROPIN"
for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
  if [[ -f $f ]]; then sed -i "s/^${PORT_MARK}//" "$f"; fi
done
mkdir -p /run/sshd && chmod 0755 /run/sshd
if ! sshd -t; then
  warn "sshd -t сообщает об ошибке конфигурации — проверьте /etc/ssh/sshd_config"
fi

# 3. Файрвол: открыть 22 до перезапуска sshd
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  if (( DISABLE_UFW )); then
    ufw --force disable >/dev/null
    log "UFW выключен"
  else
    ufw allow 22/tcp comment 'vps-rollback' >/dev/null
    log "UFW: открыт 22/tcp"
  fi
fi

# 4. Перезапуск sshd (текущие сессии не рвутся)
systemctl daemon-reload
if systemctl is-active --quiet ssh.socket; then
  systemctl stop ssh.service 2>/dev/null || true
  systemctl restart ssh.socket
  systemctl start ssh.service 2>/dev/null || true
else
  systemctl restart ssh.service
fi

# 5. fail2ban: следить за 22 портом
if [[ -f $F2B_JAIL ]]; then
  sed -i -E 's/^port = .*/port = ssh/' "$F2B_JAIL"
  fail2ban-client reload >/dev/null 2>&1 || systemctl restart fail2ban || true
  log "fail2ban: jail sshd переключён на 22"
fi

# 6. Состояние
if [[ -f $STATE_FILE ]]; then
  sed -i -E 's/^SSH_PORT=.*/SSH_PORT=22/; s/^TARPIT=.*/TARPIT=0/' "$STATE_FILE"
fi

sleep 1
if ss -Htln 'sport = :22' | grep -q .; then
  log "Готово: SSH снова слушает порт 22"
else
  warn "Порт 22 не слушается! Проверьте: systemctl status ssh ssh.socket"
  exit 1
fi
