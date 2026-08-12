#!/usr/bin/env bash
set -Eeuo pipefail

APPDATA="/mnt/user/appdata/omni"
HOSTNAME_VALUE=""
ADDRESS=""
ADMIN_EMAIL=""
AUTH_MODE="dex"
OIDC_PROVIDER_URL=""
OIDC_CLIENT_ID=""
FORCE_CONFIG=false

usage() {
  cat <<'EOF'
Configure a single-instance Omni installation for Unraid.

Usage:
  setup.sh --hostname NAME --address IP --admin-email EMAIL [options]

Required:
  --hostname NAME          DNS name used to reach Omni (for example omni.home.arpa)
  --address IP             LAN IP advertised to Talos machines
  --admin-email EMAIL      Initial Omni administrator; must match the OIDC email claim

Options:
  --appdata PATH           Appdata directory (default: /mnt/user/appdata/omni)
  --auth MODE              dex, authentik, or oidc (default: dex)
  --oidc-provider-url URL  Issuer URL for authentik/oidc modes
  --oidc-client-id ID      OIDC client ID for authentik/oidc modes
  --force-config           Back up and regenerate YAML config; never rotates identity keys
  -h, --help               Show this help

Secrets are prompted for without echo. For unattended setup, set OMNI_DEX_PASSWORD
or OMNI_OIDC_CLIENT_SECRET in the environment rather than passing secrets as arguments.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
}

need_value() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "$1 requires a value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --appdata) need_value "$@"; APPDATA=$2; shift 2 ;;
    --hostname) need_value "$@"; HOSTNAME_VALUE=$2; shift 2 ;;
    --address) need_value "$@"; ADDRESS=$2; shift 2 ;;
    --admin-email) need_value "$@"; ADMIN_EMAIL=$2; shift 2 ;;
    --auth) need_value "$@"; AUTH_MODE=$2; shift 2 ;;
    --oidc-provider-url) need_value "$@"; OIDC_PROVIDER_URL=$2; shift 2 ;;
    --oidc-client-id) need_value "$@"; OIDC_CLIENT_ID=$2; shift 2 ;;
    --force-config) FORCE_CONFIG=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

if [[ -t 0 ]]; then
  [[ -n "$HOSTNAME_VALUE" ]] || { read -r -p "Omni DNS hostname: " HOSTNAME_VALUE; }
  [[ -n "$ADDRESS" ]] || { read -r -p "Reachable LAN IPv4 address: " ADDRESS; }
  [[ -n "$ADMIN_EMAIL" ]] || { read -r -p "Initial admin email: " ADMIN_EMAIL; }
fi

