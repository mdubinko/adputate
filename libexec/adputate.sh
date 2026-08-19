#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/project.env" ]]; then
  PROJECT_ROOT="$SCRIPT_DIR"
else
  PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
fi

if [[ -f "$PROJECT_ROOT/project.env" ]]; then
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/project.env"
fi

APP_NAME="${ADPUTATE_DISPLAY_NAME:-Adputate}"
CLI_NAME="${ADPUTATE_CLI_NAME:-adputate}"
VERSION_FILE="$PROJECT_ROOT/VERSION"
if [[ -n "${ADPUTATE_LAUNCHER:-}" ]]; then
  CLI_LAUNCHER="$ADPUTATE_LAUNCHER"
elif command -v "$CLI_NAME" >/dev/null 2>&1; then
  CLI_LAUNCHER="$(command -v "$CLI_NAME")"
else
  CLI_LAUNCHER="$PROJECT_ROOT/bin/$CLI_NAME"
fi
if [[ -n "${CONTAINER_BIN:-}" ]]; then
  CONTAINER_BIN="$CONTAINER_BIN"
elif [[ -x /opt/homebrew/bin/container ]]; then
  CONTAINER_BIN="/opt/homebrew/bin/container"
else
  CONTAINER_BIN="container"
fi
APP_DIR="${ADPUTATE_APP_DIR:-$HOME/Library/Application Support/$APP_NAME}"
DATA_DIR="$APP_DIR/data"
CONFIG_DIR="$APP_DIR/config"
RUNTIME_CONFIG_FILE="$CONFIG_DIR/runtime.env"

