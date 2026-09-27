# Adputate

Pi-hole for Apple Silicon Macs, using Apple's native container runtime.

Adputate is an experimental macOS wrapper around the official Pi-hole container image. It provides a dependable standalone DNS server plus a portable controller for operating that replica alongside an existing Pi-hole v6 authority.

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
- Keep a readable inventory of Pi-hole authorities and replicas, with credentials in macOS Keychain.
- Query recent logs from every active Pi-hole into local JSON and grep-friendly text snapshots.
- Read and change blocking state across all active Pi-holes with per-node verification.

The implementation has been tested with:

- Apple Silicon and macOS 26.6.2
- Apple `container` 1.2.2
- `pihole/pihole:2026.07.2` on `linux/arm64`

## Requirements

Controller-only operation needs macOS and its standard `curl`, `dig`, Keychain, and network tools. It does not need Apple Container.

Hosting a Pi-hole on the same Mac additionally needs:

- An Apple Silicon Mac
- macOS 26 or newer
- Apple's [`container`](https://github.com/apple/container) CLI, version 1.x

Building Adputate from source needs Xcode Command Line Tools. The native port-53 frontend is compiled once by `make build`; privileged host installation copies that already-built executable and never invokes a compiler as root.

Install Apple Container from its signed release package, start its system service, and confirm that `container --version` works before using Adputate.

Before installation, disconnect Cloudflare WARP and turn off iCloud Private Relay (or turn off **Limit IP Address Tracking** for the active network). Both can take control of macOS DNS independently of the DNS servers shown in Network settings. Adputate's service, router frontend, and macOS DNS installation commands stop before making changes when either override is active; they never change those products' settings themselves. WARP may remain installed while disconnected.

## Getting Adputate (current pre-release)

Adputate does not yet have a Homebrew formula or numbered release. A new machine currently starts from the source repository, but the installed command no longer depends on the checkout remaining in place.

There is not yet a canonical public clone URL configured for this repository. Until one is published, copy the checkout to the target Mac or clone it from the development remote supplied by the project owner, then run:

```bash
cd adputate
make test
make install PREFIX="$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
adputate install
```

`make build` compiles the native DNS frontend with the selected `CC`, `CPPFLAGS`, `CFLAGS`, and `LDFLAGS`. `make install PREFIX=...` installs a self-contained tree containing the CLI, templates, container metadata, and built frontend. The launcher resolves symbolic links before finding that tree, so it works both from an ordinary prefix and through Homebrew's versioned Cellar links.

For system-wide source installation, choose a writable staging prefix or run only the final `make install` with the required privileges. Adputate itself should still be run as the ordinary operator account; it requests elevation only for its explicitly privileged port-53 frontend.

The eventual Homebrew distribution uses two repositories:

1. The main `adputate` repository contains all source, tests, documentation, and numbered release tags.
2. A small `homebrew-adputate` repository contains only the Homebrew formula and bottle metadata.

Until acceptance into `homebrew/core`, installation from that second repository will require explicit formula-level trust with `brew trust --formula OWNER/adputate/adputate`. The tap is intentionally deferred until a canonical GitHub location and first numbered release exist.

## Install and configure

Run one interactive installer:

```bash
bin/adputate install
```

It asks two independent questions:

1. Which existing Pi-hole nodes should Adputate manage? Each is assigned an explicit authority or replica role, fixed API and DNS endpoints, and an optional application password stored in Keychain.
2. Should this Mac also run a Pi-hole?

Answering no to the second question is a complete, supported installation. An operator workstation does not need Apple Container, a local Pi-hole, privileged ports, or startup services. It can manage a single existing NUC, manage several remote Pi-holes, search their logs, coordinate blocking, and point its own selected network service at them.

Answering yes initializes local host configuration and prints the independently verifiable host-install stages: review/configure, doctor, start, explicit replica registration, login recovery service, and the privileged port-53 frontend. The installer does not silently perform those privilege- or network-changing stages.

## Pi-hole host quick start

