# Milestone 1 working plan: paired Pi-hole operation

Status: implementation in progress; controller foundation complete  
Primary scenario: an existing, normally always-on Pi-hole on a NUC paired with an Adputate-managed Pi-hole on a Mac  
Direction: NUC is the configuration authority; Adputate is the replica

## Implemented controller foundation (2026-08-19)

The first Milestone 1 slice deliberately uses one CLI, not separate local and remote programs:

```text
adputate status
adputate config show
adputate discover
adputate instance list|add|remove
adputate query <text> [--since 1h]
adputate blocking status|disable 5m|enable

adputate host ...
```

The top-level commands are portable controller operations. They call the Pi-hole v6 APIs directly and can run from the normal operator workstation after its instance inventory and Keychain credentials have been configured. SSH is not part of the normal query, status, or blocking workflow. `adputate host ...` is reserved for operations on the Mac that actually runs the Adputate container, port-53 frontend, and launchd jobs.

Instance enrollment is explicit. `adputate discover` examines DNS servers advertised to the current Mac and validates candidates with the Pi-hole identity endpoint, but never changes configuration. This handles the useful case where DHCP advertises Pi-hole directly while remaining honest when DHCP advertises only a router.

Configuration is intentionally human-readable:

- controller defaults: `~/Library/Application Support/Adputate/config/cluster.conf`;
- one non-secret file per Pi-hole: `config/instances.d/<id>.conf`;
- passwords: macOS Keychain, never the instance files; and
- query snapshots: `query-snapshots/<timestamp>/<instance>.json` plus a grep-friendly `.txt` file.

The Mac host is explicitly registered as a `replica`; it is not silently inferred. Exactly one explicitly configured node may have the `authority` role.

The Adputate host LaunchAgent now runs `adputate host ensure` at login and every 60 seconds. The command is idempotent and restores the user-scoped Apple Container service and Pi-hole container after a crash or OS upgrade. Because Apple Container is user-scoped, DNS service begins after that Mac user logs in; an unattended Mac Studio therefore needs automatic login or an accepted post-reboot login procedure. The native port-53 frontend remains a system LaunchDaemon, but cannot answer usefully until its Pi-hole backend is available.

## Outcome

Milestone 1 makes two Pi-holes behave like one understandable DNS service without weakening Milestone 0's standalone behavior.

At completion, Adputate will:

- pair with and authenticate to another Pi-hole v6 instance;
- replicate an explicitly allowlisted set of shared policy from the primary to the replica;
- perform operational actions, especially temporary blocking disablement, across both nodes;
- report cluster health, sync health, version compatibility, and partial failures;
- search both query logs from one command for day-to-day troubleshooting; and
- uninstall its pairing components and credentials cleanly without modifying or removing the existing NUC installation.

Milestone 0 remains a supported configuration. Pairing is optional, and loss of either Pi-hole or the sync process must not prevent the other Pi-hole from serving its last known configuration.

## Product principles

1. **One configuration authority.** Milestone 1 is one-way replication, not multi-master merge. The NUC is primary by default and the Adputate instance is a replica.
2. **Shared policy is not machine configuration.** Blocklists and allow/deny policy may be replicated. Listener addresses, ports, interfaces, credentials, and other host-specific settings may not.
3. **DNS servers are peers, not strict active/standby servers.** Clients may query either configured resolver at any time. Both nodes therefore need consistent policy and coordinated operational state.
4. **No silent partial success.** Every cluster operation names each target and reports success, failure, or unavailability for each one.
5. **Last-good service beats forced convergence.** If sync fails, both DNS servers continue using their existing configurations.
6. **Secrets stay out of ordinary configuration files.** Pairing secrets are stored in macOS Keychain. Short-lived Pi-hole API sessions are closed after use.
7. **Short, filesystem-first query snapshots.** Milestone 1 pulls a bounded window (one hour by default) from every known active Pi-hole into a private local snapshot, then searches those files with standard filesystem grep tools. It introduces no query-log database.
8. **Pin every deployed artifact.** Pi-hole and Nebula Sync use tested versions or digests, never `latest`.

## Scope

### In scope

- Peer discovery hints plus explicit pairing and confirmation
- Pi-hole v6 API authentication and capability/version checks
- Keychain-backed application-password storage
- Cluster status and a paired form of `doctor`
- Cluster-wide blocking enable, disable, timer, and status operations
- Selective one-way policy replication
- Manual and scheduled sync, last-success state, and catch-up after sleep or downtime
- Federated query-log search and domain diagnosis
- An on-demand support bundle with clear privacy controls
- Install, upgrade, and clean-uninstall behavior for all Milestone 1 components
- Automated tests and a real two-machine acceptance test

### Explicitly out of scope

