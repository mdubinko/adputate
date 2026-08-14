# Router Deployment

Do not make Adputate the network's only resolver until every preflight check passes. Keep a known-good secondary resolver during rollout.

## Preflight

1. Give the Mac a DHCP reservation or static LAN address.
2. Disconnect Cloudflare WARP and turn off iCloud Private Relay, or turn off **Limit IP Address Tracking** for this network. WARP may remain installed while disconnected.
3. Prevent sleep while it is serving DNS, or explicitly validate sleep/wake behavior for your setup.
4. Persist the address and interface, then reconcile if required:

   ```bash
   bin/adputate configure --bind-address <mac-lan-ip> --web-port 18080 \
     --dns-port 5053 --router-interface <interface>
   bin/adputate reconcile --yes
   ```

5. Install both supervised services and verify local health:

   ```bash
   bin/adputate service-install
   bin/adputate router-preflight
   bin/adputate router-install
   bin/adputate health
   ```

`router-install` requests administrator access. It compiles and installs a small native frontend under `/Library/Application Support/Adputate`, plus the system LaunchDaemon `/Library/LaunchDaemons/com.adputate.dns-forwarder.plist`. The process binds only the configured LAN IPv4 address on TCP/UDP 53 and drops to `nobody` before serving requests.

If macOS asks whether to allow incoming network connections, allow them for the frontend; otherwise local checks may pass while LAN clients time out.

### Port-53 preflight

`router-preflight` uses administrator access so it can see listeners owned by every user. It reports TCP and UDP separately, including the process, PID, account, and bound address. It recognizes common cases such as:

- macOS `mDNSResponder` and Internet Sharing
- Homebrew `dnsmasq`
- Docker Desktop and OrbStack
- Tailscale, WireGuard, OpenVPN, and several common commercial VPN clients

The standard `mDNSResponder` wildcard listener is allowed because Adputate binds the exact configured IPv4 address. Another process on that exact address, or an unknown wildcard listener, fails installation with a remediation hint. A loopback-only listener is reported as a warning because it does not directly occupy the LAN address.

VPN clients and Network Extensions can intercept or reroute DNS without owning a visible port-53 socket. Adputate explicitly stops installation when Cloudflare WARP is connected or iCloud Private Relay is active and asks you to turn it off; it does not modify either product. Other interceptors may not expose a reliable status interface, so successful UDP and TCP probes remain mandatory. Installation performs both probes and restores the previous frontend—or removes a new failed installation—if startup validation fails.

## Test from another LAN machine

Run all four tests against port 53, without `-p 5053`:

```bash
dig @<mac-lan-ip> example.com A
dig +tcp @<mac-lan-ip> example.com A
dig @<mac-lan-ip> doubleclick.net A
curl --fail http://<mac-lan-ip>:18080/admin/
```

Expected results:

- Both external-name queries return addresses and have DNS status `NOERROR`.
- The blocked-domain query returns Pi-hole's configured blocking answer, normally `0.0.0.0`.
- The admin endpoint returns HTTP successfully.

If UDP and TCP differ, stop. Routers and clients need both. Check the macOS incoming-connections prompt/firewall, `bin/adputate router-status`, and `bin/adputate health`.

## Router cutover

Set the router's LAN/DHCP DNS server to the reserved Mac address. Start with a working secondary resolver. Renew one test client's DHCP lease and confirm browsing, UDP DNS, TCP DNS, and blocked-domain behavior before rolling the change across the network.

The router must advertise the Mac's address, not `127.0.0.1`, not port `5053`, and not the container's private VM address.

## Use on the host Mac

After port 53 is healthy, Adputate can safely snapshot and update one macOS network service:

```bash
bin/adputate dns-enable "USB 10/100/1000 LAN"
bin/adputate dns-disable
```

`dns-enable` refuses an unhealthy frontend, saves the previous DNS list before changing it, verifies the new value, and attempts restoration if the change fails. `dns-disable` restores the exact saved list, including the absence of manually configured servers.
