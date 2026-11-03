#!/usr/bin/env bash
# 04-tarpit.sh — SSH на случайный порт + fail2ban + ловушка endlessh на 22 порту.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

USAGE="Использование: sudo bash 04-tarpit.sh [опции]

SSH на случайный порт + fail2ban + ловушка endlessh на 22 порту."

WITH_UFW=0
WITH_TARPIT=1
WITH_LOGGING=0

parse_args "$@"
run_setup
