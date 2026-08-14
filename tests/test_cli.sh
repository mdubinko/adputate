#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$PROJECT_ROOT/bin/adputate"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/adputate-tests.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local output="$1" expected="$2"
  [[ "$output" == *"$expected"* ]] || fail "expected output to contain: $expected"
}

FAKE_CONTAINER="$TEST_TMP/container"
FAKE_STATE_FILE="$TEST_TMP/container-state"
printf 'missing\n' >"$FAKE_STATE_FILE"

cat >"$FAKE_CONTAINER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="$(cat "$FAKE_STATE_FILE")"
case "${1:-}" in
  --version) printf 'container CLI version 1.2.2 (test)\n' ;;
  list)
    if [[ " $* " == *" --all "* ]]; then
      [[ "$state" == "missing" ]] || printf 'adputate-pihole\n'
    else
      [[ "$state" == "running" ]] && printf 'adputate-pihole\n'
    fi
    ;;
  inspect)
    cat <<JSON
[{"configuration":{"labels":{"adputate_config_version":"1","adputate_bind_address":"127.0.0.1","adputate_web_port":"19080","adputate_dns_port":"15053","adputate_image":"pihole/pihole:2026.07.2","adputate_memory":"256M"},"image":{"reference":"docker.io/pihole/pihole:2026.07.2"}}}]
JSON
    ;;
  volume)
    [[ "${2:-}" == "inspect" ]] && exit 1
    ;;
  system) exit 0 ;;
  run) printf 'running\n' >"$FAKE_STATE_FILE" ;;
  start) printf 'running\n' >"$FAKE_STATE_FILE" ;;
  stop) printf 'stopped\n' >"$FAKE_STATE_FILE" ;;
  delete) printf 'missing\n' >"$FAKE_STATE_FILE" ;;
  exec) exit 0 ;;
  logs) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKE_CONTAINER"

export HOME="$TEST_TMP/home"
export ADPUTATE_APP_DIR="$TEST_TMP/app"
export CONTAINER_BIN="$FAKE_CONTAINER"
export FAKE_STATE_FILE
mkdir -p "$HOME/Library/Application Support"

output="$($CLI help)"
assert_contains "$output" 'configure [options]'
assert_contains "$output" 'router-install'
assert_contains "$output" 'upgrade <image> --yes'

$CLI configure --bind-address 127.0.0.1 --web-port 19080 --dns-port 15053 \
  --image pihole/pihole:2026.07.2 --memory 256M >/dev/null
[[ -f "$ADPUTATE_APP_DIR/config/runtime.env" ]] || fail 'runtime configuration was not created'

output="$($CLI config)"
assert_contains "$output" 'Bind address:  127.0.0.1'
assert_contains "$output" 'Web port:      19080'
assert_contains "$output" 'DNS backend:   15053'

if $CLI configure --dns-port 53 >/dev/null 2>&1; then
  fail 'configure accepted a privileged backend port'
fi

if $CLI health >"$TEST_TMP/health.out" 2>&1; then
  fail 'health succeeded without a container'
fi
assert_contains "$(cat "$TEST_TMP/health.out")" 'does not exist'

printf 'stopped\n' >"$FAKE_STATE_FILE"
output="$($CLI status)"
assert_contains "$output" 'exists but is stopped'
assert_contains "$output" 'matches desired state'

output="$($CLI launchd-plist)"
assert_contains "$output" "$PROJECT_ROOT/bin/adputate"

if "$PROJECT_ROOT/packaging/router/adputate-router" install 127.0.0.1 15053 en0 >/dev/null 2>&1; then
  fail 'router helper ran without root privileges'
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  /usr/bin/xcrun clang -O2 -Wall -Wextra -Werror -pthread \
    "$PROJECT_ROOT/packaging/router/adputate-dns-proxy.c" -o "$TEST_TMP/adputate-dns-proxy"
  if "$TEST_TMP/adputate-dns-proxy" >/dev/null 2>&1; then
    fail 'DNS proxy accepted missing arguments'
  fi
fi

printf 'PASS: CLI configuration, drift, health-failure, plist, privilege, and proxy-build tests\n'
