#!/usr/bin/env bash

set -euo pipefail

DRY_RUN=0
SKIP_INSTALL=0
SKIP_TUNNEL=0
SKIP_LOGIN=0
REMOTE_BIND="127.0.0.1:17890"
LOCAL_PROXY="127.0.0.1:7890"
INSTALL_SCRIPT=""
SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/config}"
REMOTE_FORWAR_PORT=""
LOCAL_FORWARD_PORT=""

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PLUGIN_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  /Remote-Connector REMOTE_SSH_MACHINE [REMOTE_FORWAR_PORT] [LOCAL_FORWARD_PORT]
  @Remote Connector REMOTE_SSH_MACHINE [REMOTE_FORWAR_PORT] [LOCAL_FORWARD_PORT]
  scripts/codex-remote-connector.sh [options] REMOTE_SSH_MACHINE [REMOTE_FORWAR_PORT] [LOCAL_FORWARD_PORT]

What it does:
  1. Reads ~/.ssh/config and verifies REMOTE_SSH_MACHINE is a Host entry.
  2. Creates ~/.codex on the remote machine.
  3. Copies scripts/codex_install.sh to ~/.codex/codex_install.sh on the remote machine.
  4. Runs the install script remotely.
  5. Starts a reverse SSH tunnel:
     ssh -fN -R 127.0.0.1:17890:127.0.0.1:7890 REMOTE_SSH_MACHINE
  6. Runs codex login --device-auth on the remote machine.
  7. Prints the connection details to add in Codex desktop Connections.

Options:
  REMOTE_FORWAR_PORT       Optional local proxy target port. Default: 7890.
  LOCAL_FORWARD_PORT       Optional remote bind port. Default: 17890.
  --dry-run                 Print commands without running ssh/scp.
  --ssh-config PATH         Read SSH Host entries from PATH instead of ~/.ssh/config.
  --install-script PATH     Copy this install script instead of ./scripts/codex_install.sh.
  --remote-bind HOST:PORT   Remote reverse tunnel bind address. Default: 127.0.0.1:17890.
  --local-proxy HOST:PORT   Local proxy forwarded by the tunnel. Default: 127.0.0.1:7890.
  --skip-install            Do not create ~/.codex, copy, or run codex_install.sh.
  --skip-tunnel             Do not start the reverse SSH tunnel.
  --skip-login              Do not run codex login --device-auth.
  -h, --help                Show this help text.
EOF
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$1"
}

dry() {
  printf 'DRY RUN: %s\n' "$1"
}

need_value() {
  [ "$#" -ge 2 ] || die "$1 requires a value."
}

validate_port() {
  name="$1"
  value="$2"

  case "$value" in
    "" | *[!0-9]*)
      die "$name must be a TCP port from 1 to 65535."
      ;;
  esac

  if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    die "$name must be a TCP port from 1 to 65535."
  fi
}

assign_positional() {
  value="$1"

  if [ -z "$REMOTE" ]; then
    REMOTE="$value"
    return
  fi

  if [ -z "$REMOTE_FORWAR_PORT" ]; then
    REMOTE_FORWAR_PORT="$value"
    return
  fi

  if [ -z "$LOCAL_FORWARD_PORT" ]; then
    LOCAL_FORWARD_PORT="$value"
    return
  fi

  die "Usage accepts at most REMOTE_SSH_MACHINE REMOTE_FORWAR_PORT LOCAL_FORWARD_PORT."
}

host_exists() {
  alias="$1"
  config="$2"

  [ -f "$config" ] || return 1

  awk -v target="$alias" '
    /^[[:space:]]*($|#)/ { next }
    {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      n = split(line, fields, /[[:space:]]+/)
      start = 1
      if (fields[1] == "") {
        start = 2
      }
      keyword = tolower(fields[start])
      if (keyword == "host") {
        for (i = start + 1; i <= n; i++) {
          if (fields[i] == target) {
            found = 1
          }
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$config"
}

remote_codex_installed() {
  if [ "$DRY_RUN" -eq 1 ]; then
    dry "ssh $REMOTE 'test -x \"\$HOME/.codex/bin/codex\"'"
    return 1
  fi

  ssh "$REMOTE" 'test -x "$HOME/.codex/bin/codex"'
}

remote_codex_authenticated() {
  if [ "$DRY_RUN" -eq 1 ]; then
    dry "ssh $REMOTE 'test -s \"\$HOME/.codex/auth.json\"'"
    return 1
  fi

  ssh "$REMOTE" 'test -s "$HOME/.codex/auth.json"'
}

tunnel_running() {
  if [ "$DRY_RUN" -eq 1 ]; then
    dry "pgrep -f 'ssh .* -R $REMOTE_BIND:$LOCAL_PROXY $REMOTE'"
    return 1
  fi

  command -v pgrep >/dev/null 2>&1 || return 1
  pgrep -f "ssh .* -R $REMOTE_BIND:$LOCAL_PROXY $REMOTE" >/dev/null 2>&1
}

REMOTE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --ssh-config)
      need_value "$@"
      SSH_CONFIG="$2"
      shift
      ;;
    --install-script)
      need_value "$@"
      INSTALL_SCRIPT="$2"
      shift
      ;;
    --remote-bind)
      need_value "$@"
      REMOTE_BIND="$2"
      shift
      ;;
    --local-proxy)
      need_value "$@"
      LOCAL_PROXY="$2"
      shift
      ;;
    --skip-install)
      SKIP_INSTALL=1
      ;;
    --skip-tunnel)
      SKIP_TUNNEL=1
      ;;
    --skip-login)
      SKIP_LOGIN=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      assign_positional "$1"
      ;;
  esac
  shift
