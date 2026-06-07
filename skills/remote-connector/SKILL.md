---
name: remote-connector
description: Use when the user invokes @Remote Connector or @Remote-Connector, mentions Remote Connector, asks to connect Codex to a remote SSH host, or wants to install/login Codex on a remote machine using an ssh alias from ~/.ssh/config.
---

# Remote Connector

## Behavior

- If the user invokes `@Remote Connector` or `@Remote-Connector` with no SSH alias or no other instructions, show the usage text below and do not run commands.
- If the user supplies an SSH alias, run the bundled bash script against that alias.
- Re-running the script for the same alias is intentional: it checks the remote Codex binary, the reverse SSH tunnel, and the remote auth file, then repairs missing pieces instead of blindly duplicating work.
- The optional positional ports are `REMOTE_FORWAR_PORT` then `LOCAL_FORWARD_PORT`; they default to `7890` and `17890`.
- These positional defaults preserve the default tunnel as `ssh -fN -R 127.0.0.1:17890:127.0.0.1:7890 REMOTE_SSH_MACHINE`.
- The SSH alias must match a `Host` token in the local `~/.ssh/config`.
- Use only shell, `ssh`, `scp`, and standard Unix tools. Do not install extra local packages.
- Prefer manual browser-auth fallback over collecting account passwords, passkeys, or 2FA secrets.

## Usage Text

```text
Usage:
  @Remote-Connector REMOTE_SSH_MACHINE [REMOTE_FORWAR_PORT] [LOCAL_FORWARD_PORT]
  @Remote Connector REMOTE_SSH_MACHINE [REMOTE_FORWAR_PORT] [LOCAL_FORWARD_PORT]

What it does:
  1. Reads ~/.ssh/config and verifies REMOTE_SSH_MACHINE is a Host entry.
  2. Checks whether ~/.codex/bin/codex already exists on the remote machine.
  3. Installs or repairs remote Codex only when it is missing.
  4. Checks whether the matching reverse SSH tunnel is already running.
  5. Starts or repairs the reverse SSH tunnel when needed:
     ssh -fN -R 127.0.0.1:17890:127.0.0.1:7890 REMOTE_SSH_MACHINE
  6. Checks whether remote Codex authentication already exists.
  7. Runs codex login --device-auth only when authentication is missing.
  8. Prints the connection details to add in Codex desktop Connections.

Options are available by running:
  scripts/codex-remote-connector.sh --help
```

## Run Workflow

From the plugin root, run:

```bash
scripts/codex-remote-connector.sh REMOTE_SSH_MACHINE [REMOTE_FORWAR_PORT] [LOCAL_FORWARD_PORT]
```

If the current working directory is not the plugin root, locate the installed plugin directory that contains `.codex-plugin/plugin.json`, then run the script from there.

## Authentication Handling

When the remote command prints a device-auth URL and code:

- Keep the SSH command running until authentication completes.
- If Chrome automation is available and the user has asked for automation, open the verification URL locally and enter the device code.
- If browser automation is unavailable or blocked, relay the URL and code to the user so they can complete verification manually.
- Do not type passwords, passkeys, or 2FA secrets for the user.

## Codex Desktop Connections

After remote login succeeds, help the user add a connection in the Codex desktop app using the script output:

- SSH host/alias: the supplied `REMOTE_SSH_MACHINE`
- Remote Codex binary: `~/.codex/bin/codex`
- Remote Codex home: `~/.codex`
- Reverse proxy on remote: `http://127.0.0.1:17890`

If desktop UI automation is available and appropriate, use it to add the connection. Otherwise, provide the exact fields above.
