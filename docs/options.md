# Options reference

## Setup command

```text
setup.sh --address IP --admin-email EMAIL [options]
```

| Option | Required | Default | Description |
| --- | --- | --- | --- |
| `--address IP` | Yes | — | Static Unraid LAN IPv4 address. Used in advertised Omni endpoints, the WireGuard endpoint, and the generated TLS certificate. |
| `--admin-email EMAIL` | Yes | — | Initial Omni administrator. In Dex mode this is also the login email. With external OIDC it must exactly match the provider's `email` claim. |
| `--appdata PATH` | No | `/mnt/user/appdata/omni` | Persistent host directory containing configuration, databases, TLS material, and encryption keys. Both templates must use the same path. |
| `--hostname NAME` | No | Value of `--address` | Optional DNS name used instead of the IP in advertised URLs, Dex issuer, and redirect URI. The generated certificate includes this DNS name and the IP. |
| `--auth MODE` | No | `dex` | Authentication mode: `dex`, `authentik`, or `oidc`. |
| `--oidc-provider-url URL` | Authentik/OIDC only | — | Exact HTTPS issuer URL published by the identity provider. This is not necessarily its login-page URL. |
| `--oidc-client-id ID` | Authentik/OIDC only | — | OAuth2/OIDC client identifier registered for Omni. |
| `--force-config` | No | Off | Backs up and regenerates `omni.yaml`; in Dex mode it also backs up/regenerates `dex.yaml`, password hash, and client secret. It never rotates the account UUID, CA, server key, or etcd encryption key. |
| `-h`, `--help` | No | — | Prints command help without changing files. |

If `--address` or `--admin-email` is omitted in an interactive terminal, setup prompts for it. Non-interactive runs must provide both.

### Secret environment variables

| Variable | Used by | Description |
| --- | --- | --- |
| `OMNI_DEX_PASSWORD` | `--auth dex` | Supplies the initial local password without a prompt. Prefer an interactive prompt where possible; environment variables can be visible to privileged processes. The clear-text password is fed once to `htpasswd` and is not written to appdata. |
| `OMNI_OIDC_CLIENT_SECRET` | `--auth authentik` or `oidc` | Supplies the provider's client secret without a prompt. It is written to `omni.yaml` because Omni requires it at startup; protect and back up that file accordingly. |

Do not pass secrets as command-line arguments because they can be saved in shell history or exposed in process listings.

## Authentication modes

### `dex`

The default and simplest option. Setup generates a Dex configuration, bcrypt password hash, random Omni/Dex client secret, and persistent Dex SQLite database.

Install both templates and start `Omni-Dex` before `Omni`. The redirect URI is:

```text
https://UNRAID-IP:8443/oidc/consume
```

If `--hostname` is supplied, replace `UNRAID-IP` with that hostname.

### `authentik`

Uses an existing Authentik instance. In Authentik, create an OAuth2/OpenID provider and application with:

- A strict redirect URI of `https://UNRAID-IP:8443/oidc/consume`
- Scopes `openid`, `profile`, and `email`
- A verified `email` claim matching `--admin-email`

Example:

```sh
./setup.sh \
  --address 192.168.1.10 \
  --admin-email you@example.com \
  --auth authentik \
  --oidc-provider-url https://auth.example.com/application/o/omni/ \
  --oidc-client-id omni
```

Install only the Omni template.

### `oidc`

Uses any standards-compliant external OIDC provider, such as Keycloak. Register the same redirect URI and claims described for Authentik, then supply the provider's exact issuer URL and client ID.

Example:

```sh
./setup.sh \
  --address 192.168.1.10 \
  --admin-email you@example.com \
  --auth oidc \
  --oidc-provider-url https://idp.example.com/realms/homelab \
  --oidc-client-id omni
```

Install only the Omni template.

## Omni template fields

| Field | Default | Description |
| --- | --- | --- |
| **Name** | `Omni` | Unraid container name. It can be changed without changing Omni's account identity. |
| **Repository** | `ghcr.io/siderolabs/omni:latest` | Official upstream image. Replace `latest` with a release tag for controlled upgrades. |
| **Network Type** | `Host` | Required for SideroLink networking. Ports therefore bind directly on the Unraid host and cannot be remapped through normal bridge-mode port fields. |
| **Privileged** | Off | Full privileged mode is unnecessary. |
| **Extra Parameters** | `--restart unless-stopped --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun` | Adds the network capability and TUN device required by WireGuard, plus restart policy. Do not remove these options. |
| **Post Arguments** | `--config-path=/config/omni.yaml` | Makes Omni load the generated YAML file. |
| **Omni Appdata** | `/mnt/user/appdata/omni` → `/config` | Persistent configuration and data mount. Change the host side only if the same path was supplied to `setup.sh`. |
| **TLS trust bundle** | `/config/tls/trust-bundle.pem` | `SSL_CERT_FILE` used for normal public roots plus the generated local CA. Append a private OIDC-provider CA here when necessary. |

