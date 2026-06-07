# Codex Remote Connector

[中文文档](README_ZH.md)

Codex Remote Connector helps prepare an SSH host for use from the Codex desktop app. It verifies a local SSH alias, installs the Codex CLI on the remote machine, starts a reverse proxy tunnel, runs Codex device login on the remote host, and prints the connection fields you need in Codex.

## What it does

When you run Remote Connector against an SSH alias, it:

1. Reads `~/.ssh/config` and verifies the alias is a concrete `Host` entry.
2. Creates `~/.codex` on the remote host.
3. Copies `scripts/codex_install.sh` to `~/.codex/codex_install.sh`.
4. Runs the installer on the remote host.
5. Starts a reverse SSH tunnel from the remote host to your local proxy:

   ```bash
   ssh -fN -R 127.0.0.1:17890:127.0.0.1:7890 REMOTE_SSH_MACHINE
   ```

6. Runs `codex login --device-auth` on the remote host.
7. Prints the Codex desktop connection details.

The bundled installer places the remote Codex binary at `~/.codex/bin/codex`. The wrapper sets `http_proxy`, `https_proxy`, `HTTP_PROXY`, and `HTTPS_PROXY` to `http://127.0.0.1:17890` when Codex runs on the remote host.

## Requirements

Local machine:

- Codex desktop app.
- OpenSSH client with working `ssh` and `scp`.
- A concrete SSH alias in `~/.ssh/config`.
- Optional but recommended: a local HTTP proxy listening on `127.0.0.1:7890`, or pass `REMOTE_FORWAR_PORT` / `--local-proxy` with the proxy you use.

Remote machine:

- macOS or Linux.
- x64 or ARM64 CPU.
- `sh`, `tar`, `mktemp`, and either `curl` or `wget`.
- Internet access to download Codex releases from GitHub, unless you skip installation and provide Codex yourself.
- The SSH user should be the same user that will run Codex.

## Install in Codex

Codex discovers local plugins through a local marketplace file. The simplest setup is to clone this repository to `~/plugins/remote-connector`, add a personal marketplace entry, then install the plugin from that marketplace.

1. Clone the plugin from GitHub.

   ```bash
   mkdir -p ~/plugins
   git clone https://github.com/wanghao9610/Codex-Remote-Connector.git ~/plugins/remote-connector
   ```

   If you already cloned it, update it with:

   ```bash
   cd ~/plugins/remote-connector
   git pull
   ```

   If you are developing from a local checkout instead, symlink it into the same location:

   ```bash
   mkdir -p ~/plugins
   ln -s /path/to/Codex-Remote-Connector ~/plugins/remote-connector
   ```

2. Add the plugin to your personal marketplace.

   The default personal marketplace file is:

   ```text
   ~/.agents/plugins/marketplace.json
   ```

   If this file does not exist yet, create it with:

   ```json
   {
     "name": "personal",
     "interface": {
       "displayName": "Personal"
     },
     "plugins": [
       {
         "name": "remote-connector",
         "source": {
           "source": "local",
           "path": "./plugins/remote-connector"
         },
         "policy": {
           "installation": "AVAILABLE",
           "authentication": "ON_INSTALL"
         },
         "category": "Productivity"
       }
     ]
   }
   ```

   If the file already exists, add only the `remote-connector` object to the existing `plugins` array. Do not replace your existing marketplace entries.

3. Install or refresh the plugin in Codex.

   ```bash
   codex plugin add remote-connector@personal
   ```

4. Start a new Codex thread.

   New or refreshed plugin skills are picked up at the start of a thread. In the new thread, invoke:

   ```text
   /Remote-Connector devbox
   ```

## Quick start

1. Add the remote host to your local SSH config.

   ```text
   Host devbox
     HostName devbox.example.com
     User you
     IdentityFile ~/.ssh/id_ed25519
   ```

2. Confirm normal SSH works.

   ```bash
   ssh devbox
   ```

3. Run Remote Connector.

   From Codex, after installing this plugin:

   ```text
   /Remote-Connector devbox
   @Remote Connector devbox
   ```

   Or run the script directly from this repository:

   ```bash
   scripts/codex-remote-connector.sh devbox
   ```

   Optional positional ports are supported:

   ```text
   /Remote-Connector REMOTE_SSH_MACHINE [REMOTE_FORWAR_PORT] [LOCAL_FORWARD_PORT]
   ```

4. Complete the device login.

   Keep the command running when it prints the device authentication URL and code. Open the URL locally, enter the code, and finish sign-in with the same account and workspace you use in Codex desktop.

5. Add the SSH connection in Codex desktop.

   Open **Settings > Connections** and add or enable the SSH host with the values printed by the script:

   ```text
   SSH host/alias: devbox
   Remote Codex binary: ~/.codex/bin/codex
   Remote Codex home: ~/.codex
   Reverse proxy on remote: http://127.0.0.1:17890
   ```

6. Choose a remote project folder in Codex and start a thread.

## Script usage

```bash
scripts/codex-remote-connector.sh [options] REMOTE_SSH_MACHINE [REMOTE_FORWAR_PORT] [LOCAL_FORWARD_PORT]
```

