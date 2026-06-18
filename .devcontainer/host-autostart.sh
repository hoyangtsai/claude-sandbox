#!/usr/bin/env bash
# Host-side autostart for the claude-sandbox dev container.
#
# Invoked by a macOS LaunchAgent (com.hoyang.claude-sandbox-autostart) at login
# and whenever OrbStack's Docker socket (re)appears. It waits for the Docker
# engine to be ready, then runs `devcontainer up`, which re-runs the container's
# postStartCommand — applying the firewall FIRST, then launching openab.
#
# Why not a Docker `--restart` policy? A plain container restart does NOT re-run
# postStartCommand, so the deny-by-default firewall would never be applied and
# the trust-all-tools agent would lose its containment. Going through
# `devcontainer up` preserves the firewall-first ordering.
set -uo pipefail

WORKSPACE="/Users/hoyang/claude-sandbox"
# LaunchAgents get a minimal PATH; add Node (for the devcontainer CLI) + docker.
export PATH="/Users/hoyang/.nvm/versions/node/v23.11.0/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

LOG="$HOME/Library/Logs/claude-sandbox-autostart.log"
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG"; }

# Single-flight: WatchPaths can fire several times in quick succession.
LOCK="/tmp/claude-sandbox-autostart.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  log "another autostart run holds the lock — exiting"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

log "autostart triggered"

# Wait (up to ~2 min) for the Docker engine to accept connections. On login
# OrbStack may still be booting; on a manual OrbStack start the socket exists
# but the engine needs a moment.
ready=false
for _ in $(seq 1 60); do
  if docker info >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  log "docker engine not ready after timeout — giving up (will retry on next trigger)"
  exit 0
fi
log "docker engine ready"

# Bring the dev container up. Idempotent: starts it if stopped, runs postStart.
log "running: devcontainer up --workspace-folder $WORKSPACE"
devcontainer up --workspace-folder "$WORKSPACE" >> "$LOG" 2>&1
rc=$?
log "devcontainer up exited rc=$rc"

# --- Safety net: guarantee the firewall is active before openab serves -------
# This container's baked devcontainer.metadata may carry a STALE postStartCommand
# (predating the firewall), so `devcontainer up` can start openab uncontained.
# Don't trust it — verify the OUTPUT policy is DROP; if not, apply the firewall
# and restart openab so the trust-all-tools agent only ever runs behind it.
C="$(docker ps -q --filter "label=devcontainer.local_folder=$WORKSPACE" | head -1)"
if [[ -z "$C" ]]; then
  log "WARN: no running container found for $WORKSPACE — cannot verify firewall"
  exit 0
fi

if docker exec "$C" bash -lc 'sudo iptables -L OUTPUT -n 2>/dev/null | head -1 | grep -q "policy DROP"'; then
  log "firewall already active (OUTPUT policy DROP) — ok"
else
  log "WARN: firewall NOT active after up — applying it now and restarting openab"
  docker exec "$C" bash -lc 'sudo /usr/local/bin/init-firewall.sh' >> "$LOG" 2>&1
  # Stop openab and WAIT for it to actually exit — pkill is async and openab
  # takes a few seconds to shut down; restarting too early hits start-openab's
  # "already running" guard and leaves nothing running.
  docker exec "$C" bash -lc '
    pkill -TERM -f "[o]penab run" 2>/dev/null || true
    for _ in $(seq 1 15); do pgrep -f "[o]penab run" >/dev/null || break; sleep 1; done
    pgrep -f "[o]penab run" >/dev/null && pkill -KILL -f "[o]penab run" || true
    sleep 1' >> "$LOG" 2>&1
  docker exec -u vscode "$C" bash -lc 'bash /workspaces/claude-sandbox/.devcontainer/start-openab.sh' >> "$LOG" 2>&1
  if docker exec "$C" bash -lc 'sudo iptables -L OUTPUT -n 2>/dev/null | head -1 | grep -q "policy DROP"'; then
    log "firewall now active — openab restarted contained"
  else
    log "ERROR: firewall still not active — stopping openab to stay fail-closed"
    docker exec "$C" bash -lc 'pkill -f "[o]penab run" || true' >> "$LOG" 2>&1
  fi
fi
exit 0