- Multi-master or bidirectional conflict resolution
- Automatic failover through a virtual IP
- DHCP high availability
- Continuous centralized log ingestion or a new log database
- Remote NUC host administration through SSH
- Remote collection of systemd, Docker, kernel, or other host logs
- A replacement for the full Pi-hole administration interface
- Automatic modification of the existing NUC installation beyond API-authorized policy changes
- Silent scanning of every device on the LAN

## Architecture

Milestone 1 has two deliberately separate planes.

### Policy plane

Nebula Sync performs selective, one-way replication from the NUC to Adputate. Adputate owns its configuration, lifecycle, scheduling, health reporting, and version pin.

The initial shared-policy allowlist is:

- groups;
- adlists;
- domain allow/deny entries, including regex entries;
- adlist-to-group mappings;
- domain-to-group mappings; and
- after validation, clients and client-to-group mappings.

Local DNS and CNAME records require an explicit product decision during implementation. If enabled, only their exact Pi-hole v6 configuration keys will be added to the allowlist.

The following remain node-local and must never be copied by the default profile:

- DNS listener mode, interfaces, addresses, and ports;
- webserver address, port, TLS, and authentication configuration;
- API passwords, application passwords, and sessions;
- DHCP server configuration and leases;
- NTP, debug, privacy, and database-retention settings;
- container environment-controlled settings;
- upstream resolvers unless the user explicitly adopts a shared-upstream profile; and
- `dns.blocking.active` or any blocking timer/state.

Nebula Sync must run with selective sync. Continuous full Teleporter/config sync is prohibited because it can overwrite host-specific settings or fail against Pi-hole settings made read-only by container environment variables.

### Operational plane

An Adputate Pi-hole v6 API client performs live actions against every paired node:

- health and version checks;
- blocking status;
- timed or indefinite disablement;
- enablement;
- query-log search;
- policy/rule lookup used by diagnosis; and
- sync preflight and postflight verification.

Operational state is never delegated to periodic policy synchronization.

### Observability plane

Milestone 1 provides federated, on-demand investigation:

- retrieve the requested short window from every known active Pi-hole;
- write one raw JSON file and one human-readable search file per source node;
- preserve source identity in filenames and snapshot metadata;
- search the local snapshot with standard filesystem grep tools;
- report unavailable, logging-disabled, privacy-redacted, and retention-limited nodes; and
- avoid a database, continuous ingestion, or indefinite centralized history.

Local Adputate runtime logs may be added to an on-demand support bundle. Remote host logs are reported as unavailable unless a future milestone adds an explicit remote collection mechanism.

## Implementation sequence

### 1. Freeze the paired-system contract

- Record the supported Pi-hole Core, FTL, Web, and API version ranges.
- Read the API documentation served by both real Pi-holes and compare required endpoints.
- Confirm the exact Teleporter/gravity categories and `/api/config` keys used by the selective profile.
- Verify experimentally how timed blocking changes `/api/dns/blocking`, `/api/config`, and `pihole.toml`.
- Confirm that the selective profile never copies active blocking state.
- Decide whether local DNS/CNAME records and client mappings are enabled initially.
- Document downgrade and version-skew behavior.

Exit condition: the shared-policy allowlist and node-local denylist are represented as testable data, not scattered shell conditionals.

### 2. Harden peer discovery and pairing

The explicit `discover` and `instance add|remove` foundation is implemented. An optional interactive `adputate pair` workflow remains as an ergonomic layer over those primitives.

Discovery sources, in order:

1. active and scoped resolvers from `scutil --dns`;
2. manually configured DNS servers on all network services;
3. safe validation of private-address candidates using Pi-hole API identity/version endpoints; and
4. an explicitly entered hostname or IP address.

Current-network behavior must handle the common case where DHCP advertises only the router and the router forwards to Pi-hole. Discovery is a convenience, not a promise.

The workflow must:

- display every candidate and how it was discovered;
- require confirmation of the primary and replica roles;
- validate DNS and HTTP/API reachability independently;
- reject accidental pairing of a node with itself;
- obtain or accept a Pi-hole application password;
- store the secret in macOS Keychain;
- record only non-secret endpoint and role metadata in Adputate configuration; and
- provide `adputate unpair` without uninstalling either Pi-hole.

Optional broad neighbor probing is deferred or exposed only behind an explicit `--discover-lan` action.

### 3. Harden the Pi-hole v6 API client

One reusable shell client now serves status, blocking, and log queries with Keychain-backed authentication and explicit session deletion. Before Milestone 1 is complete it still needs formal version/capability checks and richer structured error reporting.

Required behavior:

- HTTP and HTTPS endpoints with secure certificate verification by default;
- application-password authentication through `/api/auth`;
- short-lived SID handling and explicit session deletion;
- connection and overall request timeouts;
- structured handling of authentication, authorization, rate-limit, API-version, and server errors;
- node identity and version/capability discovery;
- redaction of passwords, SIDs, CSRF values, and sensitive headers from logs; and
- deterministic mockable transport for tests.

