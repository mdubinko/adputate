# Adputate

Pi-hole for Apple Silicon Macs, using Apple's native container runtime.

Adputate is an experimental macOS wrapper around the official Pi-hole container image. Its first milestone is a dependable standalone DNS server with explicit health checks, persistent data, backups, and safe lifecycle management. Primary/replica synchronization can come later.

> [!WARNING]
> Adputate is pre-release infrastructure. Keep a working secondary resolver while testing, reserve the Mac's LAN address, and verify port 53 from another machine before changing router DHCP settings.

## Status

The current shell CLI can:

- Validate host, runtime, configuration, ports, and LaunchAgent prerequisites.
- Start and stop a pinned Pi-hole container.
- Persist Pi-hole data in Apple container named volumes.
- Check the Pi-hole API, admin HTTP endpoint, and DNS over UDP and TCP.
- Enable or disable blocking and report blocking status.
- Export and import Pi-hole Teleporter archives.
- Install and manage a per-user LaunchAgent.
- Persist desired runtime configuration and detect/reconcile container drift.
- Wait for API, HTTP, UDP DNS, and TCP DNS readiness after lifecycle changes.
- Install a supervised, least-privilege TCP/UDP port-53 frontend.
- Back up, change, verify, and restore macOS DNS settings.
- Perform backup-first image upgrades with automatic rollback.
- Bind published services to loopback or an active LAN IPv4 address.

The implementation has been tested with:

- Apple Silicon and macOS 26.6.1
- Apple `container` 1.2.2
- `pihole/pihole:2026.07.2` on `linux/arm64`

## Requirements

- An Apple Silicon Mac
- macOS 26 or newer
- Apple's [`container`](https://github.com/apple/container) CLI, version 1.x
- `/usr/bin/curl`, `/usr/bin/dig`, and the standard macOS command-line tools checked by `doctor`
- Xcode Command Line Tools (`xcrun clang`) to build the small native port-53 frontend during installation

Install Apple Container from its signed release package, start its system service, and confirm that `container --version` works before using Adputate.

Before installation, disconnect Cloudflare WARP and turn off iCloud Private Relay (or turn off **Limit IP Address Tracking** for the active network). Both can take control of macOS DNS independently of the DNS servers shown in Network settings. Adputate's service, router frontend, and macOS DNS installation commands stop before making changes when either override is active; they never change those products' settings themselves. WARP may remain installed while disconnected.

## Quick Start

```bash
bin/adputate doctor
bin/adputate start
bin/adputate health
bin/adputate password
bin/adputate admin
```

The defaults are intentionally local-only:

```text
Admin UI: http://127.0.0.1:8080/admin/
DNS:      127.0.0.1:5053 over TCP and UDP
```

Test DNS without changing macOS network settings:

```bash
dig @127.0.0.1 -p 5053 example.com A
dig +tcp @127.0.0.1 -p 5053 example.com A
```

Runtime state is stored under `~/Library/Application Support/Adputate`. Pi-hole configuration is stored in Apple container named volumes rather than inside the repository. For LAN/router use, continue with [Router Deployment](docs/router-deployment.md).

## Configuration

The CLI reads project identity from `project.env` and persists runtime settings in `~/Library/Application Support/Adputate/config/runtime.env`. Environment variables take precedence over persisted values, which take precedence over defaults.

| Variable | Default | Purpose |
|---|---:|---|
| `ADPUTATE_BIND_ADDRESS` | `127.0.0.1` | Host IPv4 address used for published services |
| `ADPUTATE_WEB_PORT` | `8080` | Host admin HTTP port |
| `ADPUTATE_DNS_PORT` | `5053` | Host DNS port for TCP and UDP |
| `ADPUTATE_IMAGE` | `pihole/pihole:2026.07.2` | Pi-hole image tag |
| `ADPUTATE_MEMORY` | `256M` | Container memory limit |
| `ADPUTATE_ROUTER_INTERFACE` | detected | LAN interface used by the port-53 frontend |
| `ADPUTATE_APP_DIR` | `~/Library/Application Support/Adputate` | Runtime configuration, logs, and backups |
| `CONTAINER_BIN` | auto-detected | Apple Container executable |

Persist a LAN configuration before creating the container:

```bash
bin/adputate configure --bind-address <mac-lan-ip> --web-port 18080 \
  --dns-port 5053 --router-interface <interface>
bin/adputate config
bin/adputate doctor
bin/adputate start
```

