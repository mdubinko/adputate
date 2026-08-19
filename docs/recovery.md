# Recovery

Keep this path available before changing router or macOS DNS settings.

## Restore this Mac's DNS

```bash
adputate client dns restore --yes
```

If the checkout is unavailable, inspect `~/Library/Application Support/Adputate/config/dns-backup.env`, then restore the recorded service in System Settings or with `networksetup -setdnsservers`. Do not delete the backup until the prior configuration is restored.

## Remove the port-53 frontend

First point the router and this Mac at another resolver. Then run:

```bash
adputate host router uninstall
```

This removes only Adputate's system LaunchDaemon and installed proxy. It does not delete Pi-hole data.

## Remove Adputate completely

Restore any router DHCP/DNS setting first, then run:

```bash
adputate uninstall --yes
adputate uninstall-audit
```

The uninstall restores DNS previously changed by `client dns apply`, removes both launchd jobs, removes the Application Firewall entry, and deletes the container, volumes, runtime files, and logs. It removes only container images that Adputate recorded pulling itself; pre-existing shared cache entries are preserved. It does not remove the installed executable or Apple's Container installation. Use `--keep-images` to retain even Adputate-pulled images.

## Recover a stopped or unhealthy backend

```bash
adputate host status
adputate host doctor
adputate host health
adputate host restart
adputate host health
```

If `host status` reports configuration drift, review it and use `adputate host reconcile --yes`. Reconciliation preserves named volumes.

## Recover an image upgrade

`adputate host upgrade` exports a Teleporter archive before changing images. If the new image fails readiness, Adputate restores the previous image setting and recreates the prior container while preserving named volumes. Backups are stored under `~/Library/Application Support/Adputate/teleporter`.

## Emergency network recovery

If DNS is broken and the CLI cannot recover it:

1. Change the router's DNS server to a known-good resolver.
2. In macOS System Settings, clear the manual DNS entry for the active network service or restore its previous addresses.
3. Renew client DHCP leases or reconnect clients.
4. Diagnose with explicit targets: `dig @<mac-lan-ip> example.com`, then `dig @<mac-lan-ip> -p 5053 example.com`.

Port 53 failing while port 5053 works isolates the native frontend. Both failing isolates the backend/container or host network.