Exit condition: one command can authenticate to both nodes, report identity/version, and close both sessions without leaking credentials.

### 4. Extend cluster status and harden `doctor`

Top-level `adputate status` already reports API reachability and blocking state per active node. Extend it and the diagnostic surface with the remaining compatibility, DNS, privacy, clock-skew, and synchronization checks below.

Report per node:

- DNS reachability over UDP and TCP;
- API and admin reachability;
- Pi-hole component versions and compatibility;
- blocking state and remaining timer;
- query-logging and relevant privacy state;
- local clock and measured clock skew where available;
- role and endpoint;
- last successful policy sync;
- current policy-sync health; and
- whether the node is operating on last-good state.

The summary must distinguish degraded service from total service failure.

### 5. Implement cluster-wide blocking operations

Foundation implemented: status, timed or indefinite disablement, enablement, all-node preflight, per-node read-back verification, and nonzero partial-failure exits are covered by the current CLI tests. Real two-node acceptance remains outstanding.

Add:

```text
adputate blocking status
adputate blocking disable 5m
adputate blocking disable --until-enabled
adputate blocking enable
```

For each requested state change:

1. preflight every configured node;
2. authenticate independently;
3. issue the operation to all reachable targets;
4. read back state and remaining timer from each target;
5. retry only safe/idempotent verification as appropriate;
6. print a per-node result; and
7. exit nonzero on partial failure.

The command must never claim “blocking disabled” without confirming every intended node. A node becoming unavailable between preflight and verification is a partial failure.

### 6. Integrate pinned selective Nebula Sync

- Keep the selected `ghcr.io/lovelaze/nebula-sync:v0.11.2` release pinned and add its tested immutable image digest before enabling synchronization.
- Generate the selective configuration from the shared-policy allowlist.
- Keep credentials out of environment examples and process listings where possible; provide them to the isolated sync process through protected files derived from Keychain at launch.
- Run Nebula Sync as a separately identifiable, least-privileged component.
- Do not grant access to Adputate's Pi-hole volumes unless strictly required.
- Set bounded timeouts and retries.
- Capture structured last-run, last-success, duration, source version, target version, and error state.
- Run gravity only where required, and avoid unnecessary simultaneous work on both DNS servers.

Exit condition: changing, adding, and deleting every shared-policy object on the NUC converges on Adputate without changing any node-local setting.

### 7. Add sync orchestration

Add:

```text
adputate sync status
adputate sync now
adputate sync pause
adputate sync resume
```

The scheduler must:

- perform an initial sync after pairing only with explicit confirmation;
- run often enough that interactive allowlist changes are useful;
- catch up promptly after the Mac wakes or returns to the network;
- prevent overlapping runs;
- leave both Pi-holes serving last-good data during failure;
- use exponential backoff with an upper bound;
- retain concise, bounded run history; and
- surface stale replication through `health` and `doctor`.

The replica's admin panel remains usable for inspection, but documentation must warn that direct policy changes there may be overwritten.

### 8. Add federated investigation

The filesystem-first `query` foundation is implemented: it collects a bounded window from every active node into private raw JSON and readable text files before searching locally. Pagination/truncation detection, richer normalization, `diagnose`, and the opt-in support bundle remain.

Add:

```text
adputate query <domain> [--since DURATION] [--client ADDRESS]
adputate diagnose <domain> [--since DURATION]
adputate support-bundle [--since DURATION]
```

`query` must:

- default to a one-hour window and accept an explicit bounded override;
- collect from all known active Pi-holes before searching;
- preserve raw API responses as per-node JSON files;
- create per-node human-readable files suitable for `grep`;
- preserve node identity and duplicate events;
- support exact-domain and useful suffix matching;
- show client, query type, result/status, reply, upstream, and matched-rule information when available; and
- clearly report nodes that are unreachable, redacted, logging-disabled, or outside retention.

`diagnose` must combine:

- direct A, AAAA, and HTTPS/SVCB DNS queries against each node;
- current blocking state;
- matching recent query events;
- rule/list searches on each node;
- policy-sync freshness; and
- an explanation of divergent results or the absence of queries from both logs.

`support-bundle` must:

- include paired health, version, sync, and recent relevant service-log information;
- include local Adputate runtime logs;
- state that remote host logs were not collected;
- redact all secrets;
- default to redacting client addresses and optionally domains;
- require an explicit flag to include sensitive query details; and
- write a bounded, user-owned archive that uninstall does not silently delete.

### 9. Complete lifecycle and uninstall behavior

Install/upgrade must account for:

- Keychain entries;
- pairing metadata;
- Nebula Sync image and runtime state;
- scheduler/launchd artifacts;
- bounded sync logs; and
- version migrations.

