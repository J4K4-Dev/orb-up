#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! grep -Fq 'New-ScheduledTaskAction -Execute $executable -Argument "-WindowStyle Hidden ' "$ROOT/orb-up.ps1"; then
	printf 'FAIL: scheduled updater does not launch PowerShell with a hidden window\n' >&2
	exit 1
fi

printf 'PASS: scheduled updater launches PowerShell with a hidden window\n'
