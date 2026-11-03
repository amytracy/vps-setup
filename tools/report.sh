#!/usr/bin/env bash
# vps-report — отчёт за сутки + архив логов в текстовом виде.
# Ставится в /usr/local/sbin/vps-report, запускается таймером vps-report.timer после полуночи.
#
#   sudo vps-report               отчёт за вчера
#   sudo vps-report 2026-11-03    отчёт за конкретный день
#
# Результат:
#   /var/log/vps-report/ГГГГ-ММ-ДД.txt                       — отчёт (хранится 365 дней)
#   /var/log/vps-archive/ГГГГ-ММ-ДД/{ssh,sudo,fail2ban,endlessh,ufw}.log.gz — сырые логи (180 дней)
set -uo pipefail

DAY=${1:-$(date -d yesterday +%F)}
date -d "$DAY" >/dev/null 2>&1 || { echo "Неверная дата: $DAY (нужно ГГГГ-ММ-ДД)" >&2; exit 1; }
NEXT=$(date -d "$DAY +1 day" +%F)
REPORT_DIR=/var/log/vps-report
ARCHIVE_ROOT=/var/log/vps-archive
ARCHIVE_DIR=$ARCHIVE_ROOT/$DAY
KEEP_ARCHIVE_DAYS=${KEEP_ARCHIVE_DAYS:-180}
KEEP_REPORT_DAYS=${KEEP_REPORT_DAYS:-365}

[[ $EUID -eq 0 ]] || { echo "Запустите через sudo" >&2; exit 1; }
mkdir -p "$REPORT_DIR" "$ARCHIVE_DIR"
chmod 750 "$REPORT_DIR" "$ARCHIVE_ROOT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

j() { journalctl --no-pager -q -o short-iso --since "$DAY 00:00:00" --until "$NEXT 00:00:00" "$@" 2>/dev/null; }

# ---------------------------------------------------------------- сбор
j -t sshd -t sshd-session -t sshd-auth >"$TMP/ssh.log"
j -t sudo -t su                        >"$TMP/sudo.log"
j -u endlessh                          >"$TMP/endlessh.log"
j -k | grep 'UFW '                     >"$TMP/ufw.log"
zgrep -h "^$DAY" /var/log/fail2ban.log* 2>/dev/null | sort >"$TMP/fail2ban.log"

for f in ssh sudo fail2ban endlessh ufw; do
  if [[ -s $TMP/$f.log ]]; then gzip -c "$TMP/$f.log" >"$ARCHIVE_DIR/$f.log.gz"; fi
done
chmod 640 "$ARCHIVE_DIR"/* 2>/dev/null

# ---------------------------------------------------------------- отчёт
top()    { sort | uniq -c | sort -rn | head -n "${1:-10}" | awk '{printf "    %6d  %s\n", $1, $2}'; }
or_none() { local s; s=$(cat); if [[ -n $s ]]; then echo "$s"; else echo "    —"; fi; }
FAIL_RE='Failed (password|publickey|keyboard-interactive)|Invalid user|authentication failure|maximum authentication attempts'

{
  echo "Отчёт VPS $(hostname) за $DAY"
  echo "Сформирован: $(date '+%F %T')"

  echo
  echo "=== SSH ==="
  echo "Неудачных попыток входа: $(grep -cE "$FAIL_RE" "$TMP/ssh.log")"
  echo "Топ-10 IP по неудачным попыткам:"
  grep -E "$FAIL_RE" "$TMP/ssh.log" | sed -nE 's/.* from ([0-9a-fA-F:.]+) port .*/\1/p' | top 10 | or_none
  echo "Топ-10 перебираемых логинов:"
  sed -nE 's/.*Invalid user ([^ ]*) from .*/\1/p' "$TMP/ssh.log" | top 10 | or_none
  echo "Успешные входы:"
  grep 'Accepted ' "$TMP/ssh.log" \
    | sed -E 's/^([^ ]+) [^ ]+ [^:]+: Accepted ([^ ]+) for ([^ ]+) from ([^ ]+) port [0-9]+.*/    \1  \3 ← \4 (\2)/' | or_none

  echo
  echo "=== fail2ban ==="
  echo "Банов: $(grep -c ' Ban ' "$TMP/fail2ban.log"), разбанов: $(grep -c ' Unban ' "$TMP/fail2ban.log")"
  echo "Забаненные IP:"
  sed -nE 's/.* Ban ([^ ]+).*/\1/p' "$TMP/fail2ban.log" | top 15 | or_none

  echo
  echo "=== Ловушка endlessh (порт 22) ==="
  echo "Подключений: $(grep -c 'ACCEPT ' "$TMP/endlessh.log"), уникальных IP: $(sed -nE 's/.*ACCEPT host=(::ffff:)?([^ ]+).*/\2/p' "$TMP/endlessh.log" | sort -u | wc -l)"
  sed -nE 's/.*CLOSE .*time=([0-9.]+).*/\1/p' "$TMP/endlessh.log" \
    | awk '{s += $1; if ($1 > m) m = $1} END {printf "Время ботов потрачено впустую: %.1f ч (рекорд одного подключения: %.1f мин)\n", s/3600, m/60}'
  echo "Самые настойчивые:"
  sed -nE 's/.*ACCEPT host=(::ffff:)?([^ ]+).*/\2/p' "$TMP/endlessh.log" | top 10 | or_none

  echo
  echo "=== UFW ==="
  echo "Заблокированных пакетов: $(grep -c 'UFW BLOCK' "$TMP/ufw.log")"
  echo "Топ портов, куда стучались:"
  grep 'UFW BLOCK' "$TMP/ufw.log" | sed -nE 's/.* PROTO=([A-Z]+) .*DPT=([0-9]+).*/\2\/\1/p' | top 10 | or_none
  echo "Топ источников:"
  grep 'UFW BLOCK' "$TMP/ufw.log" | sed -nE 's/.* SRC=([^ ]+) .*/\1/p' | top 10 | or_none

  echo
  echo "=== sudo ==="
  grep -E 'COMMAND=' "$TMP/sudo.log" | sed -E 's/^([^ ]+) [^ ]+ sudo\[[0-9]+\]: *([^ ]+) : .*COMMAND=(.*)/    \1  \2: \3/' | tail -n 30 | or_none

  echo
  echo "Сырые логи: $ARCHIVE_DIR/"
} >"$REPORT_DIR/$DAY.txt"
chmod 640 "$REPORT_DIR/$DAY.txt"

# ---------------------------------------------------------------- очистка
find "$ARCHIVE_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_ARCHIVE_DAYS" -exec rm -rf {} + 2>/dev/null
find "$REPORT_DIR" -maxdepth 1 -name '*.txt' -mtime +"$KEEP_REPORT_DAYS" -delete 2>/dev/null

if [[ -t 1 ]]; then cat "$REPORT_DIR/$DAY.txt"; else echo "Отчёт: $REPORT_DIR/$DAY.txt"; fi