```bash
bin/adputate host doctor
bin/adputate host start
bin/adputate host health
bin/adputate host password
bin/adputate host admin
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
| `ADPUTATE_UPSTREAMS` | router-provided | Explicit Pi-hole upstream override, separated by commas or semicolons |
| `ADPUTATE_APP_DIR` | `~/Library/Application Support/Adputate` | Runtime configuration, logs, and backups |
| `ADPUTATE_ISSUES_URL` | unset | GitHub issue form opened by `bugreport --open` |
| `CONTAINER_BIN` | auto-detected | Apple Container executable |

On a fresh local-host configuration, Adputate uses the DNS resolvers supplied by DHCP on the default-route interface. If DHCP does not expose a resolver list, it uses that interface's default router address. The resolved addresses and their source are persisted and shown by both `host config` and `config show`; a later network change does not silently rewrite a running Pi-hole. Run `adputate host configure --upstreams router` to deliberately refresh the choice.

This default preserves the network operator's existing DNS policy, including local names and split-horizon behavior, instead of silently choosing a public resolver vendor. Cloudflare and Quad9 are ordinary explicit choices, not Adputate policy:

```bash
adputate host configure --upstreams '1.1.1.1;9.9.9.9'
```

Lists may be comma- or semicolon-separated and each entry may use Pi-hole's `address#port` form. Adputate rejects loopback, this host's Pi-hole address, and every configured Pi-hole endpoint as a direct upstream. It cannot see an indirect loop inside a router: if the router itself forwards DNS back to this Pi-hole, choose independent upstreams explicitly.

Persist a LAN configuration before creating the container:

```bash
bin/adputate host configure --bind-address <mac-lan-ip> --web-port 18080 \
  --dns-port 5053 --router-interface <interface> --upstreams router
bin/adputate host config
bin/adputate host doctor
bin/adputate host start
bin/adputate host register adputate
```

If persisted values no longer match the existing container, lifecycle commands refuse to proceed and `host status` reports the exact drift. Review it, then run `bin/adputate host reconcile --yes`; named volumes are preserved.

## Pairing an existing Pi-hole

Adputate uses one CLI surface. Top-level commands operate the configured Pi-hole group from an ordinary workstation; `adputate host ...` commands administer the Mac that actually hosts the Adputate container. Routine status, blocking, and query-log work does not require SSH.

Pi-hole's built-in local web/DNS name is `pi.hole`. A name such as `adblocker.local` is instead the Linux machine hostname advertised through mDNS. In container installations, `pi.hole` may resolve to a container-internal address, so discovery treats it only as an identity signal and retains the independently validated LAN address as the endpoint.

First inspect candidates without changing configuration:

```bash
bin/adputate discover
```

Create a Pi-hole application password on the existing authority, then store it without placing it in shell history (the final `-w` causes an interactive prompt):

```bash
/usr/bin/security add-generic-password \
  -U \
  -a nuc \
  -s com.adputate.pihole.instance \
  -l "Adputate: NUC Pi-hole API" \
  -w
```

Enroll the authority using its fixed LAN address. This reads the password from Keychain without printing it:

```bash
/usr/bin/security find-generic-password -w \
  -a nuc -s com.adputate.pihole.instance | \
  bin/adputate instance add nuc \
    --name "NUC Pi-hole" \
    --role authority \
    --api-url http://<nuc-lan-ip> \
    --dns <nuc-lan-ip>#53 \
    --password-stdin
```

Verify both Pi-holes and perform routine operations:

```bash
bin/adputate status
bin/adputate query example.com              # one-hour window by default
bin/adputate blocking disable 5m
bin/adputate blocking enable
```

Each active Pi-hole query request currently asks for at most 10,000 records. Adputate does not paginate or report truncation yet, so a busy Pi-hole can produce an incomplete snapshot even inside the default one-hour window. Use a shorter `--since` window when completeness matters until pagination is implemented.

To point only this Mac at the configured Pi-hole group, first review the plan and then apply it explicitly:

```bash
bin/adputate client dns plan
bin/adputate client dns apply --yes
bin/adputate client dns restore --yes
```

DNS settings on macOS belong to individual network services. With no `--service`, Adputate selects only the active physical service carrying the default route. It does not modify Wi-Fi merely because Wi-Fi is also connected, and it never modifies VPN, bridge, phone-tethering, or other virtual/transient services. Select a different service explicitly with `--service "Wi-Fi"`.

Before applying, every active Pi-hole endpoint must answer DNS over UDP and TCP port 53. Adputate orders the authority first and replicas afterward, backs up whether the selected service used explicit DNS or DHCP-provided DNS, applies the complete endpoint set, verifies it, and restores the original state on failure. Ordering is for legibility and does not promise strict macOS primary/fallback behavior.

