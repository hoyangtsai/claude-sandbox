# claude-sandbox

A network-firewalled **dev container** that runs **openab** — a Slack/Discord
ACP broker — with Claude Code as its agent backend. The container *is* the
sandbox: openab drives a Claude Code agent in trust-all-tools mode, and a
deny-by-default firewall is what makes that safe.

## Layout

```
claude-sandbox/
├── .devcontainer/          Dev container definition (this wrapper)
│   ├── devcontainer.json   Features, mounts, lifecycle hooks, remoteEnv
│   ├── Dockerfile          Debian base + firewall tooling (iptables/ipset)
│   ├── init-firewall.sh    Deny-by-default outbound firewall (runs every start)
│   ├── allowed-domains.txt Editable firewall allowlist
│   └── start-openab.sh     Auto-launches openab detached on container start
└── openab/                 Clone of github.com/openabdev/openab
    └── config.toml          openab config (gitignored)
```

`.devcontainer/` is part of this wrapper, **not** the openab repo — the openab
clone in `openab/` stays a clean upstream checkout.

## What runs here

- **openab** (Rust) — bridges Slack ↔ a coding agent over the Agent Client
  Protocol (ACP), spawning one agent subprocess per conversation.
- **claude-agent-acp** — the adapter openab spawns; bridges openab ↔ Claude
  Code. `config.toml` uses `[agent] command = "claude-agent-acp"`. Claude Code
  has no `--acp` flag — this adapter is required.
- openab **auto-approves** every agent tool-permission request, so the agent
  runs trust-all-tools / YOLO. The **firewall is the containment** for that.

## The firewall

`init-firewall.sh` runs on every container start (`postStartCommand`).
Deny-by-default: it sets the `OUTPUT` policy to `DROP` first (fail-closed),
then allows only the IPs of domains in `.devcontainer/allowed-domains.txt`
(Slack, Anthropic API, GitHub, crates.io, npm, …).

Edit the allowlist, then re-apply without a rebuild:

```bash
sudo /usr/local/bin/init-firewall.sh
```

## Running openab

Slack tokens reach openab two ways, checked in order by `start-openab.sh`:

1. **Host environment** via `remoteEnv` (`${localEnv:...}`) — works when you run
   `devcontainer up` from a shell that exported the tokens:

   ```bash
   export SLACK_BOT_TOKEN='xoxb-...'
   export SLACK_APP_TOKEN='xapp-...'
   devcontainer up --workspace-folder ~/Code/claude-sandbox
   ```

2. **Persisted env file** `~/.claude/openab.env` (mode 600) on the
   `openab-config` volume — the fallback when the host env is empty (GUI/VS Code
   launches don't inherit your shell profile; host reboots lose the export).
   This is what makes autostart reliable regardless of launch method. It lives
   next to the `claude auth` credentials on the same volume, survives rebuilds,
   and is **not** in git or the image. Create/refresh it inside the container:

   ```bash
   printf 'export SLACK_BOT_TOKEN=%q\nexport SLACK_APP_TOKEN=%q\n' \
     "$SLACK_BOT_TOKEN" "$SLACK_APP_TOKEN" > ~/.claude/openab.env
   chmod 600 ~/.claude/openab.env
   ```

- **postCreate** installs the ACP adapter + Claude Code CLI and builds
  `openab/target/release/openab`.
- **postStart** applies the firewall, then `start-openab.sh` launches openab
  **detached** — but only if: not already running, the binary exists, *and*
  both Slack tokens are resolved (host env, else `~/.claude/openab.env`).
  Logs → `openab/openab.log`.

Manual control, inside the container:

```bash
pgrep -x openab                 # running?
tail -f openab/openab.log       # logs
pkill -f 'openab run'           # stop
```

## Auto-start on the host (OrbStack)

So the stack comes up on its own when OrbStack starts, a macOS **LaunchAgent**
runs `devcontainer up` (it does *not* use a Docker `--restart` policy — a plain
container restart skips `postStartCommand`, so the firewall would never apply).

- Agent: `~/Library/LaunchAgents/com.hoyang.claude-sandbox-autostart.plist`
  — fires at login and whenever OrbStack's `~/.orbstack/run` socket dir changes.
- Script: `.devcontainer/host-autostart.sh` — waits for the Docker engine, runs
  `devcontainer up`, then **verifies the firewall is active** (`OUTPUT` policy
  `DROP`). If not, it applies `init-firewall.sh` and restarts openab so the
  agent never keeps serving uncontained. Logs → `~/Library/Logs/claude-sandbox-autostart.log`.
- Manage: `launchctl kickstart -k gui/$(id -u)/com.hoyang.claude-sandbox-autostart`
  (run now), `launchctl bootout gui/$(id -u)/com.hoyang.claude-sandbox-autostart`
  (disable).

**Why the safety net exists:** this container's baked `devcontainer.metadata`
label carries a *stale* `postStartCommand` (`start-openab.sh` only, no firewall)
from before the firewall was added to `devcontainer.json`. `devcontainer up`
honors the label, so it starts openab without the firewall. The host script
re-applies it. The clean permanent fix is to **rebuild** the container so the
label matches the current `devcontainer.json` (`init-firewall.sh && start-openab.sh`):

```bash
devcontainer up --workspace-folder ~/claude-sandbox --remove-existing-container
```

## Authentication

The Claude Code agent authenticates via OAuth, once, inside the container:

```bash
claude auth login
```

Credentials persist in `~/.claude/` on the **`openab-config`** Docker volume —
they survive rebuilds, so no re-login is needed.

## Gotchas

- **Hardcoded paths** — `devcontainer.json` and `start-openab.sh` reference
  `/workspaces/claude-sandbox`. Renaming the project directory breaks them.
- **`~/.claude.json`** (settings/history, *not* auth) is not on a volume, so it
  resets on each rebuild. Harmless — auth lives in `~/.claude/.credentials.json`,
  which is persisted.
- `postStartCommand` runs via the devcontainer tooling (`devcontainer up` /
  VS Code), **not** a bare `docker start`.

## Working on openab's code

For changes inside `openab/`, see `openab/AGENTS.md` — it requires
`cargo fmt`, `cargo clippy -- -D warnings`, and `cargo test` to pass.
