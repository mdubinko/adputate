#!/usr/bin/env bash
set -euo pipefail

action="${1:-}"
bind_address="${2:-}"
backend_port="${3:-}"
interface="${4:-}"
service_label="${5:-com.adputate.dns-forwarder}"
support_dir="/Library/Application Support/Adputate"
legacy_pf_file="$support_dir/router-forward.pf"
legacy_loader="$support_dir/load-router-forwarder"
proxy="$support_dir/adputate-dns-proxy"
source_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(CDPATH= cd -- "$source_dir/../.." && pwd)"
prebuilt_proxy="$project_root/build/adputate-dns-proxy"
plist="/Library/LaunchDaemons/$service_label.plist"
log_file="/var/log/adputate-dns-forwarder.log"

listener_hint() {
  local command_name
  command_name="$(printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  case "$command_name" in
    mdnsrespo*) printf 'macOS mDNSResponder (expected wildcard listener)' ;;
    dnsmasq*) printf 'dnsmasq; check `brew services list` and stop or reconfigure dnsmasq' ;;
    docker*|com.docker*) printf 'Docker Desktop; inspect its DNS/network settings or quit it temporarily' ;;
    orbstack*) printf 'OrbStack; inspect its DNS/network settings or stop it temporarily' ;;
    internetsh*|bootpd*) printf 'macOS Internet Sharing; turn it off in System Settings' ;;
    tailscale*|wireguard*|openvpn*|anyconnect*|globalpro*|forti*|cloudflare*|mullvad*|nordvpn*|expressvpn*|viscosity*)
      printf 'VPN client; disable its DNS feature or disconnect it temporarily'
      ;;
    *) printf 'unknown service; identify it by PID before continuing' ;;
  esac
}

classify_listeners() {
  local target_address="$1" own_pid="${2:-}" protocol command_name pid owner socket_name hint conflict=0
  local command_lower
  while IFS=$'\t' read -r protocol command_name pid owner socket_name; do
    [[ -n "$command_name" ]] || continue
    if [[ -n "$own_pid" && "$pid" == "$own_pid" ]]; then
      printf '[INFO] %s port 53 listener: %s (pid %s, user %s) on %s — Adputate DNS frontend\n' \
        "$protocol" "$command_name" "$pid" "$owner" "$socket_name"
      printf '[PASS] Listener belongs to the currently installed Adputate frontend.\n'
      continue
    fi

    hint="$(listener_hint "$command_name")"
    printf '[INFO] %s port 53 listener: %s (pid %s, user %s) on %s — %s\n' \
      "$protocol" "$command_name" "$pid" "$owner" "$socket_name" "$hint"

    command_lower="$(printf '%s' "$command_name" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    if [[ "$command_lower" == mdnsrespo* && ( "$socket_name" == "*:53" || "$socket_name" == "0.0.0.0:53" ) ]]; then
      printf '[PASS] Allowing the standard macOS wildcard listener; Adputate binds the exact LAN address.\n'
      continue
    fi

    case "$socket_name" in
      "$target_address:53"|"*:53"|"0.0.0.0:53")
        printf '[FAIL] This listener conflicts with %s:53/%s.\n' "$target_address" "$protocol" >&2
        conflict=1
        ;;
      *)
        printf '[WARN] This listener does not directly occupy %s:53, but may affect local DNS.\n' "$target_address"
        ;;
    esac
  done
  (( conflict == 0 ))
}

listener_snapshot() {
  local protocol output
  for protocol in TCP UDP; do
    if [[ "$protocol" == "TCP" ]]; then
      output="$(/usr/sbin/lsof -nP -iTCP:53 -sTCP:LISTEN 2>/dev/null || true)"
    else
      output="$(/usr/sbin/lsof -nP -iUDP:53 2>/dev/null || true)"
    fi
    printf '%s\n' "$output" | /usr/bin/awk -v protocol="$protocol" '
      NR > 1 {
        socket_name = $NF
        if (socket_name == "(LISTEN)") socket_name = $(NF - 1)
        printf "%s\t%s\t%s\t%s\t%s\n", protocol, $1, $2, $3, socket_name
      }
    '
  done
}

known_dns_interceptors() {
  local matches
  matches="$(/usr/bin/pgrep -il 'Docker|OrbStack|dnsmasq|InternetSharing|bootpd|Tailscale|WireGuard|OpenVPN|AnyConnect|GlobalProtect|FortiClient|Cloudflare|Mullvad|NordVPN|ExpressVPN|Viscosity' 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    printf '[WARN] Running software that may alter or intercept DNS was detected:\n%s\n' "$matches"
  fi
  printf '[WARN] VPN and Network Extension DNS interception may not own a visible port-53 socket. UDP and TCP probes are still required.\n'
}