This first implementation detects default-route changes whenever `status`, `plan`, or `apply` runs; it does not continuously rewrite DNS in response to roaming, VPN, sleep/wake, or interface events. Continuous network-aware switching is deferred until those transitions have dedicated acceptance tests. A laptop should restore client DNS before leaving a network where the private Pi-hole addresses are reachable.

Non-secret controller configuration is deliberately legible under `~/Library/Application Support/Adputate/config`: `cluster.conf` contains defaults and `instances.d/<id>.conf` contains one endpoint per Pi-hole. Passwords remain in Keychain. Query snapshots are stored under `query-snapshots/<timestamp>` as raw JSON plus searchable text.

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
> This is the target architecture. The current milestone implementation still uses one bind address for the Pi-hole backend and router frontend, and `client dns apply` manages one macOS network service at a time. A loopback frontend plus transactional multi-service DNS configuration must be implemented and tested before roaming protection is complete.

## Native DNS Proxy

`adputate-dns-proxy` is the small native program called the **native frontend** or **port-53 frontend** elsewhere in this document. It forwards DNS over TCP and UDP from one Mac LAN address on port 53 to one Pi-hole backend on an unprivileged port. It is not a resolver, cache, filter, policy engine, or database; Pi-hole remains responsible for resolving and blocking every query.

The proxy exists because routers and ordinary DNS clients expect their server on port 53, while Apple Container cannot publish the Pi-hole backend on that privileged host port as an ordinary user. Running the container runtime or the whole Pi-hole service as root would grant far more code privilege than this job requires. Adputate instead confines root privilege to a deliberately small native process: it binds exactly the configured LAN address on port 53, then drops to macOS's `nobody` account before forwarding traffic to the unprivileged container backend.

The current implementation has one configured IPv4 backend and deliberately provides no public-DNS fallback, caching, load balancing, or failover. If Pi-hole or its backend port is unavailable, client queries time out visibly instead of bypassing filtering. Launchd restarts a crashed proxy, but it does not select a different Pi-hole. The currently shipped proxy is the router-facing frontend; the separate loopback-only frontend described in the target architecture above has not yet been implemented.

The proxy limits each backend operation to four seconds, accepts at most 128 concurrent forwarding workers, caps UDP packets at 4096 bytes, validates that replies have the query's transaction ID and DNS response flag, and handles one request per TCP connection. It currently supports IPv4 only. These limits keep the privileged network boundary small and predictable; they are not intended to replace a general-purpose DNS proxy.

`make build` compiles the proxy before any privileged installation occurs. `adputate host router preflight` checks the selected address, interface, and existing TCP/UDP port-53 listeners. `host router install` copies the built executable into a root-owned support directory and installs its system LaunchDaemon; `host router status` probes the resulting path over both UDP and TCP. Runtime output is written to `/var/log/adputate-dns-forwarder.log`. `host router uninstall` unloads the daemon and removes the installed proxy, log, and privileged support files.

## The Publish Path

The container is deliberately never given a privileged host port:

```text
LAN client :53 (UDP/TCP)
  -> native LaunchDaemon frontend on <mac-lan-ip>:53
  -> Apple Container publish on <mac-lan-ip>:5053
  -> Pi-hole container :53

Browser -> <mac-lan-ip>:18080 -> Pi-hole container :80
```

Keeping Apple Container on an unprivileged backend port avoids relying on privileged publication inside its VM networking path and makes each layer independently testable.

## Health and Diagnostics

`doctor` is non-destructive. It checks:

- Host architecture and macOS version
- Apple Container version and service reachability
- Required macOS commands
- Port numbers, conflicts, and privileged-port constraints
- Bind-address ownership
- Image pinning
- Persisted upstream syntax, direct-loop conflicts, and direct DNS reachability
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

## Bug Reports

`adputate bugreport` creates a sanitized Markdown report, saves it under `~/Library/Application Support/Adputate/bugreports` with private file permissions, and copies the same text to the macOS clipboard. It then prints the saved path and configured issue URL. It never uploads, emails, or submits anything.

The report contains Adputate, macOS, architecture, and Apple Container versions; coarse service-installation state; an instance count; and instance roles, enabled state, authentication mode, and transport. It deliberately excludes passwords, Keychain contents, DNS queries, domain names, Pi-hole endpoint addresses, hostnames, usernames, and raw environment variables. Review the saved copy before pasting it into a public issue.

