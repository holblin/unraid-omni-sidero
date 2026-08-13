# Installing Omni on Unraid

This guide installs a single Omni server with embedded etcd. The default authentication option also installs Dex as a second container so you can sign in with a local administrator account.

No domain or local DNS is required. The examples use the Unraid server's static LAN IP, `192.168.1.10`; replace it everywhere with your own address.

## Before you begin

- Give Unraid a static IPv4 address or DHCP reservation.
- Confirm `/dev/net/tun` exists by running `ls -l /dev/net/tun` in the Unraid terminal.
- Ensure ports `8443`, `8090`, `8091`, `8100`, `5556`, and `50180` are not already used. Port `5556` is only needed for Dex.
- Decide whether to use the included local Dex login or an existing Authentik/OIDC provider.
- Read Sidero's licensing terms. Free self-hosting is intended for non-production use, and Omni requires EULA acceptance.

## Fast, repeatable installation

This command always downloads the current installer from the repository, configures Omni, and installs or refreshes both DockerMan templates:

```sh
curl -fsSL https://raw.githubusercontent.com/holblin/unraid-omni-sidero/main/install-unraid.sh | bash -s -- --address 192.168.101.96 --admin-email holblin@gmail.com --auth dex
```

It is safe to replay while testing new revisions. Existing account identity, certificates, encryption keys, databases, and configuration are preserved. The current templates are overwritten with the newest repository versions. If setup needs a Dex password, it prompts through the terminal even though the installer itself is streamed through `curl`.

The installer does not automatically create or replace running containers. After it completes, select the refreshed templates under **Docker → Add Container** as described below.

## Manual installation

### 1. Download the project

Open **Unraid WebUI → Terminal** and run:

```sh
cd /tmp
git clone https://github.com/holblin/unraid-omni-sidero.git
cd unraid-omni-sidero
```

Using `/tmp` is intentional: the repository itself is only needed during setup. Persistent files are written under `/mnt/user/appdata/omni`.

If `git` is unavailable, download and extract the repository archive instead.

### 2. Generate the configuration

For the simplest local login:

```sh
./setup.sh \
  --address 192.168.1.10 \
  --admin-email you@example.com \
  --auth dex
```

Enter a strong Dex password when prompted. The script creates `/mnt/user/appdata/omni` and prints the resulting Omni URL.

For Authentik or another OIDC provider, configure that provider first and use the corresponding example in [Options reference](options.md#authentication-modes).

### 3. Install the Unraid templates

#### Direct installation (recommended)

Still in the cloned repository, copy the templates into DockerMan's persistent user-template directory:

```sh
mkdir -p /boot/config/plugins/dockerMan/templates-user
cp templates/omni.xml /boot/config/plugins/dockerMan/templates-user/my-omni.xml
cp templates/omni-dex.xml /boot/config/plugins/dockerMan/templates-user/my-omni-dex.xml
```

Then:

1. Open **Docker → Add Container**.
2. Select `Omni-Dex` from the **Template** menu when using Dex.
3. Confirm **Omni Appdata** is `/mnt/user/appdata/omni`, then select **Apply**.
4. Start `Omni-Dex` and check its log for errors.
5. Return to **Docker → Add Container** and select `Omni`.
6. Confirm **Omni Appdata** is `/mnt/user/appdata/omni` and apply it.

For Authentik or generic OIDC, skip `Omni-Dex` and install only `Omni`.

#### Template repository installation

If your Unraid version exposes a **Template repositories** field, add:

```text
https://github.com/holblin/unraid-omni-sidero
```

After saving, the same `Omni` and `Omni-Dex` entries should appear under **Docker → Add Container**. Direct installation above works when that legacy field is unavailable.

### 4. Trust the generated certificate authority

Copy this file from Unraid to every computer that will open Omni:

```text
/mnt/user/appdata/omni/tls/ca.crt
```

Import it as a trusted root certificate using your operating system or browser's certificate manager. This is necessary because the default IP certificate is signed by a private CA rather than a public certificate authority.

Do not distribute `ca.key`, `server.key`, or `omni.asc`.

### 5. Open Omni

Browse to:

```text
https://192.168.1.10:8443
```

On the first visit:

1. Accept the Omni EULA.
2. Select the OIDC login option.
3. For Dex, sign in using the email supplied to `--admin-email` and the password entered during setup.
4. Confirm the Omni dashboard loads.

### 6. Check machine connectivity

Talos machines must be able to reach the Unraid IP on:

- `8090/tcp` for machine registration
- `8091/tcp` for events
- `50180/udp` for SideroLink WireGuard

Administrative clients using an Omni-generated kubeconfig also need `8100/tcp`. These are LAN connections by default; router port forwarding is unnecessary when all machines are on the same network.

## Updating an existing installation

Before using **Force Update** in Unraid:

1. Stop `Omni`, then `Omni-Dex`.
2. Back up `/mnt/user/appdata/omni` as one complete directory.
3. Review Sidero's Omni upgrade notes.
4. Update/start Dex first, then update/start Omni.

The templates track `latest`. To control upgrades, replace `latest` in each container's **Repository** field with a tested release tag.

## Removing or recovering the containers

Removing an Unraid container does not remove `/mnt/user/appdata/omni`. Reinstall the templates with the same appdata path to recover the installation.

Never delete or regenerate only part of the identity material. The embedded database, `account-id`, `omni.asc`, and TLS files must be backed up and restored together.