`unpair` removes pairing automation and credentials but leaves the standalone Adputate Pi-hole running.

Full uninstall removes every Adputate-owned Milestone 1 artifact unless the user explicitly asks to retain images or diagnostic exports. It must never delete or reconfigure the NUC. `uninstall-audit` must include Keychain, scheduler, sync container/image, configuration, and log checks.

### 10. Documentation and release readiness

- Add a concise paired architecture section to the README.
- Explain that multiple DNS servers are not strict primary/secondary failover.
- Explain primary authority, replica overwrite behavior, and sync lag.
- Document cluster-wide disablement as the supported temporary-bypass path.
- Document what is and is not synchronized.
- Document privacy implications of query logs and support bundles.
- Include recovery procedures for lost credentials, unavailable primary, stale replica, version mismatch, and failed sync.
- Remove or clearly label every experimental option before release.

## Test strategy

### Automated unit tests

- API authentication success, rejection, timeout, malformed response, and session cleanup
- Version and capability parsing across supported versions
- Secret redaction from output and logs
- Duration parsing and blocking timer verification
- Partial cluster-operation failure
- Discovery candidate filtering and self-pair rejection
- Shared-policy allowlist enforcement
- Sync status, staleness, locking, backoff, and wake catch-up
- Query-log normalization, merging, source labeling, and clock skew
- Privacy/logging-disabled/unreachable-node presentation
- Unpair, uninstall, and uninstall-audit ownership boundaries

### Automated integration tests

Run two isolated Pi-hole v6 instances on non-privileged test ports and verify:

- pairing and independent authentication;
- policy creation, update, deletion, and mapping convergence;
- node-local listener/upstream/web/DHCP settings remain unchanged;
- timed blocking disablement reaches both nodes and both re-enable;
- indefinite disablement and explicit enablement;
- one node failing before, during, and after a cluster operation;
- full convergence after the replica is offline;
- sync across a supported version skew and rejection of unsupported skew;
- matching, divergent, duplicate, and absent query-log events;
- logging disabled and privacy-redacted modes; and
- clean unpair/uninstall followed by a pristine reinstall and re-pair.

### Real-network acceptance test

Use the actual NUC and Adputate Mac with at least one separate LAN client.

1. Configure the client with both Pi-holes as DNS servers.
2. Confirm successful A, AAAA, and TCP-fallback queries against each node directly.
3. Confirm the client uses each node under realistic network conditions.
4. Add an allow rule, deny rule, regex rule, list, group, and mapping on the NUC; verify convergence.
5. Delete each object and verify convergence.
6. Prove that listener, upstream, webserver, and DHCP settings do not converge.
7. Disable blocking for five minutes through Adputate; verify both nodes immediately and after automatic re-enable.
8. Repeat with one node unavailable and verify clear partial-failure reporting.
9. Trigger a known blocked query and locate it through the merged query command.
10. Create divergent node results and confirm `diagnose` explains them.
11. Test while WARP, Private Relay, or browser encrypted DNS bypasses Pi-hole; confirm “neither node observed the query” is reported accurately.
12. Sleep/wake and disconnect/reconnect the Mac; verify catch-up and last-good service.
13. Unpair, audit, re-pair, uninstall, audit, reinstall, and repeat the basic DNS tests.

## Milestone 1 exit criteria

Milestone 1 is complete only when all of the following are true:

- The standalone Milestone 0 path still passes without pairing.
- Pairing is understandable without requiring knowledge of macOS resolver internals.
- The NUC remains the clear source of truth and the replica converges reliably.
- No default sync can change a node-local setting.
- Temporary blocking controls behave consistently across both Pi-holes.
- Every cluster action exposes partial failure.
- A domain can be investigated across both Pi-holes from one command.
- A sleeping or disconnected Mac returns to a known-good state without manual repair.
- Credentials do not appear in files, process arguments, logs, or support bundles.
- Unpair and uninstall leave no Adputate-owned pairing artifacts and never disturb the NUC.
- The real-network acceptance test passes from a third machine on the subnet.

## Deferred follow-on work

- A unified graphical control and investigation page
- Continuous live-tail aggregation
- Central log retention, dashboards, and metrics export
- Optional remote host-log collection through an agent or SSH
- Multi-primary conflict handling
- Virtual-IP or routing-based failover
- DHCP high availability
- Automated router configuration

## Decisions still required

These are implementation-time decisions, not reasons to block initial work:

- Whether local DNS and CNAME records belong in the first shared-policy profile
- Whether client and client-group mappings are enabled by default
- Default sync interval and staleness warning threshold
- Whether Nebula Sync runs continuously with its own scheduler or once per Adputate-managed launch
- Supported TLS policy for a peer using a private/self-signed certificate
- Default domain/client redaction policy for support bundles
- Whether a small cluster control page is part of Milestone 1 or follows immediately afterward