`REMOTE_SSH_MACHINE` must be a simple SSH `Host` alias from `~/.ssh/config`. For safety, aliases are limited to letters, numbers, dots, underscores, and hyphens. `REMOTE_FORWAR_PORT` defaults to `7890`; `LOCAL_FORWARD_PORT` defaults to `17890`.

Options:

| Option | Description |
| --- | --- |
| `--dry-run` | Print the SSH and SCP commands without running them. |
| `--ssh-config PATH` | Read host entries from another SSH config file. |
| `--install-script PATH` | Copy a different install script instead of `./scripts/codex_install.sh`. |
| `--remote-bind HOST:PORT` | Remote bind address for the reverse tunnel. Default: `127.0.0.1:17890`. |
| `--local-proxy HOST:PORT` | Local proxy forwarded by the tunnel. Default: `127.0.0.1:7890`. |
| `--skip-install` | Do not create `~/.codex`, copy the installer, or install Codex. |
| `--skip-tunnel` | Do not start the reverse SSH tunnel. |
| `--skip-login` | Do not run `codex login --device-auth`. |
| `-h`, `--help` | Show help text. |

Useful examples:

```bash
# Verify what will happen without touching the remote host.
scripts/codex-remote-connector.sh --dry-run devbox

# Use a different local proxy port.
scripts/codex-remote-connector.sh devbox 8080

# Use different local proxy and remote bind ports.
scripts/codex-remote-connector.sh devbox 8080 18888

# Codex is already installed and authenticated on the remote host.
scripts/codex-remote-connector.sh --skip-install --skip-login devbox

# Only install and authenticate; manage the tunnel yourself.
scripts/codex-remote-connector.sh --skip-tunnel devbox
```

## Installer details

`scripts/codex_install.sh` installs a standalone Codex CLI under the remote user's Codex home:

```text
~/.codex/bin/codex
~/.codex/packages/standalone/
```

The installer supports these environment variables when you run it manually:

| Variable | Description |
| --- | --- |
| `CODEX_RELEASE` | Codex version to install. Defaults to `latest`. |
| `CODEX_NON_INTERACTIVE` | Set to `1`, `true`, or `yes` to skip prompts. |
| `CODEX_HOME` | Codex home directory. Defaults to `~/.codex`. |
| `CODEX_INSTALL_DIR` | Directory for the visible `codex` command. Defaults to `$CODEX_HOME/bin`. |

If the remote host cannot reach GitHub releases, install Codex on the remote host another way, make sure `~/.codex/bin/codex` exists, then run:

```bash
scripts/codex-remote-connector.sh --skip-install devbox
```

## Security notes

- Remote Connector uses only `ssh`, `scp`, and standard shell tools.
- It requires an SSH alias that already works from your local machine.
- The reverse tunnel binds to `127.0.0.1` on the remote host by default, so it is not exposed publicly.
- Do not expose Codex app server transports or proxy ports directly to shared or public networks.
- Do not share device login codes, passkeys, passwords, or MFA secrets.
- The remote host should be treated like any other development machine with access to your code and credentials.

## Troubleshooting

### `Host 'devbox' not found in ~/.ssh/config`

Add a concrete `Host devbox` entry to `~/.ssh/config`. Pattern-only entries such as `Host *` are not enough.

### SSH works in a terminal, but the script cannot find the host

Pass the config file explicitly:

```bash
scripts/codex-remote-connector.sh --ssh-config ~/.ssh/config devbox
```

### The installer cannot download Codex

Make sure the remote host has `curl` or `wget` and can access GitHub releases. If your environment requires a special install path, install Codex manually and rerun with `--skip-install`.

### Codex on the remote host cannot reach the internet

Keep the reverse SSH tunnel running and confirm the local proxy is reachable from your local machine. If your local proxy does not listen on `127.0.0.1:7890`, pass `REMOTE_FORWAR_PORT` or `--local-proxy HOST:PORT`.

### Device login hangs or does not complete

Keep the SSH login command open until the browser authentication finishes. Confirm you are signing in to the same ChatGPT account and workspace used by Codex desktop.

### Codex desktop cannot start the remote connection

Check the connection values:

```text
SSH host/alias: the same alias used by ssh
Remote Codex binary: ~/.codex/bin/codex
Remote Codex home: ~/.codex
Reverse proxy on remote: http://127.0.0.1:17890
```

Then SSH into the host and verify:

```bash
~/.codex/bin/codex --version
```

## Local validation

Run a no-op end-to-end preview:

```bash
scripts/codex-remote-connector.sh --dry-run devbox
```

Check shell syntax:

```bash
bash -n scripts/codex-remote-connector.sh
```

Check the plugin manifest is valid JSON:

```bash
python3 -m json.tool .codex-plugin/plugin.json
```

## Publishing checklist

Before publishing this repository on GitHub:

- Set the final repository name and description.
- Replace the manifest author in `.codex-plugin/plugin.json` if `Local` is not what you want to publish.
- Add a real license file that matches the manifest license.
- Add screenshots or a short terminal recording if you want users to understand the flow quickly.
- Tag releases when changing script behavior.
- Ask testers to try both plugin invocation and direct script invocation on a disposable SSH host.

## License

The plugin manifest currently declares `MIT`. Add a `LICENSE` file before publishing if you want GitHub to detect the license automatically.