`adputate bugreport --open` performs the same local generation and clipboard copy, then opens `ADPUTATE_ISSUES_URL`. It still does not paste or submit the issue. Until the canonical GitHub repository exists and that URL is configured, ordinary `bugreport` remains useful but `--open` stops after copying the report and explains that the tracker is not configured.

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

The final port-53 path must still be tested from a physically separate LAN client after `host router install`; local success cannot prove that a host firewall or network policy permits incoming traffic.

## Commands

```text
status                      Reachability and blocking state for every active node
config show                 Controller paths, defaults, and instance inventory
discover                    Validate advertised DNS servers as Pi-hole candidates
instance list|add|remove    Manage explicit authority/replica endpoints
query <text> [--since 1h]   Snapshot all active nodes, then search local files
query snapshot [--since 1h] Collect without searching
blocking status             Read every active node
blocking disable 5m         Timed cluster-wide bypass with verification
blocking enable             Enable and verify every active node
bugreport [--open]          Save and copy sanitized diagnostics; optionally open issues

host config|doctor|health|status
                            Inspect the local Adputate container host
host start|ensure|stop|restart
                            Manage or idempotently recover the local service
host configure [options]    Persist the local container configuration
host register [id]          Explicitly register this host as a replica
host service install|uninstall|enable|disable|kick|status|plist
                            Manage login startup and periodic recovery
host sync configure --yes|status|now|pause|resume|logs|remove --yes
                            Manage selective NUC-to-local policy replication
host router install|preflight|status|uninstall
                            Manage the native port-53 frontend
install                     Choose local protection or configure existing nodes
install --local --yes        Start and verify local DNS protection on this Mac
client dns status|plan      Show the selected service and proposed DNS endpoints
client dns apply --yes      Back up and apply the active Pi-hole endpoint set
client dns restore --yes    Restore the exact previous DNS/DHCP state
host teleporter export [dir]|import <zip>
host upgrade <image> --yes|reset
host uninstall --yes [--keep-images]|uninstall-audit
                            Remove/audit only this Mac's hosted Pi-hole
uninstall --yes|uninstall-audit
                            Remove/audit all controller and host state
```

The user LaunchAgent runs `adputate host ensure` at login and every 60 seconds to recover Apple Container and Pi-hole after a crash. Apple Container is user-scoped, so service begins only after that Mac user logs in; an unattended host needs automatic login or an explicit post-reboot login procedure. The job records the stable launcher found in `PATH` (or `ADPUTATE_LAUNCHER` when explicitly set), so a Homebrew upgrade can move the versioned installation without leaving launchd pointed at the old Cellar.

## Clean Uninstall

There are deliberately two cleanup scopes:

```bash
adputate host uninstall --yes
adputate host uninstall-audit
```

Host cleanup restores saved client DNS, removes the system LaunchDaemon and Application Firewall registration, removes the user LaunchAgent, deletes the local container and named volumes, removes local-host runtime configuration and registration, and deletes only image-cache entries that Adputate recorded pulling itself. Pre-existing or shared images are left alone. Remote Pi-hole endpoints, controller defaults, and query snapshots are preserved, so the Mac can continue as a controller.

To remove the controller as well:

```bash
adputate uninstall --yes
adputate uninstall-audit
```

Full cleanup first performs any required host cleanup, then removes every Adputate-owned Pi-hole credential from Keychain and deletes the controller inventory, DNS backup, and query snapshots. After its audit passes, the packaged executable can be removed with the package manager. Images that are still used by another container are retained and reported as a cleanup failure rather than being forcibly deleted.

Use `--keep-images` when the image cache is intentionally shared. Adputate stops Apple Container services only when it recorded that it started them and no other containers remain.

Neither cleanup scope removes Apple Container itself. Router DHCP/DNS settings are external and must be restored separately. A source checkout or Homebrew package is also left in place because deleting the running program is the package manager's responsibility. After `adputate uninstall --yes` succeeds, remove a source installation with `make uninstall PREFIX="$HOME/.local"`; a future Homebrew installation should be removed with `brew uninstall adputate`. macOS may retain ordinary unified logs and a harmless historical launchd enable/disable preference; the audit reports the latter as a warning.

## Local Protection Without an Existing Pi-hole

Run `adputate install --local --yes` to start a localhost-only Pi-hole, install its
port-53 frontend, and connect this Mac's DNS. Setup verifies a macOS system lookup
in Pi-hole's query log and restores the previous DNS settings if verification
fails. See [local protection setup and restoration](docs/local-protection.md) for
requirements, network-service selection, and limitations.