if [[ -f "$RUNTIME_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$RUNTIME_CONFIG_FILE"
fi

CONTAINER_NAME="${ADPUTATE_CONTAINER_NAME:-${CLI_NAME}-pihole}"
SERVICE_LABEL="${ADPUTATE_SERVICE_LABEL:-com.${CLI_NAME}.pihole}"
IMAGE="${ADPUTATE_IMAGE:-${ADPUTATE_CONFIG_IMAGE:-pihole/pihole:2026.07.2}}"
SMOKE_IMAGE="${ADPUTATE_SMOKE_IMAGE:-alpine:3.22}"
MEMORY="${ADPUTATE_MEMORY:-${ADPUTATE_CONFIG_MEMORY:-256M}}"
ENV_FILE="$CONFIG_DIR/pihole.env"
LOG_DIR="$APP_DIR/logs"
TELEPORTER_DIR="$APP_DIR/teleporter"
DNS_BACKUP_FILE="$CONFIG_DIR/dns-backup.env"
OWNED_IMAGES_FILE="$DATA_DIR/owned-images"
CONTAINER_SYSTEM_MARKER="$DATA_DIR/started-container-system"
ETC_PIHOLE_VOLUME="${ADPUTATE_ETC_PIHOLE_VOLUME:-${CLI_NAME}-etc-pihole}"
ETC_DNSMASQ_VOLUME="${ADPUTATE_ETC_DNSMASQ_VOLUME:-${CLI_NAME}-etc-dnsmasq.d}"
HOST_WEB_PORT="${ADPUTATE_WEB_PORT:-${ADPUTATE_CONFIG_WEB_PORT:-8080}}"
HOST_DNS_PORT="${ADPUTATE_DNS_PORT:-${ADPUTATE_CONFIG_DNS_PORT:-5053}}"
HOST_BIND_ADDRESS="${ADPUTATE_BIND_ADDRESS:-${ADPUTATE_CONFIG_BIND_ADDRESS:-127.0.0.1}}"
ROUTER_INTERFACE="${ADPUTATE_ROUTER_INTERFACE:-${ADPUTATE_CONFIG_ROUTER_INTERFACE:-}}"
ROUTER_SERVICE_LABEL="${ADPUTATE_ROUTER_SERVICE_LABEL:-com.${CLI_NAME}.dns-forwarder}"
ROUTER_SUPPORT_DIR="${ADPUTATE_ROUTER_SUPPORT_DIR:-/Library/Application Support/$APP_NAME}"
ROUTER_PLIST_PATH="${ADPUTATE_ROUTER_PLIST_PATH:-/Library/LaunchDaemons/$ROUTER_SERVICE_LABEL.plist}"
ROUTER_PROXY_PATH="$ROUTER_SUPPORT_DIR/adputate-dns-proxy"
ROUTER_LOG_PATH="${ADPUTATE_ROUTER_LOG_PATH:-/var/log/adputate-dns-forwarder.log}"
CLUSTER_CONFIG_FILE="$CONFIG_DIR/cluster.conf"
INSTANCES_DIR="$CONFIG_DIR/instances.d"
QUERY_SNAPSHOT_ROOT="$APP_DIR/query-snapshots"
KEYCHAIN_SERVICE="${ADPUTATE_KEYCHAIN_SERVICE:-com.${CLI_NAME}.pihole.instance}"
DEFAULT_PIHOLE_UPSTREAMS="1.1.1.1;9.9.9.9"
CURL_BIN="${ADPUTATE_CURL_BIN:-/usr/bin/curl}"
SECURITY_BIN="${ADPUTATE_SECURITY_BIN:-/usr/bin/security}"
PLUTIL_BIN="${ADPUTATE_PLUTIL_BIN:-/usr/bin/plutil}"
SCUTIL_BIN="${ADPUTATE_SCUTIL_BIN:-/usr/sbin/scutil}"
NETWORKSETUP_BIN="${ADPUTATE_NETWORKSETUP_BIN:-/usr/sbin/networksetup}"
ROUTE_BIN="${ADPUTATE_ROUTE_BIN:-/sbin/route}"
DIG_BIN="${ADPUTATE_DIG_BIN:-/usr/bin/dig}"
SUDO_BIN="${ADPUTATE_SUDO_BIN:-/usr/bin/sudo}"
PBCOPY_BIN="${ADPUTATE_PBCOPY_BIN:-/usr/bin/pbcopy}"
OPEN_BIN="${ADPUTATE_OPEN_BIN:-/usr/bin/open}"
ISSUES_URL="${ADPUTATE_ISSUES_URL:-}"

usage() {
  cat <<'EOF'
Usage: __CLI_NAME__ <command>

Controller commands (work from any Mac with Adputate and its configuration):
  status      Show reachability and blocking state for every active instance.
  config show
              Show controller paths, defaults, and the legible instance inventory.
  instance list
  instance add <id> --api-url URL --dns ENDPOINT [options]
  instance remove <id>
              Manage explicit Pi-hole endpoints; credentials live in Keychain.
  discover    Inspect DNS servers advertised to this Mac and identify Pi-hole APIs.
  query <text> [--since DURATION]
              Snapshot every active instance, then grep the local files.
  query snapshot [--since DURATION]
              Save raw and readable query logs locally (default window: 1h).
  blocking status|enable|disable <DURATION|--until-enabled>
              Read or change blocking state on every active Pi-hole instance.
  bugreport [--open]
              Save and copy a sanitized diagnostic report; optionally open the issue form.
  install     Configure existing Pi-holes and optionally prepare a local Pi-hole host.
  client dns status|plan|apply --yes|restore --yes
              Manage this Mac's DNS using the active Pi-hole endpoints.
  uninstall --yes [--keep-images]
              Remove controller state, credentials, client DNS changes, and any hosted service.
  uninstall-audit
              Verify that no Adputate-managed runtime state remains.

Host commands (run on the always-on Mac Studio that hosts Adputate):
  host config|doctor|health|status|start|ensure|stop|restart|logs|admin|shell|smoke
  host configure [options]       Persist the container host configuration.
  host register [id]             Explicitly add this host as a replica endpoint.
  host reconcile --yes           Recreate a drifted container, preserving data.
  host blocking status|enable|disable [time]
  host password
  host service install|uninstall|enable|disable|kick|status|plist
  host router install|preflight|status|uninstall
  host teleporter export [directory]|import <zip>
  host upgrade <image> --yes|reset
  host uninstall --yes [--keep-images]|uninstall-audit
              Remove or audit only the Pi-hole hosted by this Mac.

Default endpoints (override with ADPUTATE_BIND_ADDRESS, ADPUTATE_WEB_PORT,
and ADPUTATE_DNS_PORT):
  Admin UI: http://127.0.0.1:8080/admin/
  DNS:      127.0.0.1#5053
EOF
}

render_usage() {
  usage | sed "s/__CLI_NAME__/$CLI_NAME/g"
}

bugreport() {
  local open_issue=0 argument timestamp report_dir report_file version os_version os_build architecture
  local container_version container_state instance_count=0 file role active auth transport
  for argument in "$@"; do
    case "$argument" in
      --open) open_issue=1 ;;
      *) die "Usage: $CLI_NAME bugreport [--open]" ;;
    esac
  done

  ensure_dirs
  timestamp="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
  report_dir="$APP_DIR/bugreports"
  report_file="$report_dir/${CLI_NAME}-bugreport-$timestamp.md"
  /bin/mkdir -p "$report_dir"
  /bin/chmod 700 "$report_dir"

  version="unknown"
  [[ ! -f "$VERSION_FILE" ]] || version="$(<"$VERSION_FILE")"
  os_version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || printf 'unknown')"
  os_build="$(/usr/bin/sw_vers -buildVersion 2>/dev/null || printf 'unknown')"
  architecture="$(/usr/bin/uname -m 2>/dev/null || printf 'unknown')"

  if have_container; then
    container_version="$("$CONTAINER_BIN" --version 2>&1 | /usr/bin/head -n 1 || printf 'unavailable')"
    if container_service_reachable; then
      container_state="service reachable"
    else
      container_state="installed; service unreachable"
    fi
  else
    container_version="not installed"
    container_state="not installed"
  fi

  for file in "$INSTANCES_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    instance_count=$((instance_count + 1))
  done

  {
    printf '# Adputate bug report\n\n'
    printf 'Review this report before posting it. It intentionally excludes passwords, Keychain data, '
    printf 'DNS queries, domain names, endpoint addresses, hostnames, usernames, and raw environment variables.\n\n'
    printf '## What I attempted\n\n<!-- Describe the action or command. -->\n\n'
    printf '## What happened\n\n<!-- Include the visible error or unexpected behavior. -->\n\n'
    printf '## What I expected\n\n<!-- Describe the expected result. -->\n\n'
    printf '## Sanitized diagnostics\n\n'
    printf -- '- Report time (UTC): %s\n' "$timestamp"
    printf -- '- Adputate version: %s\n' "$version"
    printf -- '- macOS version: %s (%s)\n' "$os_version" "$os_build"
    printf -- '- Architecture: %s\n' "$architecture"
    printf -- '- Apple Container: %s\n' "$container_version"
    printf -- '- Apple Container state: %s\n' "$container_state"
    printf -- '- Controller configured: %s\n' "$([[ -f "$CLUSTER_CONFIG_FILE" ]] && printf yes || printf no)"
    printf -- '- Configured Pi-hole instances: %s\n' "$instance_count"
    printf -- '- Local-host configuration: %s\n' "$([[ -f "$RUNTIME_CONFIG_FILE" ]] && printf present || printf absent)"
    printf -- '- User recovery service: %s\n' "$([[ -f "$(launchd_plist_path)" ]] && printf installed || printf absent)"
    printf -- '- Privileged DNS frontend: %s\n' "$([[ -f "$ROUTER_PLIST_PATH" ]] && printf installed || printf absent)"
    if (( instance_count > 0 )); then
      printf '\n## Instance configuration shape\n\n'
      instance_count=0
      for file in "$INSTANCES_DIR"/*.conf; do
        [[ -f "$file" ]] || continue
        instance_count=$((instance_count + 1))
        role="$(config_value "$file" ROLE)"
        active="$(config_value "$file" ACTIVE)"
        auth="$(config_value "$file" AUTH)"
        transport="$(config_value "$file" TRANSPORT)"
        printf -- '- Instance %s: role=%s, active=%s, auth=%s, transport=%s\n' \
          "$instance_count" "$role" "$active" "$auth" "$transport"
      done
    fi
  } >"$report_file"
  /bin/chmod 600 "$report_file"

  [[ -x "$PBCOPY_BIN" ]] || die "Bug report saved at $report_file, but clipboard tool is unavailable: $PBCOPY_BIN"
  "$PBCOPY_BIN" <"$report_file" || die "Bug report saved at $report_file, but copying it to the clipboard failed"

  printf 'Sanitized bug report copied to the clipboard.\n'
  printf 'Review saved copy: %s\n' "$report_file"
  if [[ -n "$ISSUES_URL" ]]; then
    printf 'Report an issue: %s\n' "$ISSUES_URL"
    printf 'Paste the report into the issue and complete the three description sections.\n'
  else
    printf 'Issue tracker: not configured yet. Keep the saved report for the project maintainer.\n'
  fi

  if (( open_issue == 1 )); then
    [[ -n "$ISSUES_URL" ]] || die "The report was copied, but ADPUTATE_ISSUES_URL is not configured"
    [[ -x "$OPEN_BIN" ]] || die "The report was copied, but the URL opener is unavailable: $OPEN_BIN"
    "$OPEN_BIN" "$ISSUES_URL"
  fi
}

die() {
  printf '%s: %s\n' "$CLI_NAME" "$*" >&2
  exit 1
}

have_container() {
  command -v "$CONTAINER_BIN" >/dev/null 2>&1
}

require_container() {
  have_container || die "Apple container CLI not found. Install or expose it as CONTAINER_BIN."
}

require_apple_silicon() {
  [[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon arm64 host required."
}

container_exists() {
  "$CONTAINER_BIN" list --all --quiet 2>/dev/null | grep -Fxq "$CONTAINER_NAME"
}

container_running() {
  "$CONTAINER_BIN" list --quiet 2>/dev/null | grep -Fxq "$CONTAINER_NAME"
}

container_service_reachable() {
  "$CONTAINER_BIN" list --all --quiet >/dev/null 2>&1
}

container_inspect_file() {
  local destination="$1"
  "$CONTAINER_BIN" inspect "$CONTAINER_NAME" >"$destination"
}

inspect_value() {
  local file="$1" key_path="$2"
  /usr/bin/plutil -extract "$key_path" raw -o - "$file" 2>/dev/null || true
}

container_drift_report() {
  container_exists || return 0
  local inspection actual expected drift=0
  inspection="$(mktemp "${TMPDIR:-/tmp}/adputate-inspect.XXXXXX")"
  if ! container_inspect_file "$inspection"; then
    rm -f "$inspection"
    printf 'Could not inspect %s.\n' "$CONTAINER_NAME"
    return 1
  fi

  while IFS='|' read -r key_path expected; do
    actual="$(inspect_value "$inspection" "$key_path")"
    if [[ "$actual" != "$expected" ]]; then
      printf '  %s: expected %s, found %s\n' "${key_path##*.}" "$expected" "${actual:-unset}"
      drift=1
    fi
  done <<EOF
0.configuration.labels.adputate_config_version|1
0.configuration.labels.adputate_bind_address|$HOST_BIND_ADDRESS
0.configuration.labels.adputate_web_port|$HOST_WEB_PORT
0.configuration.labels.adputate_dns_port|$HOST_DNS_PORT
0.configuration.labels.adputate_image|$IMAGE
0.configuration.labels.adputate_memory|$MEMORY
EOF

  rm -f "$inspection"
  (( drift == 0 ))
}

container_matches_config() {
  container_drift_report >/dev/null
}

require_container_matches_config() {
  if ! container_matches_config; then
    printf '%s configuration drift detected:\n' "$CONTAINER_NAME" >&2
    container_drift_report >&2 || true
    die "Run: $CLI_NAME host reconcile --yes"
  fi
}

container_current_image() {
  local inspection image
  inspection="$(mktemp "${TMPDIR:-/tmp}/adputate-inspect.XXXXXX")"
  container_inspect_file "$inspection" || { rm -f "$inspection"; return 1; }
  image="$(inspect_value "$inspection" '0.configuration.labels.adputate_image')"
  if [[ -z "$image" ]]; then
    image="$(inspect_value "$inspection" '0.configuration.image.reference')"
    image="${image#docker.io/}"
  fi
  rm -f "$inspection"
  printf '%s\n' "$image"
}

volume_exists() {
  "$CONTAINER_BIN" volume inspect "$1" >/dev/null 2>&1
}

image_exists() {
  "$CONTAINER_BIN" image inspect "$1" >/dev/null 2>&1
}

record_owned_image_if_missing() {
  local image="$1"
  image_exists "$image" && return 0
  ensure_dirs
  if [[ ! -f "$OWNED_IMAGES_FILE" ]] || ! grep -Fxq "$image" "$OWNED_IMAGES_FILE"; then
    printf '%s\n' "$image" >>"$OWNED_IMAGES_FILE"
    chmod 600 "$OWNED_IMAGES_FILE"
  fi
}

ensure_volumes() {
  require_container
  volume_exists "$ETC_PIHOLE_VOLUME" || "$CONTAINER_BIN" volume create "$ETC_PIHOLE_VOLUME" >/dev/null
  volume_exists "$ETC_DNSMASQ_VOLUME" || "$CONTAINER_BIN" volume create "$ETC_DNSMASQ_VOLUME" >/dev/null
}

ensure_dirs() {
  umask 077
  mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$TELEPORTER_DIR" \
    "$INSTANCES_DIR" "$QUERY_SNAPSHOT_ROOT"
}

safe_config_value() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

config_value() {
  local file="$1" key="$2"
  awk -F= -v wanted="$key" '
    $1 == wanted {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$file"
}

register_host_instance() {
  local instance_id="${1:-adputate}" dns_endpoint file
  valid_instance_id "$instance_id" || die "Host instance id must use lowercase letters, numbers, dashes, or underscores"
  ensure_dirs
  if [[ -f "$ROUTER_PLIST_PATH" ]]; then
    dns_endpoint="$HOST_BIND_ADDRESS#53"
  else
    dns_endpoint="$HOST_BIND_ADDRESS#$HOST_DNS_PORT"
  fi
  file="$INSTANCES_DIR/$instance_id.conf"
  if [[ -f "$file" && "$(config_value "$file" AUTH)" != "managed-local" ]]; then
    die "Refusing to overwrite non-host instance $instance_id; remove it explicitly first"
  fi
  {
    printf '# Explicitly registered local Adputate host. No password is stored here.\n'
    printf 'ID=%s\n' "$instance_id"
    printf 'NAME=%s on %s\n' "$APP_NAME" "$(hostname -s)"
    printf 'ROLE=replica\n'
    printf 'ACTIVE=true\n'
    printf 'API_URL=http://%s:%s\n' "$HOST_BIND_ADDRESS" "$HOST_WEB_PORT"
    printf 'DNS_ENDPOINT=%s\n' "$dns_endpoint"
    printf 'TRANSPORT=http\n'
    printf 'AUTH=managed-local\n'
  } >"$file"
  chmod 600 "$file"
  printf 'Registered this host as replica %s.\n' "$instance_id"
}

ensure_cluster_config() {
  ensure_dirs
  if [[ ! -f "$CLUSTER_CONFIG_FILE" ]]; then
    {
      printf '# Adputate cluster defaults. This file never contains passwords.\n'
      printf 'DEFAULT_QUERY_WINDOW=1h\n'
      printf 'QUERY_SNAPSHOT_ROOT=%s\n' "$QUERY_SNAPSHOT_ROOT"
    } >"$CLUSTER_CONFIG_FILE"
    chmod 600 "$CLUSTER_CONFIG_FILE"
  fi
}

instance_files() {
  local file
  ensure_cluster_config
  for file in "$INSTANCES_DIR"/*.conf; do
    [[ -f "$file" ]] && printf '%s\n' "$file"
  done | /usr/bin/sort
}

show_instances() {
  local file id name role active api_url dns_endpoint transport auth upstreams count=0 authority="not configured"
  ensure_cluster_config
  printf 'Cluster config:   %s\n' "$CLUSTER_CONFIG_FILE"
  printf 'Instance configs: %s\n' "$INSTANCES_DIR"
  printf 'Query snapshots:  %s\n' "$QUERY_SNAPSHOT_ROOT"
  printf 'Default window:   %s\n' "$(config_value "$CLUSTER_CONFIG_FILE" DEFAULT_QUERY_WINDOW)"
  if [[ -f "$ENV_FILE" ]]; then
    upstreams="$(awk -F= '$1 == "FTLCONF_dns_upstreams" {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE")"
    if [[ -n "$upstreams" ]]; then
      printf 'Local upstreams:  %s (currently fixed by Adputate)\n' "$upstreams"
    else
      printf 'Local upstreams:  not forced; Pi-hole configuration applies\n'
    fi
  fi
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    id="$(config_value "$file" ID)"
    name="$(config_value "$file" NAME)"
    role="$(config_value "$file" ROLE)"
    active="$(config_value "$file" ACTIVE)"
    api_url="$(config_value "$file" API_URL)"
    dns_endpoint="$(config_value "$file" DNS_ENDPOINT)"
    transport="$(config_value "$file" TRANSPORT)"
    auth="$(config_value "$file" AUTH)"
    [[ "$role" != "authority" ]] || authority="$id"
    printf '\nInstance: %s\n' "$id"
    printf '  Name:      %s\n' "$name"
    printf '  Role:      %s\n' "$role"
    printf '  Active:    %s\n' "$active"
    printf '  API:       %s\n' "$api_url"
    printf '  DNS:       %s\n' "$dns_endpoint"
    printf '  Transport: %s\n' "$transport"
    printf '  Auth:      %s\n' "$auth"
    count=$((count + 1))
  done < <(instance_files)
  printf '\nPolicy authority: %s\n' "$authority"
  if (( count == 0 )); then
    printf '\nNo Pi-hole instances configured. Use `%s discover`, then `%s instance add`.\n' "$CLI_NAME" "$CLI_NAME"
  elif (( count == 1 )); then
    printf '\nPeer Pi-hole: not configured. Add it with `%s instance add`.\n' "$CLI_NAME"
  fi
}

show_controller_config() {
  show_instances
}

discover_instances() {
  local candidate host api_url found=0
  [[ -x "$SCUTIL_BIN" ]] || die "Automatic discovery currently requires macOS scutil; use '$CLI_NAME instance add'"
  printf 'DNS servers advertised to this Mac:\n'
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    found=1
    host="$candidate"
    [[ "$candidate" != *:* ]] || host="[$candidate]"
    api_url="http://$host"
    if "$CURL_BIN" --silent --show-error --fail --max-time 2 "$api_url/api/info/version" >/dev/null 2>&1; then
      printf '  %s  Pi-hole detected (%s)\n' "$candidate" "$api_url"
    else
      printf '  %s  not a Pi-hole API\n' "$candidate"
    fi
  done < <("$SCUTIL_BIN" --dns | /usr/bin/awk '/nameserver\[[0-9]+\]/{print $3}' | /usr/bin/sort -u)
  (( found != 0 )) || printf '  none found\n'
  printf '\nDiscovery never changes configuration. Add a validated server explicitly with:\n'
  printf '  %s instance add <id> --role authority|replica --api-url <url> --dns <ip>\n' "$CLI_NAME"
}

cluster_status() {
  local file id name role active response state failed=0 count=0 work_dir
  ensure_cluster_config
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/adputate-status.XXXXXX")"
  chmod 700 "$work_dir"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    active="$(config_value "$file" ACTIVE)"
    [[ "$active" == "true" ]] || continue
    id="$(config_value "$file" ID)"
    name="$(config_value "$file" NAME)"
    role="$(config_value "$file" ROLE)"
    response="$work_dir/$id.json"
    count=$((count + 1))
    if instance_api_request "$file" GET dns/blocking "" "$response"; then
      state="$(blocking_state_from_file "$response")"
      printf '%s (%s)\n  Role: %s\n  API: reachable\n  Blocking: %s\n' "$name" "$id" "$role" "$state"
    else
      printf '%s (%s)\n  Role: %s\n  API: unreachable\n' "$name" "$id" "$role" >&2
      failed=1
    fi
  done < <(instance_files)
  rm -rf -- "$work_dir"
  (( count != 0 )) || { printf 'No active Pi-hole instances are configured.\n' >&2; return 1; }
  (( failed == 0 ))
}

valid_instance_id() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

valid_api_url() {
  local url="$1" authority
  [[ "$url" == http://* || "$url" == https://* ]] || return 1
  authority="${url#*://}"
  [[ -n "$authority" && "$authority" != *[[:space:]]* && "$authority" != *'@'* &&
     "$authority" != *'/'* && "$authority" != *'?'* && "$authority" != *'#'* ]]
}

valid_dns_endpoint() {
  local endpoint="$1" address port
  [[ "$endpoint" != *[[:space:]]* && "$endpoint" != *'#'*'#'* ]] || return 1
  address="${endpoint%%#*}"
  port="${endpoint##*#}"
  [[ "$endpoint" == *'#'* ]] || port=53
  [[ -n "$address" && "$port" =~ ^[0-9]+$ ]] || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

instance_add() {
  local id="${1:-}" name="" role="replica" active="true" api_url="" dns_endpoint=""
  local auth="keychain" password="" file value transport
  [[ -n "$id" ]] || die "Usage: $CLI_NAME instance add <id> --api-url URL --dns ENDPOINT [options]"
  shift
  valid_instance_id "$id" || die "Instance id must use lowercase letters, numbers, dashes, or underscores"
  while (( $# > 0 )); do
    case "$1" in
      --name) (( $# >= 2 )) || die "--name requires a value"; name="$2"; shift 2 ;;
      --role) (( $# >= 2 )) || die "--role requires a value"; role="$2"; shift 2 ;;
      --api-url) (( $# >= 2 )) || die "--api-url requires a value"; api_url="${2%/}"; shift 2 ;;
      --dns) (( $# >= 2 )) || die "--dns requires a value"; dns_endpoint="$2"; shift 2 ;;
      --inactive) active="false"; shift ;;
      --no-auth) auth="none"; shift ;;
      --password-stdin) IFS= read -r password; auth="keychain"; shift ;;
      --password-prompt)
        [[ -t 0 ]] || die "--password-prompt requires an interactive terminal"
        IFS= read -r -s -p "Pi-hole application password for $id: " password
        printf '\n'
        auth="keychain"
        shift
        ;;
      *) die "Unknown instance option: $1" ;;
    esac
  done
  name="${name:-$id}"
  for value in "$name" "$api_url" "$dns_endpoint"; do
    safe_config_value "$value" || die "Instance values may not contain newlines"
  done
  [[ "$role" == "authority" || "$role" == "replica" ]] || die "Role must be authority or replica"
  valid_api_url "$api_url" || die "API URL must be an http:// or https:// origin without credentials, path, query, or fragment"
  valid_dns_endpoint "$dns_endpoint" || die "DNS endpoint must look like an address or address#port"
  transport="${api_url%%:*}"
  ensure_cluster_config
  file="$INSTANCES_DIR/$id.conf"
  [[ ! -e "$file" ]] || die "Instance already exists: $id"
  if [[ "$role" == "authority" ]]; then
    local existing authority_id
    for existing in "$INSTANCES_DIR"/*.conf; do
      [[ -f "$existing" ]] || continue
      if [[ "$(config_value "$existing" ROLE)" == "authority" ]]; then
        authority_id="$(config_value "$existing" ID)"
        die "Policy authority is already $authority_id; remove or change it explicitly first"
      fi
    done
  fi
  if [[ "$auth" == "keychain" ]]; then
    [[ -n "$password" ]] || die "Use --password-stdin to store the Pi-hole application password securely"
    "$SECURITY_BIN" add-generic-password -U -a "$id" -s "$KEYCHAIN_SERVICE" -w "$password" >/dev/null
  fi
  {
    printf '# Non-secret Pi-hole instance metadata.\n'
    printf 'ID=%s\n' "$id"
    printf 'NAME=%s\n' "$name"
    printf 'ROLE=%s\n' "$role"
    printf 'ACTIVE=%s\n' "$active"
    printf 'API_URL=%s\n' "$api_url"
    printf 'DNS_ENDPOINT=%s\n' "$dns_endpoint"
    printf 'TRANSPORT=%s\n' "$transport"
    printf 'AUTH=%s\n' "$auth"
  } >"$file"
  chmod 600 "$file"
  printf 'Added Pi-hole instance %s.\n' "$id"
  show_instances
}

instance_remove() {
  local id="${1:-}" file
  [[ -n "$id" ]] || die "Usage: $CLI_NAME instance remove <id>"
  ensure_cluster_config
  file="$INSTANCES_DIR/$id.conf"
  [[ -f "$file" ]] || die "Unknown instance: $id"
  delete_instance_credential "$id" || \
    die "Could not remove the Keychain credential for $id; instance configuration was preserved"
  rm -f -- "$file"
  printf 'Removed Pi-hole instance %s and its Adputate-owned credential.\n' "$id"
}

delete_instance_credential() {
  local id="$1" status
  if "$SECURITY_BIN" delete-generic-password -a "$id" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
    return 0
  else
    status=$?
  fi
  # macOS security(1) returns errSecItemNotFound (44) when cleanup is already complete.
  (( status == 44 ))
}

duration_seconds() {
  local duration="$1" amount unit multiplier
  [[ "$duration" =~ ^([1-9][0-9]*)([smhd])$ ]] || return 1
  amount="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"
  case "$unit" in
    s) multiplier=1 ;;
    m) multiplier=60 ;;
    h) multiplier=3600 ;;
    d) multiplier=86400 ;;
  esac
  printf '%s\n' "$((10#$amount * multiplier))"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf '%s' "$value"
}

instance_password() {
  local file="$1" id auth
  id="$(config_value "$file" ID)"
  auth="$(config_value "$file" AUTH)"
  case "$auth" in
    managed-local)
      awk -F= '$1 == "FTLCONF_webserver_api_password" {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE"
      ;;
    keychain)
      "$SECURITY_BIN" find-generic-password -w -a "$id" -s "$KEYCHAIN_SERVICE"
      ;;
    none) return 0 ;;
    *) die "Unsupported authentication mode for $id: $auth" ;;
  esac
}

instance_api_request() {
  local file="$1" method="$2" endpoint="$3" payload="$4" output="$5"
  local id api_url password temporary auth_payload auth_response request_payload sid curl_config result=0
  id="$(config_value "$file" ID)"
  api_url="$(config_value "$file" API_URL)"
  password="$(instance_password "$file")" || return 1
  temporary="$(mktemp -d "${TMPDIR:-/tmp}/adputate-api.XXXXXX")"
  chmod 700 "$temporary"
  auth_payload="$temporary/auth.json"
  auth_response="$temporary/auth-response.json"
  request_payload="$temporary/request.json"
  curl_config="$temporary/curl.conf"
  if [[ -n "$password" ]]; then
    printf '{"password":"%s"}\n' "$(json_escape "$password")" >"$auth_payload"
    chmod 600 "$auth_payload"
    if ! "$CURL_BIN" --silent --show-error --fail-with-body --connect-timeout 5 --max-time 15 \
      --request POST --header 'Content-Type: application/json' --data-binary "@$auth_payload" \
      --output "$auth_response" "$api_url/api/auth"; then
      rm -rf -- "$temporary"
      return 1
    fi
    sid="$("$PLUTIL_BIN" -extract session.sid raw -o - "$auth_response" 2>/dev/null || true)"
    [[ -n "$sid" && ${#sid} -le 256 && "$sid" =~ ^[A-Za-z0-9+/=_-]+$ ]] || {
      printf 'Pi-hole %s returned an invalid session identifier.\n' "$id" >&2
      rm -rf -- "$temporary"
      return 1
    }
    printf 'header = "X-FTL-SID: %s"\n' "$sid" >"$curl_config"
    chmod 600 "$curl_config"
  else
    : >"$curl_config"
  fi
  if [[ -n "$payload" ]]; then
    printf '%s\n' "$payload" >"$request_payload"
    chmod 600 "$request_payload"
    "$CURL_BIN" --config "$curl_config" --silent --show-error --fail-with-body \
      --connect-timeout 5 --max-time 30 --request "$method" \
      --header 'Content-Type: application/json' --data-binary "@$request_payload" \
      --output "$output" "$api_url/api/$endpoint" || result=1
  else
    "$CURL_BIN" --config "$curl_config" --silent --show-error --fail-with-body \
      --connect-timeout 5 --max-time 30 --request "$method" \
      --output "$output" "$api_url/api/$endpoint" || result=1
  fi
  if [[ -n "${sid:-}" ]]; then
    "$CURL_BIN" --config "$curl_config" --silent --show-error --max-time 10 \
      --request DELETE "$api_url/api/auth" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$temporary"
  return "$result"
}

fetch_instance_queries() {
  local file="$1" from="$2" until="$3" output="$4"
  instance_api_request "$file" GET "queries?from=$from&until=$until&length=10000" "" "$output"
}

blocking_state_from_file() {
  "$PLUTIL_BIN" -extract blocking raw -o - "$1" 2>/dev/null
}

blocking_timer_from_file() {
  "$PLUTIL_BIN" -extract timer raw -o - "$1" 2>/dev/null || printf 'none'
}

cluster_blocking_status() {
  local file id name active response state timer failed=0
  ensure_cluster_config
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    id="$(config_value "$file" ID)"
    name="$(config_value "$file" NAME)"
    active="$(config_value "$file" ACTIVE)"
    [[ "$active" == "true" ]] || continue
    response="$(mktemp "${TMPDIR:-/tmp}/adputate-blocking.XXXXXX")"
    if instance_api_request "$file" GET dns/blocking "" "$response"; then
      state="$(blocking_state_from_file "$response")"
      timer="$(blocking_timer_from_file "$response")"
      printf '%s (%s): %s; timer=%s\n' "$name" "$id" "$state" "$timer"
    else
      printf '%s (%s): unavailable\n' "$name" "$id" >&2
      failed=1
    fi
    rm -f -- "$response"
  done < <(instance_files)
  return "$failed"
}

cluster_blocking_change() {
  local desired="$1" duration="${2:-}" payload expected timer_seconds=""
  local work_dir file id name active response state failed=0
  if [[ "$desired" == "false" ]]; then
    [[ -n "$duration" ]] || die "Usage: $CLI_NAME blocking disable <DURATION|--until-enabled>"
    if [[ "$duration" == "--until-enabled" ]]; then
      payload='{"blocking":false}'
    else
      timer_seconds="$(duration_seconds "$duration")" || die "Duration must look like 5m or 1h"
      payload="{\"blocking\":false,\"timer\":$timer_seconds}"
    fi
    expected="disabled"
  else
    payload='{"blocking":true}'
    expected="enabled"
  fi
  ensure_cluster_config
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/adputate-blocking.XXXXXX")"
  chmod 700 "$work_dir"
  # Preflight every active target before changing any node.
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    id="$(config_value "$file" ID)"
    name="$(config_value "$file" NAME)"
    active="$(config_value "$file" ACTIVE)"
    [[ "$active" == "true" ]] || continue
    if ! instance_api_request "$file" GET dns/blocking "" "$work_dir/$id-preflight.json"; then
      printf '%s (%s): preflight failed; no nodes were changed\n' "$name" "$id" >&2
      failed=1
    fi
  done < <(instance_files)
  if (( failed != 0 )); then
    rm -rf -- "$work_dir"
    return 1
  fi
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    id="$(config_value "$file" ID)"
    name="$(config_value "$file" NAME)"
    active="$(config_value "$file" ACTIVE)"
    [[ "$active" == "true" ]] || continue
    response="$work_dir/$id-change.json"
    if instance_api_request "$file" POST dns/blocking "$payload" "$response" && \
       instance_api_request "$file" GET dns/blocking "" "$work_dir/$id-verify.json"; then
      state="$(blocking_state_from_file "$work_dir/$id-verify.json")"
      if [[ "$state" == "$expected" || ( "$expected" == "enabled" && "$state" == "true" ) || \
            ( "$expected" == "disabled" && "$state" == "false" ) ]]; then
        printf '%s (%s): verified %s\n' "$name" "$id" "$expected"
      else
        printf '%s (%s): verification returned %s, expected %s\n' "$name" "$id" "$state" "$expected" >&2
        failed=1
      fi
    else
      printf '%s (%s): change or verification failed\n' "$name" "$id" >&2
      failed=1
    fi
  done < <(instance_files)
  rm -rf -- "$work_dir"
  (( failed == 0 )) || return 1
}

cluster_blocking() {
  local action="${1:-}"
  case "$action" in
    status) cluster_blocking_status ;;
    enable) cluster_blocking_change true ;;
    disable) cluster_blocking_change false "${2:-}" ;;
    *) die "Usage: $CLI_NAME blocking status|enable|disable <DURATION|--until-enabled>" ;;
  esac
}

query_window_from_args() {
  local default_window window
  ensure_cluster_config
  default_window="$(config_value "$CLUSTER_CONFIG_FILE" DEFAULT_QUERY_WINDOW)"
  window="$default_window"
  while (( $# > 0 )); do
    case "$1" in
      --since) (( $# >= 2 )) || die "--since requires a duration"; window="$2"; shift 2 ;;
      *) die "Unknown query option: $1" ;;
    esac
  done
  duration_seconds "$window" >/dev/null || die "Duration must look like 30m, 1h, or 1d"
  printf '%s\n' "$window"
}

collect_query_snapshot() {
  local window seconds until from stamp snapshot_dir metadata file id name active raw searchable
  local failed=0 collected=0
  window="$(query_window_from_args "$@")"
  seconds="$(duration_seconds "$window")"
  until="$(date +%s)"
  from="$((until - seconds))"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  snapshot_dir="$(mktemp -d "$QUERY_SNAPSHOT_ROOT/$stamp.XXXXXX")"
  chmod 700 "$snapshot_dir"
  metadata="$snapshot_dir/snapshot.conf"
  {
    printf '# Query-log snapshot metadata; raw logs remain in sibling JSON files.\n'
    printf 'WINDOW=%s\nFROM_EPOCH=%s\nUNTIL_EPOCH=%s\n' "$window" "$from" "$until"
  } >"$metadata"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    id="$(config_value "$file" ID)"
    name="$(config_value "$file" NAME)"
    active="$(config_value "$file" ACTIVE)"
    [[ "$active" == "true" ]] || { printf 'INSTANCE_%s=inactive\n' "$id" >>"$metadata"; continue; }
    raw="$snapshot_dir/$id.json"
    searchable="$snapshot_dir/$id.txt"
    printf 'Collecting %s (%s)...\n' "$name" "$id" >&2
    if fetch_instance_queries "$file" "$from" "$until" "$raw" && \
       "$PLUTIL_BIN" -p "$raw" >"$searchable" 2>/dev/null; then
      printf 'INSTANCE_%s=collected\n' "$id" >>"$metadata"
      collected=$((collected + 1))
    else
      printf 'INSTANCE_%s=failed\n' "$id" >>"$metadata"
      printf 'Could not collect query logs from %s (%s).\n' "$name" "$id" >&2
      rm -f -- "$raw" "$searchable"
      failed=1
    fi
  done < <(instance_files)
  chmod 600 "$metadata" "$snapshot_dir"/* 2>/dev/null || true
  (( collected > 0 )) || failed=1
  printf '%s\n' "$snapshot_dir"
  return "$failed"
}

query_logs() {
  local needle="${1:-}" snapshot_dir collection_failed=0 matched=0 file
  [[ -n "$needle" ]] || die "Usage: $CLI_NAME query <text> [--since DURATION]"
  shift
  if ! snapshot_dir="$(collect_query_snapshot "$@")"; then
    collection_failed=1
  fi
  printf 'Snapshot: %s\n' "$snapshot_dir"
  for file in "$snapshot_dir"/*.txt; do
    [[ -f "$file" ]] || continue
    if /usr/bin/grep -i -F -q -- "$needle" "$file"; then
      printf '\nMatches in %s:\n' "$(basename "$file" .txt)"
      /usr/bin/grep -n -i -F -m 20 -C 10 -- "$needle" "$file" || true
      matched=1
    fi
  done
  (( matched == 1 )) || printf 'No matching query-log entries in the %s window.\n' \
    "$(config_value "$snapshot_dir/snapshot.conf" WINDOW)"
  (( collection_failed == 0 )) || return 1
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_ipv4() {
  local address="$1" octet rest index
  [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  rest="$address"
  for index in 1 2 3 4; do
    octet="${rest%%.*}"
    (( 10#$octet <= 255 )) || return 1
    if [[ "$rest" == *.* ]]; then
      rest="${rest#*.}"
    fi
  done
}

valid_memory() {
  [[ "$1" =~ ^[1-9][0-9]*[KMG]$ ]]
}

image_is_pinned() {
  [[ "$1" == *":"* && "$1" != *":latest" ]]
}

detect_default_interface() {
  /sbin/route -n get default 2>/dev/null | awk '$1 == "interface:" {print $2; exit}'
}

write_runtime_config() {
  local bind_address="$1" web_port="$2" dns_port="$3" image="$4" memory="$5" router_interface="$6"
  local temporary
  ensure_dirs
  temporary="$(mktemp "$CONFIG_DIR/runtime.env.XXXXXX")"
  chmod 600 "$temporary"
  {
    printf '# Generated by %s configure.\n' "$CLI_NAME"
    printf 'ADPUTATE_CONFIG_BIND_ADDRESS=%q\n' "$bind_address"
    printf 'ADPUTATE_CONFIG_WEB_PORT=%q\n' "$web_port"
    printf 'ADPUTATE_CONFIG_DNS_PORT=%q\n' "$dns_port"
    printf 'ADPUTATE_CONFIG_IMAGE=%q\n' "$image"
    printf 'ADPUTATE_CONFIG_MEMORY=%q\n' "$memory"
    printf 'ADPUTATE_CONFIG_ROUTER_INTERFACE=%q\n' "$router_interface"
  } >"$temporary"
  mv "$temporary" "$RUNTIME_CONFIG_FILE"
}

ensure_runtime_config() {
  [[ -f "$RUNTIME_CONFIG_FILE" ]] || write_runtime_config \
    "$HOST_BIND_ADDRESS" "$HOST_WEB_PORT" "$HOST_DNS_PORT" "$IMAGE" "$MEMORY" "$ROUTER_INTERFACE"
}

show_host_config() {
  printf 'Runtime config: %s\n' "$RUNTIME_CONFIG_FILE"
  printf 'Bind address:  %s\n' "$HOST_BIND_ADDRESS"
  printf 'Web port:      %s\n' "$HOST_WEB_PORT"
  printf 'DNS backend:   %s\n' "$HOST_DNS_PORT"
  printf 'Image:         %s\n' "$IMAGE"
  printf 'Memory:        %s\n' "$MEMORY"
  printf 'LAN interface: %s\n' "${ROUTER_INTERFACE:-not configured}"
  if [[ -f "$ROUTER_PLIST_PATH" ]]; then
    printf 'Port 53:       installed\n'
  else
    printf 'Port 53:       not installed\n'
  fi
}

configure_runtime() {
  local bind_address="$HOST_BIND_ADDRESS" web_port="$HOST_WEB_PORT" dns_port="$HOST_DNS_PORT"
  local image="$IMAGE" memory="$MEMORY" router_interface="$ROUTER_INTERFACE"

  while (( $# > 0 )); do
    case "$1" in
      --bind-address) (( $# >= 2 )) || die "--bind-address requires a value"; bind_address="$2"; shift 2 ;;
      --web-port) (( $# >= 2 )) || die "--web-port requires a value"; web_port="$2"; shift 2 ;;
      --dns-port) (( $# >= 2 )) || die "--dns-port requires a value"; dns_port="$2"; shift 2 ;;
      --image) (( $# >= 2 )) || die "--image requires a value"; image="$2"; shift 2 ;;
      --memory) (( $# >= 2 )) || die "--memory requires a value"; memory="$2"; shift 2 ;;
      --router-interface) (( $# >= 2 )) || die "--router-interface requires a value"; router_interface="$2"; shift 2 ;;
      --show) show_host_config; return ;;
      *) die "Unknown configure option: $1" ;;
    esac
  done

  valid_ipv4 "$bind_address" || die "Invalid IPv4 bind address: $bind_address"
  valid_port "$web_port" || die "Invalid web port: $web_port"
  (( 10#$web_port >= 1024 )) || die "The Pi-hole web backend must use an unprivileged port (1024 or higher)"
  valid_port "$dns_port" || die "Invalid DNS port: $dns_port"
  (( 10#$dns_port >= 1024 )) || die "The Pi-hole backend must use an unprivileged port (1024 or higher)"
  [[ "$web_port" != "$dns_port" ]] || die "Web and DNS backend ports must be different"
  image_is_pinned "$image" || die "Image must use a pinned tag, not latest: $image"
  [[ "$image" != *[[:space:]]* ]] || die "Image reference may not contain whitespace"
  valid_memory "$memory" || die "Memory must look like 256M or 1G: $memory"

  if [[ "$bind_address" != "127.0.0.1" ]]; then
    [[ -n "$router_interface" ]] || router_interface="$(detect_default_interface)"
    [[ -n "$router_interface" ]] || die "Could not detect the default LAN interface; pass --router-interface"
    [[ "$router_interface" =~ ^[a-zA-Z0-9]+$ ]] || die "Invalid router interface: $router_interface"
    /sbin/ifconfig "$router_interface" 2>/dev/null | grep -Fq "inet $bind_address " || \
      die "$bind_address is not assigned to interface $router_interface"
  fi

  write_runtime_config "$bind_address" "$web_port" "$dns_port" "$image" "$memory" "$router_interface"
  printf 'Saved runtime configuration.\n'
  ADPUTATE_CONFIG_BIND_ADDRESS="$bind_address"
  ADPUTATE_CONFIG_WEB_PORT="$web_port"
  ADPUTATE_CONFIG_DNS_PORT="$dns_port"
  ADPUTATE_CONFIG_IMAGE="$image"
  ADPUTATE_CONFIG_MEMORY="$memory"
  ADPUTATE_CONFIG_ROUTER_INTERFACE="$router_interface"
  HOST_BIND_ADDRESS="$bind_address"
  HOST_WEB_PORT="$web_port"
  HOST_DNS_PORT="$dns_port"
  IMAGE="$image"
  MEMORY="$memory"
  ROUTER_INTERFACE="$router_interface"
  show_host_config
}

generate_password() {
  /usr/bin/openssl rand -base64 24 | tr -d '\n'
}

detect_timezone() {
  local zone
  zone="$(/bin/ls -l /etc/localtime 2>/dev/null | sed 's#.*zoneinfo/##')"
  if [[ -n "$zone" && "$zone" != *" "* && "$zone" != /etc/localtime* ]]; then
    printf '%s' "$zone"
  else
    printf 'UTC'
  fi
}

init_config() {
  ensure_dirs
  ensure_runtime_config
  if [[ ! -f "$ENV_FILE" ]]; then
    local password
    password="$(generate_password)"
    cat >"$ENV_FILE" <<EOF
TZ=$(detect_timezone)
FTLCONF_webserver_api_password=$password
FTLCONF_dns_listeningMode=ALL
FTLCONF_dns_upstreams=$DEFAULT_PIHOLE_UPSTREAMS
EOF
    chmod 600 "$ENV_FILE"
  elif grep -q '^TZ=$' "$ENV_FILE"; then
    sed -i '' "s#^TZ=.*#TZ=$(detect_timezone)#" "$ENV_FILE"
  fi
}

warp_connected() {
  local status="${ADPUTATE_WARP_STATUS:-}" warp_cli="${ADPUTATE_WARP_CLI:-}"

  if [[ -z "$status" ]]; then
    if [[ -z "$warp_cli" ]]; then
      if command -v warp-cli >/dev/null 2>&1; then
        warp_cli="$(command -v warp-cli)"
      elif [[ -x "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli" ]]; then
        warp_cli="/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli"
      else
        return 1
      fi
    fi
    status="$("$warp_cli" status 2>/dev/null)" || return 1
  fi

  printf '%s\n' "$status" | grep -Eq '^Status( update)?: Connected[[:space:]]*$'
}

private_relay_enabled() {
  local status="${ADPUTATE_PRIVATE_RELAY_STATUS:-}"

  if [[ -z "$status" ]]; then
    status="$(
      defaults export com.apple.networkserviceproxy - 2>/dev/null |
        plutil -extract NSPServiceStatusManagerInfo raw -o - - 2>/dev/null |
        base64 -D 2>/dev/null |
        plutil -p - 2>/dev/null |
        awk '/"PrivacyProxyServiceStatus" =>/ { print $3; exit }'
    )" || return 1
  fi

  [[ "$status" == "1" || "$status" == "true" || "$status" == "enabled" ]]
}

privacy_preflight() {
  local blocked=0

  if warp_connected; then
    printf 'Cloudflare WARP is connected and is controlling this Mac\047s DNS path.\n' >&2
    printf 'Turn WARP off, then rerun this command. Adputate will not change WARP settings.\n' >&2
    blocked=1
  fi
  if private_relay_enabled; then
    printf 'iCloud Private Relay is enabled and can bypass network DNS filtering.\n' >&2
    printf 'Turn off Private Relay (or Limit IP Address Tracking for this network), then rerun this command.\n' >&2
    printf 'Adputate will not change iCloud settings.\n' >&2
    blocked=1
  fi

  (( blocked == 0 ))
}

CHECK_PASS_COUNT=0
CHECK_WARN_COUNT=0
CHECK_FAIL_COUNT=0

reset_checks() {
  CHECK_PASS_COUNT=0
  CHECK_WARN_COUNT=0
  CHECK_FAIL_COUNT=0
}

check_pass() {
  CHECK_PASS_COUNT=$((CHECK_PASS_COUNT + 1))
  printf '[PASS] %s\n' "$*"
}

check_warn() {
  CHECK_WARN_COUNT=$((CHECK_WARN_COUNT + 1))
  printf '[WARN] %s\n' "$*"
}

check_fail() {
  CHECK_FAIL_COUNT=$((CHECK_FAIL_COUNT + 1))
  printf '[FAIL] %s\n' "$*"
}

check_summary() {
  printf '\nSummary: %s passed, %s warnings, %s failed\n' \
    "$CHECK_PASS_COUNT" "$CHECK_WARN_COUNT" "$CHECK_FAIL_COUNT"
  (( CHECK_FAIL_COUNT == 0 ))
}

port_listener_summary() {
  local protocol="$1"
  local port="$2"
  if [[ "$protocol" == "TCP" ]]; then
    /usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $1 " (pid " $2 ")"; exit}'
  else
    /usr/sbin/lsof -nP -iUDP:"$port" 2>/dev/null | awk 'NR > 1 {print $1 " (pid " $2 ")"; exit}'
  fi
}

check_port_available() {
  local label="$1"
  local protocol="$2"
  local port="$3"
  local listener
  listener="$(port_listener_summary "$protocol" "$port" || true)"
  if [[ -n "$listener" ]]; then
    check_fail "$label port $port/$protocol is already used by $listener"
  else
    check_pass "$label port $port/$protocol is available"
  fi
}

doctor() {
  reset_checks

  local arch macos_version macos_major container_version container_major state_parent plist_path installed_bin
  arch="$(uname -m)"
  if [[ "$arch" == "arm64" ]]; then
    check_pass "Host architecture is arm64"
  else
    check_fail "Host architecture is $arch; Apple Silicon arm64 is required"
  fi

  macos_version="$(sw_vers -productVersion 2>/dev/null || true)"
  macos_major="${macos_version%%.*}"
  if [[ "$macos_major" =~ ^[0-9]+$ ]] && (( macos_major >= 26 )); then
    check_pass "macOS $macos_version is supported"
  else
    check_fail "macOS ${macos_version:-unknown} is unsupported; macOS 26 or newer is required"
  fi

  if command -v "$CONTAINER_BIN" >/dev/null 2>&1; then
    container_version="$("$CONTAINER_BIN" --version 2>/dev/null || true)"
    container_major="$(printf '%s\n' "$container_version" | sed -nE 's/.*version ([0-9]+).*/\1/p')"
    if [[ "$container_major" =~ ^[0-9]+$ ]] && (( container_major >= 1 )); then
      check_pass "$container_version"
    else
      check_warn "Apple container version could not be confirmed as 1.x: ${container_version:-unknown}"
    fi
    if container_service_reachable; then
      check_pass "Apple container service is reachable"
    else
      check_fail "Apple container service is not reachable"
    fi
  else
    check_fail "Apple container CLI not found at $CONTAINER_BIN"
  fi

  local required_command
  for required_command in /usr/bin/curl /usr/bin/dig /usr/bin/openssl /usr/bin/plutil /usr/bin/sudo /bin/launchctl /usr/sbin/lsof /usr/sbin/networksetup /sbin/ifconfig /sbin/route; do
    if [[ -x "$required_command" ]]; then
      check_pass "Required command exists: $required_command"
    else
      check_fail "Required command is missing: $required_command"
    fi
  done
  if [[ -x "$PROJECT_ROOT/build/adputate-dns-proxy" ]]; then
    check_pass "Prebuilt native DNS frontend is installed"
  else
    check_fail "Native DNS frontend is missing; run: make build"
  fi

  if [[ -f "$PROJECT_ROOT/project.env" ]]; then
    check_pass "Project configuration found"
  else
    check_warn "Project configuration is missing; built-in defaults will be used"
  fi

  if [[ -f "$RUNTIME_CONFIG_FILE" ]]; then
    check_pass "Persistent runtime configuration found"
  else
    check_warn "Persistent runtime configuration is not initialized; run: $CLI_NAME host configure"
  fi

  if [[ "$HOST_WEB_PORT" =~ ^[0-9]+$ ]] && (( HOST_WEB_PORT >= 1 && HOST_WEB_PORT <= 65535 )); then
    check_pass "Web port $HOST_WEB_PORT is valid"
  else
    check_fail "Web port is invalid: $HOST_WEB_PORT"
  fi
  if [[ "$HOST_DNS_PORT" =~ ^[0-9]+$ ]] && (( HOST_DNS_PORT >= 1 && HOST_DNS_PORT <= 65535 )); then
    check_pass "DNS port $HOST_DNS_PORT is valid"
    if (( HOST_DNS_PORT < 1024 && EUID != 0 )); then
      check_fail "Apple container requires root privileges to publish DNS on host port $HOST_DNS_PORT"
    fi
  else
    check_fail "DNS port is invalid: $HOST_DNS_PORT"
  fi

  if [[ "$HOST_BIND_ADDRESS" == "127.0.0.1" ]]; then
    check_pass "Bind address is local-only: $HOST_BIND_ADDRESS"
    if [[ "$HOST_DNS_PORT" == "53" ]]; then
      check_warn "Direct loopback publishing on port 53 collided with Apple container DNS on this host during testing"
    fi
  elif [[ "$HOST_BIND_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && /sbin/ifconfig | grep -Fq "inet $HOST_BIND_ADDRESS "; then
    check_pass "Bind address belongs to this Mac: $HOST_BIND_ADDRESS"
  else
    check_fail "Bind address is not an active IPv4 address on this Mac: $HOST_BIND_ADDRESS"
  fi

  if [[ "$IMAGE" == *":latest" || "$IMAGE" != *":"* ]]; then
    check_warn "Pi-hole image is not pinned to a release: $IMAGE"
  else
    check_pass "Pi-hole image is pinned: $IMAGE"
  fi

  state_parent="$(dirname -- "$APP_DIR")"
  if [[ -d "$APP_DIR" && -w "$APP_DIR" ]]; then
    check_pass "Application data directory is writable"
  elif [[ ! -e "$APP_DIR" && -d "$state_parent" && -w "$state_parent" ]]; then
    check_pass "Application data directory can be created"
  else
    check_fail "Application data path is not writable: $APP_DIR"
  fi

  if container_running; then
    check_pass "$CONTAINER_NAME is running; host port availability checks are skipped"
    if container_matches_config; then
      check_pass "$CONTAINER_NAME matches persistent runtime configuration"
    else
      check_fail "$CONTAINER_NAME configuration has drifted; run: $CLI_NAME host reconcile --yes"
    fi
  else
    check_port_available "Admin HTTP" TCP "$HOST_WEB_PORT"
    check_port_available "DNS" TCP "$HOST_DNS_PORT"
    check_port_available "DNS" UDP "$HOST_DNS_PORT"
  fi

  if [[ -f "$ROUTER_PLIST_PATH" ]]; then
    check_pass "Router-facing port-53 LaunchDaemon is installed"
    local router_bind router_backend router_port
    router_bind="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$ROUTER_PLIST_PATH" 2>/dev/null || true)"
    router_backend="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$ROUTER_PLIST_PATH" 2>/dev/null || true)"
    router_port="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:3' "$ROUTER_PLIST_PATH" 2>/dev/null || true)"
    if [[ "$router_bind" == "$HOST_BIND_ADDRESS" && "$router_backend" == "$HOST_BIND_ADDRESS" && "$router_port" == "$HOST_DNS_PORT" ]]; then
      check_pass "Router frontend matches persistent runtime configuration"
    else
      check_fail "Router frontend configuration has drifted; run: $CLI_NAME host router install"
    fi
  elif [[ "$HOST_BIND_ADDRESS" != "127.0.0.1" ]]; then
    check_warn "Router-facing port-53 frontend is not installed"
  fi

  if [[ -f "$DNS_BACKUP_FILE" ]]; then
    check_warn "A macOS DNS restore point is active; restore with: $CLI_NAME client dns restore --yes"
  fi

  if warp_connected; then
    check_warn "Cloudflare WARP is connected and overrides this Mac's normal DNS path"
  else
    check_pass "Cloudflare WARP is not connected"
  fi
  if private_relay_enabled; then
    check_warn "iCloud Private Relay is enabled and can bypass network DNS filtering"
  else
    check_pass "iCloud Private Relay is not enabled"
  fi

  plist_path="$(launchd_plist_path)"
  if [[ -f "$plist_path" ]]; then
    installed_bin="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist_path" 2>/dev/null || true)"
    if [[ "$installed_bin" == "$CLI_LAUNCHER" ]]; then
      check_pass "LaunchAgent points to the current Adputate launcher"
    else
      check_warn "LaunchAgent points to ${installed_bin:-an unreadable path}; run: $CLI_NAME host service install"
    fi
  else
    check_warn "LaunchAgent is not installed"
  fi

  check_summary
}

