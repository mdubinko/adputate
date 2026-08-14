# Adputate

Pi-hole for Apple Silicon Macs, using Apple's native container runtime.

Adputate is an experimental macOS wrapper around the official Pi-hole container image. Its first milestone is a dependable standalone DNS server with explicit health checks, persistent data, backups, and safe lifecycle management. Primary/replica synchronization can come later.

> [!WARNING]
> Adputate is not ready to become a router's only DNS server. Pi-hole works over a LAN-bound unprivileged port, but router-compatible TCP/UDP port 53 still needs a supervised privileged forwarding layer. Keep a working secondary resolver while testing.

## Status

The current shell CLI can:

- Validate host, runtime, configuration, ports, and LaunchAgent prerequisites.
- Start and stop a pinned Pi-hole container.
- Persist Pi-hole data in Apple container named volumes.
- Check the Pi-hole API, admin HTTP endpoint, and DNS over UDP and TCP.
- Enable or disable blocking and report blocking status.
- Export and import Pi-hole Teleporter archives.
- Install and manage a per-user LaunchAgent.
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

Install Apple Container from its signed release package, start its system service, and confirm that `container --version` works before using Adputate.

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

Runtime state is stored under `~/Library/Application Support/Adputate`. Pi-hole configuration is stored in Apple container named volumes rather than inside the repository.

## Configuration

The CLI reads project identity from `project.env`. Runtime settings can be overridden in the environment:

| Variable | Default | Purpose |
|---|---:|---|
| `ADPUTATE_BIND_ADDRESS` | `127.0.0.1` | Host IPv4 address used for published services |
| `ADPUTATE_WEB_PORT` | `8080` | Host admin HTTP port |
| `ADPUTATE_DNS_PORT` | `5053` | Host DNS port for TCP and UDP |
| `ADPUTATE_IMAGE` | `pihole/pihole:2026.07.2` | Pi-hole image tag |
| `ADPUTATE_MEMORY` | `256M` | Container memory limit |
| `ADPUTATE_APP_DIR` | `~/Library/Application Support/Adputate` | Runtime configuration, logs, and backups |
| `CONTAINER_BIN` | auto-detected | Apple Container executable |

For an experimental LAN-bound instance on an unprivileged port:

```bash
ADPUTATE_BIND_ADDRESS=<mac-lan-ip> \
ADPUTATE_WEB_PORT=18080 \
ADPUTATE_DNS_PORT=5053 \
bin/adputate doctor

ADPUTATE_BIND_ADDRESS=<mac-lan-ip> \
ADPUTATE_WEB_PORT=18080 \
ADPUTATE_DNS_PORT=5053 \
bin/adputate start
```

Use the same overrides with `health`, `status`, `admin-url`, and `dns-url`.

Changing these settings does not reconfigure an existing container yet. Stop and reset the container before recreating it with different publishing settings. `reset` preserves named-volume data; `uninstall --yes` deletes it.

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

`health` returns a nonzero status unless all of these checks pass:

- The container exists and is running.
- Pi-hole's FTL API responds inside the container.
- The admin HTTP endpoint responds without using a configured host proxy.
- DNS responds over UDP.
- DNS responds over TCP.

## Verified Networking Behavior

The following behavior has been verified on the versions listed above:

- LAN publishing on an unprivileged port works over TCP and UDP.
- A second isolated container resolved external names through the Mac's LAN-facing listener.
- Pi-hole returned `0.0.0.0` for a domain on its blocklist.
- Stopping the container makes `health` fail; restarting restores all health checks.
- Direct publication of `127.0.0.1:53` collided with Apple Container's networking path.
- Direct publication of a LAN address on port 53 was rejected because host ports below 1024 require root privileges.

Router-compatible service therefore needs a small privileged host component that forwards LAN TCP/UDP port 53 to Pi-hole's unprivileged published port. It must be supervised, preserve a recovery path, and be tested from a physically separate LAN client before router deployment.

## Commands

```text
doctor                      Validate prerequisites and configuration
health                      Check API, HTTP, UDP DNS, and TCP DNS
smoke                       Test registry access with a small ARM container
init                        Create runtime configuration
start | stop | restart      Manage the Pi-hole container
status | logs | shell       Inspect the running service
admin | admin-url           Open or print the admin endpoint
dns-url                     Print the DNS endpoint
password                    Print the generated Pi-hole admin password
blocking-status             Report Pi-hole blocking state
enable | disable [duration] Control Pi-hole blocking
teleporter-export [dir]     Export a Teleporter archive
teleporter-import <zip>     Import a Teleporter archive
launchd-plist               Render the LaunchAgent plist
service-install             Install and start the user LaunchAgent
service-enable              Enable login startup
service-disable             Disable login startup
service-kick                Run the installed job now
service-status              Report LaunchAgent state
service-uninstall           Remove the user LaunchAgent
reset                       Delete the container but preserve volumes
uninstall --yes             Delete the container, volumes, and runtime data
```

The LaunchAgent records an absolute path to the CLI. Run `bin/adputate service-install` again after moving or renaming the checkout.

## Milestone 0: Dependable Standalone Server

Before paired-primary synchronization, the project still needs:

- A supervised privileged TCP/UDP port-53 forwarding layer
- Safe macOS DNS backup, enable, disable, and automatic restoration
- Persistent runtime configuration and container-drift reconciliation
- Readiness handling during startup
- Backup-first image upgrade and rollback
- Automated shell tests and macOS integration tests
- Stable installation outside a source checkout
- Reboot, sleep/wake, DHCP-address-change, and failure-injection testing
- Signed and notarized packaging

After that milestone, planned work includes optional [Nebula Sync](https://github.com/lovelaze/nebula-sync) integration, primary-to-replica synchronization, drift detection, and health-aware failover. The dedicated Pi-hole should remain authoritative by default.

## Project Layout

```text
bin/adputate                         Shell CLI
containers/manifest.toml            Deployment manifest
containers/*.env.example            Configuration examples
packaging/launchd/*.plist.template  LaunchAgent template
project.env                          Project identity
tests/                               Future automated tests
```

## Acknowledgements

Adputate builds on:

- [Pi-hole](https://pi-hole.net/) and its [official container image](https://github.com/pi-hole/docker-pi-hole)
- [Apple Container](https://github.com/apple/container)
- [DesktopECHO/PiCon](https://github.com/DesktopECHO/PiCon), which demonstrated the practicality of a self-contained Pi-hole appliance on macOS
- [Nebula Sync](https://github.com/lovelaze/nebula-sync) for the planned Pi-hole v6 synchronization path

Adputate is not affiliated with or endorsed by Pi-hole, Apple, PiCon, or Nebula Sync.

## License

MIT. See [LICENSE](LICENSE).
