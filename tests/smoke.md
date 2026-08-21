# Docker smoke test

Run these checks on an Unraid test host after `setup.sh` and template installation:

1. Confirm `/dev/net/tun` exists and the documented ports are unused.
2. In Dex mode, start `Omni-Dex`, inspect its logs, then start `Omni`.
3. Confirm `curl --cacert /mnt/user/appdata/omni/tls/ca.crt https://UNRAID-IP:8443` reaches Omni.
4. Accept the EULA and complete the selected OIDC login.
5. Restart both containers and confirm the same account and Omni state remain.
6. Recreate both containers from their templates and repeat the state check.
7. Confirm `omni.yaml` advertises `grpc://UNRAID-IP:8090`, that port 8090 is reachable only from the trusted Talos LAN, and that no router port-forward exposes it.
8. Download fresh installation media from this Omni instance, boot a Talos machine with it, and verify the machine appears in Omni.
9. Download a kubeconfig and confirm it connects through `https://UNRAID-IP:8100`.

These checks are intentionally manual: a meaningful test requires host networking, WireGuard, an identity provider, and a Talos machine.
