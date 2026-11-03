#!/usr/bin/env bash
# 02-firewall.sh — SSH на случайный порт + fail2ban + UFW: всё входящее закрыто, кроме SSH и портов из --allow.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

USAGE="Использование: sudo bash 02-firewall.sh [опции]

SSH на случайный порт + fail2ban + UFW: всё входящее закрыто, кроме SSH и портов из --allow."

WITH_UFW=1
WITH_TARPIT=0
WITH_LOGGING=0

parse_args "$@"
run_setup
