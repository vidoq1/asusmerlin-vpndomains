# VPN Domains for Asuswrt-Merlin

A domain-based IPv4 routing add-on that lives inside the Asuswrt-Merlin admin interface. Keep a list of domains in a regular WebUI tab, and route connections to their resolved IPv4 addresses through an existing WireGuard client.

It uses the router's existing dnsmasq, ipset, firewall, policy routing, admin WebUI, and service hooks. It does not create a VPN connection, run a separate web server, or open another management port.

> Status: installation, reinstallation, purge, WireGuard selection, domain routing, and WebUI operation have been tested on an ASUS ROG Rapture GT-AX11000 Pro running Asuswrt-Merlin 3006.102.9. Other models and firmware versions are untested. Boot recovery and compatibility with every third-party add-on are not established by these tests. See [Compatibility](#compatibility).

## Why this exists

Sometimes only a small set of websites needs a VPN. Sending an entire device or network through a tunnel is unnecessary, while maintaining destination IP rules manually is inconvenient.

VPN Domains keeps the domain list editable in the router's WebUI. dnsmasq adds resolved IPv4 addresses for those domains to an ipset, and a policy-routing rule sends matching traffic through the selected WireGuard client.

DNS filtering stays separate. Adding a domain here does not whitelist it in Diversion, DNS Director, or a filtering DNS service.

## Features

- Manage the domain list under `LAN -> VPN Domains`.
- One lowercase domain per line; a base domain includes its subdomains.
- Comments and blank lines are supported.
- `Reload` reads the current list; `Save and apply` validates, saves, and applies it.
- Detect ready WireGuard clients and explicitly select the client used for domain routing.
- Resolve the client's routing-table number from the router's table mapping.
- Apply domain routing globally, without per-network selection.
- Validate the generated dnsmasq include before installing it.
- Keep shared hook integrations in marked blocks.
- Preserve an existing backend during ordinary WebUI repair.
- Provide compatibility checks and a WireGuard-selection test without applying configuration changes.
- Back up affected files outside the add-on directory before managed backend changes.
- Package everything in one self-contained `vpn-domain-install.sh`. No external payload directory or additional repository files are required for installation.

## What it does not do

- No OpenVPN support or selection.
- No WireGuard profile creation, configuration import, or automatic tunnel start.
- No per-device or per-network exclusions.
- No IPv6 domain routing.
- No VPN kill switch or guarantee that matching traffic cannot use WAN.
- No DNS-filter exceptions, DNS Director policy changes, or parental-control enforcement.
- No URL, application, or content inspection.
- No guarantee that every request belonging to a website uses the same route. Websites may use additional domains and shared infrastructure.
- No silent backend upgrade during an ordinary `install` on an existing active installation.

## How it works

```text
Client DNS lookup
    |
    v
Configured DNS path / applicable DNS filtering
    |
    +-- Blocked response -> VPN Domains does not supply the real address
    |
    +-- A matching lookup handled by router dnsmasq returns IPv4 addresses
            |
            v
        ipset: vpn_domain_v4
            |
Client IPv4 traffic to an address in that set
            |
            v
        mangle PREROUTING -> mark 0x100/0xff00
            |
            v
        policy rule priority 11000 -> selected WireGuard routing table
```

The main components are:

1. `vpn-domain-dnsmasq-generate.sh` converts the allowlist into dnsmasq `ipset=` directives and syntax-tests the result.
2. `dnsmasq.postconf` includes that generated file in the live dnsmasq configuration and ensures the destination ipset exists.
3. dnsmasq populates `vpn_domain_v4` from matching DNS responses it processes.
4. `vpn-domain-routing.sh` checks tunnel readiness and manages the mark and policy-routing rule.
5. `vpn-domain-refresh.sh` regenerates the DNS include, requests a DNS restart if its content has changed or is not recorded as loaded, and applies routing.

The set uses IPv4 addresses with a 3600-second timeout. It is not a per-client database: once an address is in the set, matching traffic from any local client reaching the router's rule can use the selected route.

### DNS filtering comes first

"DNS filtering comes first" describes the sequence of operations, not a special firewall priority or a bypass-proof access-control mechanism.

VPN Domains does not replace a blocked DNS response with the real address. If a device's filtering DNS server returns `0.0.0.0` or no usable address, adding the domain to VPN Domains does not unblock it.

Example: a gambling domain is in the VPN Domains allowlist.

- A child's device uses a family-filtering DNS server assigned through DNS Director. That server returns `0.0.0.0`, so the device does not receive the site's real address and cannot open it through this lookup. VPN Domains does not remove the block.
- A parent's device uses DNS without that filtering. If the real IPv4 address is learned by the router's matching dnsmasq/ipset path, traffic to it is routed through the selected ready WireGuard client.

An external resolver's response does not automatically populate the router's ipset. Clients using another DNS server, DoH, DoT, or cached addresses may therefore behave differently. The address might also already be in the shared set because another client resolved it.

VPN Domains does not prevent DNS-filter bypass. A client that independently obtains a real address already in the set can match the same routing rule. Enforcing the children's DNS policy remains the responsibility of your existing network configuration.

### Tunnel readiness and normal-routing fallback

A selectable client must have:

- an interface named `wgcN`;
- an IPv4 address;
- a routing-table mapping;
- a default IPv4 route, or both `0.0.0.0/1` and `128.0.0.0/1`, through that interface;
- at least one successful handshake no older than 180 seconds.

The backend repeats readiness checks when applying rules. A cron job does this every minute, and relevant router events trigger refreshes as well.

If the tunnel is not ready at a check, the add-on removes its domain-routing rules. Other router rules then determine the route, commonly WAN. This is not an immediate failover guarantee: a tunnel failure between checks can interrupt matching connections until the next update.

The health job currently removes and recreates the add-on's routing rules during application. It does not restart WireGuard. Repeated `vpn-domain-routing: enabled` log messages are not evidence of tunnel restarts.

### WebUI commands

```text
Browser: LAN -> VPN Domains
    |
    | POST /start_apply.htm
    | action_script = restart_vpndomain
    | request in shared add-on settings
    v
Firmware httpd -> service-event -> webui-handler.sh
    |
    +-- read: publish the current list and return
    +-- save: validate, save, run backend refresh, publish result
    |
    v
/tmp/vpdomain-webui/state.json
    |
    v
Browser fetches the result through the existing WebUI
```

The page uses `_vpdomain_*` settings keys and clears the request keys after reading them.

Opening the page reads published state; it does not submit a save or refresh command. `Reload` submits a read request. Although the firmware event is named `restart_vpndomain`, the read handler does not call backend refresh or restart the tunnel.

`Save and apply` can restart dnsmasq when the generated include changes. The handler checks the list revision to detect stale edits and attempts to restore the previous list if applying the change fails. Rollback is best effort, not a substitute for backups.

### Menu and page slot

- The page is added to the LAN menu beside a supported Switch Control/VLAN menu entry.
- The add-on finds its existing page by its own marker and reuses it. Otherwise it requests a page slot through Merlin's helper API.
- The assigned page is recorded in `/jffs/addons/vpn-domain/page`. Do not assume a fixed slot such as `user2.asp` or `user3.asp`.
- It refuses to overwrite an existing page without the VPN Domains marker.
- The menu uses a cache-busting query when loading `menuTree.js`.
- A missing supported LAN menu anchor stops mounting rather than choosing an unrelated location.

## Requirements

- Asuswrt-Merlin with the expected add-on WebUI/helper support.
- `Administration -> System -> Enable JFFS custom scripts and configs = Yes`.
- SSH access with root-equivalent privileges and an interactive terminal for selection and confirmation prompts.
- A configured, connected WireGuard client meeting the readiness checks above.
- Router tools used by the backend: `ip`, `iptables`, `ipset`, `wg`, `dnsmasq`, `cru`, and the usual shell utilities.
- `/usr/sbin/helper.sh` and `/usr/bin/flock`.
- Entware Base64 at `/opt/bin/base64`. There is no BusyBox Base64 fallback in this version.
- A browser supporting `fetch`, `async/await`, `TextEncoder`, `TextDecoder`, and the Web Crypto API used for request IDs.

The WebUI allowlist limit is 3072 bytes, including comments and newlines. The request also shares the firmware's add-on settings capacity with other add-ons; a nearly full settings store can prevent saving a list below that limit.

## Compatibility

| Item | Status |
|---|---|
| GT-AX11000 Pro, Merlin 3006.102.9 | Tested for installation lifecycle, selection, WebUI, and domain routing |
| Other Merlin models/builds | Untested; required tools and WebUI integration must be available |
| Stock ASUS firmware | Not a supported target for this installer |
| OpenVPN | Not supported |
| IPv6 routing | Not implemented |

On the tested router, existing hook calls for installed plug-ins remained present after the installation cycle. This is not a blanket compatibility guarantee or a complete functional test of those add-ons.

## Installation

### Prepare the WireGuard client

```text
Free VPN client (WireGuard) can be obteined: PROTON VPN https://protonvpn.com/
```

In the Merlin WebUI:

1. Open `VPN -> VPN Client`.
2. Select WireGuard and the client profile you intend to use.
3. Import the provider's configuration if the client is not configured yet.
4. Set `Enable WireGuard = Yes`, apply, and wait for the connection.
5. Make sure a successful recent handshake exists before running installation.

On firmware using the name `VPN Fusion`, use `VPN -> VPN Fusion -> Add profile -> WireGuard`, import the configuration, and enable the connection. The exact controls depend on firmware.

Do not add an all-devices/default-VPN rule just to satisfy the installer. This add-on creates its own domain-routing rule after confirmation.

### Copy and run the installer

Use your own admin username and router address:

```sh
scp vpn-domain-install.sh admin@router_ip:/tmp/vpn-domain-install.sh
ssh admin@router_ip
```

Then, inside the interactive SSH session:

```sh
sh /tmp/vpn-domain-install.sh
```

With no command, the installer shows its description and main menu. It does not automatically install anything.

To explicitly install:

```sh
sh /tmp/vpn-domain-install.sh install
```

For a fresh installation, it explains the changes, finds ready WireGuard clients, asks you to select one, and asks for `YES` before applying configuration.

At the selection prompt:

- enter a listed number to select a client;
- enter `h` for setup instructions;
- enter `q` to cancel without applying configuration.

If no client is ready, it explains what is missing and where to enable WireGuard. No backend configuration is installed by that failed selection attempt.

After successful installation, preserve the installer yourself:

```sh
cp -p /tmp/vpn-domain-install.sh /jffs/addons/vpn-domain/install.sh
```

The installer creates its components but does not automatically copy its own source into the add-on directory. `/tmp` is temporary; the copy above keeps the maintenance commands available after reboot.

Refresh the router WebUI and open `LAN -> VPN Domains`.

### Domain-list format

```text
# One lowercase domain per line.
example.com
example.net
```

`example.com` covers that domain and its subdomains. Do not enter URLs, paths, ports, `*.` prefixes, or uppercase names. Use ASCII domain names, including their ASCII/Punycode form where applicable.

Click `Reload` to read the current router copy. Edit the list and click `Save and apply` to validate and apply it. If another change made your editor revision stale, reload before trying again.

## Commands and maintenance

```sh
sh /jffs/addons/vpn-domain/vpn-domain-install.sh help
sh /jffs/addons/vpn-domain/vpn-domain-install.sh status
sh /jffs/addons/vpn-domain/vpn-domain-install.sh check
sh /jffs/addons/vpn-domain/vpn-domain-install.sh test-menu
```

| Command | Behavior |
|---|---|
| No command | Show the main menu; no implicit installation |
| `install` | Fresh install, or WebUI-only repair of an existing active backend |
| `configure-vpn` | Explicit binding change, recognized legacy migration, or re-enable |
| `check` | Check compatibility and recognized hook cleanup without applying configuration |
| `test-menu` | Test WireGuard discovery and selection; do not save the selection |
| `status` | Show installation, configured binding, and routing state |
| `uninstall` | Disable integration, preserving the list and component files |
| `purge --yes` | Disable and remove the add-on and its data; also asks for `YES` |

Checks still use temporary staging files and installer locking. "No configuration changes" does not mean absolutely no filesystem activity or log entries.

### Reinstalling and updating

On an existing active installation, ordinary `install` restores only the WebUI source, support scripts, and its two marked WebUI hooks. It preserves backend scripts, the allowlist, the generated DNS include, and the VPN binding. This branch does not request a DNS restart or apply routing.

A partial installation stops instead of being silently treated as fresh. A disabled installation also stops: use `configure-vpn` to explicitly re-enable it.

Running a newer installer with `install` is therefore not a general backend upgrade. Backend changes require the explicit configuration/migration path, where supported. Replace the persistent installer copy yourself after adopting a new version.

### Changing the selected WireGuard client

```sh
sh /jffs/addons/vpn-domain/install.sh configure-vpn
```

This asks for a client selection. An unchanged active managed binding is left untouched. A changed binding, migration, or re-enable requires `YES`, backs up affected files, replaces the backend/integration, restarts dnsmasq, and applies routing.

Only recognized legacy backend versions and hook patterns can be migrated automatically. Unknown unmarked references stop the operation; the tool does not guess which third-party lines it may remove.

## What the installer changes

### Persistent files

```text
/jffs/addons/vpn-domain/
    VPNDomain.asp
    mount.sh
    webui-handler.sh
    lib.sh
    page
    .managed-v3

/jffs/scripts/
    vpn-domain-dnsmasq-generate.sh
    vpn-domain-routing.sh
    vpn-domain-refresh.sh

/jffs/configs/
    vpn-domain-allowlist.txt
    vpn-domain-routing.conf
    vpn-domain-settings.conf
```

`vpn-domain-routing.conf` is the generated dnsmasq include, despite its name. The selected WireGuard interface and numeric routing-table ID are stored separately in `vpn-domain-settings.conf`.

The directory can also contain a previous allowlist saved by the WebUI, lifecycle markers, older files retained during migration, and an installer copy if you saved one there.

### Shared hooks and cron

The managed installation adds marked blocks to:

| Hook | Purpose |
|---|---|
| `services-start` | Mount WebUI and run a delayed backend refresh |
| `service-event` | Dispatch VPN Domains WebUI requests |
| `service-event-end` | Refresh after relevant VPN/routing/firewall/DNS events |
| `dnsmasq.postconf` | Create the ipset, generate and include the DNS configuration |
| `nat-start` | Register the health cron job |

The active `VPNDomainRoutingHealth` cron job runs `vpn-domain-routing.sh apply` every minute. No separate persistent add-on daemon is started.

Shared hook files may be created if absent. Existing unrelated content is kept; managed edits set the affected hook scripts executable. Recognized legacy integration is cleaned up only through an explicit backend-changing operation, not ordinary WebUI repair.

### Runtime files and rules

- `/www/user/userN.asp`: live WebUI page.
- `/www/user/vpdomain`: link to `/tmp/vpdomain-webui`.
- `/tmp/menuTree.js`: menu entry, bind-mounted over the firmware menu module.
- `/tmp/vpdomain-webui/`: published WebUI state and operation results.
- `/tmp/vpn-domain-dns-config.hash`: recorded generated DNS include hash.
- `vpn_domain_v4`: IPv4 destination ipset.
- mangle `PREROUTING`: mark matching destinations with `0x100/0xff00`.
- policy rule priority `11000`: send that mark to the selected WireGuard table.

These mark values and priority are reserved by this implementation, not dynamically allocated. The installer checks for certain conflicts, but cannot establish compatibility with every possible custom firewall rule.

### Backups and rollback

Affected files are backed up under:

```text
/jffs/vpn-domain-backups/<timestamp>-<pid>/
```

Backend-changing operations record missing files and the pre-change cron listing as well. Failures after the transaction begins trigger a best-effort file, cron, DNS, and routing rollback. This is not a complete snapshot of router state, and live WebUI state is not fully reconstructed by every rollback path.

Backups are outside the add-on directory and survive `purge`. They are not automatically pruned. Copy important backups off the router; they can contain private configuration and cron details.

## Uninstall

```sh
sh /jffs/addons/vpn-domain/install.sh uninstall
```

After confirmation, this:

1. Backs up affected files.
2. Removes `VPNDomainRoutingHealth` from active cron.
3. Removes recognized VPN Domains hook blocks, including supported legacy blocks.
4. Removes the add-on's destination-marking and matching policy-routing rules.
5. Restarts dnsmasq without the add-on's DNS include integration.
6. Marks the installation disabled.
7. Removes its live page, menu entry, resource link, and temporary WebUI directory.

It keeps the allowlist, generated DNS include, settings, backend scripts, add-on directory, and saved installer. It does not stop or delete the WireGuard client, delete its keys, or remove the WireGuard table's routes.

It does not explicitly flush or destroy `vpn_domain_v4`; the set can remain without the removed routing rule. Logs and external backups are retained. Other add-ons' hook content is not intentionally removed.

An ordinary `install` does not silently re-enable a disabled backend. Use `configure-vpn` for an explicitly confirmed re-enable.

### Full removal

Because purge removes the add-on directory, run a copy stored outside it:

```sh
cp -p /jffs/addons/vpn-domain/install.sh /tmp/vpn-domain-install.sh
cd /tmp
sh /tmp/vpn-domain-install.sh purge --yes
```

It still asks you to type `YES`.

Purge performs the integration removal, then removes the three backend scripts, allowlist, generated DNS include, binding settings, DNS hash stamp, and add-on directory. External backups remain. Save your list separately before doing this if you want to reuse it.

Do not just delete the add-on directory: that leaves backend scripts, DNS hooks, routing integration, and cron outside the directory. Do not force an installation into managed mode by manually creating marker files.

## Security model

- The router's admin interface is the management boundary. The add-on does not introduce separate users or per-device permissions.
- Admin users can edit the list; backend operations run with router privileges.
- Domains are validated before generating dnsmasq directives. The WebUI also syntax-tests candidate directives and uses revision checks to detect stale edits.
- Requests use shared firmware add-on settings. They are not a channel for arbitrary shell commands or arbitrary file paths.
- Selection and managed changes use confirmation and locking, but neither the installer nor its rollback is a security audit or a guarantee against every concurrent modification.
- DNS and IP-based routing are not content filtering. Shared hosting/CDN addresses can cause other domains at the same address to follow the VPN route.
- IPv6, independent DNS resolution, and cached addresses can produce behavior outside the intended IPv4 DNS/ipset path.

Keep a backup before changing routing on a router you depend on.

## Troubleshooting

| Symptom | Check |
|---|---|
| Running without arguments does not install | Intentional: choose an action from the main menu or use `install` |
| No ready WireGuard client | Follow the printed `VPN -> VPN Client` instructions; check IPv4, full routes, table mapping, and handshake age |
| A connected client is skipped | A handshake older than 180 seconds fails this installer's readiness check; inspect the profile and retry |
| No WebUI tab | Clear cache; Refresh the browser; inspect `/tmp/vpdomain-webui-mount.log`, the saved page slot, and the supported LAN menu anchor |
| `Reload` logs `restart_vpndomain` | This is the WebUI event name, not a WireGuard restart; the read handler returns without backend refresh |
| Saving fails or times out | Check the admin session, 3072-byte limit, shared settings capacity, and handler/apply logs |
| List revision conflict | Click `Reload`, reconcile your changes, and save again |
| Domain does not use VPN | Check the selected client, current IPv4 rules, DNS path, and whether its resolved address is in `vpn_domain_v4` |
| Blocked domain stays blocked | Expected: the add-on does not override the device's DNS filter |
| Rules disappear when the tunnel is unavailable | Expected readiness behavior; normal router routing remains in control |
| Legacy migration/removal refused | Unknown backend or hook references require inspection; do not bypass the guard |
| `install` reports a disabled installation | Use `configure-vpn` to re-enable, or perform a backed-up purge for a clean cycle |
| Shell reports `getcwd` after purge | Its current directory was deleted; run `cd /tmp` |

Useful read-only diagnostics:

```sh
sh /jffs/addons/vpn-domain/install.sh status
wg show interfaces
ip -4 rule show
iptables -t mangle -S
ipset list vpn_domain_v4
grep -nF 'vpn-domain-routing.conf' /etc/dnsmasq.conf
cru l
```

Useful logs:

```text
/tmp/vpdomain-webui-mount.log
/tmp/vpdomain-webui-handler.log
/tmp/vpdomain-webui-apply.log
/tmp/vpdomain-webui-test.log
/tmp/vpn-domain-config-test.log
/tmp/vpn-domain-boot-refresh.log
```

Also inspect the system log for `vpn-domain`, `vpdomain`, and `dnsmasq` entries. Avoid publishing private keys, full router backups, or private allowlists when asking for help.

## Notes and limitations

- DNS routing operates on resolved destination IPs, not the hostname in each connection.
- Existing client DNS caches may delay the effect of list changes. A domain's additional service/CDN domains may need separate consideration.
- Changing the generated DNS include clears the old set entries through the postconf integration; new matching lookups repopulate them.
- The page's command channel writes small updates to `custom_settings.txt` on JFFS. Opening the page only reads published state; explicit Reload and Save operations use the settings channel.
- The installer and boot hooks include readiness waits, but boot recovery still needs validation on your own model and firmware. A successful live install does not prove every boot-order scenario.
- This add-on changes DNS integration, firewall marking, and policy routing. It is not a zero-impact WebUI-only extension.

## Disclaimer

This software is provided as is, without warranty. It edits shared router hooks and changes DNS integration and IPv4 routing. Installation, migration, re-enable, and removal can interrupt connectivity and restart dnsmasq.

Test on a non-critical setup first, keep backups outside the router, and retain a working SSH access path. Automatic backups and best-effort rollback do not guarantee recovery from every failure.

## License

This project is released under the [MIT License](LICENSE.md).

You are free to use, fork, modify, and redistribute it, provided that you retain the copyright notice and license text.

Copyright (c) 2026 Albert Sayapov.

## Support the development

Feel free to support the development of this and future builds via [paypal](https://www.paypal.com/donate/?business=D7YMVYBKM8BZW&no_recurring=0&item_name=Support+the+development+github.com%2Fvidoq1&currency_code=USD)
