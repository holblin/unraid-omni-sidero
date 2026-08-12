# Omni for Unraid

Unraid templates and a setup helper for running one self-hosted [Sidero Omni](https://docs.siderolabs.com/omni/overview/what-is-omni) instance with embedded etcd. It uses Sidero's official Omni image and, for the easiest local login, the official Dex image.

> [!IMPORTANT]
> Omni's Business Source License permits free self-hosting for non-production use. Production use may require an agreement with Sidero Labs. Omni also requires EULA acceptance on first launch. Review [Sidero's licensing guidance](https://docs.siderolabs.com/omni/self-hosted/prod-vs-non-prod) before deploying it.

## What gets installed

- `Omni`: the single Omni server, embedded etcd, SQLite, API/UI, SideroLink, and Kubernetes proxy.
- `Omni-Dex`: optional. It supplies one local password-backed OIDC login. Do not install it when using Authentik or another OIDC provider.
- `/mnt/user/appdata/omni`: configuration, database files, account UUID, TLS CA/key, and the etcd encryption key. Back up this entire directory as one unit.

The default endpoints are:

| Port | Protocol | Purpose |
| --- | --- | --- |
| 8443 | TCP | Omni UI and API |
| 8090 | TCP | Machine/SideroLink API |
| 8091 | TCP | Talos event sink |
| 8100 | TCP | Kubernetes API proxy |
| 5556 | TCP | Dex OIDC, Dex mode only |
| 50180 | UDP | SideroLink WireGuard |

Omni uses host networking because SideroLink/WireGuard requires it. Ensure these ports are unused on Unraid. The dynamic workload load-balancer range and workload proxy are not enabled by this project.

## Install

### 1. Configure DNS

Choose a stable DNS name, such as `omni.home.arpa`, and make it resolve to the Unraid server's LAN IP from browsers and every Talos machine. A local DNS record is preferred; temporary `/etc/hosts` entries also work for clients that support them.

### 2. Run the setup helper

From an Unraid terminal:

```sh
git clone https://github.com/holblin/unraid-omni-sidero.git /tmp/unraid-omni-sidero
cd /tmp/unraid-omni-sidero
./setup.sh \
  --appdata /mnt/user/appdata/omni \
  --hostname omni.home.arpa \
  --address 192.168.1.10 \
  --admin-email you@example.com \
  --auth dex
```

The script prompts for secrets without echoing them. It generates a unique, persistent account ID, a local CA and server certificate, a GPG encryption key, and readable YAML configuration. It is safe to rerun: existing identity material and configuration are preserved. `--force-config` explicitly backs up and regenerates YAML, but never rotates identity keys.

Switching authentication modes requires `--force-config`. Review the generated backup and new configuration before restarting the containers.

Do not delete or independently regenerate `account-id`, `omni.asc`, or files below `tls/` after Omni has data. Restore the complete appdata backup if this material is lost or incomplete.

### 3. Trust the local CA

Import `/mnt/user/appdata/omni/tls/ca.crt` into the trust store of every browser/administrative workstation that connects to Omni. The certificate covers the configured DNS name, LAN IP, and loopback address.

If an external OIDC provider uses a different private CA, append that CA certificate to `tls/trust-bundle.pem`. Omni reads this bundle through `SSL_CERT_FILE`.

### 4. Add the Unraid templates

In Unraid, add this repository URL under **Docker → Template repositories**:

```text
https://github.com/holblin/unraid-omni-sidero
```

Then choose **Docker → Add Container** and select the templates:

1. For Dex mode, install and start `Omni-Dex` first.
2. Install `Omni` and confirm its appdata path exactly matches the path passed to `setup.sh`.
3. Open `https://omni.home.arpa:8443`, accept the EULA, and sign in.

For Authentik or generic OIDC, install only `Omni`.

## Authentication choices

### Local Dex (default)

Run setup with `--auth dex`. The email passed to `--admin-email` is the initial Omni administrator and the username entered on the Dex login page. Start `Omni-Dex` before `Omni`.

Dex stores its password hash and database beneath the shared appdata directory. Changing the clear-text environment variable later does not change an existing Dex password; intentionally regenerate the Dex configuration with `--force-config`, or edit Dex according to its documentation.

### Authentik

In Authentik:

1. Create an OAuth2/OpenID provider and application for Omni.
2. Set the strict redirect URI to `https://omni.home.arpa:8443/oidc/consume`, substituting your hostname.
3. Ensure the provider returns `openid`, `profile`, and `email`, including a verified `email` claim.
4. Copy the provider's issuer URL, client ID, and client secret.

Then run:

```sh
./setup.sh \
  --hostname omni.home.arpa \
  --address 192.168.1.10 \
  --admin-email you@example.com \
  --auth authentik \
  --oidc-provider-url https://auth.example.com/application/o/omni/ \
  --oidc-client-id replace-me
```

Omit `OMNI_OIDC_CLIENT_SECRET` to receive a hidden interactive prompt. The admin email must exactly match Authentik's `email` claim. Use Authentik's displayed issuer URL rather than constructing it from this example.

### Generic OIDC

Use `--auth oidc` with the provider's exact issuer URL and client ID. Register the same redirect URI shown above. The provider must support OIDC discovery and return a verified email claim:

```sh
./setup.sh \
  --hostname omni.home.arpa \
  --address 192.168.1.10 \
  --admin-email you@example.com \
  --auth oidc \
  --oidc-provider-url https://idp.example.com/realms/homelab \
  --oidc-client-id omni
```

This works with standards-compliant providers such as Authentik and Keycloak. Provider-specific logout, group, and role mapping are advanced configuration and are not generated automatically.

## Advanced configuration

Edit `/mnt/user/appdata/omni/omni.yaml`, then restart Omni. The file uses Sidero's current [configuration schema](https://docs.siderolabs.com/omni/reference/omni-configuration). Useful extensions include S3 etcd backups, workload proxying, external etcd, and break-glass configuration.

Changing an advertised hostname, LAN address, or port also requires a matching TLS certificate and firewall/DNS changes. Rerunning with `--force-config` does not rotate the existing certificate, so a hostname/address change requires a deliberate migration and new certificate signed by the existing CA.

## Firewall and connectivity

Allow the tabled ports from the networks that need them. At minimum:

- Browsers and CLI clients need `8443/tcp` and, when applicable, `5556/tcp`.
- Talos machines need `8090/tcp`, `8091/tcp`, and `50180/udp` to the advertised Unraid address.
- Administrative clients using generated kubeconfigs need `8100/tcp`.
- Omni needs outbound HTTPS/DNS access to the configured OIDC provider, Sidero registries, and `factory.talos.dev` unless those services are mirrored.

This repository does not alter Unraid firewall rules, router port forwards, DNS, or reverse-proxy configuration. Exposing Omni publicly requires a separate threat-model and trusted certificate setup.

## Updates

The templates intentionally track `:latest`, so **Force Update** may install a new Omni or Dex release. Before updating:

1. Stop Omni and Dex.
2. Back up the complete appdata directory together.
3. Review [Omni's upgrade notes](https://docs.siderolabs.com/omni/self-hosted/upgrading-omni) and release notes.
4. Update Dex first if needed, then Omni; start Dex before Omni.

For controlled upgrades, replace `latest` in the Unraid Repository field with a tested version tag.

## Backup and restore

For a consistent cold backup, stop Omni and Dex and copy `/mnt/user/appdata/omni` in full. Restore it to the same path before recreating either container. Never restore the database without its original `account-id` and `omni.asc` encryption key.

S3 etcd backups can be enabled in `omni.yaml` following [Sidero's backup documentation](https://docs.siderolabs.com/omni/self-hosted/backup-omni-database), but they do not replace backing up TLS, configuration, SQLite, and encryption keys.

## Troubleshooting

- **Omni exits immediately:** check `docker logs Omni`; verify `/dev/net/tun` exists, the appdata path is correct, and no required host port is occupied.
- **OIDC discovery or certificate error:** verify the issuer is reachable from Unraid and append the provider's private CA to `tls/trust-bundle.pem`.
- **Redirect mismatch:** the provider redirect must exactly equal `https://HOSTNAME:8443/oidc/consume`.
- **Login succeeds but access is denied:** the OIDC email claim must exactly match the initial admin email in `omni.yaml`.
- **Browser certificate warning:** access Omni by the configured hostname and trust `tls/ca.crt` on that client.
- **Talos machine never appears:** verify DNS, `8090/tcp`, `8091/tcp`, `50180/udp`, and that the advertised LAN IP is reachable from the machine.
- **Port 8443 is unavailable:** change both API endpoint/advertised URL in `omni.yaml`, regenerate a matching setup if required, and update the template WebUI URL.

## Manual acceptance checklist

- Dex mode reaches the login page and accepts the configured local account.
- Authentik/generic OIDC returns to `/oidc/consume` and creates the matching initial admin.
- Omni and Dex restart cleanly after an Unraid reboot.
- Recreating containers preserves users, clusters, embedded etcd, and SQLite state.
- A Talos machine can reach the machine API and establish SideroLink WireGuard.
- An Omni-generated kubeconfig reaches the Kubernetes proxy on port 8100.

## Development

Run `./tests/test.sh`. It validates template XML and exercises all setup modes without creating real GPG keys or pulling images. Docker smoke checks are documented in `tests/smoke.md` because they require host networking, `/dev/net/tun`, and deployment-specific DNS.

This repository's scripts and templates are MIT licensed. Omni and Dex retain their own upstream licenses.