If persisted values no longer match the existing container, lifecycle commands refuse to proceed and `status` reports the exact drift. Review it, then run `bin/adputate reconcile --yes`; named volumes are preserved.

## Network Architecture and Trust

Adputate has two distinct DNS roles:

```text
Mac applications
  -> every physical macOS network service uses 127.0.0.1:53
  -> host-only native frontend
  -> Pi-hole on an unprivileged loopback backend port

LAN clients
  -> one explicitly trusted, stable LAN address on port 53
  -> router-facing native frontend
  -> the same Pi-hole backend
```

The host-only path is intended to follow the Mac between Wi-Fi, Ethernet, and untrusted networks without exposing DNS to those networks. Adputate should back up and configure every physical macOS network service to use the loopback listener. VPN-created and other virtual services are not changed automatically because they may require scoped or organization-managed DNS. A newly installed physical network service should be reported by `doctor` until it is protected or explicitly excluded.

The router-facing path is different: it listens on exactly one explicitly trusted LAN address, never on every interface or a wildcard address. That address needs a DHCP reservation or static assignment before a router advertises it to clients. Moving between Wi-Fi and USB Ethernet does not require exposing DNS on both; both host network services continue to use the local loopback path, while the router continues to use the one stable server path. That selected link—normally Ethernet for a server—must remain connected for LAN clients; automatic router-facing failover is not implied.

This policy deliberately has no public secondary resolver. macOS clients do not reliably treat listed DNS servers as ordered primary and fallback choices, so adding one could silently bypass blocking. If the local service is unhealthy, DNS should fail visibly and recovery or uninstall should restore the exact saved settings.

> [!IMPORTANT]
> This is the target architecture. The current milestone implementation still uses one bind address for the Pi-hole backend and router frontend, and `dns-enable` manages one macOS network service at a time. A loopback frontend plus transactional multi-service DNS configuration must be implemented and tested before roaming protection is complete.

## The Publish Path

The container is deliberately never given a privileged host port:

```text
LAN client :53 (UDP/TCP)
  -> native LaunchDaemon frontend on <mac-lan-ip>:53
  -> Apple Container publish on <mac-lan-ip>:5053
  -> Pi-hole container :53

Browser -> <mac-lan-ip>:18080 -> Pi-hole container :80
```

The native frontend opens only the configured LAN address, then drops from root to macOS's `nobody` account. It validates DNS transaction IDs, caps concurrent work, applies I/O timeouts, and forwards both UDP and TCP. Keeping Apple Container on an unprivileged backend port avoids relying on privileged publication inside its VM networking path and makes each layer independently testable.

## Health and Diagnostics

`doctor` is non-destructive. It checks:

- Host architecture and macOS version
- Apple Container version and service reachability
- Required macOS commands
- Port numbers, conflicts, and privileged-port constraints
- Bind-address ownership
- Image pinning
- Runtime data-path writability
- Stale or missing LaunchAgent configuration
- Active Cloudflare WARP or iCloud Private Relay DNS-path overrides

`health` returns a nonzero status unless all of these checks pass:

- The container exists and is running.
- Pi-hole's FTL API responds inside the container.
- The admin HTTP endpoint responds without using a configured host proxy.
- DNS responds over UDP.
- DNS responds over TCP.
- When installed, the router-facing frontend responds over UDP and TCP on port 53.

## Verified Networking Behavior

The following behavior has been verified on the versions listed above:

- LAN publishing on an unprivileged port works over TCP and UDP.
- A second isolated container resolved external names through the Mac's LAN-facing listener.
- A physically separate LAN machine passed external UDP, external TCP, blocked-domain, and admin HTTP checks against the unprivileged backend.
- Pi-hole returned `0.0.0.0` for a domain on its blocklist.
- Stopping the container makes `health` fail; restarting restores all health checks.
- Direct publication of `127.0.0.1:53` collided with Apple Container's networking path.
- Direct publication of a LAN address on port 53 was rejected because host ports below 1024 require root privileges.
- The native frontend resolves and blocks locally over UDP and TCP port 53.

The final port-53 path must still be tested from a physically separate LAN client after `router-install`; local success cannot prove that a host firewall or network policy permits incoming traffic.

## Commands

