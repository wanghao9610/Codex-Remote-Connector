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
LOCAL_CODEX_OVERRIDE="${CODEX_LOCAL_BINARY:-}"
REMOTE_FORWAR_PORT=""
LOCAL_FORWARD_PORT=""

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  @Remote-Connector REMOTE_SSH_MACHINE [REMOTE_FORWAR_PORT] [LOCAL_FORWARD_PORT]
  scripts/codex-remote-connector.sh [options] REMOTE_SSH_MACHINE [REMOTE_FORWAR_PORT] [LOCAL_FORWARD_PORT]

What it does:
  1. Reads ~/.ssh/config and verifies REMOTE_SSH_MACHINE is a Host entry.
  2. Detects the Codex CLI version bundled with the current desktop app.
  3. Compares it with ~/.codex/bin/codex on the remote machine.
  4. Installs the matching version and configures its proxy wrapper when needed.
  5. Starts a reverse SSH tunnel:
     ssh -fN -R 127.0.0.1:17890:127.0.0.1:7890 REMOTE_SSH_MACHINE
  6. Runs codex login --device-auth on the remote machine.
  7. Prints the Add SSH connection fields for Codex > Settings > Connections > SSH.

Options:
  REMOTE_FORWAR_PORT       Optional local proxy target port. Default: 7890.
  LOCAL_FORWARD_PORT       Optional remote bind port. Default: 17890.
  --dry-run                 Print commands without running ssh/scp.
  --ssh-config PATH         Read SSH Host entries from PATH instead of ~/.ssh/config.
  --local-codex PATH        Use PATH as the local Codex version source.
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

validate_endpoint() {
  local name="$1"
  local value="$2"
  local host
  local inner_host
  local port

  case "$value" in
    *:*)
      host="${value%:*}"
      port="${value##*:}"
      ;;
    *)
      die "$name must use HOST:PORT format."
      ;;
  esac

  case "$host" in
    \[*\])
      inner_host="${host#\[}"
      inner_host="${inner_host%\]}"
      case "$inner_host" in
        "" | *[!0-9A-Fa-f:]* | *\[* | *\]*)
          die "$name contains an invalid IPv6 host."
          ;;
      esac
      ;;
    "" | *[!A-Za-z0-9._-]*)
      die "$name contains an invalid host."
      ;;
  esac

  validate_port "$name" "$port"
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

ssh_config_value() {
  alias="$1"
  config="$2"
  option="$3"

  [ -f "$config" ] || return 1

  awk -v target="$alias" -v wanted="$option" '
    BEGIN { wanted = tolower(wanted) }
    /^[[:space:]]*($|#)/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      n = split(line, fields, /[[:space:]]+/)
      keyword = tolower(fields[1])

      if (keyword == "host") {
        in_target = 0
        for (i = 2; i <= n; i++) {
          if (fields[i] == target) {
            in_target = 1
          }
        }
        next
      }

      if (in_target && keyword == wanted) {
        value = ""
        for (i = 2; i <= n; i++) {
          value = value (i == 2 ? "" : " ") fields[i]
        }
        print value
        found = 1
        exit
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$config"
}

codex_version_from_output() {
  sed -n 's/.* \([0-9][0-9A-Za-z.+-]*\)$/\1/p' | head -n 1
}

codex_version_from_binary() {
  local codex_path="$1"

  [ -x "$codex_path" ] || return 1
  "$codex_path" --version 2>/dev/null | codex_version_from_output
}

validate_codex_version() {
  local version="$1"

  if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'; then
    die "Unsupported local Codex version '$version'. Expected x.y.z or x.y.z-PRERELEASE."
  fi
}

ancestor_codex_binary() {
  local pid="$PPID"
  local command_line
  local executable
  local parent_pid
  local depth=0

  command -v ps >/dev/null 2>&1 || return 1

  while [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 12 ]; do
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    executable="${command_line%% *}"
    case "$executable" in
      */codex)
        if [ -x "$executable" ]; then
          printf '%s\n' "$executable"
          return 0
        fi
        ;;
    esac

    parent_pid="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')"
    case "$parent_pid" in
      "" | *[!0-9]*)
        return 1
        ;;
    esac
    pid="$parent_pid"
    depth=$((depth + 1))
  done

  return 1
}