health() {
  reset_checks
  require_container

  if ! container_service_reachable; then
    check_fail "Apple container service is not reachable; run: container system start"
    check_summary
    return
  fi
  if ! container_exists; then
    check_fail "$CONTAINER_NAME does not exist; run: $CLI_NAME host start"
    check_summary
    return
  fi
  if ! container_running; then
    check_fail "$CONTAINER_NAME exists but is stopped; run: $CLI_NAME host start"
    check_summary
    return
  fi
  check_pass "$CONTAINER_NAME is running"

  if "$CONTAINER_BIN" exec "$CONTAINER_NAME" pihole api dns/blocking >/dev/null 2>&1; then
    check_pass "Pi-hole FTL API responds inside the container"
  else
    check_fail "Pi-hole FTL API did not respond inside the container"
  fi

  if "$CURL_BIN" --noproxy '*' --silent --show-error --fail --max-time 5 "http://$HOST_BIND_ADDRESS:$HOST_WEB_PORT/admin/" >/dev/null 2>&1; then
    check_pass "Admin HTTP endpoint responds at $HOST_BIND_ADDRESS:$HOST_WEB_PORT"
  else
    check_fail "Admin HTTP endpoint did not respond at $HOST_BIND_ADDRESS:$HOST_WEB_PORT"
  fi

  if dns_query_works udp "$HOST_DNS_PORT"; then
    check_pass "DNS responds over UDP at $HOST_BIND_ADDRESS:$HOST_DNS_PORT"
  else
    check_fail "DNS did not respond over UDP at $HOST_BIND_ADDRESS:$HOST_DNS_PORT"
  fi

  if dns_query_works tcp "$HOST_DNS_PORT"; then
    check_pass "DNS responds over TCP at $HOST_BIND_ADDRESS:$HOST_DNS_PORT"
  else
    check_fail "DNS did not respond over TCP at $HOST_BIND_ADDRESS:$HOST_DNS_PORT"
  fi

  if [[ -f "$ROUTER_PLIST_PATH" ]]; then
    if dns_query_works udp 53; then
      check_pass "Router-facing DNS responds over UDP at $HOST_BIND_ADDRESS:53"
    else
      check_fail "Router-facing DNS did not respond over UDP at $HOST_BIND_ADDRESS:53"
    fi
    if dns_query_works tcp 53; then
      check_pass "Router-facing DNS responds over TCP at $HOST_BIND_ADDRESS:53"
    else
      check_fail "Router-facing DNS did not respond over TCP at $HOST_BIND_ADDRESS:53"
    fi
  else
    check_warn "Router-facing port-53 frontend is not installed"
  fi

  check_summary
}

