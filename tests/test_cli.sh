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
FAKE_IMAGE_FILE="$TEST_TMP/container-images"
printf 'missing\n' >"$FAKE_STATE_FILE"
printf 'pihole/pihole:2026.07.2\n' >"$FAKE_IMAGE_FILE"

cat >"$FAKE_CONTAINER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="$(cat "$FAKE_STATE_FILE")"
case "${1:-}" in
  --version) printf 'container CLI version 1.2.2 (test)\n' ;;
  list)
    if [[ " $* " == *" --all "* ]]; then
      [[ "$state" == "missing" ]] || printf '%s\n' "$FAKE_CONTAINER_NAME"
    else
      [[ "$state" == "running" ]] && printf '%s\n' "$FAKE_CONTAINER_NAME"
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
  image)
    case "${2:-}" in
      inspect) grep -Fxq "${3:-}" "$FAKE_IMAGE_FILE" ;;
      delete)
        grep -Fvx "${3:-}" "$FAKE_IMAGE_FILE" >"$FAKE_IMAGE_FILE.new" || true
        mv "$FAKE_IMAGE_FILE.new" "$FAKE_IMAGE_FILE"
        ;;
      *) exit 0 ;;
    esac
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
export ADPUTATE_CONTAINER_NAME="adputate-test-pihole"
export ADPUTATE_SERVICE_LABEL="com.adputate.test.pihole"
export ADPUTATE_ROUTER_SERVICE_LABEL="com.adputate.test.dns-forwarder"
export ADPUTATE_ROUTER_SUPPORT_DIR="$TEST_TMP/router-support"
export ADPUTATE_ROUTER_PLIST_PATH="$TEST_TMP/com.adputate.test.dns-forwarder.plist"
export ADPUTATE_ROUTER_LOG_PATH="$TEST_TMP/adputate-dns-forwarder.log"
export FAKE_STATE_FILE FAKE_IMAGE_FILE
export FAKE_CONTAINER_NAME="$ADPUTATE_CONTAINER_NAME"
mkdir -p "$HOME/Library/Application Support"

output="$($CLI help)"
assert_contains "$output" 'configure [options]'
assert_contains "$output" 'router-install'
assert_contains "$output" 'router-preflight'
assert_contains "$output" 'upgrade <image> --yes'

if ADPUTATE_WARP_STATUS='Status update: Connected' "$CLI" router-preflight >"$TEST_TMP/warp.out" 2>&1; then
  fail 'router preflight accepted an active Cloudflare WARP connection'
fi
assert_contains "$(cat "$TEST_TMP/warp.out")" 'Cloudflare WARP is connected'
assert_contains "$(cat "$TEST_TMP/warp.out")" 'Turn WARP off'

for install_command in service-install router-install dns-enable; do
  if ADPUTATE_WARP_STATUS='Status update: Connected' "$CLI" "$install_command" >"$TEST_TMP/$install_command.out" 2>&1; then
    fail "$install_command accepted an active Cloudflare WARP connection"
  fi
  assert_contains "$(cat "$TEST_TMP/$install_command.out")" 'Cloudflare WARP is connected'
done

if ADPUTATE_PRIVATE_RELAY_STATUS=1 "$CLI" router-preflight >"$TEST_TMP/private-relay.out" 2>&1; then
  fail 'router preflight accepted active iCloud Private Relay'
fi
assert_contains "$(cat "$TEST_TMP/private-relay.out")" 'iCloud Private Relay is enabled'
assert_contains "$(cat "$TEST_TMP/private-relay.out")" 'Limit IP Address Tracking'

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

listener_output="$(printf 'TCP\tmDNSRespo\t735\t_mdnsresponder\t*:53\n' | \
  "$PROJECT_ROOT/packaging/router/adputate-router" classify 192.0.2.10)"
assert_contains "$listener_output" 'expected wildcard listener'
assert_contains "$listener_output" 'Allowing the standard macOS wildcard listener'