[[ -n "$HOSTNAME_VALUE" ]] || die "--hostname is required"
[[ -n "$ADDRESS" ]] || die "--address is required"
[[ -n "$ADMIN_EMAIL" ]] || die "--admin-email is required"
[[ "$HOSTNAME_VALUE" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "invalid DNS hostname"
[[ "$ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "--address must be an IPv4 address"
[[ "$ADMIN_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "invalid admin email"
case "$AUTH_MODE" in dex|authentik|oidc) ;; *) die "--auth must be dex, authentik, or oidc" ;; esac

IFS=. read -r ip1 ip2 ip3 ip4 <<<"$ADDRESS"
for octet in "$ip1" "$ip2" "$ip3" "$ip4"; do
  (( 10#$octet <= 255 )) || die "invalid IPv4 address"
done

command -v openssl >/dev/null 2>&1 || die "openssl is required"
command -v docker >/dev/null 2>&1 || [[ "${OMNI_SETUP_TEST_MODE:-0}" == 1 ]] || die "Docker is required"

yaml_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

random_uuid() {
  local hex
  hex=$(openssl rand -hex 16)
  printf '%s-%s-%s-%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

prompt_secret_twice() {
  local label=$1 first second
  [[ -t 0 ]] || die "$label must be supplied through the documented environment variable in non-interactive mode"
  read -r -s -p "$label: " first
  printf '\n' >&2
  read -r -s -p "Confirm $label: " second
  printf '\n' >&2
  [[ -n "$first" ]] || die "$label cannot be empty"
  [[ "$first" == "$second" ]] || die "$label values did not match"
  printf '%s' "$first"
}

mkdir -p "$APPDATA" "$APPDATA/data/etcd" "$APPDATA/dex" "$APPDATA/tls"

identity_files=(
  "$APPDATA/account-id"
  "$APPDATA/omni.asc"
  "$APPDATA/tls/ca.key"
  "$APPDATA/tls/ca.crt"
  "$APPDATA/tls/server.key"
  "$APPDATA/tls/server.crt"
  "$APPDATA/tls/server-chain.pem"
)
identity_count=0
for identity_file in "${identity_files[@]}"; do
  [[ -f "$identity_file" ]] && identity_count=$((identity_count + 1))
done
if (( identity_count > 0 && identity_count < ${#identity_files[@]} )); then
  die "identity material is incomplete; restore the whole appdata backup rather than regenerating individual keys"
fi

if (( identity_count == 0 )); then
  log "Generating persistent Omni identity and TLS material..."
  random_uuid >"$APPDATA/account-id"

  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -subj "/CN=Omni Unraid Local CA/O=Omni Unraid" \
    -keyout "$APPDATA/tls/ca.key" -out "$APPDATA/tls/ca.crt" >/dev/null 2>&1

  san_config=$(mktemp "${TMPDIR:-/tmp}/omni-openssl.XXXXXX")
  trap 'rm -f "${san_config:-}"' EXIT
  {
    printf '[req]\ndistinguished_name=dn\nreq_extensions=req_ext\nprompt=no\n'
    printf '[dn]\nCN=%s\n' "$HOSTNAME_VALUE"
    printf '[req_ext]\nsubjectAltName=@alt_names\n'
    printf '[alt_names]\nDNS.1=%s\nIP.1=%s\nIP.2=127.0.0.1\n' "$HOSTNAME_VALUE" "$ADDRESS"
  } >"$san_config"
  openssl req -new -newkey rsa:4096 -nodes -keyout "$APPDATA/tls/server.key" \
    -out "$APPDATA/tls/server.csr" -config "$san_config" >/dev/null 2>&1
  openssl x509 -req -sha256 -days 825 -in "$APPDATA/tls/server.csr" \
    -CA "$APPDATA/tls/ca.crt" -CAkey "$APPDATA/tls/ca.key" -CAcreateserial \
    -extfile "$san_config" -extensions req_ext -out "$APPDATA/tls/server.crt" >/dev/null 2>&1
  cp "$APPDATA/tls/server.crt" "$APPDATA/tls/server-chain.pem"
  printf '\n' >>"$APPDATA/tls/server-chain.pem"
  sed -n '/-----BEGIN CERTIFICATE-----/,$p' "$APPDATA/tls/ca.crt" >>"$APPDATA/tls/server-chain.pem"
  rm -f "$APPDATA/tls/server.csr" "$APPDATA/tls/ca.srl" "$san_config"
  trap - EXIT

  if [[ "${OMNI_SETUP_TEST_MODE:-0}" == 1 ]]; then
    printf '%s\n' 'TEST-ONLY-OMNI-ENCRYPTION-KEY' >"$APPDATA/omni.asc"
  elif command -v gpg >/dev/null 2>&1; then
    gnupg_home=$(mktemp -d "${TMPDIR:-/tmp}/omni-gnupg.XXXXXX")
    chmod 700 "$gnupg_home"
    gpg --homedir "$gnupg_home" --batch --passphrase '' --quick-generate-key \
      'Omni Unraid (etcd encryption) <omni@internal.local>' rsa4096 cert never >/dev/null 2>&1
    fingerprint=$(gpg --homedir "$gnupg_home" --with-colons --list-keys omni@internal.local | awk -F: '$1 == "fpr" {print $10; exit}')
    gpg --homedir "$gnupg_home" --batch --passphrase '' --quick-add-key "$fingerprint" rsa4096 encr never >/dev/null 2>&1
    gpg --homedir "$gnupg_home" --batch --export-secret-key --armor omni@internal.local >"$APPDATA/omni.asc"
    rm -rf "$gnupg_home"
  else
    docker run --rm -v "$APPDATA:/work" alpine:3.22 sh -ec '
      apk add --no-cache gnupg >/dev/null
      export GNUPGHOME=/tmp/gnupg
      mkdir -m 700 "$GNUPGHOME"
      gpg --batch --passphrase "" --quick-generate-key "Omni Unraid (etcd encryption) <omni@internal.local>" rsa4096 cert never
      fingerprint=$(gpg --with-colons --list-keys omni@internal.local | awk -F: '\''$1 == "fpr" {print $10; exit}'\'')
      gpg --batch --passphrase "" --quick-add-key "$fingerprint" rsa4096 encr never
      gpg --batch --export-secret-key --armor omni@internal.local > /work/omni.asc
    '
  fi
else
  log "Preserving existing account UUID, CA, TLS certificate, and encryption key."
fi

if [[ ! -f "$APPDATA/tls/trust-bundle.pem" ]]; then
  if [[ "${OMNI_SETUP_TEST_MODE:-0}" == 1 ]]; then
    cp "$APPDATA/tls/ca.crt" "$APPDATA/tls/trust-bundle.pem"
  else
    docker run --rm --entrypoint cat ghcr.io/siderolabs/omni:latest \
      /etc/ssl/certs/ca-certificates.crt >"$APPDATA/tls/trust-bundle.pem" || \
      die "could not extract the system CA bundle from the Omni image"
    printf '\n' >>"$APPDATA/tls/trust-bundle.pem"
    sed -n '/-----BEGIN CERTIFICATE-----/,$p' "$APPDATA/tls/ca.crt" >>"$APPDATA/tls/trust-bundle.pem"
  fi
fi

ACCOUNT_ID=$(tr -d '[:space:]' <"$APPDATA/account-id")

if [[ "$AUTH_MODE" == "dex" ]]; then
  if [[ ! -f "$APPDATA/dex/dex.yaml" || "$FORCE_CONFIG" == true ]]; then
    DEX_PASSWORD=${OMNI_DEX_PASSWORD:-}
    [[ -n "$DEX_PASSWORD" ]] || DEX_PASSWORD=$(prompt_secret_twice "Dex admin password")
    DEX_CLIENT_SECRET=$(openssl rand -hex 32)
    if [[ "${OMNI_SETUP_TEST_MODE:-0}" == 1 ]]; then
      # shellcheck disable=SC2016 # bcrypt hashes contain literal dollar signs.
      DEX_PASSWORD_HASH='$2y$12$test.hash.for.configuration.validation.only'
    else
      DEX_PASSWORD_HASH=$(printf '%s\n%s\n' "$DEX_PASSWORD" "$DEX_PASSWORD" | \
        docker run --rm -i httpd:2.4-alpine htpasswd -niBC 12 admin | sed -n 's/^admin://p')
    fi
    [[ -n "$DEX_PASSWORD_HASH" ]] || die "failed to generate the Dex password hash"
    cat >"$APPDATA/dex/dex.yaml.new" <<EOF
issuer: https://${HOSTNAME_VALUE}:5556
storage:
  type: sqlite3
  config:
    file: /config/data/dex.db
web:
  https: 0.0.0.0:5556
  tlsCert: /config/tls/server-chain.pem
  tlsKey: /config/tls/server.key
enablePasswordDB: true
staticClients:
  - name: Omni
    id: omni
    secret: $(yaml_quote "$DEX_CLIENT_SECRET")
    redirectURIs:
      - https://${HOSTNAME_VALUE}:8443/oidc/consume
staticPasswords:
  - email: $(yaml_quote "$ADMIN_EMAIL")
    username: admin
    preferredUsername: admin
    userID: $(yaml_quote "$ACCOUNT_ID")
    hash: $(yaml_quote "$DEX_PASSWORD_HASH")
EOF
    [[ ! -f "$APPDATA/dex/dex.yaml" ]] || cp "$APPDATA/dex/dex.yaml" "$APPDATA/dex/dex.yaml.bak.$(date +%Y%m%d%H%M%S)"
    mv "$APPDATA/dex/dex.yaml.new" "$APPDATA/dex/dex.yaml"
  else
    DEX_CLIENT_SECRET=$(sed -n 's/^    secret: "\(.*\)"/\1/p' "$APPDATA/dex/dex.yaml" | head -n 1)
    [[ -n "$DEX_CLIENT_SECRET" ]] || die "could not read the existing Dex client secret"
    log "Preserving existing Dex users and client secret."
  fi
  OIDC_PROVIDER_URL="https://${HOSTNAME_VALUE}:5556"
  OIDC_CLIENT_ID="omni"
  OIDC_CLIENT_SECRET="$DEX_CLIENT_SECRET"
else
  if [[ -t 0 ]]; then
    [[ -n "$OIDC_PROVIDER_URL" ]] || { read -r -p "OIDC issuer URL: " OIDC_PROVIDER_URL; }
    [[ -n "$OIDC_CLIENT_ID" ]] || { read -r -p "OIDC client ID: " OIDC_CLIENT_ID; }
  fi
  [[ "$OIDC_PROVIDER_URL" =~ ^https://[^[:space:]]+$ ]] || die "an https --oidc-provider-url is required"
  [[ -n "$OIDC_CLIENT_ID" ]] || die "--oidc-client-id is required"
  OIDC_CLIENT_SECRET=${OMNI_OIDC_CLIENT_SECRET:-}
  if [[ -z "$OIDC_CLIENT_SECRET" && -f "$APPDATA/omni.yaml" && "$FORCE_CONFIG" != true ]]; then
    OIDC_CLIENT_SECRET=$(sed -n 's/^    clientSecret: "\(.*\)"/\1/p' "$APPDATA/omni.yaml" | head -n 1)
  fi
  [[ -n "$OIDC_CLIENT_SECRET" ]] || OIDC_CLIENT_SECRET=$(prompt_secret_twice "OIDC client secret")
fi

if [[ -f "$APPDATA/omni.yaml" && "$FORCE_CONFIG" != true ]]; then
  log "Preserving existing $APPDATA/omni.yaml (use --force-config to regenerate it)."
else
  [[ ! -f "$APPDATA/omni.yaml" ]] || cp "$APPDATA/omni.yaml" "$APPDATA/omni.yaml.bak.$(date +%Y%m%d%H%M%S)"
  cat >"$APPDATA/omni.yaml.new" <<EOF
# Generated by unraid-omni-sidero/setup.sh. Back up this entire directory.
account:
  id: $(yaml_quote "$ACCOUNT_ID")
  name: "unraid-omni"

auth:
  initialUsers:
    - $(yaml_quote "$ADMIN_EMAIL")
  auth0:
    enabled: false
  oidc:
    enabled: true
    providerURL: $(yaml_quote "$OIDC_PROVIDER_URL")
    clientID: $(yaml_quote "$OIDC_CLIENT_ID")
    clientSecret: $(yaml_quote "$OIDC_CLIENT_SECRET")
    scopes:
      - openid
      - profile
      - email

services:
  api:
    endpoint: "0.0.0.0:8443"
    advertisedURL: "https://${HOSTNAME_VALUE}:8443"
    certFile: "/config/tls/server-chain.pem"
    keyFile: "/config/tls/server.key"
  kubernetesProxy:
    endpoint: "0.0.0.0:8100"
    advertisedURL: "https://${HOSTNAME_VALUE}:8100"
    certFile: "/config/tls/server-chain.pem"
    keyFile: "/config/tls/server.key"
  machineAPI:
    endpoint: "0.0.0.0:8090"
    advertisedURL: "https://${HOSTNAME_VALUE}:8090"
    certFile: "/config/tls/server-chain.pem"
    keyFile: "/config/tls/server.key"
  siderolink:
    joinTokensMode: strict
    eventSinkPort: 8091
    wireGuard:
      endpoint: "0.0.0.0:50180"
      advertisedEndpoint: "${ADDRESS}:50180"
  workloadProxy:
    enabled: false

storage:
  default:
    kind: etcd
    etcd:
      embedded: true
      runElections: false
      embeddedDBPath: "/config/data/etcd"
      privateKeySource: "file:///config/omni.asc"
  sqlite:
    path: "/config/data/omni.db"
EOF
  mv "$APPDATA/omni.yaml.new" "$APPDATA/omni.yaml"
  log "Wrote $APPDATA/omni.yaml"
fi

chmod 600 "$APPDATA/account-id" "$APPDATA/omni.asc" "$APPDATA/tls/ca.key" "$APPDATA/tls/server.key"
chmod 644 "$APPDATA/tls/ca.crt" "$APPDATA/tls/server.crt" "$APPDATA/tls/server-chain.pem" "$APPDATA/omni.yaml"
chmod 644 "$APPDATA/tls/trust-bundle.pem"
[[ ! -f "$APPDATA/dex/dex.yaml" ]] || chmod 644 "$APPDATA/dex/dex.yaml"

cat <<EOF

Setup complete.

  Appdata:       ${APPDATA}
  Omni URL:      https://${HOSTNAME_VALUE}:8443
  Authentication: ${AUTH_MODE}
  Local CA:      ${APPDATA}/tls/ca.crt

Make ${HOSTNAME_VALUE} resolve to ${ADDRESS}, trust ca.crt on your clients, and
open the ports documented in README.md. For Dex mode, install/start Omni-Dex
before Omni. EULA acceptance is completed in the Omni UI on first launch.
EOF