router_helper() {
  printf '%s/packaging/router/adputate-router' "$PROJECT_ROOT"
}

require_router_config() {
  local helper
  helper="$(router_helper)"
  [[ -x "$helper" ]] || die "Router helper not found or not executable: $helper"
  [[ "$HOST_BIND_ADDRESS" != "127.0.0.1" ]] || die "Configure an active LAN bind address first"
  valid_port "$HOST_DNS_PORT" && (( 10#$HOST_DNS_PORT >= 1024 )) || \
    die "Configure an unprivileged DNS backend port first"
  [[ -n "$ROUTER_INTERFACE" ]] || die "Configure a LAN interface first"
}

router_preflight() {
  local helper
  privacy_preflight || die "DNS privacy preflight failed"
  require_router_config
  helper="$(router_helper)"
  /usr/bin/sudo "$helper" preflight "$HOST_BIND_ADDRESS" "$HOST_DNS_PORT" "$ROUTER_INTERFACE" "$ROUTER_SERVICE_LABEL"
}

router_install() {
  local helper
  privacy_preflight || die "DNS privacy preflight failed"
  require_router_config
  helper="$(router_helper)"
  backend_ready || die "Pi-hole backend is not healthy; run: $CLI_NAME host health"
  printf 'Installing a root LaunchDaemon for the native port-53 frontend.\n'
  /usr/bin/sudo "$helper" install "$HOST_BIND_ADDRESS" "$HOST_DNS_PORT" "$ROUTER_INTERFACE" "$ROUTER_SERVICE_LABEL"
  if ! router_status; then
    printf 'Post-install DNS probes failed; removing the failed frontend.\n' >&2
    /usr/bin/sudo "$helper" uninstall "" "" "" "$ROUTER_SERVICE_LABEL" || true
    die "Router frontend installation was rolled back"
  fi
}

router_status() {
  reset_checks
  if [[ -f "$ROUTER_PLIST_PATH" ]]; then
    check_pass "Router LaunchDaemon is installed"
  else
    check_fail "Router LaunchDaemon is not installed"
  fi
  if /bin/launchctl print "system/$ROUTER_SERVICE_LABEL" >/dev/null 2>&1; then
    check_pass "Router LaunchDaemon is loaded"
  else
    check_fail "Router LaunchDaemon is not loaded"
  fi
  if dns_query_works udp 53; then
    check_pass "Router-facing DNS responds over UDP at $HOST_BIND_ADDRESS:53"
  else
    check_fail "Router-facing DNS did not respond over UDP at $HOST_BIND_ADDRESS:53"
  fi
  if dns_query_works tcp 53; then
    check_pass "Router-facing DNS responds over TCP at $HOST_BIND_ADDRESS:53"
  else
    check_fail "Router-facing DNS did not respond over TCP at $HOST_BIND_ADDRESS:53"
  fi
  check_summary
}

router_uninstall() {
  local helper
  helper="$(router_helper)"
  [[ -x "$helper" ]] || die "Router helper not found or not executable: $helper"
  /usr/bin/sudo "$helper" uninstall "" "" "" "$ROUTER_SERVICE_LABEL"
}

client_dns_default_service() {
  local device
  device="$("$ROUTE_BIN" -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}')"
  [[ -n "$device" ]] || die "Could not determine the default-route interface"
  "$NETWORKSETUP_BIN" -listnetworkserviceorder | /usr/bin/awk -v device="$device" '
    /^\([0-9]+\) / {
      service=$0
      sub(/^\([0-9]+\) /, "", service)
    }
    index($0, "Device: " device ")") { print service; exit }
  '
}

client_dns_targets() {
  local desired_role file role active endpoint address port
  for desired_role in authority replica; do
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      role="$(config_value "$file" ROLE)"
      active="$(config_value "$file" ACTIVE)"
      [[ "$role" == "$desired_role" && "$active" == "true" ]] || continue
      endpoint="$(config_value "$file" DNS_ENDPOINT)"
      address="${endpoint%%#*}"
      port="${endpoint##*#}"
      [[ "$endpoint" == *'#'* ]] || port=53
      [[ "$port" == "53" ]] || die "Instance $(config_value "$file" ID) is not available on standard DNS port 53"
      [[ -n "$address" ]] || die "Instance $(config_value "$file" ID) has no DNS address"
      printf '%s\n' "$address"
    done < <(instance_files)
  done
}

client_dns_service_from_args() {
  local service="" option
  while (( $# > 0 )); do
    option="$1"
    case "$option" in
      --service) (( $# >= 2 )) || die "--service requires a network service name"; service="$2"; shift 2 ;;
      --yes) shift ;;
      *) die "Unknown client DNS option: $option" ;;
    esac
  done
  if [[ -z "$service" ]]; then
    service="$(client_dns_default_service)"
    [[ -n "$service" ]] || die "Could not map the default route to a macOS network service"
  fi
  printf '%s\n' "$service"
}

client_dns_plan() {
  local service current target count=0
  service="$(client_dns_service_from_args "$@")"
  current="$("$NETWORKSETUP_BIN" -getdnsservers "$service" 2>&1)" || die "$current"
  printf 'Local client DNS plan\n'
  printf '  Network service: %s\n' "$service"
  printf '  Current DNS:\n'
  while IFS= read -r target; do printf '    %s\n' "$target"; done <<<"$current"
  printf '  Pi-hole DNS:\n'
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    printf '    %s\n' "$target"
    count=$((count + 1))
  done < <(client_dns_targets)
  (( count != 0 )) || die "No active Pi-hole DNS endpoints are configured"
  if [[ -f "$DNS_BACKUP_FILE" ]]; then
    printf '  Restore point: active at %s\n' "$DNS_BACKUP_FILE"
  else
    printf '  Restore point: none\n'
  fi
  printf '\nOnly the selected network service will change. VPN and other interfaces are untouched.\n'
}

restore_dns_backup() {
  [[ -f "$DNS_BACKUP_FILE" ]] || die "No saved DNS configuration exists"
  # shellcheck disable=SC1090
  source "$DNS_BACKUP_FILE"
  [[ -n "${DNS_SERVICE:-}" ]] || die "Saved DNS configuration is invalid"
  declare -p DNS_PREVIOUS >/dev/null 2>&1 || die "Saved DNS configuration is invalid"
  if (( ${#DNS_PREVIOUS[@]} == 0 )); then
    "$SUDO_BIN" "$NETWORKSETUP_BIN" -setdnsservers "$DNS_SERVICE" empty
  else
    "$SUDO_BIN" "$NETWORKSETUP_BIN" -setdnsservers "$DNS_SERVICE" "${DNS_PREVIOUS[@]}"
  fi
}

client_dns_apply() {
  local network_service current line temporary target confirmed=false target_count=0
  local -a previous_dns=() targets=()
  for line in "$@"; do [[ "$line" != "--yes" ]] || confirmed=true; done
  [[ "$confirmed" == "true" ]] || die "Review '$CLI_NAME client dns plan', then rerun apply with --yes"
  privacy_preflight || die "DNS privacy preflight failed"
  network_service="$(client_dns_service_from_args "$@")"
  [[ ! -f "$DNS_BACKUP_FILE" ]] || die "A client DNS restore point is already active; run: $CLI_NAME client dns restore --yes"
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    targets[target_count]="$target"
    target_count=$((target_count + 1))
  done < <(client_dns_targets)
  (( target_count != 0 )) || die "No active Pi-hole DNS endpoints are configured"
  for target in "${targets[@]}"; do
    "$DIG_BIN" +short +time=2 +tries=1 "@$target" example.com A >/dev/null || die "DNS preflight failed over UDP for $target"
    "$DIG_BIN" +tcp +short +time=2 +tries=1 "@$target" example.com A >/dev/null || die "DNS preflight failed over TCP for $target"
  done

  current="$("$NETWORKSETUP_BIN" -getdnsservers "$network_service" 2>&1)" || die "$current"
  if [[ "$current" != "There aren't any DNS Servers set on $network_service." ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && previous_dns[${#previous_dns[@]}]="$line"
    done <<<"$current"
  fi

  ensure_dirs
  temporary="$(mktemp "$CONFIG_DIR/dns-backup.env.XXXXXX")"
  chmod 600 "$temporary"
  {
    printf 'DNS_SERVICE=%q\n' "$network_service"
    printf 'DNS_PREVIOUS=('
    for line in "${previous_dns[@]}"; do
      printf '%q ' "$line"
    done
    printf ')\n'
  } >"$temporary"
  mv "$temporary" "$DNS_BACKUP_FILE"

  if ! "$SUDO_BIN" "$NETWORKSETUP_BIN" -setdnsservers "$network_service" "${targets[@]}"; then
    restore_dns_backup || true
    die "Could not set DNS; the previous configuration was restored"
  fi
  for target in "${targets[@]}"; do
    if ! "$NETWORKSETUP_BIN" -getdnsservers "$network_service" | grep -Fxq "$target"; then
      restore_dns_backup || true
      die "DNS verification failed for $target; the previous configuration was restored"
    fi
  done
  printf 'Applied %s Pi-hole DNS endpoints to %s. Restore with: %s client dns restore --yes\n' \
    "$target_count" "$network_service" "$CLI_NAME"
}

client_dns_restore() {
  [[ "${1:-}" == "--yes" ]] || die "Refusing to change DNS without --yes"
  restore_dns_backup
  rm -f "$DNS_BACKUP_FILE"
  printf 'Restored the previous DNS configuration.\n'
}

client_dns_status() {
  local current_default managed_service
  current_default="$(client_dns_default_service)"
  if [[ -f "$DNS_BACKUP_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$DNS_BACKUP_FILE"
    managed_service="${DNS_SERVICE:-}"
    [[ -n "$managed_service" ]] || die "Saved DNS configuration is invalid"
    client_dns_plan --service "$managed_service"
    if [[ "$current_default" != "$managed_service" ]]; then
      printf '\nNetwork change detected: default-route service is now %s; managed DNS remains on %s.\n' \
        "$current_default" "$managed_service" >&2
      printf 'Restore the old service before applying DNS to the new network.\n' >&2
      return 1
    fi
  else
    client_dns_plan "$@"
  fi
}

smoke() {
  require_apple_silicon
  require_container
  start_container_system
  printf 'Checking Docker registry DNS...\n'
  if ! "$CURL_BIN" -sSI --connect-timeout 10 https://registry-1.docker.io/v2/ >/dev/null; then
    die "Cannot reach registry-1.docker.io. Container image pulls will fail until host DNS/network access is fixed."
  fi
  printf 'Running tiny ARM container...\n'
  record_owned_image_if_missing "$SMOKE_IMAGE"
  "$CONTAINER_BIN" run --rm --platform linux/arm64 "$SMOKE_IMAGE" uname -m
}

start_container_system() {
  container_service_reachable && return
  "$CONTAINER_BIN" system start >/dev/null
  container_service_reachable || die "Apple container service did not become reachable"
  ensure_dirs
  : >"$CONTAINER_SYSTEM_MARKER"
  chmod 600 "$CONTAINER_SYSTEM_MARKER"
}

create_pihole() {
  record_owned_image_if_missing "$IMAGE"
  "$CONTAINER_BIN" run \
    --detach \
    --name "$CONTAINER_NAME" \
    --platform linux/arm64 \
    --cpus 1 \
    --memory "$MEMORY" \
    --label adputate_config_version=1 \
    --label "adputate_bind_address=$HOST_BIND_ADDRESS" \
    --label "adputate_web_port=$HOST_WEB_PORT" \
    --label "adputate_dns_port=$HOST_DNS_PORT" \
    --label "adputate_image=$IMAGE" \
    --label "adputate_memory=$MEMORY" \
    --env-file "$ENV_FILE" \
    --publish "$HOST_BIND_ADDRESS:$HOST_WEB_PORT:80/tcp" \
    --publish "$HOST_BIND_ADDRESS:$HOST_DNS_PORT:53/tcp" \
    --publish "$HOST_BIND_ADDRESS:$HOST_DNS_PORT:53/udp" \
    --volume "$ETC_PIHOLE_VOLUME:/etc/pihole" \
    --volume "$ETC_DNSMASQ_VOLUME:/etc/dnsmasq.d" \
    "$IMAGE"
}

dns_query_works() {
  local protocol="$1" port="$2" output
  if [[ "$protocol" == "udp" ]]; then
    output="$("$DIG_BIN" +time=2 +tries=1 +short \
      @"$HOST_BIND_ADDRESS" -p "$port" pi.hole A 2>/dev/null)" || return 1
  else
    output="$("$DIG_BIN" +tcp +time=2 +tries=1 +short \
      @"$HOST_BIND_ADDRESS" -p "$port" pi.hole A 2>/dev/null)" || return 1
  fi
  grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' <<<"$output"
}

backend_ready() {
  container_running && \
    "$CONTAINER_BIN" exec "$CONTAINER_NAME" pihole api dns/blocking >/dev/null 2>&1 && \
    "$CURL_BIN" --noproxy '*' --silent --fail --max-time 3 "http://$HOST_BIND_ADDRESS:$HOST_WEB_PORT/admin/" >/dev/null 2>&1 && \
    dns_query_works udp "$HOST_DNS_PORT" && \
    dns_query_works tcp "$HOST_DNS_PORT"
}

wait_for_ready() {
  local timeout="${ADPUTATE_READY_TIMEOUT:-30}" elapsed=0
  printf 'Waiting for Pi-hole readiness'
  while (( elapsed < timeout )); do
    if backend_ready; then
      printf ' ready.\n'
      return
    fi
    printf '.'
    sleep 1
    elapsed=$((elapsed + 1))
  done
  printf ' failed.\n' >&2
  "$CONTAINER_BIN" logs "$CONTAINER_NAME" 2>/dev/null | tail -50 >&2 || true
  return 1
}

start_pihole() {
  require_apple_silicon
  require_container
  init_config
  start_container_system
  ensure_volumes

  if container_running; then
    require_container_matches_config
    printf '%s is already running.\n' "$CONTAINER_NAME"
    wait_for_ready || die "Pi-hole did not become ready"
    return
  fi

  if container_exists; then
    require_container_matches_config
    "$CONTAINER_BIN" start "$CONTAINER_NAME"
    wait_for_ready || die "Pi-hole did not become ready"
    return
  fi

  create_pihole
  wait_for_ready || die "Pi-hole did not become ready"
}

ensure_pihole() {
  # launchd calls this periodically. start_pihole is intentionally idempotent and
  # restores both the user-scoped Apple Container runtime and the Pi-hole container.
  start_pihole
}

reconcile_container() {
  [[ "${1:-}" == "--yes" ]] || die "Refusing to recreate the container without --yes"
  require_apple_silicon
  require_container
  init_config
  start_container_system
  ensure_volumes
  if container_exists; then
    "$CONTAINER_BIN" stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    "$CONTAINER_BIN" delete "$CONTAINER_NAME"
  fi
  create_pihole
  wait_for_ready || die "Pi-hole did not become ready after reconciliation"
  printf 'Reconciled %s without deleting named volumes.\n' "$CONTAINER_NAME"
}

stop_pihole() {
  require_container
  if container_exists; then
    "$CONTAINER_BIN" stop "$CONTAINER_NAME"
  else
    printf '%s does not exist.\n' "$CONTAINER_NAME"
  fi
}

restart_pihole() {
  require_container
  container_exists && require_container_matches_config
  stop_pihole
  start_pihole
}

reset_container() {
  require_container
  if container_exists; then
    "$CONTAINER_BIN" stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    "$CONTAINER_BIN" delete "$CONTAINER_NAME"
  else
    printf '%s does not exist.\n' "$CONTAINER_NAME"
  fi
}

status() {
  require_container
  if container_running; then
    printf '%s is running.\n' "$CONTAINER_NAME"
  elif container_exists; then
    printf '%s exists but is stopped.\n' "$CONTAINER_NAME"
  else
    printf '%s has not been created.\n' "$CONTAINER_NAME"
  fi
  if container_exists; then
    if container_matches_config; then
      printf 'Config:    matches desired state\n'
    else
      printf 'Config:    drift detected; run: %s host reconcile --yes\n' "$CLI_NAME"
      container_drift_report || true
    fi
  fi
  printf 'Admin UI: http://%s:%s/admin/\n' "$HOST_BIND_ADDRESS" "$HOST_WEB_PORT"
  printf 'DNS:      %s#%s\n' "$HOST_BIND_ADDRESS" "$HOST_DNS_PORT"
  if [[ -f "$ROUTER_PLIST_PATH" ]]; then
    printf 'Router:   %s#53\n' "$HOST_BIND_ADDRESS"
  else
    printf 'Router:   not installed\n'
  fi
  printf 'Volumes:  %s, %s\n' "$ETC_PIHOLE_VOLUME" "$ETC_DNSMASQ_VOLUME"
}

admin_url() {
  printf 'http://%s:%s/admin/\n' "$HOST_BIND_ADDRESS" "$HOST_WEB_PORT"
}

dns_url() {
  printf '%s#%s\n' "$HOST_BIND_ADDRESS" "$HOST_DNS_PORT"
}

logs() {
  require_container
  "$CONTAINER_BIN" logs "$CONTAINER_NAME"
}

open_admin() {
  "$OPEN_BIN" "$(admin_url)"
}

blocking_status() {
  require_container
  container_running || die "$CONTAINER_NAME is not running. Run: $CLI_NAME host start"
  "$CONTAINER_BIN" exec "$CONTAINER_NAME" pihole api dns/blocking
}

enable_blocking() {
  require_container
  container_running || die "$CONTAINER_NAME is not running. Run: $CLI_NAME host start"
  "$CONTAINER_BIN" exec "$CONTAINER_NAME" pihole enable
}

disable_blocking() {
  require_container
  container_running || die "$CONTAINER_NAME is not running. Run: $CLI_NAME host start"
  local duration="${1:-}"
  if [[ -n "$duration" ]]; then
    "$CONTAINER_BIN" exec "$CONTAINER_NAME" pihole disable "$duration"
  else
    "$CONTAINER_BIN" exec "$CONTAINER_NAME" pihole disable
  fi
}

password() {
  [[ -f "$ENV_FILE" ]] || die "No managed env file exists yet. Run: $CLI_NAME host start"
  awk -F= '$1 == "FTLCONF_webserver_api_password" {print $2}' "$ENV_FILE"
}

shell_into_container() {
  require_container
  "$CONTAINER_BIN" exec --interactive --tty "$CONTAINER_NAME" /bin/bash
}

teleporter_export() {
  require_container
  container_running || die "$CONTAINER_NAME is not running. Run: $CLI_NAME host start"
  ensure_dirs
  local dest_dir output archive dest_path
  dest_dir="${1:-$TELEPORTER_DIR}"
  mkdir -p "$dest_dir"
  output="$("$CONTAINER_BIN" exec "$CONTAINER_NAME" sh -c 'cd /tmp && pihole-FTL --teleporter')"
  printf '%s\n' "$output"
  archive="$(printf '%s\n' "$output" | awk '/\.zip$/ {print $NF}' | tail -1)"
  [[ -n "$archive" ]] || die "Could not determine Teleporter archive name."
  dest_path="$dest_dir/$archive"
  "$CONTAINER_BIN" exec "$CONTAINER_NAME" cat "/tmp/$archive" >"$dest_path"
  "$CONTAINER_BIN" exec "$CONTAINER_NAME" rm -f "/tmp/$archive" >/dev/null 2>&1 || true
  printf 'Saved Teleporter archive: %s\n' "$dest_path"
}

teleporter_import() {
  require_container
  container_running || die "$CONTAINER_NAME is not running. Run: $CLI_NAME host start"
  local archive
  archive="${1:-}"
  [[ -n "$archive" ]] || die "Usage: $CLI_NAME host teleporter import <zip>"
  [[ -f "$archive" ]] || die "Teleporter archive not found: $archive"
  "$CONTAINER_BIN" exec --interactive "$CONTAINER_NAME" sh -c \
    'tmp=/tmp/adputate-import.$$; trap '\''rm -f "$tmp"'\'' EXIT HUP INT TERM; cat >"$tmp" && pihole-FTL --teleporter "$tmp"' <"$archive"
}

upgrade_pihole() {
  local target_image="${1:-}" confirmation="${2:-}" old_image backup_dir
  [[ -n "$target_image" ]] || die "Usage: $CLI_NAME host upgrade <pinned-image> --yes"
  [[ "$confirmation" == "--yes" ]] || die "Refusing to upgrade without --yes"
  image_is_pinned "$target_image" || die "Upgrade image must use a pinned tag, not latest"
  require_container
  container_running || die "$CONTAINER_NAME must be running for a backup-first upgrade"
  backend_ready || die "Pi-hole must be healthy before upgrade"
  old_image="$(container_current_image)"
  [[ -n "$old_image" ]] || die "Could not determine the current image"
  [[ "$old_image" != "$target_image" ]] || die "$CONTAINER_NAME already uses $target_image"

  backup_dir="$TELEPORTER_DIR/pre-upgrade-$(date +%Y%m%d-%H%M%S)"
  printf 'Creating pre-upgrade Teleporter backup...\n'
  teleporter_export "$backup_dir"
  printf 'Pulling %s...\n' "$target_image"
  record_owned_image_if_missing "$target_image"
  "$CONTAINER_BIN" image pull "$target_image"

  "$CONTAINER_BIN" stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  "$CONTAINER_BIN" delete "$CONTAINER_NAME"
  IMAGE="$target_image"
  write_runtime_config "$HOST_BIND_ADDRESS" "$HOST_WEB_PORT" "$HOST_DNS_PORT" "$IMAGE" "$MEMORY" "$ROUTER_INTERFACE"

  if create_pihole && wait_for_ready; then
    printf 'Upgrade succeeded: %s -> %s\n' "$old_image" "$target_image"
    return
  fi

  printf 'Upgrade failed; rolling back to %s...\n' "$old_image" >&2
  "$CONTAINER_BIN" stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  "$CONTAINER_BIN" delete "$CONTAINER_NAME" >/dev/null 2>&1 || true
  IMAGE="$old_image"
  write_runtime_config "$HOST_BIND_ADDRESS" "$HOST_WEB_PORT" "$HOST_DNS_PORT" "$IMAGE" "$MEMORY" "$ROUTER_INTERFACE"
  create_pihole
  wait_for_ready || die "Upgrade and rollback both failed; backup is in $backup_dir"
  die "Upgrade failed and the previous image was restored; backup is in $backup_dir"
}

launchd_plist() {
  local template="$PROJECT_ROOT/packaging/launchd/com.adputate.pihole.plist.template"
  [[ -f "$template" ]] || die "Launchd template not found: $template"
  sed \
    -e "s#__ADPUTATE_SERVICE_LABEL__#$SERVICE_LABEL#g" \
    -e "s#__ADPUTATE_BIN__#$CLI_LAUNCHER#g" \
    -e "s#__ADPUTATE_LOG_DIR__#$LOG_DIR#g" \
    "$template"
}

launchd_domain() {
  printf 'gui/%s' "$(id -u)"
}

launchd_plist_path() {
  printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$SERVICE_LABEL"
}

service_install() {
  privacy_preflight || die "DNS privacy preflight failed"
  ensure_dirs
  local plist_path
  plist_path="$(launchd_plist_path)"
  mkdir -p "$HOME/Library/LaunchAgents"
  launchd_plist >"$plist_path"
  plutil -lint "$plist_path" >/dev/null

  launchctl bootout "$(launchd_domain)" "$plist_path" >/dev/null 2>&1 || true
  launchctl bootstrap "$(launchd_domain)" "$plist_path"
  launchctl kickstart -k "$(launchd_domain)/$SERVICE_LABEL" >/dev/null 2>&1 || true
  printf 'Installed %s at %s\n' "$SERVICE_LABEL" "$plist_path"
}

service_uninstall() {
  local plist_path
  plist_path="$(launchd_plist_path)"
  launchctl bootout "$(launchd_domain)" "$plist_path" >/dev/null 2>&1 || true
  rm -f "$plist_path"
  printf 'Removed %s\n' "$SERVICE_LABEL"
}

service_enable() {
  local plist_path
  plist_path="$(launchd_plist_path)"
  [[ -f "$plist_path" ]] || service_install
  launchctl enable "$(launchd_domain)/$SERVICE_LABEL"
  printf 'Enabled %s at user login\n' "$SERVICE_LABEL"
}

service_disable() {
  local plist_path
  plist_path="$(launchd_plist_path)"
  [[ -f "$plist_path" ]] || die "LaunchAgent is not installed. Run: $CLI_NAME host service install"
  launchctl disable "$(launchd_domain)/$SERVICE_LABEL"
  printf 'Disabled %s at user login\n' "$SERVICE_LABEL"
}

service_kick() {
  local plist_path
  plist_path="$(launchd_plist_path)"
  [[ -f "$plist_path" ]] || service_install
  launchctl kickstart -k "$(launchd_domain)/$SERVICE_LABEL"
  printf 'Kicked %s\n' "$SERVICE_LABEL"
}

service_status() {
  local plist_path
  plist_path="$(launchd_plist_path)"
  local domain_service
  domain_service="$(launchd_domain)/$SERVICE_LABEL"

  if [[ -f "$plist_path" ]]; then
    printf 'LaunchAgent: installed at %s\n' "$plist_path"
  else
    printf 'LaunchAgent: not installed\n'
  fi

  local print_output state last_exit runs enabled_status
  print_output="$(launchctl print "$domain_service" 2>/dev/null || true)"
  if [[ -z "$print_output" ]]; then
    printf 'launchctl: not loaded\n'
    return
  fi

  state="$(printf '%s\n' "$print_output" | awk -F'= ' '/state =/ {print $2; exit}')"
  last_exit="$(printf '%s\n' "$print_output" | awk -F'= ' '/last exit code =/ {print $2; exit}')"
  runs="$(printf '%s\n' "$print_output" | awk -F'= ' '/runs =/ {print $2; exit}')"

  if launchctl print-disabled "$(launchd_domain)" 2>/dev/null | grep -q "\"$SERVICE_LABEL\" => true"; then
    enabled_status="disabled"
  else
    enabled_status="enabled"
  fi

  printf 'launchctl: loaded\n'
  printf 'startup:   %s\n' "$enabled_status"
  printf 'state:     %s\n' "${state:-unknown}"
  printf 'runs:      %s\n' "${runs:-unknown}"
  printf 'last exit: %s\n' "${last_exit:-unknown}"
}

host_uninstall_audit() {
  local keep_images="${1:-0}" image_manifest="${2:-$OWNED_IMAGES_FILE}"
  local firewall_apps disabled_output audit_image image_count=0
  reset_checks

  [[ ! -e "$DNS_BACKUP_FILE" ]] && check_pass "No active macOS DNS backup" || \
    check_fail "macOS DNS backup remains at $DNS_BACKUP_FILE"
  [[ ! -e "$ROUTER_PLIST_PATH" ]] && check_pass "No router LaunchDaemon plist" || \
    check_fail "Router LaunchDaemon plist remains at $ROUTER_PLIST_PATH"
  if /bin/launchctl print "system/$ROUTER_SERVICE_LABEL" >/dev/null 2>&1; then
    check_fail "Router LaunchDaemon remains loaded"
  else
    check_pass "Router LaunchDaemon is not loaded"
  fi
  [[ ! -e "$ROUTER_SUPPORT_DIR" ]] && check_pass "No privileged Adputate support directory" || \
    check_fail "Privileged support directory remains at $ROUTER_SUPPORT_DIR"
  [[ ! -e "$ROUTER_LOG_PATH" ]] && check_pass "No router frontend log" || \
    check_fail "Router frontend log remains"

  firewall_apps="$(/usr/libexec/ApplicationFirewall/socketfilterfw --listapps 2>/dev/null || true)"
  if grep -Fq "$ROUTER_PROXY_PATH" <<<"$firewall_apps"; then
    check_fail "Application Firewall registration remains for $ROUTER_PROXY_PATH"
  else
    check_pass "No Adputate Application Firewall registration"
  fi

  local plist_path
  plist_path="$(launchd_plist_path)"
  [[ ! -e "$plist_path" ]] && check_pass "No user LaunchAgent plist" || \
    check_fail "User LaunchAgent plist remains at $plist_path"
  if /bin/launchctl print "$(launchd_domain)/$SERVICE_LABEL" >/dev/null 2>&1; then
    check_fail "User LaunchAgent remains loaded"
  else
    check_pass "User LaunchAgent is not loaded"
  fi

  if command -v "$CONTAINER_BIN" >/dev/null 2>&1 && container_service_reachable; then
    container_exists && check_fail "$CONTAINER_NAME still exists" || check_pass "No Adputate container"
    volume_exists "$ETC_PIHOLE_VOLUME" && check_fail "$ETC_PIHOLE_VOLUME still exists" || check_pass "No Pi-hole volume"
    volume_exists "$ETC_DNSMASQ_VOLUME" && check_fail "$ETC_DNSMASQ_VOLUME still exists" || check_pass "No dnsmasq volume"
    if [[ -f "$image_manifest" ]]; then
      while IFS= read -r audit_image; do
        [[ -n "$audit_image" ]] || continue
        image_count=$((image_count + 1))
        if image_exists "$audit_image"; then
          if [[ "$keep_images" == "1" ]]; then
            check_warn "Adputate-pulled image was deliberately retained: $audit_image"
          else
            check_fail "Adputate-pulled image remains cached: $audit_image"
          fi
        else
          check_pass "Adputate-pulled image is not cached: $audit_image"
        fi
      done <"$image_manifest"
    fi
    (( image_count != 0 )) || check_pass "No Adputate-owned image cache entries"
  else
    check_warn "Apple Container is absent or stopped; container, volume, and image cleanup cannot be verified"
  fi

  [[ ! -e "$RUNTIME_CONFIG_FILE" ]] && check_pass "No local-host runtime configuration" || \
    check_fail "Local-host runtime configuration remains at $RUNTIME_CONFIG_FILE"
  [[ ! -e "$ENV_FILE" ]] && check_pass "No local Pi-hole environment file" || \
    check_fail "Local Pi-hole environment remains at $ENV_FILE"
  local managed_file managed_count=0
  for managed_file in "$INSTANCES_DIR"/*.conf; do
    [[ -f "$managed_file" ]] || continue
    [[ "$(config_value "$managed_file" AUTH)" != "managed-local" ]] || managed_count=$((managed_count + 1))
  done
  (( managed_count == 0 )) && check_pass "No managed-local instance registration" || \
    check_fail "$managed_count managed-local instance registration(s) remain"

  disabled_output="$(/bin/launchctl print-disabled "$(launchd_domain)" 2>/dev/null || true)"
  if grep -Fq "\"$SERVICE_LABEL\"" <<<"$disabled_output"; then
    check_warn "launchd retains an enable/disable preference for $SERVICE_LABEL; macOS has no safe per-service reset command"
  fi
  check_summary
}

host_uninstall() {
  local confirmed=0 keep_images=0 argument image image_list cleanup_failed=0
  local system_started_for_cleanup=0 stop_owned_system=0 other_containers firewall_apps
  local container_available=0
  for argument in "$@"; do
    case "$argument" in
      --yes) confirmed=1 ;;
      --keep-images) keep_images=1 ;;
      *) die "Unknown uninstall option: $argument" ;;
    esac
  done
  (( confirmed == 1 )) || die "Refusing to remove data without --yes."
  if have_container; then
    container_available=1
    if ! container_service_reachable; then
      "$CONTAINER_BIN" system start >/dev/null
      container_service_reachable || die "Apple Container service could not be started for cleanup"
      system_started_for_cleanup=1
    fi
  else
    printf 'Apple Container is not installed; cleaning all non-container host artifacts.\n'
  fi
  [[ -f "$CONTAINER_SYSTEM_MARKER" ]] && stop_owned_system=1

  image_list="$(mktemp "${TMPDIR:-/tmp}/adputate-uninstall-images.XXXXXX")"
  if [[ -f "$OWNED_IMAGES_FILE" ]]; then
    while IFS= read -r image; do
      [[ -n "$image" ]] && printf '%s\n' "$image" >>"$image_list"
    done <"$OWNED_IMAGES_FILE"
  fi
  /usr/bin/sort -u -o "$image_list" "$image_list"

  if [[ -f "$DNS_BACKUP_FILE" ]]; then
    printf 'Restoring the previous macOS DNS configuration...\n'
    client_dns_restore --yes
  fi
  firewall_apps="$(/usr/libexec/ApplicationFirewall/socketfilterfw --listapps 2>/dev/null || true)"
  if [[ -e "$ROUTER_PLIST_PATH" || -e "$ROUTER_SUPPORT_DIR" || -e "$ROUTER_LOG_PATH" ]] || \
      /bin/launchctl print "system/$ROUTER_SERVICE_LABEL" >/dev/null 2>&1 || \
      grep -Fq "$ROUTER_PROXY_PATH" <<<"$firewall_apps"; then
    printf 'Removing the privileged port-53 frontend...\n'
    router_uninstall
  fi
  service_uninstall >/dev/null 2>&1 || true
  if (( container_available == 1 )); then
    reset_container
    "$CONTAINER_BIN" volume delete "$ETC_PIHOLE_VOLUME" >/dev/null 2>&1 || true
    "$CONTAINER_BIN" volume delete "$ETC_DNSMASQ_VOLUME" >/dev/null 2>&1 || true
    volume_exists "$ETC_PIHOLE_VOLUME" && cleanup_failed=1
    volume_exists "$ETC_DNSMASQ_VOLUME" && cleanup_failed=1

    if (( keep_images == 0 )); then
      while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        if image_exists "$image"; then
          printf 'Removing cached image %s...\n' "$image"
          if ! "$CONTAINER_BIN" image delete "$image"; then
            printf 'Could not remove shared or in-use image: %s\n' "$image" >&2
            cleanup_failed=1
          fi
        fi
      done <"$image_list"
    fi
  fi
  [[ -n "$APP_DIR" && "$APP_DIR" != "/" && "$APP_DIR" != "$HOME" && ${#APP_DIR} -gt 8 ]] || \
    die "Refusing to clean unsafe application data path: $APP_DIR"
  if (( cleanup_failed == 0 )); then
    rm -f -- "$RUNTIME_CONFIG_FILE" "$ENV_FILE" "$OWNED_IMAGES_FILE" "$CONTAINER_SYSTEM_MARKER"
    rm -rf -- "$LOG_DIR" "$TELEPORTER_DIR"
    local managed_file
    for managed_file in "$INSTANCES_DIR"/*.conf; do
      [[ -f "$managed_file" ]] || continue
      [[ "$(config_value "$managed_file" AUTH)" != "managed-local" ]] || rm -f -- "$managed_file"
    done
  else
    printf 'Retaining local-host configuration so cleanup can be retried.\n' >&2
  fi

  printf 'Auditing host uninstall...\n'
  host_uninstall_audit "$keep_images" "$image_list" || cleanup_failed=1
  rm -f "$image_list"
  if (( container_available == 1 )); then
    other_containers="$("$CONTAINER_BIN" list --all --quiet 2>/dev/null || true)"
  fi
  if (( container_available == 1 )) && [[ -z "$other_containers" && ( "$system_started_for_cleanup" == "1" || "$stop_owned_system" == "1" ) ]]; then
    printf 'Restoring Apple Container services to their pre-Adputate stopped state...\n'
    "$CONTAINER_BIN" system stop >/dev/null || cleanup_failed=1
  fi
  (( cleanup_failed == 0 )) || die "Uninstall completed with artifacts that require attention"
  printf 'Adputate host uninstall completed cleanly. Controller configuration was preserved.\n'
}

host_artifacts_present() {
  [[ -e "$RUNTIME_CONFIG_FILE" || -e "$ENV_FILE" || -e "$(launchd_plist_path)" || \
     -e "$ROUTER_PLIST_PATH" || -e "$ROUTER_SUPPORT_DIR" ]] && return 0
  command -v "$CONTAINER_BIN" >/dev/null 2>&1 && container_service_reachable && container_exists
}

controller_uninstall_audit() {
  reset_checks
  [[ ! -e "$APP_DIR" ]] && check_pass "No Adputate controller or host state" || \
    check_fail "Adputate state remains at $APP_DIR"
  [[ ! -e "$(launchd_plist_path)" ]] && check_pass "No user LaunchAgent plist" || \
    check_fail "User LaunchAgent plist remains"
  [[ ! -e "$ROUTER_PLIST_PATH" && ! -e "$ROUTER_SUPPORT_DIR" ]] && \
    check_pass "No privileged DNS frontend" || check_fail "Privileged DNS frontend remains"
  check_summary
}

controller_uninstall() {
  local confirmed=0 keep_images=0 argument file id auth credential_cleanup_failed=0
  for argument in "$@"; do
    case "$argument" in
      --yes) confirmed=1 ;;
      --keep-images) keep_images=1 ;;
      *) die "Unknown uninstall option: $argument" ;;
    esac
  done
  (( confirmed == 1 )) || die "Refusing to remove data without --yes."

  if host_artifacts_present; then
    if (( keep_images == 1 )); then
      host_uninstall --yes --keep-images
    else
      host_uninstall --yes
    fi
  elif [[ -f "$DNS_BACKUP_FILE" ]]; then
    client_dns_restore --yes
  fi

  for file in "$INSTANCES_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="$(config_value "$file" ID)"
    auth="$(config_value "$file" AUTH)"
    if [[ "$auth" == "keychain" ]]; then
      if ! delete_instance_credential "$id"; then
        printf 'Could not remove Keychain credential for %s; configuration was preserved.\n' "$id" >&2
        credential_cleanup_failed=1
      fi
    fi
  done
  (( credential_cleanup_failed == 0 )) || die "Controller uninstall stopped before deleting configuration"

  [[ -n "$APP_DIR" && "$APP_DIR" != "/" && "$APP_DIR" != "$HOME" && ${#APP_DIR} -gt 8 ]] || \
    die "Refusing to remove unsafe application data path: $APP_DIR"
  rm -rf -- "$APP_DIR"
  controller_uninstall_audit || die "Controller uninstall completed with artifacts that require attention"
  printf 'Adputate uninstall completed cleanly. The packaged executable can now be removed.\n'
}

host_service_command() {
  case "${1:-}" in
    install) service_install ;;
    uninstall) service_uninstall ;;
    enable) service_enable ;;
    disable) service_disable ;;
    kick) service_kick ;;
    status) service_status ;;
    plist) launchd_plist ;;
    *) die "Usage: $CLI_NAME host service install|uninstall|enable|disable|kick|status|plist" ;;
  esac
}

host_router_command() {
  case "${1:-}" in
    install) router_install ;;
    preflight) router_preflight ;;
    status) router_status ;;
    uninstall) router_uninstall ;;
    *) die "Usage: $CLI_NAME host router install|preflight|status|uninstall" ;;
  esac
}

setup_workstation() {
  ensure_cluster_config
  printf 'Initialized controller-only workstation configuration.\n'
  printf 'No container, launchd job, router frontend, or DNS setting was installed.\n\n'
  show_instances
  printf '\nNext: add or discover Pi-hole instances, then review `%s client dns plan`.\n' "$CLI_NAME"
}

prompt_yes_no() {
  local prompt="$1" default="${2:-no}" answer
  if [[ "$default" == "yes" ]]; then
    IFS= read -r -p "$prompt [Y/n] " answer
    [[ -z "$answer" || "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
  else
    IFS= read -r -p "$prompt [y/N] " answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
  fi
}

install_wizard() {
  local id name role api_url dns_endpoint default_role file
  [[ -t 0 && -t 1 ]] || die "Interactive install requires a terminal"
  ensure_cluster_config
  printf 'Adputate can manage existing Pi-holes without installing one on this Mac.\n'
  show_instances
  while prompt_yes_no 'Configure an existing Pi-hole node?' yes; do
    IFS= read -r -p '  Short id (for example nuc): ' id
    IFS= read -r -p "  Display name [$id]: " name
    name="${name:-$id}"
    default_role="authority"
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      if [[ "$(config_value "$file" ROLE)" == "authority" ]]; then default_role="replica"; break; fi
    done < <(instance_files)
    IFS= read -r -p "  Role [$default_role]: " role
    role="${role:-$default_role}"
    IFS= read -r -p '  API base URL (for example http://192.168.1.10): ' api_url
    IFS= read -r -p '  DNS endpoint (for example 192.168.1.10#53): ' dns_endpoint
    if prompt_yes_no '  Does this Pi-hole require an application password?' yes; then
      instance_add "$id" --name "$name" --role "$role" --api-url "$api_url" \
        --dns "$dns_endpoint" --password-prompt
    else
      instance_add "$id" --name "$name" --role "$role" --api-url "$api_url" \
        --dns "$dns_endpoint" --no-auth
    fi
    prompt_yes_no 'Configure another existing Pi-hole node?' no || break
  done

  if prompt_yes_no 'Install a Pi-hole on this Mac?' no; then
    host_setup
  else
    setup_workstation
  fi
}

host_setup() {
  require_apple_silicon
  require_container
  init_config
  printf 'Initialized Pi-hole host configuration. No service or privileged frontend was installed.\n\n'
  show_host_config
  printf '\nInstall sequence:\n'
  printf '  1. Review `%s host config`; use `host configure` if needed.\n' "$CLI_NAME"
  printf '  2. %s host doctor\n' "$CLI_NAME"
  printf '  3. %s host start\n' "$CLI_NAME"
  printf '  4. %s host register adputate\n' "$CLI_NAME"
  printf '  5. %s host service install\n' "$CLI_NAME"
  printf '  6. %s host router install\n' "$CLI_NAME"
  printf 'Each stage remains independently verifiable and reversible.\n'
}

client_command() {
  case "${1:-}" in
    dns)
      shift
      case "${1:-}" in
        status) shift; client_dns_status "$@" ;;
        plan) shift; client_dns_plan "$@" ;;
        apply) shift; client_dns_apply "$@" ;;
        restore) shift; client_dns_restore "$@" ;;
        *) die "Usage: $CLI_NAME client dns status|plan|apply --yes|restore --yes" ;;
      esac ;;
    *) die "Usage: $CLI_NAME client dns status|plan|apply|restore" ;;
  esac
}

host_command() {
  local command="${1:-}"
  shift || true
  case "$command" in
    config) show_host_config ;;
    doctor) doctor ;;
    health) health ;;
    status) status ;;
    start) start_pihole ;;
    ensure) ensure_pihole ;;
    stop) stop_pihole ;;
    restart) restart_pihole ;;
    logs) logs ;;
    admin) open_admin ;;
    admin-url) admin_url ;;
    dns-url) dns_url ;;
    shell) shell_into_container ;;
    smoke) smoke ;;
    init) init_config ;;
    configure) configure_runtime "$@" ;;
    register) register_host_instance "${1:-adputate}" ;;
    reconcile) reconcile_container "${1:-}" ;;
    blocking)
      case "${1:-}" in
        status) blocking_status ;;
        enable) enable_blocking ;;
        disable) disable_blocking "${2:-}" ;;
        *) die "Usage: $CLI_NAME host blocking status|enable|disable [time]" ;;
      esac ;;
    password) password ;;
    service) host_service_command "$@" ;;
    router) host_router_command "$@" ;;
    teleporter)
      case "${1:-}" in
        export) teleporter_export "${2:-}" ;;
        import) teleporter_import "${2:-}" ;;
        *) die "Usage: $CLI_NAME host teleporter export [directory]|import <zip>" ;;
      esac ;;
    upgrade) upgrade_pihole "${1:-}" "${2:-}" ;;
    reset) reset_container ;;
    uninstall) host_uninstall "$@" ;;
    uninstall-audit) host_uninstall_audit ;;
    *) die "Unknown host command. Run '$CLI_NAME --help'." ;;
  esac
}

main() {
  local command="${1:-}"
  shift || true
  case "$command" in
    status) cluster_status ;;
    config) [[ "${1:-}" == "show" ]] || die "Usage: $CLI_NAME config show"; show_controller_config ;;
    instance)
      case "${1:-}" in
        list) show_instances ;;
        add) shift; instance_add "$@" ;;
        remove) shift; instance_remove "${1:-}" ;;
        *) die "Usage: $CLI_NAME instance list|add|remove" ;;
      esac ;;
    discover) discover_instances ;;
    query)
      if [[ "${1:-}" == "snapshot" ]]; then shift; collect_query_snapshot "$@"; else query_logs "$@"; fi ;;
    blocking) cluster_blocking "$@" ;;
    bugreport) bugreport "$@" ;;
    install) install_wizard ;;
    uninstall) controller_uninstall "$@" ;;
    uninstall-audit) controller_uninstall_audit ;;
    -V|--version|version)
      [[ -f "$VERSION_FILE" ]] || die "Version metadata is missing"
      printf '%s %s\n' "$APP_NAME" "$(<"$VERSION_FILE")"
      ;;
    client) client_command "$@" ;;
    host) host_command "$@" ;;
    -h|--help|help|"") render_usage ;;
    *) render_usage; exit 64 ;;
  esac
}

main "$@"
