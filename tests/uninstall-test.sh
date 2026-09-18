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
cat > "$TEMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
	has-session) [[ "${SESSION_EXISTS:-0}" == 1 && "$3" == "=${ORB_UP_SESSION:-amp-runner}" ]] ;;
	kill-session) ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$TEMP/bin/crontab" "$TEMP/bin/tmux"
export PATH="$TEMP/bin:$PATH"
export HOME="$TEMP/home"
export CRON_FILE="$TEMP/crontab"
export TMUX_LOG="$TEMP/tmux.log"

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

# Exercise a real controlling terminal with the script piped into Bash.
python3 - "$ROOT/uninstall.sh" <<'PY'
import errno
import os
import pty
import select
import subprocess
import sys
import time

script = sys.argv[1]
for answer in ('y', 'n', '', 'yes'):
    os.environ['SESSION_EXISTS'] = '1'
    os.environ['ORB_UP_SESSION'] = 'custom-runner' if answer == 'yes' else 'amp-runner'
    open(os.environ['TMUX_LOG'], 'w').close()
    pid, fd = pty.fork()
    if pid == 0:
        os.execlp('bash', 'bash', '-c', 'cat "$1" | bash', 'test', script)
    output = b''
    replied = False
    deadline = time.monotonic() + 10
    try:
        while True:
            assert time.monotonic() < deadline, 'uninstall prompt timed out'
            if not select.select([fd], [], [], 0.1)[0]:
                continue
            try:
                chunk = os.read(fd, 4096)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output += chunk
            if b'[y/N]' in output and not replied:
                os.write(fd, (answer + '\n').encode())
                replied = True
    finally:
        os.close(fd)
    _, status = os.waitpid(pid, 0)
    assert status == 0 and replied, output
    with open(os.environ['TMUX_LOG']) as log:
        kills = [line.strip() for line in log if line.startswith('kill-session')]
    expected = ['kill-session -t =' + os.environ['ORB_UP_SESSION']] if answer in ('y', 'yes') else []
    assert kills == expected, (kills, expected)
    assert (b'Stopped runner session' if expected else b'was left running') in output, output
print('PASS: piped uninstall prompts on terminal; yes, no, Enter, and custom session')

for exists in ('0', '1'):
    os.environ['SESSION_EXISTS'] = exists
    open(os.environ['TMUX_LOG'], 'w').close()
    result = subprocess.run(['bash', script], input='', text=True, capture_output=True, start_new_session=True, timeout=10)
    assert result.returncode == 0, result.stderr
    with open(os.environ['TMUX_LOG']) as log:
        assert 'kill-session' not in log.read()
    assert ('was left running' in result.stdout) == (exists == '1'), result.stdout
print('PASS: absent session and no-terminal uninstall never stop sessions')
PY
