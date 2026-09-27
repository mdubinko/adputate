#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/adputate-local-tests.XXXXXX")"
trap 'rm -rf "$LOCAL_TMP"' EXIT
export ADPUTATE_APP_DIR="$LOCAL_TMP/app"
# Load functions without starting a service or changing the machine's DNS.
source "$TEST_ROOT/libexec/adputate.sh" help >/dev/null
HOST_BIND_ADDRESS=127.0.0.1
ROUTER_PLIST_PATH="$LOCAL_TMP/frontend.plist"
DSCACHEUTIL_BIN="$LOCAL_TMP/resolver"
export LOCAL_PROBE_FILE="$LOCAL_TMP/probe"
cat >"$DSCACHEUTIL_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$5" >"$LOCAL_PROBE_FILE"
EOF
chmod +x "$DSCACHEUTIL_BIN"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
require_apple_silicon() { :; }
require_container() { :; }
privacy_preflight() { return 0; }
client_dns_service_from_args() { printf 'Test Wi-Fi'; }
init_config() { ensure_dirs; }
start_pihole() { printf 'start\n' >>"$LOCAL_TMP/stages"; }
service_install() { printf 'service\n' >>"$LOCAL_TMP/stages"; }
router_install() {
  require_router_config
  [[ "$ROUTER_INTERFACE" == lo0 ]] || fail 'localhost did not select loopback'
  touch "$ROUTER_PLIST_PATH"
}
client_dns_apply() {
  [[ "$(client_dns_targets)" == 127.0.0.1 ]] || fail 'wrong DNS target'
  touch "$DNS_BACKUP_FILE"
  printf 'local\n' >"$LOCAL_TMP/dns"
}
restore_dns_backup() { printf 'original\n' >"$LOCAL_TMP/dns"; }
instance_api_request() {
  local domain
  domain="$(cat "$LOCAL_PROBE_FILE")"
  [[ "${LOCAL_VERIFY_FAIL:-0}" != 1 ]] || domain=unrelated.example.com
  printf '{"queries":[{"domain":"%s"}]}\n' "$domain" >"$5"
}

if (install_local) >"$LOCAL_TMP/output" 2>&1; then fail 'accepted missing --yes'; fi
[[ ! -e "$LOCAL_TMP/stages" ]] || fail 'mutated before consent'
install_local --yes >"$LOCAL_TMP/output"
grep -Fq 'Verified: a macOS system DNS lookup' "$LOCAL_TMP/output" || fail 'missing system verification'
[[ "$(cat "$LOCAL_TMP/dns")" == local ]] || fail 'successful setup did not retain DNS'
[[ "$(config_value "$INSTANCES_DIR/adputate.conf" DNS_ENDPOINT)" == '127.0.0.1#53' ]] || fail 'registered backend port'

if (install_local --yes) >"$LOCAL_TMP/output" 2>&1; then fail 'overwrote active restore point'; fi
client_dns_restore --yes >/dev/null
if (LOCAL_VERIFY_FAIL=1 install_local --yes) >"$LOCAL_TMP/output" 2>&1; then fail 'accepted bypassed DNS'; fi
[[ "$(cat "$LOCAL_TMP/dns")" == original ]] || fail 'verification failure did not restore DNS'
[[ ! -f "$DNS_BACKUP_FILE" ]] || fail 'retained restored backup'

printf 'ACTIVE=true\nAUTH=none\n' >"$INSTANCES_DIR/remote.conf"
if (install_local --yes) >"$LOCAL_TMP/output" 2>&1; then fail 'accepted other active nodes'; fi
grep -Fq 'existing instance configuration was preserved' "$LOCAL_TMP/output" || fail 'missing conflict explanation'
rm "$INSTANCES_DIR/remote.conf"
if (HOST_BIND_ADDRESS=192.0.2.1 install_local --yes) >"$LOCAL_TMP/output" 2>&1; then fail 'replaced LAN host'; fi

printf 'PASS: local setup, system resolver verification, DNS rollback, and existing configuration protection\n'
