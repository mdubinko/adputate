# Recovery

Keep this path available before changing router or macOS DNS settings.

## Restore this Mac's DNS

```bash
bin/adputate dns-disable
```

If the checkout is unavailable, inspect `~/Library/Application Support/Adputate/config/dns-backup.env`, then restore the recorded service in System Settings or with `networksetup -setdnsservers`. Do not delete the backup until the prior configuration is restored.

## Remove the port-53 frontend

First point the router and this Mac at another resolver. Then run:

```bash
bin/adputate router-uninstall
```

This removes only Adputate's system LaunchDaemon and installed proxy. It does not delete Pi-hole data.

## Remove Adputate completely

Restore any router DHCP/DNS setting first, then run:

```bash
bin/adputate uninstall --yes
bin/adputate uninstall-audit
```

The uninstall restores DNS previously changed by `dns-enable`, removes both launchd jobs, removes the Application Firewall entry, deletes the container, volumes, runtime files, logs, and Adputate-used image cache. It does not remove the source checkout or Apple's Container installation. Use `--keep-images` only when retaining the cache is intentional.

## Recover a stopped or unhealthy backend

```bash
bin/adputate status
bin/adputate doctor
bin/adputate health
bin/adputate restart
bin/adputate health
```

If `status` reports configuration drift, review it and use `bin/adputate reconcile --yes`. Reconciliation preserves named volumes.

## Recover an image upgrade

`upgrade` exports a Teleporter archive before changing images. If the new image fails readiness, Adputate restores the previous image setting and recreates the prior container while preserving named volumes. Backups are stored under `~/Library/Application Support/Adputate/teleporter`.

## Emergency network recovery

If DNS is broken and the CLI cannot recover it:

1. Change the router's DNS server to a known-good resolver.
2. In macOS System Settings, clear the manual DNS entry for the active network service or restore its previous addresses.
3. Renew client DHCP leases or reconnect clients.
4. Diagnose with explicit targets: `dig @<mac-lan-ip> example.com`, then `dig @<mac-lan-ip> -p 5053 example.com`.

Port 53 failing while port 5053 works isolates the native frontend. Both failing isolates the backend/container or host network.
