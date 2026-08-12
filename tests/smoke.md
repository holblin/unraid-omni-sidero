# Docker smoke test

Run these checks on an Unraid test host after `setup.sh` and template installation:

1. Confirm `/dev/net/tun` exists and the documented ports are unused.
2. In Dex mode, start `Omni-Dex`, inspect its logs, then start `Omni`.
3. Confirm `curl --cacert /mnt/user/appdata/omni/tls/ca.crt https://HOSTNAME:8443` reaches Omni.
4. Accept the EULA and complete the selected OIDC login.
5. Restart both containers and confirm the same account and Omni state remain.
6. Recreate both containers from their templates and repeat the state check.
7. Boot a Talos machine using the Omni join configuration and verify it appears in Omni.
8. Download a kubeconfig and confirm it connects through `https://HOSTNAME:8100`.

These checks are intentionally manual: a meaningful test requires reachable DNS, host networking, WireGuard, an identity provider, and a Talos machine.

