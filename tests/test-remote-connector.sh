#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH='' cd -- "$TEST_DIR/.." && pwd)"
CONNECTOR="$PROJECT_ROOT/scripts/codex-remote-connector.sh"
INSTALLER="$PROJECT_ROOT/scripts/codex_install.sh"
TEMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local path="$1"
  local expected="$2"

  grep -F "$expected" "$path" >/dev/null 2>&1 || fail "Expected '$expected' in $path"
}

assert_not_contains() {
  local path="$1"
  local unexpected="$2"

  if grep -F "$unexpected" "$path" >/dev/null 2>&1; then
    fail "Did not expect '$unexpected' in $path"
  fi
}

make_fixture() {
  local fixture="$1"
  local remote_version="$2"
  local remote_configured="$3"
  local fixture_dir="$TEMP_ROOT/$fixture"

  mkdir -p "$fixture_dir/bin"
  printf 'Host testbox\n  HostName test.example.com\n  User tester\n' >"$fixture_dir/ssh_config"

  cat >"$fixture_dir/local-codex" <<'EOF'
#!/bin/sh
printf 'codex-cli 1.2.3\n'
EOF
  chmod +x "$fixture_dir/local-codex"
  printf '%s\n' "$remote_version" >"$fixture_dir/remote-version"
  printf '%s\n' "$remote_configured" >"$fixture_dir/remote-configured"

  cat >"$fixture_dir/bin/ssh" <<'EOF'
#!/bin/sh
printf 'ssh %s\n' "$*" >>"$MOCK_LOG"

case "$*" in
  *'codex_install.sh --release'*)
    printf '1.2.3\n' >"$MOCK_STATE_DIR/remote-version"
    printf '1\n' >"$MOCK_STATE_DIR/remote-configured"
    ;;
  *'--version'*)
    printf 'codex-cli %s\n' "$(cat "$MOCK_STATE_DIR/remote-version")"
    ;;
  *'grep -Fqx'*)
    [ "$(cat "$MOCK_STATE_DIR/remote-configured")" = "1" ]
    ;;
esac
EOF
  chmod +x "$fixture_dir/bin/ssh"

  cat >"$fixture_dir/bin/scp" <<'EOF'
#!/bin/sh
printf 'scp %s\n' "$*" >>"$MOCK_LOG"
EOF
  chmod +x "$fixture_dir/bin/scp"

  MOCK_LOG="$fixture_dir/commands.log" \
  MOCK_STATE_DIR="$fixture_dir" \
  PATH="$fixture_dir/bin:$PATH" \
    "$CONNECTOR" \
      --ssh-config "$fixture_dir/ssh_config" \
      --local-codex "$fixture_dir/local-codex" \
      --skip-tunnel \
      --skip-login \
      testbox >"$fixture_dir/output.log" 2>&1
}

make_fixture matching 1.2.3 1
assert_contains "$TEMP_ROOT/matching/output.log" "Remote Codex version and proxy configuration already match"
assert_not_contains "$TEMP_ROOT/matching/commands.log" "scp "
assert_not_contains "$TEMP_ROOT/matching/commands.log" "codex_install.sh --release"

make_fixture mismatch 1.2.2 1
assert_contains "$TEMP_ROOT/mismatch/output.log" "Remote Codex 1.2.2 does not match local Codex 1.2.3"
assert_contains "$TEMP_ROOT/mismatch/commands.log" "scp "
assert_contains "$TEMP_ROOT/mismatch/commands.log" "codex_install.sh --release '1.2.3' --proxy-url 'http://127.0.0.1:17890'"
assert_contains "$TEMP_ROOT/mismatch/output.log" "Remote Codex 1.2.3 is installed and configured"

make_fixture missing "" 0
assert_contains "$TEMP_ROOT/missing/output.log" "Remote Codex is missing or its version could not be read"
assert_contains "$TEMP_ROOT/missing/commands.log" "codex_install.sh --release '1.2.3'"

make_fixture stale_config 1.2.3 0
assert_contains "$TEMP_ROOT/stale_config/output.log" "Remote Codex 1.2.3 has stale proxy configuration"
assert_contains "$TEMP_ROOT/stale_config/commands.log" "codex_install.sh --release '1.2.3' --proxy-url 'http://127.0.0.1:17890'"

PATH="$TEMP_ROOT/matching/bin:$PATH" \
  "$CONNECTOR" \
    --dry-run \
    --ssh-config "$TEMP_ROOT/matching/ssh_config" \
    --local-codex "$TEMP_ROOT/matching/local-codex" \
    --skip-tunnel \
    --skip-login \
    testbox >"$TEMP_ROOT/dry-run.log" 2>&1
assert_contains "$TEMP_ROOT/dry-run.log" "Remote Codex is missing or its version could not be read"
assert_contains "$TEMP_ROOT/dry-run.log" "codex_install.sh --release 1.2.3 --proxy-url http://127.0.0.1:17890"

installer_dir="$TEMP_ROOT/installer"
installer_home="$installer_dir/home"
installer_codex_home="$installer_home/.codex"
installer_mock_bin="$installer_dir/bin"
mkdir -p "$installer_mock_bin"

case "$(uname -s):$(uname -m)" in
  Darwin:arm64 | Darwin:aarch64)
    installer_target="aarch64-apple-darwin"
    ;;
  Darwin:x86_64 | Darwin:amd64)
    installer_target="x86_64-apple-darwin"
    ;;
  Linux:arm64 | Linux:aarch64)
    installer_target="aarch64-unknown-linux-musl"
    ;;
  Linux:x86_64 | Linux:amd64)
    installer_target="x86_64-unknown-linux-musl"
    ;;
  *)
    fail "Unsupported test platform: $(uname -s):$(uname -m)"
    ;;
esac

installer_release="$installer_codex_home/packages/standalone/releases/1.2.3-$installer_target"
mkdir -p "$installer_release/bin" "$installer_release/codex-path" "$installer_release/codex-resources"
printf '{}\n' >"$installer_release/codex-package.json"
cat >"$installer_release/bin/codex" <<'EOF'
#!/bin/sh
printf 'codex-cli 1.2.3\n'
EOF
cat >"$installer_release/codex-path/rg" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$installer_release/bin/codex" "$installer_release/codex-path/rg"
ln -s bin/codex "$installer_release/codex"

case "$installer_target" in
  *linux*)
    cat >"$installer_release/codex-resources/bwrap" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$installer_release/codex-resources/bwrap"
    ;;
esac

cat >"$installer_mock_bin/curl" <<EOF
#!/bin/sh
cat <<'JSON'
{
  "assets": [
    {
      "name": "codex-package-$installer_target.tar.gz",
      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    {
      "name": "codex-package_SHA256SUMS",
      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  ]
}
JSON
EOF
chmod +x "$installer_mock_bin/curl"

HOME="$installer_home" \
CODEX_HOME="$installer_codex_home" \
CODEX_NON_INTERACTIVE=1 \
SHELL=/bin/sh \
PATH="$installer_mock_bin:$PATH" \
  sh "$INSTALLER" --release 1.2.3 --proxy-url http://127.0.0.1:18888 >"$installer_dir/output.log" 2>&1

assert_contains "$installer_codex_home/bin/codex" 'export http_proxy="http://127.0.0.1:18888"'
assert_contains "$installer_codex_home/bin/codex" 'export HTTPS_PROXY="http://127.0.0.1:18888"'
assert_contains "$installer_dir/output.log" "Codex CLI 1.2.3 installed successfully."

printf 'All Remote Connector tests passed.\n'