## Selective Policy Replication

The first Nebula Sync lifecycle is implemented for the primary deployment: exactly one active remote authority, such as the NUC, and exactly one active Adputate-managed local replica. It uses the pinned `ghcr.io/lovelaze/nebula-sync:v0.11.2` image and selective one-way synchronization. Groups, adlists, domain allow/deny entries, and their group mappings are copied from the authority. DNS listeners, upstreams, web settings, credentials, DHCP, NTP, database/privacy settings, blocking state, clients, and client mappings remain node-local.

Configure it on the always-on Mac that hosts the replica:

```bash
adputate host sync configure --yes
adputate host sync status
adputate host sync now
# Read both Pi-holes and compare groups, adlists, domains, and group mappings.
# This does not change either Pi-hole.
adputate host sync verify
adputate host sync resume
```

Configuration starts paused and the first command copies no policy. `sync now` is the explicit first synchronization; `sync resume` enables the five-minute default schedule. The existing login recovery LaunchAgent checks whether a run is due every minute, catches up after downtime, and prevents overlapping runs. `pause`, `logs`, and `remove --yes` complete the lifecycle. State and bounded logs identify the last attempt, last success, duration, and freshness.

Passwords are read from Keychain and the managed local Pi-hole environment only when a run begins. Adputate writes them to a mode-0600 temporary environment file, supplies that file to an ephemeral read-only Nebula Sync container, and removes it when the run exits. The generated environment uses `FULL_SYNC=false`; continuous/full Teleporter synchronization is deliberately prohibited because it could overwrite node-local settings. Nebula Sync requires elevated application-password API permission on replicas, so configuration explicitly enables Pi-hole's `webserver.api.app_sudo` on the managed local replica.

Scheduled operation does not require SSH. Manual sync lifecycle commands currently run on the Mac Studio itself, so invoking `sync now` or reading its local state from a controller-only laptop still requires an SSH session. Top-level status, query, blocking, and client-DNS commands remain controller operations and do not require SSH.

## Current Limitations

- The recovery LaunchAgent runs after its operator logs in; it is not an independent pre-login boot service.
- The native port-53 frontend is IPv4-only, forwards to one configured backend, and does not provide automatic Pi-hole failover.
- `client dns apply` changes one selected physical macOS network service and does not continuously react to roaming, VPN, sleep/wake, or interface changes.
- A cluster-wide blocking change preflights every active node and verifies the result, but it cannot be atomic if a node fails during the operation.
- Remote Pi-hole application/API passwords are stored in Keychain, but there is not yet a credential-rotation command. Replacing a remote password currently requires removing and recreating its endpoint registration. The generated password for a Pi-hole hosted on this Mac is a separate credential exposed by `adputate host password`.
- Query snapshots are limited to 10,000 records per Pi-hole request and are not paginated yet.
- Nebula Sync is pinned to a release tag but not yet to an immutable image digest, and real two-machine policy-convergence testing remains outstanding.
- Nebula Sync currently supports one remote authority and one managed-local replica; manual lifecycle control is host-local.
- The physical-client, reboot, sleep/wake, DHCP-address-change, and deliberate failure tests listed below remain release gates.

## Milestone 0: Dependable Standalone Server

The standalone server path is implemented. Before calling Milestone 0 production-ready, it still needs:

- A successful UDP/TCP port-53 test from a physically separate LAN client
- Reboot and sleep/wake testing with the LaunchAgent and LaunchDaemon installed
- DHCP-address-change and deliberate backend/frontend failure testing
- A numbered, checksummed release and Homebrew tap
- Signed and notarized packaging

Milestone 1 now includes an experimental, selectively allowlisted [Nebula Sync](https://github.com/lovelaze/nebula-sync) lifecycle. Immutable digest pinning, real primary-to-replica convergence testing, richer drift reporting, and health-aware failover remain. The dedicated Pi-hole stays authoritative by default.

## Project Layout

```text
bin/adputate                         Relocation-safe launcher
libexec/adputate.sh                  Shell CLI implementation
Makefile                             Reproducible build, test, and install entry points
VERSION                              Installed version metadata
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
- [Nebula Sync](https://github.com/lovelaze/nebula-sync) for selective Pi-hole v6 policy synchronization

Adputate is not affiliated with or endorsed by Pi-hole, Apple, PiCon, or Nebula Sync.

## License

MIT. See [LICENSE](LICENSE).