resolve_local_codex_binary() {
  local candidate

  if [ -n "$LOCAL_CODEX_OVERRIDE" ]; then
    [ -x "$LOCAL_CODEX_OVERRIDE" ] || die "Local Codex binary is not executable: $LOCAL_CODEX_OVERRIDE"
    printf '%s\n' "$LOCAL_CODEX_OVERRIDE"
    return 0
  fi

  candidate="$(ancestor_codex_binary || true)"
  if [ -n "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for candidate in \
    "/Applications/Codex.app/Contents/Resources/codex" \
    "$HOME/Applications/Codex.app/Contents/Resources/codex" \
    "/Applications/ChatGPT.app/Contents/Resources/codex" \
    "$HOME/Applications/ChatGPT.app/Contents/Resources/codex"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  candidate="$(command -v codex 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  die "Could not find the local Codex binary. Use --local-codex PATH or CODEX_LOCAL_BINARY."
}

remote_codex_version() {
  local output

  if [ "$DRY_RUN" -eq 1 ]; then
    dry "ssh $REMOTE '\"\$HOME/.codex/bin/codex\" --version'" >&2
    return 1
  fi

  output="$(ssh "$REMOTE" '"$HOME/.codex/bin/codex" --version' 2>/dev/null)" || return 1
  printf '%s\n' "$output" | codex_version_from_output
}

remote_codex_configured() {
  local expected_line="export http_proxy=\"$REMOTE_PROXY_URL\""

  if [ "$DRY_RUN" -eq 1 ]; then
    dry "ssh $REMOTE 'verify ~/.codex/bin/codex proxy configuration for $REMOTE_PROXY_URL'"
    return 1
  fi

  # Values expanded locally are restricted by validate_endpoint.
  # shellcheck disable=SC2029
  ssh "$REMOTE" "wrapper=\"\$HOME/.codex/bin/codex\"; test -x \"\$wrapper\" && grep -Fqx '$expected_line' \"\$wrapper\" && grep -Fqx 'export https_proxy=\"$REMOTE_PROXY_URL\"' \"\$wrapper\" && grep -Fqx 'export HTTP_PROXY=\"$REMOTE_PROXY_URL\"' \"\$wrapper\" && grep -Fqx 'export HTTPS_PROXY=\"$REMOTE_PROXY_URL\"' \"\$wrapper\"" >/dev/null 2>&1
}

install_remote_codex() {
  local version="$1"

  info "Preparing ~/.codex on $REMOTE"
  if [ "$DRY_RUN" -eq 1 ]; then
    dry "ssh $REMOTE 'mkdir -p ~/.codex'"
    dry "scp $INSTALL_SCRIPT $REMOTE:~/.codex/codex_install.sh"
    dry "ssh $REMOTE 'sh ~/.codex/codex_install.sh --release $version --proxy-url $REMOTE_PROXY_URL'"
    return 0
  fi

  ssh "$REMOTE" 'mkdir -p ~/.codex'
  scp "$INSTALL_SCRIPT" "$REMOTE:~/.codex/codex_install.sh"
  # Values expanded locally are restricted by validate_codex_version/validate_endpoint.
  # shellcheck disable=SC2029
  ssh "$REMOTE" "CODEX_NON_INTERACTIVE=1 sh ~/.codex/codex_install.sh --release '$version' --proxy-url '$REMOTE_PROXY_URL'"
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
    --local-codex)
      need_value "$@"
      LOCAL_CODEX_OVERRIDE="$2"
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

validate_endpoint "--remote-bind" "$REMOTE_BIND"
validate_endpoint "--local-proxy" "$LOCAL_PROXY"
REMOTE_PROXY_URL="http://$REMOTE_BIND"

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
  LOCAL_CODEX_BINARY="$(resolve_local_codex_binary)"
  LOCAL_CODEX_VERSION="$(codex_version_from_binary "$LOCAL_CODEX_BINARY" || true)"
  [ -n "$LOCAL_CODEX_VERSION" ] || die "Could not read a Codex version from $LOCAL_CODEX_BINARY."
  validate_codex_version "$LOCAL_CODEX_VERSION"
  info "Local Codex version: $LOCAL_CODEX_VERSION ($LOCAL_CODEX_BINARY)"

  info "Checking remote Codex version"
  REMOTE_CODEX_VERSION="$(remote_codex_version || true)"
  INSTALL_REASON=""
  if [ -z "$REMOTE_CODEX_VERSION" ]; then
    INSTALL_REASON="Remote Codex is missing or its version could not be read"
  elif [ "$REMOTE_CODEX_VERSION" != "$LOCAL_CODEX_VERSION" ]; then
    INSTALL_REASON="Remote Codex $REMOTE_CODEX_VERSION does not match local Codex $LOCAL_CODEX_VERSION"
  elif ! remote_codex_configured; then
    INSTALL_REASON="Remote Codex $REMOTE_CODEX_VERSION has stale proxy configuration"
  else
    info "Remote Codex version and proxy configuration already match"
  fi

  if [ -n "$INSTALL_REASON" ]; then
    info "$INSTALL_REASON"
    install_remote_codex "$LOCAL_CODEX_VERSION"

    if [ "$DRY_RUN" -eq 0 ]; then
      INSTALLED_CODEX_VERSION="$(remote_codex_version || true)"
      if [ "$INSTALLED_CODEX_VERSION" != "$LOCAL_CODEX_VERSION" ]; then
        die "Remote Codex verification failed: expected $LOCAL_CODEX_VERSION, got ${INSTALLED_CODEX_VERSION:-unknown}."
      fi
      remote_codex_configured || die "Remote Codex proxy configuration verification failed."
      info "Remote Codex $INSTALLED_CODEX_VERSION is installed and configured"
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

DISPLAY_NAME="$REMOTE"
CONFIG_HOSTNAME="$(ssh_config_value "$REMOTE" "$SSH_CONFIG" HostName || true)"
CONFIG_USER="$(ssh_config_value "$REMOTE" "$SSH_CONFIG" User || true)"
CONFIG_PORT="$(ssh_config_value "$REMOTE" "$SSH_CONFIG" Port || true)"
CONFIG_IDENTITY_FILE="$(ssh_config_value "$REMOTE" "$SSH_CONFIG" IdentityFile || true)"

if [ -z "$CONFIG_HOSTNAME" ]; then
  CONFIG_HOSTNAME="$REMOTE"
fi

if [ -n "$CONFIG_USER" ]; then
  FORM_HOSTNAME="$CONFIG_USER@$CONFIG_HOSTNAME"
else
  FORM_HOSTNAME="$CONFIG_HOSTNAME"
fi

if [ -n "$CONFIG_PORT" ]; then
  FORM_PORT="$CONFIG_PORT"
else
  FORM_PORT="(leave blank)"
fi

if [ -n "$CONFIG_IDENTITY_FILE" ]; then
  FORM_AUTH="Identity"
  FORM_IDENTITY_FILE="$CONFIG_IDENTITY_FILE"
else
  FORM_AUTH="No Auth"
  FORM_IDENTITY_FILE="(leave blank)"
fi

cat <<EOF

Add SSH connection in Codex desktop:
  Open Codex > Settings > Connections > SSH > Add SSH connection.
  Display name: $DISPLAY_NAME
  Hostname: $FORM_HOSTNAME
  SSH port (optional): $FORM_PORT
  Auth: $FORM_AUTH
  Identity file path: $FORM_IDENTITY_FILE

Remote Codex details:
  Remote Codex binary: ~/.codex/bin/codex
  Remote Codex home: ~/.codex
  Reverse proxy on remote: http://$REMOTE_BIND
EOF