if printf 'UDP\tdnsmasq\t42\troot\t192.0.2.10:53\n' | \
    "$PROJECT_ROOT/packaging/router/adputate-router" classify 192.0.2.10 \
    >"$TEST_TMP/dnsmasq.out" 2>&1; then
  fail 'listener classifier accepted dnsmasq on the target address'
fi
assert_contains "$(cat "$TEST_TMP/dnsmasq.out")" 'brew services list'
assert_contains "$(cat "$TEST_TMP/dnsmasq.out")" 'conflicts with 192.0.2.10:53/UDP'

listener_output="$(printf 'UDP\tDocker\t43\ttest\t127.0.0.1:53\n' | \
  "$PROJECT_ROOT/packaging/router/adputate-router" classify 192.0.2.10)"
assert_contains "$listener_output" 'Docker Desktop'
assert_contains "$listener_output" 'does not directly occupy 192.0.2.10:53'

if printf 'TCP\tunknown-dns\t44\troot\t*:53\n' | \
    "$PROJECT_ROOT/packaging/router/adputate-router" classify 192.0.2.10 \
    >"$TEST_TMP/unknown.out" 2>&1; then
  fail 'listener classifier accepted an unknown wildcard listener'
fi
assert_contains "$(cat "$TEST_TMP/unknown.out")" 'identify it by PID'

listener_output="$(printf 'TCP\tadputate-\t99\tnobody\t192.0.2.10:53\n' | \
  "$PROJECT_ROOT/packaging/router/adputate-router" classify 192.0.2.10 99)"
assert_contains "$listener_output" 'currently installed Adputate frontend'
assert_contains "$(cat "$PROJECT_ROOT/packaging/router/adputate-router")" 'socketfilterfw --remove'

if [[ "$(uname -s)" == "Darwin" ]]; then
  /usr/bin/xcrun clang -O2 -Wall -Wextra -Werror -pthread \
    "$PROJECT_ROOT/packaging/router/adputate-dns-proxy.c" -o "$TEST_TMP/adputate-dns-proxy"
  if "$TEST_TMP/adputate-dns-proxy" >/dev/null 2>&1; then
    fail 'DNS proxy accepted missing arguments'
  fi
fi

mkdir -p "$ADPUTATE_APP_DIR/data"
printf 'stopped\n' >"$FAKE_STATE_FILE"
output="$($CLI uninstall --yes)"
assert_contains "$output" 'Adputate uninstall completed cleanly'
[[ ! -e "$ADPUTATE_APP_DIR" ]] || fail 'uninstall retained the application data directory'
[[ "$(cat "$FAKE_STATE_FILE")" == "missing" ]] || fail 'uninstall retained the container'
if grep -Fxq 'pihole/pihole:2026.07.2' "$FAKE_IMAGE_FILE"; then
  fail 'uninstall retained the configured Pi-hole image'
fi
output="$($CLI uninstall-audit)"
assert_contains "$output" '0 failed'

$CLI configure --bind-address 127.0.0.1 --web-port 19080 --dns-port 15053 \
  --image pihole/pihole:2026.07.2 --memory 256M >/dev/null
[[ -f "$ADPUTATE_APP_DIR/config/runtime.env" ]] || fail 'fresh configuration failed after uninstall'
printf 'pihole/pihole:2026.07.2\n' >"$FAKE_IMAGE_FILE"
output="$($CLI uninstall --yes --keep-images)"
assert_contains "$output" 'deliberately retained'
grep -Fxq 'pihole/pihole:2026.07.2' "$FAKE_IMAGE_FILE" || fail '--keep-images removed the Pi-hole image'
[[ ! -e "$ADPUTATE_APP_DIR" ]] || fail '--keep-images retained application data'

printf 'PASS: CLI, drift, health-failure, port-conflict, clean-uninstall, privilege, and proxy-build tests\n'