preflight_port_53() {
  [[ "$EUID" -eq 0 ]] || { printf 'Run this helper as root for complete port ownership data.\n' >&2; return 1; }
  validate_install_args
  local own_pid snapshot
  own_pid="$(/bin/launchctl print "system/$service_label" 2>/dev/null | /usr/bin/awk '$1 == "pid" {print $3; exit}' || true)"
  snapshot="$(listener_snapshot)"
  printf 'Inspecting TCP and UDP port 53 for %s...\n' "$bind_address"
  if [[ -z "$snapshot" ]]; then
    printf '[PASS] No existing port-53 listeners were found.\n'
  elif ! printf '%s\n' "$snapshot" | classify_listeners "$bind_address" "$own_pid"; then
    known_dns_interceptors
    printf 'Port-53 preflight failed. Resolve conflicting listeners before installation.\n' >&2
    return 1
  fi
  known_dns_interceptors
  printf '[PASS] No conflicting listener owns %s:53.\n' "$bind_address"
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

validate_install_args() {
  valid_ipv4 "$bind_address" || { printf 'Invalid bind address: %s\n' "$bind_address" >&2; exit 1; }
  [[ "$bind_address" != "127.0.0.1" ]] || { printf 'The router frontend requires a LAN address.\n' >&2; exit 1; }
  [[ "$backend_port" =~ ^[0-9]+$ ]] && (( 10#$backend_port >= 1024 && 10#$backend_port <= 65535 )) || {
    printf 'Backend port must be between 1024 and 65535.\n' >&2; exit 1;
  }
  [[ "$interface" =~ ^[a-zA-Z0-9]+$ ]] || { printf 'Invalid interface: %s\n' "$interface" >&2; exit 1; }
  /sbin/ifconfig "$interface" | /usr/bin/grep -Fq "inet $bind_address " || {
    printf '%s is not assigned to %s.\n' "$bind_address" "$interface" >&2; exit 1;
  }
  [[ "$service_label" =~ ^[a-zA-Z0-9.-]+$ ]] || { printf 'Invalid service label.\n' >&2; exit 1; }
}

render_plist() {
  local destination="$1"
  cat >"$destination" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$service_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$proxy</string>
    <string>$bind_address</string>
    <string>$bind_address</string>
    <string>$backend_port</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>$log_file</string>
  <key>StandardErrorPath</key>
  <string>$log_file</string>
</dict>
</plist>
EOF
}

frontend_query_works() {
  local protocol="$1" output
  if [[ "$protocol" == "UDP" ]]; then
    output="$(/usr/bin/dig +time=1 +tries=1 +short \
      @"$bind_address" -p 53 pi.hole A 2>/dev/null)" || return 1
  else
    output="$(/usr/bin/dig +tcp +time=1 +tries=1 +short \
      @"$bind_address" -p 53 pi.hole A 2>/dev/null)" || return 1
  fi
  /usr/bin/grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' <<<"$output"
}

wait_for_frontend() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if /bin/launchctl print "system/$service_label" >/dev/null 2>&1 && \
        frontend_query_works UDP && frontend_query_works TCP; then
      return 0
    fi
    /bin/sleep 1
  done
  return 1
}

candidate_proxy=""
candidate_plist=""
backup_proxy=""
backup_plist=""
had_previous_proxy=0
had_previous_plist=0
previous_loaded=0
install_mutated=0
install_committed=0

restore_previous_install() {
  /bin/launchctl bootout system "$plist" >/dev/null 2>&1 || true
  /bin/rm -f "$proxy" "$plist"
  if (( had_previous_proxy == 1 )); then
    /bin/cp -p "$backup_proxy" "$proxy"
  fi
  if (( had_previous_plist == 1 )); then
    /bin/cp -p "$backup_plist" "$plist"
  fi
  if (( previous_loaded == 1 && had_previous_plist == 1 )); then
    /bin/launchctl bootstrap system "$plist" >/dev/null 2>&1 || true
    /bin/launchctl kickstart -k "system/$service_label" >/dev/null 2>&1 || true
  fi
}

install_exit_cleanup() {
  local status="$?"
  trap - EXIT
  if (( install_mutated == 1 && install_committed == 0 )); then
    printf 'Installation failed; restoring the previous frontend state.\n' >&2
    restore_previous_install || true
  fi
  /bin/rm -f "$candidate_proxy" "$candidate_plist" "$backup_proxy" "$backup_plist"
  exit "$status"
}

install_forwarder() {
  [[ "$EUID" -eq 0 ]] || { printf 'Run this helper as root.\n' >&2; exit 1; }
  preflight_port_53
  [[ -x "$prebuilt_proxy" ]] || {
    printf 'Missing built DNS frontend: %s\nRun `make build` before installing host services.\n' "$prebuilt_proxy" >&2
    exit 1
  }

  [[ ! -L "$support_dir" ]] || {
    printf 'Refusing symlinked support directory: %s\n' "$support_dir" >&2
    exit 1
  }
  /bin/mkdir -p "$support_dir"
  /usr/sbin/chown root:wheel "$support_dir"
  /bin/chmod 755 "$support_dir"
  [[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$support_dir")" == "0:0:755" ]] || {
    printf 'Could not secure support directory: %s\n' "$support_dir" >&2
    exit 1
  }
  candidate_proxy="$(/usr/bin/mktemp "$support_dir/.adputate-dns-proxy.new.XXXXXX")"
  candidate_plist="$(/usr/bin/mktemp "$support_dir/.adputate-dns-forwarder.new.XXXXXX")"
  backup_proxy="$(/usr/bin/mktemp "$support_dir/.adputate-dns-proxy.previous.XXXXXX")"
  backup_plist="$(/usr/bin/mktemp "$support_dir/.adputate-dns-forwarder.previous.XXXXXX")"
  trap install_exit_cleanup EXIT

  /bin/cp "$prebuilt_proxy" "$candidate_proxy"
  /usr/sbin/chown root:wheel "$candidate_proxy"
  /bin/chmod 755 "$candidate_proxy"
  render_plist "$candidate_plist"
  /usr/sbin/chown root:wheel "$candidate_plist"
  /bin/chmod 644 "$candidate_plist"
  /usr/bin/plutil -lint "$candidate_plist" >/dev/null

  if [[ -f "$proxy" ]]; then
    /bin/cp -p "$proxy" "$backup_proxy"
    had_previous_proxy=1
  fi
  if [[ -f "$plist" ]]; then
    /bin/cp -p "$plist" "$backup_plist"
    had_previous_plist=1
  fi
  if /bin/launchctl print "system/$service_label" >/dev/null 2>&1; then
    previous_loaded=1
  fi

  install_mutated=1
  /bin/launchctl bootout system "$plist" >/dev/null 2>&1 || true
  /bin/mv -f "$candidate_proxy" "$proxy"
  candidate_proxy=""
  /bin/mv -f "$candidate_plist" "$plist"
  candidate_plist=""
  /bin/rm -f "$legacy_loader" "$legacy_pf_file"
  /bin/launchctl bootstrap system "$plist"
  /bin/launchctl kickstart -k "system/$service_label"
  if ! wait_for_frontend; then
    /usr/bin/tail -40 "$log_file" >&2 2>/dev/null || true
    printf 'The frontend did not pass both UDP and TCP DNS probes.\n' >&2
    return 1
  fi
  install_committed=1
  printf 'Installed native DNS frontend: %s:53 -> %s:%s via %s\n' \
    "$bind_address" "$bind_address" "$backend_port" "$interface"
}

uninstall_forwarder() {
  [[ "$EUID" -eq 0 ]] || { printf 'Run this helper as root.\n' >&2; exit 1; }
  /bin/launchctl bootout system "$plist" >/dev/null 2>&1 || true
  /usr/libexec/ApplicationFirewall/socketfilterfw --remove "$proxy" >/dev/null 2>&1 || true
  /bin/rm -f "$plist" "$log_file"
  /bin/rm -rf "$support_dir"
  printf 'Removed %s.\n' "$service_label"
}

case "$action" in
  install) install_forwarder ;;
  preflight) preflight_port_53 ;;
  classify)
    valid_ipv4 "$bind_address" || { printf 'Invalid bind address: %s\n' "$bind_address" >&2; exit 1; }
    classify_listeners "$bind_address" "${3:-}"
    ;;
  uninstall) uninstall_forwarder ;;
  *) printf 'Usage: %s install|preflight <LAN-IP> <backend-port> <interface> [label] | classify <LAN-IP> [own-pid] | uninstall\n' "$0" >&2; exit 64 ;;
esac