done

while [ "$#" -gt 0 ]; do
  assign_positional "$1"
  shift
done

if [ -z "$REMOTE" ]; then
  usage
  exit 0
fi

case "$REMOTE" in
  -* | *[!A-Za-z0-9._-]*)
    die "REMOTE_SSH_MACHINE must be a simple SSH Host alias from ~/.ssh/config."
    ;;
esac

if ! host_exists "$REMOTE" "$SSH_CONFIG"; then
  die "Host '$REMOTE' not found in $SSH_CONFIG."
fi

if [ -n "$REMOTE_FORWAR_PORT" ]; then
  validate_port "REMOTE_FORWAR_PORT" "$REMOTE_FORWAR_PORT"
  LOCAL_PROXY="127.0.0.1:$REMOTE_FORWAR_PORT"
fi

if [ -n "$LOCAL_FORWARD_PORT" ]; then
  validate_port "LOCAL_FORWARD_PORT" "$LOCAL_FORWARD_PORT"
  REMOTE_BIND="127.0.0.1:$LOCAL_FORWARD_PORT"
fi

if [ -z "$INSTALL_SCRIPT" ]; then
  INSTALL_SCRIPT="$SCRIPT_DIR/codex_install.sh"
fi

if [ "$SKIP_INSTALL" -eq 0 ] && [ ! -f "$INSTALL_SCRIPT" ]; then
  die "Install script not found: $INSTALL_SCRIPT"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  info "DRY RUN for $REMOTE"
fi

if [ "$SKIP_INSTALL" -eq 0 ]; then
  info "Checking remote Codex installation"
  if remote_codex_installed; then
    info "Remote Codex is already installed"
  else
    info "Preparing ~/.codex on $REMOTE"
    if [ "$DRY_RUN" -eq 1 ]; then
      dry "ssh $REMOTE 'mkdir -p ~/.codex'"
      dry "scp $INSTALL_SCRIPT $REMOTE:~/.codex/codex_install.sh"
      dry "ssh $REMOTE 'sh ~/.codex/codex_install.sh'"
    else
      ssh "$REMOTE" 'mkdir -p ~/.codex'
      scp "$INSTALL_SCRIPT" "$REMOTE:~/.codex/codex_install.sh"
      ssh "$REMOTE" 'sh ~/.codex/codex_install.sh'
    fi
  fi
else
  info "Skipping remote install"
fi

if [ "$SKIP_TUNNEL" -eq 0 ]; then
  info "Checking reverse SSH tunnel"
  if tunnel_running; then
    info "Reverse SSH tunnel is already running"
  else
    info "Starting reverse SSH tunnel"
    if [ "$DRY_RUN" -eq 1 ]; then
      dry "ssh -fN -R $REMOTE_BIND:$LOCAL_PROXY $REMOTE"
    else
      ssh -fN -R "$REMOTE_BIND:$LOCAL_PROXY" "$REMOTE"
    fi
  fi
else
  info "Skipping reverse SSH tunnel"
fi

if [ "$SKIP_LOGIN" -eq 0 ]; then
  info "Checking remote Codex authentication"
  if remote_codex_authenticated; then
    info "Remote Codex authentication is already configured"
  else
    info "Starting remote Codex device login"
    if [ "$DRY_RUN" -eq 1 ]; then
      dry "ssh -t $REMOTE 'PATH=\"\$HOME/.codex/bin:\$PATH\" codex login --device-auth'"
    else
      ssh -t "$REMOTE" 'PATH="$HOME/.codex/bin:$PATH" codex login --device-auth'
    fi
  fi
else
  info "Skipping remote Codex login"
fi

cat <<EOF

Connection details for Codex desktop:
  SSH host/alias: $REMOTE
  Remote Codex binary: ~/.codex/bin/codex
  Remote Codex home: ~/.codex
  Reverse proxy on remote: http://$REMOTE_BIND
EOF
