#!/usr/bin/env bash
# Auto-start openab as a detached background process.
#
# Invoked by postStartCommand (after the firewall) on every container start.
# Best-effort by design: a missing binary or unset tokens just skip — this
# script never fails container startup.
set -uo pipefail

WORKSPACE="/workspaces/claude-sandbox"
OPENAB_DIR="$WORKSPACE/openab"
BIN="$OPENAB_DIR/target/release/openab"
CONFIG="$OPENAB_DIR/config.toml"
LOG="$OPENAB_DIR/openab.log"

# Already running (e.g. container restart without a full rebuild)? Leave it.
if pgrep -f 'openab run' >/dev/null 2>&1; then
  echo "start-openab: openab already running — nothing to do"
  exit 0
fi

# Release binary present? postCreateCommand runs 'cargo build --release'.
if [[ ! -x "$BIN" ]]; then
  echo "start-openab: $BIN not found — run 'cargo build --release' in $OPENAB_DIR" >&2
  exit 0
fi

# Tokens arrive via remoteEnv (${localEnv:...}) from the host environment.
if [[ -z "${SLACK_BOT_TOKEN:-}" || -z "${SLACK_APP_TOKEN:-}" ]]; then
  echo "start-openab: SLACK_BOT_TOKEN / SLACK_APP_TOKEN not set on the host — skipping autostart" >&2
  exit 0
fi

# Detach into its own session so openab outlives this lifecycle hook.
cd "$OPENAB_DIR"
setsid "$BIN" run -c "$CONFIG" > "$LOG" 2>&1 < /dev/null &
echo "start-openab: launched openab (detached) — logs at $LOG"
exit 0
