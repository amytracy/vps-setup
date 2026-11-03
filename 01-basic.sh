#!/usr/bin/env bash
# 01-basic.sh — SSH на случайный порт + fail2ban (базовый минимум).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

USAGE="Использование: sudo bash 01-basic.sh [опции]

SSH на случайный порт + fail2ban (базовый минимум)."

WITH_UFW=0
WITH_TARPIT=0
WITH_LOGGING=0

parse_args "$@"
run_setup
