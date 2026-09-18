#!/usr/bin/env bash
set -euo pipefail

install_directory="${ORB_UP_INSTALL_DIR:-$HOME/.local/bin}"
plugin_directory="${ORB_UP_PLUGIN_DIR:-$HOME/.config/amp/plugins}"
cron_marker='# orb-up automatic update'

# Work without the installed wrapper, including after a partial uninstall.
if command -v crontab >/dev/null 2>&1; then
	temporary_directory="$(mktemp -d)"
	trap 'rm -rf "$temporary_directory"' EXIT
	if existing_crontab="$(LC_ALL=C crontab -l 2> "$temporary_directory/cron-error")"; then
		if [[ "$existing_crontab" == *"$cron_marker"* ]]; then
			{ printf '%s\n' "$existing_crontab" | grep -vF "$cron_marker" || [[ $? -eq 1 ]]; } | crontab -
		fi
	elif ! grep -q 'no crontab for' "$temporary_directory/cron-error"; then
		cat "$temporary_directory/cron-error" >&2
		printf 'orb-up uninstaller: could not read crontab; nothing was removed.\n' >&2
		exit 1
	fi
else
	printf 'crontab is unavailable; skipping automatic update job removal.\n' >&2
fi

rm -f "$install_directory/orb-up" "$plugin_directory/orb-up-idle.ts"

session="${ORB_UP_SESSION:-amp-runner}"
if command -v tmux >/dev/null 2>&1 && tmux has-session -t "=$session" 2>/dev/null; then
	printf 'Runner session "%s" is still running. Only stop it if it is idle.\n' "$session"
	reply=''
	# stdin may contain this script (curl | bash), so ask on the controlling terminal.
	if { exec 3<> /dev/tty; } 2>/dev/null; then
		printf 'Stop this runner session now? [y/N] ' >&3
		IFS= read -r reply <&3 || reply=''
		exec 3>&-
	fi
	case "$reply" in
		y | Y | yes | YES | Yes)
			tmux kill-session -t "=$session"
			printf 'Stopped runner session "%s".\n' "$session"
			;;
		*) printf 'Session "%s" was left running; stop it when idle before starting a replacement.\n' "$session" ;;
	esac
fi

printf 'orb-up is uninstalled. Amp and saved state/logs were left intact.\n'
