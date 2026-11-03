#!/usr/bin/env bash
# 03-logging.sh — SSH на случайный порт + fail2ban + постоянные логи, архив и ежедневный отчёт.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

USAGE="Использование: sudo bash 03-logging.sh [опции]

SSH на случайный порт + fail2ban + постоянные логи, архив и ежедневный отчёт."

WITH_UFW=0
WITH_TARPIT=0
WITH_LOGGING=1

parse_args "$@"
run_setup