```text
doctor                      Validate prerequisites and configuration
health                      Check API, HTTP, UDP DNS, and TCP DNS
smoke                       Test registry access with a small ARM container
init                        Create runtime configuration
configure [options]         Persist desired runtime configuration
config                      Print desired runtime configuration
start | stop | restart      Manage the Pi-hole container
reconcile --yes             Recreate a drifted container, preserving volumes
status | logs | shell       Inspect the running service
admin | admin-url           Open or print the admin endpoint
dns-url                     Print the DNS endpoint
password                    Print the generated Pi-hole admin password
blocking-status             Report Pi-hole blocking state
enable | disable [duration] Control Pi-hole blocking
teleporter-export [dir]     Export a Teleporter archive
teleporter-import <zip>     Import a Teleporter archive
upgrade <image> --yes       Backup, upgrade, verify, and roll back on failure
router-install              Install the supervised port-53 frontend
router-preflight            Diagnose port-53 owners and DNS interceptors
router-status               Check UDP/TCP port 53
router-uninstall            Remove the port-53 frontend
dns-enable <service>        Save macOS DNS and use Adputate
dns-disable                 Restore the saved macOS DNS configuration
launchd-plist               Render the LaunchAgent plist
service-install             Install and start the user LaunchAgent
service-enable              Enable login startup
service-disable             Disable login startup
service-kick                Run the installed job now
service-status              Report LaunchAgent state
service-uninstall           Remove the user LaunchAgent
reset                       Delete the container but preserve volumes
uninstall --yes             Restore DNS and remove services, data, and images
uninstall --yes --keep-images
                            Remove everything except cached container images
uninstall-audit             Report any Adputate artifacts still installed
```

The LaunchAgent records an absolute path to the CLI. Run `bin/adputate service-install` again after moving or renaming the checkout.

## Clean Uninstall

`uninstall --yes` is designed to return the Mac to a state suitable for testing a fresh installation:

```bash
bin/adputate uninstall --yes
bin/adputate uninstall-audit
```

It restores DNS saved by `dns-enable`, removes the system LaunchDaemon and Application Firewall registration, removes the user LaunchAgent, deletes the container and named volumes, removes runtime configuration/backups/logs, and deletes the Pi-hole and smoke-test images. Images that are still used by another container are retained and reported as a cleanup failure rather than being forcibly deleted.

Use `--keep-images` when the image cache is intentionally shared. Adputate stops Apple Container services only when it recorded that it started them and no other containers remain.

The source checkout and Apple Container installation are not removed. Router DHCP/DNS settings are external and must be restored separately. macOS may retain ordinary unified logs and a harmless historical launchd enable/disable preference; `uninstall-audit` reports the latter as a warning.

## Milestone 0: Dependable Standalone Server

The standalone server path is implemented. Before calling Milestone 0 production-ready, it still needs:

- A successful UDP/TCP port-53 test from a physically separate LAN client
- Reboot and sleep/wake testing with the LaunchAgent and LaunchDaemon installed
- DHCP-address-change and deliberate backend/frontend failure testing
- A stable installer outside a source checkout
- Signed and notarized packaging

After that milestone, planned work includes optional [Nebula Sync](https://github.com/lovelaze/nebula-sync) integration, primary-to-replica synchronization, drift detection, and health-aware failover. The dedicated Pi-hole should remain authoritative by default.

## Project Layout

```text
bin/adputate                         Shell CLI
containers/manifest.toml            Deployment manifest
containers/*.env.example            Configuration examples
packaging/launchd/*.plist.template  LaunchAgent template
packaging/router/                    Native port-53 proxy and installer
project.env                          Project identity
tests/                               Shell integration tests
.github/workflows/ci.yml             macOS CI
```

Operational recovery procedures are in [Recovery](docs/recovery.md).

## Acknowledgements

Adputate builds on:

- [Pi-hole](https://pi-hole.net/) and its [official container image](https://github.com/pi-hole/docker-pi-hole)
- [Apple Container](https://github.com/apple/container)
- [DesktopECHO/PiCon](https://github.com/DesktopECHO/PiCon), which demonstrated the practicality of a self-contained Pi-hole appliance on macOS
- [Nebula Sync](https://github.com/lovelaze/nebula-sync) for the planned Pi-hole v6 synchronization path

Adputate is not affiliated with or endorsed by Pi-hole, Apple, PiCon, or Nebula Sync.

## License

MIT. See [LICENSE](LICENSE).
