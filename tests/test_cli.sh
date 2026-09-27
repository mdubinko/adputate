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
FAKE_SYSTEM_STATE="$TEST_TMP/container-system-state"
FAKE_SYNC_ENV_CAPTURE="$TEST_TMP/nebula-sync-env"
FAKE_SYNC_CONTAINER_NAME="adputate-nebula-sync"
printf 'missing\n' >"$FAKE_STATE_FILE"
printf 'pihole/pihole:2026.07.2\n' >"$FAKE_IMAGE_FILE"
printf 'running\n' >"$FAKE_SYSTEM_STATE"

cat >"$FAKE_CONTAINER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="$(cat "$FAKE_STATE_FILE")"
system_state="$(cat "$FAKE_SYSTEM_STATE")"
case "${1:-}" in
  --version) printf 'container CLI version 1.2.2 (test)\n' ;;
  system)
    case "${2:-}" in
      start) printf 'running\n' >"$FAKE_SYSTEM_STATE" ;;
      stop) printf 'stopped\n' >"$FAKE_SYSTEM_STATE" ;;
      *) exit 1 ;;
    esac
    ;;
  list)
    [[ "$system_state" == "running" ]] || exit 125
    if [[ " $* " == *" --all "* ]]; then
      [[ "$state" == "missing" ]] || printf '%s\n' "$FAKE_CONTAINER_NAME"
    else
      [[ "$state" == "running" ]] && printf '%s\n' "$FAKE_CONTAINER_NAME"
    fi
    ;;
  inspect)
    [[ "$system_state" == "running" ]] || exit 125
    cat <<JSON
    [{"configuration":{"labels":{"adputate_config_version":"2","adputate_bind_address":"127.0.0.1","adputate_web_port":"19080","adputate_dns_port":"15053","adputate_image":"pihole/pihole:2026.07.2","adputate_memory":"256M","adputate_upstreams":"192.168.86.1"},"image":{"reference":"docker.io/pihole/pihole:2026.07.2"}}}]
JSON
    ;;
  volume)
    [[ "$system_state" == "running" ]] || exit 125
    case "${2:-}" in
      inspect) exit 1 ;;
      create|delete) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  image)
    [[ "$system_state" == "running" ]] || exit 125
    case "${2:-}" in
      inspect) grep -Fxq "${3:-}" "$FAKE_IMAGE_FILE" ;;
      delete)
        grep -Fvx "${3:-}" "$FAKE_IMAGE_FILE" >"$FAKE_IMAGE_FILE.new" || true
        mv "$FAKE_IMAGE_FILE.new" "$FAKE_IMAGE_FILE"
        ;;
      *) exit 0 ;;
    esac
    ;;
  run)
    if [[ " $* " == *" --name $FAKE_SYNC_CONTAINER_NAME "* ]]; then
      args=("$@")
      for ((i=0; i<${#args[@]}; i++)); do
        if [[ "${args[$i]}" == "--env-file" ]]; then cp "${args[$((i + 1))]}" "$FAKE_SYNC_ENV_CAPTURE"; fi
      done
      printf 'test selective sync completed\n'
      [[ "${FAKE_SYNC_FAIL:-0}" != "1" ]]
    else
      printf 'running\n' >"$FAKE_STATE_FILE"
    fi
    ;;
  start) printf 'running\n' >"$FAKE_STATE_FILE" ;;
  stop) printf 'stopped\n' >"$FAKE_STATE_FILE" ;;
  delete) printf 'missing\n' >"$FAKE_STATE_FILE" ;;
  exec) exit 0 ;;
  logs) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKE_CONTAINER"

FAKE_CURL="$TEST_TMP/curl"
cat >"$FAKE_CURL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while (( $# > 0 )); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [[ "$url" == */api/auth ]]; then
  if [[ "${FAKE_AUTH_SID_MODE:-}" == "invalid" ]]; then
    [[ -n "$output" ]] && printf '{"session":{"sid":"bad\\\"sid"}}\n' >"$output"
  else
    [[ -n "$output" ]] && printf '{"session":{"sid":"test-session"}}\n' >"$output"
  fi
elif [[ "$url" == */api/info/version ]]; then
  printf '{"version":{"core":{"local":{"version":"v6-test"}}}}\n'
elif [[ "$url" == *'/api/queries?'* ]]; then
  printf '{"queries":[{"id":1,"time":1,"domain":"blocked.example","status":"GRAVITY","client":{"ip":"192.0.2.2"}}]}\n' >"$output"
elif [[ "$url" == */api/dns/blocking ]]; then
  printf '{"blocking":"enabled","timer":null}\n' >"$output"