The template's WebUI shortcut points to `https://[IP]:8443`.

## Dex template fields

| Field | Default | Description |
| --- | --- | --- |
| **Name** | `Omni-Dex` | Unraid container name. |
| **Repository** | `ghcr.io/dexidp/dex:latest` | Official upstream Dex image. It may be pinned to a release tag. |
| **Network Type** | `Host` | Allows Dex to listen directly on `5556/tcp`. |
| **Extra Parameters** | `--restart unless-stopped` | Restarts Dex unless it was manually stopped. |
| **Post Arguments** | `dex serve /config/dex/dex.yaml` | Starts Dex with the generated configuration. |
| **Omni Appdata** | `/mnt/user/appdata/omni` → `/config` | Shared read/write mount. Dex reads TLS/configuration and writes `data/dex.db`. It must match Omni's path. |

Do not install this template for Authentik or generic OIDC modes.

## Network options and ports

| Default | Config path | Purpose |
| --- | --- | --- |
| `8443/tcp` | `services.api.endpoint` | Omni UI and API |
| `8090/tcp` | `services.machineAPI.endpoint` | LAN-only plaintext gRPC machine registration; restrict to trusted Talos networks |
| `8091/tcp` | `services.siderolink.eventSinkPort` | Talos event sink inside the SideroLink tunnel; no LAN exposure required |
| `8100/tcp` | `services.kubernetesProxy.endpoint` | Kubernetes API proxy used by generated kubeconfigs |
| `5556/tcp` | `dex.yaml` issuer/web settings | Dex OIDC, only in Dex mode |
| `50180/udp` | `services.siderolink.wireGuard` | SideroLink WireGuard tunnel |

Because Omni uses host networking, changing a port means editing every matching listening endpoint, advertised URL, OIDC redirect, certificate expectation, firewall rule, and WebUI shortcut. Regenerating configuration alone does not regenerate existing certificates.

## Generated files

| Path under appdata | Purpose | Back up? |
| --- | --- | --- |
| `omni.yaml` | Omni services, authentication, and storage configuration; contains the OIDC client secret | Yes |
| `account-id` | Permanent Omni account UUID | Yes, critical |
| `omni.asc` | Secret GPG key used to encrypt/decrypt embedded-etcd data | Yes, critical |
| `data/etcd/` | Embedded Omni datastore | Yes |
| `data/omni.db` | SQLite logs and frequently updated state | Yes |
| `data/dex.db` | Dex state in Dex mode | Yes |
| `dex/dex.yaml` | Dex users, password hash, and OAuth client secret | Yes |
| `tls/ca.crt` | Local CA certificate to install on clients | Yes; safe to distribute |
| `tls/ca.key` | Local CA private key | Yes, critical; never distribute |
| `tls/server.crt` / `server-chain.pem` | Omni/Dex server certificate and chain | Yes |
| `tls/server.key` | Shared Omni/Dex private TLS key; group-readable only by Dex GID 1001 | Yes, critical; never distribute or expose the appdata share publicly |
| `tls/trust-bundle.pem` | CA bundle used for Omni's outbound TLS verification | Yes |

Back up the entire appdata directory together. Setup refuses to continue if it finds only part of the critical identity set because silently generating replacements could make existing encrypted data unreadable.

## Generated Omni defaults

- Embedded etcd enabled, with elections disabled for a single instance
- SQLite and etcd stored inside persistent appdata
- Strict SideroLink join tokens
- Workload proxy disabled
- Auth0 disabled and the selected OIDC provider enabled
- Browser API and Kubernetes proxy protected by the generated certificate
- Machine registration over LAN-only plaintext gRPC with strict join-token authentication, followed by encrypted SideroLink transport
- EULA acceptance deferred to the Omni UI

Advanced Omni fields can be edited directly in `omni.yaml`. Consult Sidero's [complete Omni configuration reference](https://docs.siderolabs.com/omni/reference/omni-configuration) before enabling external etcd, backups, workload proxying, or other features.
