#!/usr/bin/env bash
# 05-full.sh — Всё сразу: SSH на случайный порт, fail2ban, UFW, ловушка endlessh на 22, логи и отчёты.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

USAGE="Использование: sudo bash 05-full.sh [опции]

Всё сразу: SSH на случайный порт, fail2ban, UFW, ловушка endlessh на 22, логи и отчёты."

WITH_UFW=1
WITH_TARPIT=1
WITH_LOGGING=1

parse_args "$@"
run_setup