elif [[ "$url" == */api/groups ]]; then
  if [[ "$url" == http://192.0.2.53/* ]]; then group_id=7; else group_id=0; fi
  printf '{"groups":[{"id":%s,"name":"Default","enabled":true,"comment":"The default group","date_added":1,"date_modified":2}]}\n' \
    "$group_id" >"$output"
elif [[ "$url" == */api/lists ]]; then
  if [[ "$url" == http://192.0.2.53/* ]]; then group_id=7; else group_id=0; fi
  address='https://example.test/blocklist.txt'
  if [[ "${FAKE_POLICY_DRIFT:-0}" == "1" && "$url" != http://192.0.2.53/* ]]; then
    address='https://example.test/drifted.txt'
  fi
  printf '{"lists":[{"id":1,"address":"%s","type":"block","enabled":true,"comment":"Test list","groups":[%s],"date_added":1,"date_modified":2,"date_updated":3,"number":4,"invalid_domains":0,"status":1,"abp_entries":0}]}\n' \
    "$address" "$group_id" >"$output"
elif [[ "$url" == */api/domains ]]; then
  if [[ "$url" == http://192.0.2.53/* ]]; then group_id=7; else group_id=0; fi
  printf '{"domains":[{"id":1,"domain":"blocked.example","type":"deny","kind":"exact","enabled":true,"comment":"Test domain","groups":[%s],"date_added":1,"date_modified":2}]}\n' \
    "$group_id" >"$output"
else
  [[ -n "$output" ]] && printf '{}\n' >"$output"
fi
exit 0
EOF
chmod +x "$FAKE_CURL"

FAKE_SCUTIL="$TEST_TMP/scutil"
cat >"$FAKE_SCUTIL" <<'EOF'
#!/usr/bin/env bash
printf '  nameserver[0] : 192.0.2.53\n'
EOF
chmod +x "$FAKE_SCUTIL"

FAKE_ROUTE="$TEST_TMP/route"
cat >"$FAKE_ROUTE" <<'EOF'
#!/usr/bin/env bash
printf '     gateway: 192.168.86.1\n'
printf '   interface: en7\n'
EOF
chmod +x "$FAKE_ROUTE"

FAKE_IPCONFIG="$TEST_TMP/ipconfig"
cat >"$FAKE_IPCONFIG" <<'EOF'
#!/usr/bin/env bash
printf 'domain_name_server (ip_mult): {192.168.86.1}\n'
EOF
chmod +x "$FAKE_IPCONFIG"

FAKE_DNS_STATE="$TEST_TMP/client-dns-state"
printf '192.168.86.1\n' >"$FAKE_DNS_STATE"
FAKE_NETWORKSETUP="$TEST_TMP/networksetup"
cat >"$FAKE_NETWORKSETUP" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -listnetworkserviceorder)
    printf '(1) USB LAN\n(Hardware Port: USB LAN, Device: en7)\n'
    ;;
  -getdnsservers)
    if [[ -s "$FAKE_DNS_STATE" ]]; then cat "$FAKE_DNS_STATE"; else printf "There aren't any DNS Servers set on %s.\n" "${2:-}"; fi
    ;;
  -setdnsservers)
    shift 2
    if [[ "${1:-}" == "empty" ]]; then : >"$FAKE_DNS_STATE"; else printf '%s\n' "$@" >"$FAKE_DNS_STATE"; fi
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_NETWORKSETUP"

FAKE_SUDO="$TEST_TMP/sudo"
cat >"$FAKE_SUDO" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$FAKE_SUDO"

FAKE_DIG="$TEST_TMP/dig"
cat >"$FAKE_DIG" <<'EOF'
#!/usr/bin/env bash
printf '192.0.2.1\n'
EOF
chmod +x "$FAKE_DIG"

FAKE_CLIPBOARD="$TEST_TMP/clipboard"
FAKE_PBCOPY="$TEST_TMP/pbcopy"
cat >"$FAKE_PBCOPY" <<'EOF'
#!/usr/bin/env bash
cat >"$FAKE_CLIPBOARD"
EOF
chmod +x "$FAKE_PBCOPY"

FAKE_OPEN_STATE="$TEST_TMP/open-state"
FAKE_OPEN="$TEST_TMP/open"
cat >"$FAKE_OPEN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >"$FAKE_OPEN_STATE"
EOF
chmod +x "$FAKE_OPEN"

FAKE_KEYCHAIN_STATE="$TEST_TMP/keychain-state"
: >"$FAKE_KEYCHAIN_STATE"
FAKE_SECURITY="$TEST_TMP/security"
cat >"$FAKE_SECURITY" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
action="${1:-}"
shift || true
account=""
password=""
while (( $# > 0 )); do
  case "$1" in
    -a) account="$2"; shift 2 ;;
    -w)
      if (( $# >= 2 )) && [[ "$2" != -* ]]; then password="$2"; shift 2; else shift; fi
      ;;
    -s|-l) shift 2 ;;
    -U) shift ;;
    *) shift ;;
  esac
done
case "$action" in
  add-generic-password) printf '%s=%s\n' "$account" "$password" >>"$FAKE_KEYCHAIN_STATE" ;;
  find-generic-password)
    value="$(awk -F= -v account="$account" '$1 == account {sub(/^[^=]*=/, ""); print; exit}' "$FAKE_KEYCHAIN_STATE")"
    [[ -n "$value" ]] || exit 44
    printf '%s\n' "$value"
    ;;
  delete-generic-password)
    [[ "${FAKE_SECURITY_DELETE_ERROR:-0}" != "1" ]] || exit 1
    awk -F= -v account="$account" '$1 != account' "$FAKE_KEYCHAIN_STATE" >"$FAKE_KEYCHAIN_STATE.new"
    mv "$FAKE_KEYCHAIN_STATE.new" "$FAKE_KEYCHAIN_STATE"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_SECURITY"

export HOME="$TEST_TMP/home"
export ADPUTATE_APP_DIR="$TEST_TMP/app"
export CONTAINER_BIN="$FAKE_CONTAINER"
export ADPUTATE_CONTAINER_NAME="adputate-test-pihole"
export ADPUTATE_SERVICE_LABEL="com.adputate.test.pihole"
export ADPUTATE_ROUTER_SERVICE_LABEL="com.adputate.test.dns-forwarder"
export ADPUTATE_ROUTER_SUPPORT_DIR="$TEST_TMP/router-support"
export ADPUTATE_ROUTER_PLIST_PATH="$TEST_TMP/com.adputate.test.dns-forwarder.plist"
export ADPUTATE_ROUTER_LOG_PATH="$TEST_TMP/adputate-dns-forwarder.log"
export ADPUTATE_CURL_BIN="$FAKE_CURL"
export ADPUTATE_SCUTIL_BIN="$FAKE_SCUTIL"
export ADPUTATE_ROUTE_BIN="$FAKE_ROUTE"
export ADPUTATE_IPCONFIG_BIN="$FAKE_IPCONFIG"
export ADPUTATE_NETWORKSETUP_BIN="$FAKE_NETWORKSETUP"
export ADPUTATE_SUDO_BIN="$FAKE_SUDO"
export ADPUTATE_DIG_BIN="$FAKE_DIG"
export ADPUTATE_SECURITY_BIN="$FAKE_SECURITY"
export ADPUTATE_PBCOPY_BIN="$FAKE_PBCOPY"
export ADPUTATE_OPEN_BIN="$FAKE_OPEN"
export ADPUTATE_ISSUES_URL="https://example.invalid/adputate/issues/new"
export FAKE_DNS_STATE
export FAKE_STATE_FILE FAKE_IMAGE_FILE FAKE_SYSTEM_STATE FAKE_KEYCHAIN_STATE FAKE_CLIPBOARD FAKE_OPEN_STATE
export FAKE_SYNC_ENV_CAPTURE FAKE_SYNC_CONTAINER_NAME
export FAKE_CONTAINER_NAME="$ADPUTATE_CONTAINER_NAME"
mkdir -p "$HOME/Library/Application Support"

output="$($CLI help)"
assert_contains "$output" 'configure [options]'
assert_contains "$output" 'host router install|preflight|status|uninstall'
assert_contains "$output" 'instance add <id>'
assert_contains "$output" 'install     Configure existing Pi-holes'
assert_contains "$output" 'upgrade <image> --yes'
assert_contains "$output" 'uninstall --yes'
output="$($CLI --version)"
assert_contains "$output" 'Adputate 0.0.0-dev'

INSTALL_PREFIX="$TEST_TMP/install-prefix"
make -s -C "$PROJECT_ROOT" install PREFIX="$INSTALL_PREFIX"
output="$("$INSTALL_PREFIX/bin/adputate" --version)"
assert_contains "$output" 'Adputate 0.0.0-dev'
[[ -x "$INSTALL_PREFIX/libexec/adputate/build/adputate-dns-proxy" ]] || \
  fail 'installed package omitted the built DNS frontend'
mkdir -p "$TEST_TMP/homebrew-bin"
ln -s "$INSTALL_PREFIX/bin/adputate" "$TEST_TMP/homebrew-bin/adputate"
output="$(PATH="$TEST_TMP/homebrew-bin:$PATH" "$TEST_TMP/homebrew-bin/adputate" host service plist)"
assert_contains "$output" "$TEST_TMP/homebrew-bin/adputate"
make -s -C "$PROJECT_ROOT" uninstall PREFIX="$INSTALL_PREFIX"
[[ ! -e "$INSTALL_PREFIX/bin/adputate" ]] || fail 'package uninstall retained the launcher'
[[ ! -e "$INSTALL_PREFIX/libexec/adputate" ]] || fail 'package uninstall retained the application bundle'

NUC_ONLY_APP="$TEST_TMP/nuc-only-app"
ADPUTATE_APP_DIR="$NUC_ONLY_APP" "$CLI" instance add nuc-only --name 'Only Pi-hole' \
  --role authority --api-url http://192.0.2.60 --dns 192.0.2.60#53 --no-auth >/dev/null
output="$(ADPUTATE_APP_DIR="$NUC_ONLY_APP" "$CLI" status)"
assert_contains "$output" 'Only Pi-hole (nuc-only)'
assert_contains "$output" 'Role: authority'
assert_contains "$output" 'API: reachable'
output="$(ADPUTATE_APP_DIR="$NUC_ONLY_APP" "$CLI" query blocked.example)"
assert_contains "$output" 'Matches in nuc-only'
output="$(ADPUTATE_APP_DIR="$NUC_ONLY_APP" "$CLI" client dns plan)"
assert_contains "$output" '192.0.2.60'
[[ ! -e "$NUC_ONLY_APP/config/runtime.env" ]] || fail 'NUC-only setup created local host runtime configuration'
[[ "$(cat "$FAKE_STATE_FILE")" == "missing" ]] || fail 'NUC-only setup touched the container runtime'

VALIDATION_APP="$TEST_TMP/validation-app"
if ADPUTATE_APP_DIR="$VALIDATION_APP" "$CLI" instance add bad-url --role replica \
    --api-url 'http://user:secret@192.0.2.60' --dns 192.0.2.60#53 --no-auth >/dev/null 2>&1; then
  fail 'instance add accepted API credentials in a legible URL'
fi
if ADPUTATE_APP_DIR="$VALIDATION_APP" "$CLI" instance add bad-dns --role replica \
    --api-url https://192.0.2.60 --dns '192.0.2.60#not-a-port' --no-auth >/dev/null 2>&1; then
  fail 'instance add accepted an invalid DNS endpoint'
fi
ADPUTATE_APP_DIR="$VALIDATION_APP" "$CLI" instance add tls --role replica \
  --api-url https://192.0.2.60 --dns 192.0.2.60#53 --no-auth >/dev/null
grep -Fxq 'TRANSPORT=https' "$VALIDATION_APP/config/instances.d/tls.conf" || \
  fail 'HTTPS instance metadata reported the wrong transport'
if ADPUTATE_APP_DIR="$VALIDATION_APP" "$CLI" host configure --upstreams 192.0.2.60 \
    >"$TEST_TMP/peer-upstream-loop.out" 2>&1; then
  fail 'configure accepted a configured Pi-hole as an upstream'
fi
assert_contains "$(cat "$TEST_TMP/peer-upstream-loop.out")" 'would create a DNS loop'

FALLBACK_APP="$TEST_TMP/router-fallback-app"
ADPUTATE_APP_DIR="$FALLBACK_APP" ADPUTATE_IPCONFIG_BIN="$TEST_TMP/missing-ipconfig" \
  "$CLI" host configure >/dev/null
output="$(ADPUTATE_APP_DIR="$FALLBACK_APP" "$CLI" host config)"
assert_contains "$output" 'Upstreams:     192.168.86.1'
assert_contains "$output" 'Source:        default router (en7)'

AUTH_APP="$TEST_TMP/auth-app"
printf 'test-secret\n' | ADPUTATE_APP_DIR="$AUTH_APP" "$CLI" instance add secure --role authority \
  --api-url http://192.0.2.62 --dns 192.0.2.62#53 --password-stdin >/dev/null
if FAKE_AUTH_SID_MODE=invalid ADPUTATE_APP_DIR="$AUTH_APP" "$CLI" status \
    >"$TEST_TMP/invalid-sid.out" 2>&1; then
  fail 'API client accepted an unsafe session identifier'
fi
assert_contains "$(cat "$TEST_TMP/invalid-sid.out")" 'invalid session identifier'
if FAKE_SECURITY_DELETE_ERROR=1 ADPUTATE_APP_DIR="$AUTH_APP" "$CLI" instance remove secure \
    >"$TEST_TMP/keychain-delete.out" 2>&1; then
  fail 'instance remove discarded configuration after Keychain cleanup failed'
fi
[[ -f "$AUTH_APP/config/instances.d/secure.conf" ]] || fail 'failed credential cleanup lost instance metadata'
ADPUTATE_APP_DIR="$AUTH_APP" "$CLI" instance remove secure >/dev/null

if ADPUTATE_WARP_STATUS='Status update: Connected' "$CLI" host router preflight >"$TEST_TMP/warp.out" 2>&1; then
  fail 'router preflight accepted an active Cloudflare WARP connection'
fi
assert_contains "$(cat "$TEST_TMP/warp.out")" 'Cloudflare WARP is connected'
assert_contains "$(cat "$TEST_TMP/warp.out")" 'Turn WARP off'

if ADPUTATE_WARP_STATUS='Status update: Connected' "$CLI" host service install >"$TEST_TMP/service-install.out" 2>&1; then
  fail 'service install accepted an active Cloudflare WARP connection'
fi
assert_contains "$(cat "$TEST_TMP/service-install.out")" 'Cloudflare WARP is connected'
if ADPUTATE_WARP_STATUS='Status update: Connected' "$CLI" host router install >"$TEST_TMP/router-install.out" 2>&1; then
  fail 'router install accepted an active Cloudflare WARP connection'
fi
assert_contains "$(cat "$TEST_TMP/router-install.out")" 'Cloudflare WARP is connected'
if ADPUTATE_WARP_STATUS='Status update: Connected' "$CLI" client dns apply --yes >"$TEST_TMP/dns-enable.out" 2>&1; then
  fail 'client DNS apply accepted an active Cloudflare WARP connection'
fi
assert_contains "$(cat "$TEST_TMP/dns-enable.out")" 'Cloudflare WARP is connected'

if ADPUTATE_PRIVATE_RELAY_STATUS=1 "$CLI" host router preflight >"$TEST_TMP/private-relay.out" 2>&1; then
  fail 'router preflight accepted active iCloud Private Relay'
fi
assert_contains "$(cat "$TEST_TMP/private-relay.out")" 'iCloud Private Relay is enabled'
assert_contains "$(cat "$TEST_TMP/private-relay.out")" 'Limit IP Address Tracking'

$CLI host configure --bind-address 127.0.0.1 --web-port 19080 --dns-port 15053 \
  --image pihole/pihole:2026.07.2 --memory 256M >/dev/null
[[ -f "$ADPUTATE_APP_DIR/config/runtime.env" ]] || fail 'runtime configuration was not created'

output="$($CLI host config)"
assert_contains "$output" 'Bind address:  127.0.0.1'
assert_contains "$output" 'Web port:      19080'
assert_contains "$output" 'DNS backend:   15053'
assert_contains "$output" 'Upstreams:     192.168.86.1'
assert_contains "$output" 'Source:        router DHCP (en7)'
grep -Fxq 'ADPUTATE_CONFIG_UPSTREAMS=192.168.86.1' "$ADPUTATE_APP_DIR/config/runtime.env" ||
  fail 'runtime config did not persist the router-provided upstream'

if $CLI host configure --upstreams 127.0.0.1 >"$TEST_TMP/upstream-loop.out" 2>&1; then
  fail 'configure accepted a loopback upstream'
fi
assert_contains "$(cat "$TEST_TMP/upstream-loop.out")" 'would create a DNS loop'
if $CLI host configure --upstreams ::1 >"$TEST_TMP/upstream-v6-loop.out" 2>&1; then
  fail 'configure accepted an IPv6 loopback upstream'
fi
assert_contains "$(cat "$TEST_TMP/upstream-v6-loop.out")" 'would create a DNS loop'

$CLI host configure --upstreams '9.9.9.9;149.112.112.112' >/dev/null
output="$($CLI host config)"
assert_contains "$output" 'Upstreams:     9.9.9.9;149.112.112.112'
assert_contains "$output" 'Source:        explicit'
$CLI host configure --upstreams router >/dev/null

$CLI host init >/dev/null
grep -Fxq 'FTLCONF_dns_upstreams=192.168.86.1' "$ADPUTATE_APP_DIR/config/pihole.env" ||
  fail 'Pi-hole environment did not receive the router-provided upstream'
: >"$ADPUTATE_ROUTER_PLIST_PATH"
$CLI host register >/dev/null
output="$($CLI instance list)"
assert_contains "$output" 'Instance: adputate'
assert_contains "$output" 'Default window:   1h'
assert_contains "$output" 'Peer Pi-hole: not configured'

output="$($CLI bugreport)"
assert_contains "$output" 'Sanitized bug report copied to the clipboard'
assert_contains "$output" "$ADPUTATE_ISSUES_URL"
bugreport_path="$(printf '%s\n' "$output" | awk -F': ' '/^Review saved copy:/ {print $2}')"
[[ -f "$bugreport_path" ]] || fail 'bugreport did not save a reviewable copy'
cmp -s "$bugreport_path" "$FAKE_CLIPBOARD" || fail 'bugreport clipboard did not match the saved report'
assert_contains "$(cat "$bugreport_path")" 'Configured Pi-hole instances: 1'
assert_contains "$(cat "$bugreport_path")" 'role=replica, active=true, auth=managed-local'
if grep -Fq '192.0.2.' "$bugreport_path" || grep -Fq 'Adputate on' "$bugreport_path"; then
  fail 'bugreport exposed network identifiers'
fi
$CLI bugreport --open >/dev/null
[[ "$(cat "$FAKE_OPEN_STATE")" == "$ADPUTATE_ISSUES_URL" ]] || fail 'bugreport --open used the wrong issue URL'
if ADPUTATE_ISSUES_URL="" $CLI bugreport --open >"$TEST_TMP/bugreport-no-url.out" 2>&1; then
  fail 'bugreport --open succeeded without a configured issue tracker'
fi
assert_contains "$(cat "$TEST_TMP/bugreport-no-url.out")" 'report was copied'
assert_contains "$(cat "$TEST_TMP/bugreport-no-url.out")" 'ADPUTATE_ISSUES_URL is not configured'

output="$($CLI discover)"
assert_contains "$output" '192.0.2.53  Pi-hole detected'

output="$($CLI query blocked.example)"
assert_contains "$output" 'Matches in adputate'
assert_contains "$output" 'blocked.example'
snapshot_path="$(printf '%s\n' "$output" | awk '$1 == "Snapshot:" {print substr($0, 11)}')"
[[ -f "$snapshot_path/adputate.json" ]] || fail 'raw local query snapshot was not created'
[[ -f "$snapshot_path/adputate.txt" ]] || fail 'searchable local query snapshot was not created'

output="$($CLI blocking status)"
assert_contains "$output" 'Adputate on'
assert_contains "$output" 'enabled; timer=none'
output="$($CLI status)"
assert_contains "$output" 'API: reachable'
assert_contains "$output" 'Blocking: enabled'

printf 'nuc-secret\n' | $CLI instance add nuc --name 'NUC Pi-hole' --role authority \
  --api-url http://192.0.2.53 --dns 192.0.2.53#53 --password-stdin >/dev/null
output="$($CLI instance list)"
assert_contains "$output" 'Instance: nuc'
assert_contains "$output" 'Name:      NUC Pi-hole'
assert_contains "$output" 'Active:    true'
if $CLI host register nuc >/dev/null 2>&1; then
  fail 'host register overwrote an explicitly configured authority'
fi
output="$($CLI client dns plan)"
assert_contains "$output" 'Network service: USB LAN'
assert_contains "$output" '192.0.2.53'
assert_contains "$output" '127.0.0.1'
$CLI client dns apply --yes >/dev/null
[[ "$(sed -n '1p' "$FAKE_DNS_STATE")" == "192.0.2.53" ]] || fail 'authority was not first in client DNS'
[[ "$(sed -n '2p' "$FAKE_DNS_STATE")" == "127.0.0.1" ]] || fail 'replica was not second in client DNS'
$CLI client dns restore --yes >/dev/null
[[ "$(cat "$FAKE_DNS_STATE")" == "192.168.86.1" ]] || fail 'client DNS restore did not recover prior DNS'
printf 'running\n' >"$FAKE_STATE_FILE"
output="$($CLI host sync configure --yes --interval 5m --stale-after 15m)"
assert_contains "$output" 'schedule is paused and no policy was copied'
output="$($CLI host sync status)"
assert_contains "$output" 'Direction:    nuc -> adputate'
assert_contains "$output" 'paused=true'
output="$($CLI host sync now)"
assert_contains "$output" 'completed successfully'
assert_contains "$(cat "$FAKE_SYNC_ENV_CAPTURE")" 'PRIMARY=http://192.0.2.53|nuc-secret'
assert_contains "$(cat "$FAKE_SYNC_ENV_CAPTURE")" 'FULL_SYNC=false'
assert_contains "$(cat "$FAKE_SYNC_ENV_CAPTURE")" 'SYNC_GRAVITY_DOMAIN_LIST_BY_GROUP=true'
assert_contains "$(cat "$FAKE_SYNC_ENV_CAPTURE")" 'SYNC_GRAVITY_CLIENT=false'
output="$($CLI host sync verify)"
assert_contains "$output" '[PASS] Groups: 1 record(s) match'
assert_contains "$output" '[PASS] Adlists: 1 record(s) match'
assert_contains "$output" '[PASS] Domains: 1 record(s) match'
assert_contains "$output" '[PASS] Mappings: 2 record(s) match'
assert_contains "$output" 'No Pi-hole state was changed'
if FAKE_POLICY_DRIFT=1 $CLI host sync verify >"$TEST_TMP/sync-verify-drift.out" 2>&1; then
  fail 'sync verify succeeded when policies differed'
fi
assert_contains "$(cat "$TEST_TMP/sync-verify-drift.out")" '[FAIL] Adlists differ'
assert_contains "$(cat "$TEST_TMP/sync-verify-drift.out")" '[FAIL] Mappings differ'
if find "$ADPUTATE_APP_DIR/data" -name 'nebula-sync-env.*' -print -quit | grep -q .; then
  fail 'Nebula Sync runtime credential file was retained'
fi
if FAKE_SYNC_FAIL=1 $CLI host sync now >"$TEST_TMP/sync-failure.out" 2>&1; then
  fail 'sync now reported success when the Nebula Sync container failed'
fi
assert_contains "$($CLI host sync status)" 'Last result:  failed'
assert_contains "$(cat "$TEST_TMP/sync-failure.out")" 'Nebula Sync failed'
$CLI host sync resume >/dev/null
assert_contains "$($CLI host sync status)" 'paused=false'
sed -i '' 's/^LAST_ATTEMPT_EPOCH=.*/LAST_ATTEMPT_EPOCH=0/' "$ADPUTATE_APP_DIR/data/nebula-sync-state.conf"
$CLI host ensure >/dev/null
assert_contains "$($CLI host sync status)" 'Last result:  success'
$CLI host sync pause >/dev/null
assert_contains "$($CLI host sync status)" 'paused=true'
assert_contains "$($CLI host sync logs)" 'test selective sync completed'
$CLI host sync remove --yes >/dev/null
[[ ! -e "$ADPUTATE_APP_DIR/config/nebula-sync.conf" ]] || fail 'sync remove retained configuration'
printf 'missing\n' >"$FAKE_STATE_FILE"
rm -f "$ADPUTATE_ROUTER_PLIST_PATH"
$CLI instance remove nuc >/dev/null
[[ ! -e "$ADPUTATE_APP_DIR/config/instances.d/nuc.conf" ]] || fail 'instance-remove retained peer metadata'

if $CLI host configure --dns-port 53 >/dev/null 2>&1; then
  fail 'configure accepted a privileged backend port'
fi

if $CLI host health >"$TEST_TMP/health.out" 2>&1; then
  fail 'health succeeded without a container'
fi
assert_contains "$(cat "$TEST_TMP/health.out")" 'does not exist'

printf 'stopped\n' >"$FAKE_STATE_FILE"
output="$($CLI host status)"
assert_contains "$output" 'exists but is stopped'
assert_contains "$output" 'matches desired state'

printf 'stopped\n' >"$FAKE_SYSTEM_STATE"
$CLI host start >/dev/null
[[ "$(cat "$FAKE_SYSTEM_STATE")" == "running" ]] || fail 'host start did not recover the container service first'
[[ "$(cat "$FAKE_STATE_FILE")" == "running" ]] || fail 'host start did not recover the Pi-hole container'
output="$($CLI config show)"
assert_contains "$output" 'Local upstreams:  192.168.86.1'
assert_contains "$output" 'Upstream source:  router DHCP (en7)'

output="$($CLI host service plist)"
assert_contains "$output" "$PROJECT_ROOT/bin/adputate"
assert_contains "$output" '<string>host</string>'
assert_contains "$output" '<string>ensure</string>'
assert_contains "$output" '<key>StartInterval</key>'

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
assert_contains "$(cat "$PROJECT_ROOT/packaging/router/adputate-router.sh")" 'socketfilterfw --remove'

if [[ "$(uname -s)" == "Darwin" ]]; then
  make -s -C "$PROJECT_ROOT" build
  if "$PROJECT_ROOT/build/adputate-dns-proxy" >/dev/null 2>&1; then
    fail 'DNS proxy accepted missing arguments'
  fi
fi

mkdir -p "$ADPUTATE_APP_DIR/data"
printf 'pihole/pihole:2026.07.2\n' >"$ADPUTATE_APP_DIR/data/owned-images"
printf 'stopped\n' >"$FAKE_STATE_FILE"
output="$($CLI host uninstall --yes)"
assert_contains "$output" 'Adputate host uninstall completed cleanly'
[[ -e "$ADPUTATE_APP_DIR/config/cluster.conf" ]] || fail 'host uninstall removed controller configuration'
[[ ! -e "$ADPUTATE_APP_DIR/config/runtime.env" ]] || fail 'host uninstall retained host runtime configuration'
[[ "$(cat "$FAKE_STATE_FILE")" == "missing" ]] || fail 'uninstall retained the container'
if grep -Fxq 'pihole/pihole:2026.07.2' "$FAKE_IMAGE_FILE"; then
  fail 'uninstall retained the configured Pi-hole image'
fi
output="$($CLI host uninstall-audit)"
assert_contains "$output" '0 failed'

$CLI host configure --bind-address 127.0.0.1 --web-port 19080 --dns-port 15053 \
  --image pihole/pihole:2026.07.2 --memory 256M >/dev/null
[[ -f "$ADPUTATE_APP_DIR/config/runtime.env" ]] || fail 'fresh configuration failed after uninstall'
printf 'pihole/pihole:2026.07.2\n' >"$FAKE_IMAGE_FILE"
output="$($CLI host uninstall --yes)"
grep -Fxq 'pihole/pihole:2026.07.2' "$FAKE_IMAGE_FILE" || \
  fail 'host uninstall removed a pre-existing image without an ownership receipt'

$CLI host configure --bind-address 127.0.0.1 --web-port 19080 --dns-port 15053 \
  --image pihole/pihole:2026.07.2 --memory 256M >/dev/null
mkdir -p "$ADPUTATE_APP_DIR/data"
printf 'pihole/pihole:2026.07.2\n' >"$ADPUTATE_APP_DIR/data/owned-images"
output="$($CLI host uninstall --yes --keep-images)"
assert_contains "$output" 'deliberately retained'
grep -Fxq 'pihole/pihole:2026.07.2' "$FAKE_IMAGE_FILE" || fail '--keep-images removed the Pi-hole image'
[[ -e "$ADPUTATE_APP_DIR/config/cluster.conf" ]] || fail '--keep-images removed controller configuration'
[[ ! -e "$ADPUTATE_APP_DIR/config/runtime.env" ]] || fail '--keep-images retained host runtime configuration'

printf 'test-secret\n' | "$CLI" instance add keyed --name 'Keyed Pi-hole' --role replica \
  --api-url http://192.0.2.61 --dns 192.0.2.61#53 --password-stdin >/dev/null
grep -Fq 'keyed=test-secret' "$FAKE_KEYCHAIN_STATE" || fail 'test credential was not stored'
output="$($CLI uninstall --yes)"
assert_contains "$output" 'Adputate uninstall completed cleanly'
[[ ! -e "$ADPUTATE_APP_DIR" ]] || fail 'full uninstall retained controller configuration'
[[ ! -s "$FAKE_KEYCHAIN_STATE" ]] || fail 'full uninstall retained Keychain credentials'
output="$($CLI uninstall-audit)"
assert_contains "$output" '0 failed'

NO_RUNTIME_APP="$TEST_TMP/no-runtime-app"
ADPUTATE_APP_DIR="$NO_RUNTIME_APP" CONTAINER_BIN="$TEST_TMP/missing-container" \
  "$CLI" host configure --bind-address 127.0.0.1 --web-port 19080 --dns-port 15053 \
  --image pihole/pihole:2026.07.2 --memory 256M >/dev/null
output="$(ADPUTATE_APP_DIR="$NO_RUNTIME_APP" CONTAINER_BIN="$TEST_TMP/missing-container" \
  "$CLI" host uninstall --yes)"
assert_contains "$output" 'cleaning all non-container host artifacts'
[[ ! -e "$NO_RUNTIME_APP/config/runtime.env" ]] || fail 'host uninstall retained config when container CLI was absent'
ADPUTATE_APP_DIR="$NO_RUNTIME_APP" CONTAINER_BIN="$TEST_TMP/missing-container" \
  "$CLI" uninstall --yes >/dev/null
[[ ! -e "$NO_RUNTIME_APP" ]] || fail 'full uninstall retained state when container CLI was absent'

printf 'PASS: CLI, instance inventory, query snapshots, cluster status, drift, health-failure, port-conflict, clean-uninstall, privilege, and proxy-build tests\n'
