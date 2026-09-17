# orb-up

> **Retired:** Amp runners now support built-in automatic updates that wait until idle, making this wrapper unnecessary. See [One Runner Is Now Enough](https://ampcode.com/news/one-runner-is-now-enough). Use `amp --no-tui` directly instead.

A small Bash wrapper for running an [Amp](https://ampcode.com) runner in tmux, with automatic updates that wait until the runner is idle.

## Install

You'll need Bash, tmux, cron, `pgrep`, and curl on the machine that will host the runner. Install `orb-up` with:

```bash
curl -fsSL https://raw.githubusercontent.com/J4K4-Dev/orb-up/main/install.sh | bash
```

The installer:

- Installs Amp using its official installer if it isn't already available.
- Installs `orb-up` in `~/.local/bin`.
- Installs an Amp lifecycle plugin to track whether the runner is idle.
- Adds an update check to your crontab, scheduled for 17 minutes past every hour.

## Start a runner

Make sure `~/.local/bin` is on your `PATH`. Log in with `amp login` if you haven't already, then start the runner in the project directory where it should accept work:

```bash
orb-up start /path/to/project
```

If `orb-up` finds an existing `amp --no-tui` process outside its tmux session, it shows the process and asks before stopping it. Confirm only after checking that the existing runner is idle. A declined or unavailable confirmation leaves the process untouched and cancels the start.

By default, the runner uses the machine's short hostname as its stable runner ID. You can pass Amp options after the directory to choose a different ID or enable remote terminal access:

```bash
orb-up start /path/to/project --runner-id build-01 --remote-control-terminal
```

## Commands

```text
orb-up start [directory] [amp options]
orb-up status
orb-up logs [lines]
orb-up attach
orb-up restart
orb-up stop
orb-up update
orb-up enable-updates
orb-up disable-updates
```

## Automatic updates

The hourly check runs `orb-up update` to update Amp and restart the runner if Amp has changed. You can also run the command manually.

If the runner is busy, or its idle state can't be verified, the update waits until the next check. Before restarting, `orb-up` checks again: if work began during the update, the restart stays pending until a later idle check.

When upgrading an existing `orb-up` installation, run `orb-up restart` once while the runner is idle to load the idle-tracking plugin.

Update output is written to `~/.local/state/orb-up/update.log`, or `$XDG_STATE_HOME/orb-up/update.log` if `XDG_STATE_HOME` is set. `ORB_UP_STATE_DIR` overrides this directory.

## Configuration

Use environment variables to customize the tmux session, default runner ID, or update schedule. For a custom session, use the same setting when registering updates and starting the runner:

```bash
export ORB_UP_SESSION=my-runner
orb-up enable-updates
orb-up start /srv/project
```

To choose a default runner ID:

```bash
ORB_UP_RUNNER_ID=build-01 orb-up start /srv/project
```

To check for updates at 02:30 every Sunday instead of hourly:

```bash
ORB_UP_UPDATE_CRON='30 2 * * 0' orb-up enable-updates
```
