# Protect this Mac without an existing Pi-hole

On an Apple Silicon Mac with Apple's `container` command installed, run:

```sh
adputate install --local --yes
```

Or run `adputate install` and accept the local-protection option. Administrator
authorization is needed for the port-53 listener and the Mac's DNS setting.
Source checkouts must first build the package with `make build`.

Setup starts a Pi-hole container, installs its user service and a localhost-only
DNS forwarder, registers the local instance, then changes the default network
service's DNS to `127.0.0.1`. To select a service explicitly, append
`--service "Wi-Fi"`. The admin UI remains at `http://127.0.0.1:8080/admin/`
unless its port was configured differently.

A unique lookup through the macOS system resolver must appear in the local
Pi-hole query log before setup reports success. Keep query logging enabled during
setup. If verification fails, the previous DNS configuration is restored. The
host remains installed so you can inspect it with `adputate host health` and
`adputate host logs`, then retry setup.

Only the selected Mac network service changes. Other devices, VPN resolvers,
and applications using their own DNS are not covered by that verification.
WARP and Private Relay must be disabled before setup. Existing active remote
instances, LAN-host settings, and an outstanding DNS restore point are preserved;
setup stops with instructions instead of replacing them.

Pi-hole must remain running while the network service uses localhost DNS. Before
stopping it, restore the previous settings:

```sh
adputate client dns restore --yes
```

`adputate uninstall --yes` removes the installation and restores managed DNS.
The container service runs in the user's login session; this flow does not promise
DNS availability before login. A successful system-resolver probe proves that
path at setup time, not that every browser or VPN will use it forever.
