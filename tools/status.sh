#!/usr/bin/env bash
# vps-status — сводка: порт SSH, fail2ban, UFW, ловушка, отчёты.
# Ставится в /usr/local/sbin/vps-status.
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "Запустите через sudo" >&2; exit 1; }

if [[ -t 1 ]]; then H=$'\e[1;36m' B=$'\e[1m' R=$'\e[0m'; else H="" B="" R=""; fi
hdr() { printf '\n%s== %s ==%s\n' "$H" "$1" "$R"; }
indent() { sed 's/^/  /'; }
STATE_FILE=/etc/vps-setup.conf
state() { [[ -r $STATE_FILE ]] && sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1; }

# ---------------------------------------------------------------- SSH
hdr "SSH"
mkdir -p /run/sshd
echo "  Порт(ы) в конфиге: ${B}$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | xargs)${R}"
echo "  Слушают:"
ss -Htlnp | grep -E 'sshd|"systemd"' | awk '{print $4, $6}' | indent | indent
echo "  Активных SSH-сессий: $(who | wc -l)"

# ---------------------------------------------------------------- fail2ban
hdr "fail2ban"
if systemctl is-active --quiet fail2ban; then
  for jail in sshd recidive; do
    out=$(fail2ban-client status "$jail" 2>/dev/null) || continue
    cur=$(awk -F':\t*' '/Currently banned/ {print $2}' <<<"$out" | xargs)
    tot=$(awk -F':\t*' '/Total banned/ {print $2}' <<<"$out" | xargs)
    failed=$(awk -F':\t*' '/Total failed/ {print $2}' <<<"$out" | xargs)
    printf '  %-9s забанено сейчас: %s, всего банов: %s, неудачных попыток: %s\n' \
      "$jail" "${cur:-0}" "${tot:-0}" "${failed:-?}"
  done
  echo "  Последние баны:"
  grep -h ' Ban ' /var/log/fail2ban.log 2>/dev/null | tail -n 5 \
    | sed -E 's/^([0-9-]+ [0-9:]+),[0-9]+ .*\[([a-z]+)\] Ban (.*)$/\1  [\2]  \3/' | indent | indent
else
  echo "  не запущен"
fi

# ---------------------------------------------------------------- UFW
hdr "UFW"
if command -v ufw >/dev/null; then
  ufw status numbered 2>/dev/null | grep -vE '^\s*$|^--|To\s+Action' | indent
else
  echo "  не установлен"
fi

# ---------------------------------------------------------------- endlessh
hdr "Ловушка endlessh (22)"
if systemctl is-active --quiet endlessh; then
  trapped=$(ss -Htnp state established '( sport = :22 )' 2>/dev/null | grep -c endlessh)
  echo "  Статус: работает. Ботов в ловушке прямо сейчас: ${B}${trapped}${R}"
  echo "  Подключений за 24 ч: $(journalctl -u endlessh --since -24h -q --no-pager 2>/dev/null | grep -c 'ACCEPT ')"
  if (( trapped > 0 )); then
    echo "  Топ IP в ловушке:"
    ss -Htnp state established '( sport = :22 )' 2>/dev/null | grep endlessh \
      | awk '{print $4}' | sed -E 's/^\[?(::ffff:)?//; s/\]?:[0-9]+$//' \
      | sort | uniq -c | sort -rn | head -n 5 | indent | indent
  fi
  echo "  Рекордсмены за 24 ч (сколько просидели):"
  journalctl -u endlessh --since -24h -q --no-pager 2>/dev/null \
    | sed -nE 's/.*CLOSE host=(::ffff:)?([^ ]+) .*time=([0-9.]+).*/\3 \2/p' \
    | sort -rn | head -n 3 | awk '{printf "%8.1f мин  %s\n", $1/60, $2}' | indent | indent
else
  if [[ $(state TARPIT) == 1 ]]; then echo "  НЕ РАБОТАЕТ (ожидался): journalctl -u endlessh -n 30"; else echo "  не установлена"; fi
fi

# ---------------------------------------------------------------- прочее
hdr "Прочее"
if systemctl is-active --quiet vps-rollback.timer; then
  echo "  ${B}Таймер автоотката АКТИВЕН${R}: $(systemctl list-timers vps-rollback.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3}')"
fi
if [[ -d /var/log/vps-report ]]; then
  # shellcheck disable=SC2012  # имена файлов — даты
  last=$(ls -1t /var/log/vps-report/*.txt 2>/dev/null | head -n1)
  echo "  Последний отчёт: ${last:-ещё нет (появится после полуночи, или: sudo vps-report)}"
  echo "  Архив логов: $(du -sh /var/log/vps-archive 2>/dev/null | cut -f1) в /var/log/vps-archive"
fi
echo "  Журнал systemd: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?B?' | head -n1)"
[[ -r $STATE_FILE ]] && echo "  Состояние: $STATE_FILE ($(state UPDATED))"
echo
