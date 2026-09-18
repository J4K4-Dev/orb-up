#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

mkdir -p "$TEMP/bin"
cat > "$TEMP/bin/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == -l ]]; then
	if [[ "${CRON_FAILURE:-0}" == 1 ]]; then
		printf 'permission denied\n' >&2
		exit 1
	fi
	if [[ ! -f "$CRON_FILE" ]]; then
		printf 'no crontab for test-user\n' >&2
		exit 1
	fi
	cat "$CRON_FILE"
else
	cat > "$CRON_FILE"
fi
EOF
chmod +x "$TEMP/bin/crontab"
export PATH="$TEMP/bin:$PATH"
export HOME="$TEMP/home"
export CRON_FILE="$TEMP/crontab"

check_uninstall() {
	local install_dir="$1" plugin_dir="$2"
	mkdir -p "$install_dir" "$plugin_dir" "$HOME/.local/state/orb-up"
	touch "$install_dir/orb-up" "$install_dir/amp" "$plugin_dir/orb-up-idle.ts" "$plugin_dir/other.ts"
	printf 'saved log\n' > "$HOME/.local/state/orb-up/update.log"
	printf '0 0 * * * unrelated-job\n' > "$TEMP/expected-crontab"
	cat "$TEMP/expected-crontab" > "$CRON_FILE"
	printf '17 * * * * orb-up update # orb-up automatic update\n' >> "$CRON_FILE"
	bash "$ROOT/uninstall.sh"
	[[ ! -e "$install_dir/orb-up" && ! -e "$plugin_dir/orb-up-idle.ts" ]]
	[[ -f "$install_dir/amp" && -f "$plugin_dir/other.ts" ]]
	grep -qx 'saved log' "$HOME/.local/state/orb-up/update.log"
	cmp "$TEMP/expected-crontab" "$CRON_FILE"
	bash "$ROOT/uninstall.sh"
	cmp "$TEMP/expected-crontab" "$CRON_FILE"
}

check_uninstall "$HOME/.local/bin" "$HOME/.config/amp/plugins"
printf 'PASS: default uninstall preserves unrelated files and cron entries; repeat succeeds\n'

export ORB_UP_INSTALL_DIR="$TEMP/custom bin"
export ORB_UP_PLUGIN_DIR="$TEMP/custom plugins"
check_uninstall "$ORB_UP_INSTALL_DIR" "$ORB_UP_PLUGIN_DIR"
printf 'PASS: custom directories with spaces\n'

printf '17 * * * * orb-up update # orb-up automatic update\n' > "$CRON_FILE"
bash "$ROOT/uninstall.sh"
[[ ! -s "$CRON_FILE" ]]
rm "$CRON_FILE"
bash "$ROOT/uninstall.sh"
[[ ! -e "$CRON_FILE" ]]
printf 'PASS: orb-up-only and absent crontabs\n'

touch "$ORB_UP_INSTALL_DIR/orb-up" "$ORB_UP_PLUGIN_DIR/orb-up-idle.ts"
if CRON_FAILURE=1 bash "$ROOT/uninstall.sh" > "$TEMP/failure-output" 2>&1; then
	printf 'FAIL: crontab error was ignored\n' >&2
	exit 1
fi
[[ -f "$ORB_UP_INSTALL_DIR/orb-up" && -f "$ORB_UP_PLUGIN_DIR/orb-up-idle.ts" ]]
grep -q 'nothing was removed' "$TEMP/failure-output"
printf 'PASS: crontab errors leave installation intact\n'
