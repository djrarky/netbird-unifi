# NetBird on UniFi OS

This repository provides the scripts needed to install and run [NetBird] on a
[UniFi Cloud Gateway]. It uses NetBird's official Linux package and adds
persistent state, service repair, optional automatic updates, and conservative
gateway defaults.

The persistence and lifecycle design is based on Sierra Softworks'
[tailscale-unifi] project.

## Installation

1. Connect to your UniFi gateway over SSH and become `root`.

2. Run the installer:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/djrarky/netbird-unifi/main/install.sh | sh
   ```

   The installer downloads the latest release, verifies its SHA-256 checksum,
   and asks for the initial settings when run interactively. Running it again
   preserves your existing `/data/netbird/netbird-env` file.

3. Create a one-use, non-ephemeral setup key in your NetBird dashboard, then
   connect the gateway:

   ```sh
   /data/netbird/manage.sh up --setup-key 'YOUR_SETUP_KEY'
   ```

   Replace `YOUR_SETUP_KEY` with the generated key. This enrols the peer once;
   the key is not a persistent configuration value and must not be added to
   `netbird-env`. This quick form exposes it in shell history, so use the
   key-file method in the FAQ when that matters.

4. Check the connection:

   ```sh
   /data/netbird/manage.sh status
   ```

> [!NOTE]
> The install command requires this repository to be public and to have a
> published GitHub release. Cloning the source alone does not create the release
> archive used by the installer.

For a scripted first install, place overrides on the `sh` side of the pipe:

```sh
curl -fsSL https://raw.githubusercontent.com/djrarky/netbird-unifi/main/install.sh | env NETBIRD_UNIFI_NONINTERACTIVE=true NB_HOSTNAME=unifi-gateway sh
```

## Compatibility

This project is designed for UniFi OS 2.x and newer Cloud Gateways which provide
`apt`, `systemd`, and a working `/dev/net/tun` device.

> [!TIP]
> You can collect the device model, firmware, TUN, service, port, and known
> routing symptoms with `/data/netbird/manage.sh diagnose`.

> [!IMPORTANT]
> This wrapper's install and management commands must run as `root`, and its
> routing peer requires `/dev/net/tun`. It does not provide a userspace-networking
> fallback.

> [!WARNING]
> UniFi hardware and firmware combinations differ. Validate peer connectivity,
> routed Networks, and any exit-node use on your own gateway before relying on
> it remotely. Keep local access available while changing routing settings.

Legacy UniFi OS 1.x devices, USG appliances, Cloud Keys without the required
Linux facilities, and other BusyBox-only systems are not supported.

## Management

### Configuring NetBird

Persistent settings live in `/data/netbird/netbird-env`. It is deliberately
short for manual editing; the packaged template is shown below. On first
install, the installer normally replaces `NB_HOSTNAME` with the gateway's
hostname.

```sh
NB_STATE_DIR="/data/netbird/state"
NB_HOSTNAME="netbird-unifi"
NB_MANAGEMENT_URL="https://api.netbird.io:443"
NB_INTERFACE_NAME="netbird0"
NB_WIREGUARD_PORT="41642"
NB_DISABLE_EBPF_WG_PROXY="true"
NETBIRD_DNS_MODE="unmanaged"
NETBIRD_CLIENT_ROUTES="disabled"
NETBIRD_ROUTING_MODE="auto"
NETBIRD_AUTOUPDATE="false"
```

`NB_STATE_DIR` and the installation root are fixed safety boundaries and should
not be changed. Keep `netbird-env` owned by root with mode `0600`, and use only
the documented assignments because the lifecycle scripts source it as root.

After editing daemon settings, apply them with:

```sh
/data/netbird/manage.sh apply
```

To reapply peer settings such as DNS mode or client-route acceptance on an
already-connected gateway, reconnect it:

```sh
/data/netbird/manage.sh down
/data/netbird/manage.sh up
```

This briefly interrupts NetBird connectivity, so use local or alternate access.
Once the peer has been enrolled, plain `manage.sh up` reconnects it without
requiring the setup key again.

Extra arguments to `manage.sh up` are passed to the native `netbird up` command.
Native diagnostic commands remain available, but use `manage.sh up` and
`manage.sh down` so the persistent environment and configured defaults are
loaded.

### Restarting NetBird

Disconnect the gateway without uninstalling it:

```sh
/data/netbird/manage.sh down
```

Restart the service with:

```sh
/data/netbird/manage.sh restart
```

You can also manage `netbird.service` directly with `systemctl`.

### Upgrading NetBird

Run an explicit package update with:

```sh
/data/netbird/manage.sh update
```

While the maintenance units remain installed, their daily run repairs a missing
package or integration files. It only upgrades an already installed package when
`NETBIRD_AUTOUPDATE="true"` is set in `netbird-env`.

### Checking status

```sh
/data/netbird/manage.sh status
/data/netbird/manage.sh diagnose
```

### Removing NetBird

To remove NetBird and its UniFi integration while preserving configuration and
peer identity:

```sh
/data/netbird/manage.sh uninstall
```

To permanently remove everything under `/data/netbird`, including the peer's
identity, run:

```sh
/data/netbird/manage.sh purge
```

Purge requires the exact confirmation `PURGE /data/netbird`. Neither command
deletes the peer from the NetBird management service; remove it there separately
if required.

## Contributing

Issues and pull requests are welcome. When reporting a gateway-specific problem,
please include the UniFi model and firmware, the NetBird version, and the output
of `manage.sh diagnose` with secrets removed.

Real-hardware results are particularly useful for firmware recovery, routed
Networks, site-to-site access, and exit-node behaviour.

## Frequently Asked Questions

### Where are the settings and peer identity stored?

The wrapper and configuration live under `/data/netbird`. NetBird stores its
identity and service state in `/data/netbird/state`; treat that directory as a
credential and keep it root-only.

While their units survive, the installed service and daily timer repair normal
package or configuration drift. If [unifi-common] and its `udm-boot` service are
already installed, the installer also adds a persistent boot hook which can
recreate units removed by firmware. Without that hook, rerun the installer after
such an upgrade.

### How do I expose my UniFi LAN through NetBird?

Create a Network in the NetBird management console, add your LAN CIDR as a
Resource, assign this gateway as the routing peer, and grant access with a
NetBird policy. Leave masquerading enabled by default. Disable it only when you
deliberately need original source addresses and have installed the required
return route.

This differs from Tailscale: the wrapper does not advertise local routes on the
command line. See NetBird's guide to [Networks and routing peers].

### Why are remote NetBird Network routes disabled by default?

`NETBIRD_CLIENT_ROUTES="disabled"` passes `--disable-client-routes` to
`netbird up`. This prevents routes received from other NetBird routing peers or
exit nodes from taking precedence over UniFi static routes or OSPF-learned
routes. It does not prevent this gateway from serving its own LAN as a routing
peer.

Set it to `enabled`, then run `manage.sh down` followed by `manage.sh up`, only
when the gateway should consume remote NetBird Networks or exit-node routes.
This mirrors the conservative Linux route-acceptance default used with
[tailscale-unifi].

Configurations created by earlier releases do not contain this setting and
default to `enabled`, matching the wrapper's previous default. Add it explicitly
to opt those installations out of client routes.

### Can devices on my UniFi LAN initiate connections to remote resources?

Not automatically. NetBird's [Site-to-VPN] direction requires a persistent
outbound SNAT rule on this gateway and a route from the LAN toward your account's
NetBird address range. This wrapper deliberately installs neither. Follow the
official guide and substitute your configured NetBird interface (`netbird0` by
default) where its Linux examples use `wt0`.

Connecting two whole LANs is a different [Site-to-Site] design with a routing
peer at each end. If the remote destination is a NetBird Network rather than a
peer, client routes must also be enabled on this gateway.

### Why does the wrapper leave DNS unmanaged?

Gateways already provide DNS to their LANs, so the conservative default is
`NETBIRD_DNS_MODE="unmanaged"`. This passes `--disable-dns` to `netbird up`.
Set the value to `managed`, then run `manage.sh up`, if you deliberately want
NetBird to manage DNS on the gateway.

### When should I use legacy routing mode?

Leave `NETBIRD_ROUTING_MODE="auto"` unless `manage.sh diagnose` or the NetBird
service log shows known routing or firewall-chain symptoms. `legacy` sets only
`NB_USE_LEGACY_ROUTING=true`.

Routing mode chooses how NetBird implements routes; it does not choose whether
this gateway consumes remote Network routes. `NETBIRD_CLIENT_ROUTES` controls
that separately.

The wrapper deliberately does not set `NB_DISABLE_CUSTOM_ROUTING`; that separate
option can reject very broad or default routes and break exit-node use.

### Do I need to open UDP/41642 on the WAN firewall?

No. NetBird normally establishes direct connections using outbound ICE/STUN,
and routing peers do not normally require an inbound WAN rule. See NetBird's
[ports and firewall] guidance.

The wrapper uses UDP/41642 to avoid the usual [UniFi WireGuard server] port
51820 and Tailscale's usual port 41641. A static mapping or inbound rule should
only be an optional, measured troubleshooting experiment.

### How do I enrol with a setup key without putting it in shell history?

Create a root-only temporary file, arrange cleanup even if enrolment fails, and
pass its path to NetBird:

```sh
(
  umask 077
  setup_key_file="$(mktemp /tmp/netbird-setup.XXXXXX)" || exit
  trap 'rm -f -- "$setup_key_file"' 0 1 2 15
  vi "$setup_key_file"
  /data/netbird/manage.sh up --setup-key-file "$setup_key_file"
)
```

Do not store a reusable setup key in `netbird-env`.

### Why can I not see `netbird0`?

Check that `/dev/net/tun` exists, run `ip link show netbird0`, and then run
`/data/netbird/manage.sh diagnose`. The NetBird service journal usually contains
the underlying interface or routing error:

```sh
journalctl -u netbird.service -n 200 --no-pager
```

## License and acknowledgements

This project is released under the [MIT License](LICENSE).

Its UniFi persistence approach was adapted from Sierra Softworks'
[tailscale-unifi], whose MIT copyright notice is retained in this repository's
license. This is an independent community project and is not affiliated with
NetBird or Ubiquiti.

[NetBird]: https://netbird.io/
[UniFi Cloud Gateway]: https://ui.com/cloud-gateways
[tailscale-unifi]: https://github.com/SierraSoftworks/tailscale-unifi
[unifi-common]: https://github.com/unifi-utilities/unifi-common
[UniFi WireGuard server]: https://help.ui.com/hc/en-us/articles/115005445768-UniFi-Gateway-WireGuard-VPN-Server
[Networks and routing peers]: https://docs.netbird.io/manage/networks/how-routing-peers-work
[Site-to-VPN]: https://docs.netbird.io/use-cases/remote-access/site-to-vpn
[Site-to-Site]: https://docs.netbird.io/use-cases/remote-access/site-to-site
[ports and firewall]: https://docs.netbird.io/about-netbird/ports-and-firewalls
