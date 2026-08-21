#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/unraid-omni-tests.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local file=$1 pattern=$2
  grep -Fq -- "$pattern" "$file" || fail "$file does not contain: $pattern"
}

printf '%s\n' 'Checking shell syntax...'
bash -n "$ROOT/setup.sh" "$ROOT/install-unraid.sh" "$ROOT/tests/test.sh"
# shellcheck disable=SC2016 # Assert the literal safe BASH_SOURCE expansion.
assert_file_contains "$ROOT/install-unraid.sh" 'SCRIPT_PATH="${BASH_SOURCE[0]:-}"'
if "$ROOT/setup.sh" --address >/dev/null 2>&1; then
  fail 'missing option value should be rejected'
fi
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$ROOT/setup.sh" "$ROOT/install-unraid.sh" "$ROOT/tests/test.sh"
else
  printf '%s\n' 'shellcheck not installed; skipping local shellcheck'
fi

printf '%s\n' 'Validating Unraid XML...'
for template in "$ROOT"/templates/*.xml "$ROOT/ca_profile.xml"; do
  xmllint --noout "$template"
done
assert_file_contains "$ROOT/templates/omni.xml" 'ghcr.io/siderolabs/omni:latest'
assert_file_contains "$ROOT/templates/omni.xml" '<Network>host</Network>'
assert_file_contains "$ROOT/templates/omni.xml" '--cap-add NET_ADMIN'
assert_file_contains "$ROOT/templates/omni.xml" '--device /dev/net/tun:/dev/net/tun'
assert_file_contains "$ROOT/templates/omni.xml" '<WebUI>https://[IP]:8443</WebUI>'
if grep -Fq '<Shell>' "$ROOT/templates/omni.xml"; then
  fail 'minimal Omni image must not advertise an interactive shell'
fi
assert_file_contains "$ROOT/templates/omni-dex.xml" 'ghcr.io/dexidp/dex:latest'
assert_file_contains "$ROOT/templates/omni-dex.xml" '<PostArgs>dex serve /config/dex/dex.yaml</PostArgs>'
assert_file_contains "$ROOT/setup.sh" "apk add --no-cache ca-certificates"
assert_file_contains "$ROOT/setup.sh" "printf '%s\\n' \"\$DEX_PASSWORD\""
if grep -Fq -- "printf '%s\\n%s\\n' \"\$DEX_PASSWORD\" \"\$DEX_PASSWORD\"" "$ROOT/setup.sh"; then
  fail 'Dex password must be piped to htpasswd exactly once'
fi
# shellcheck disable=SC2016 # Assert the literal shell expression in setup.sh.
assert_file_contains "$ROOT/setup.sh" '[[ ! -s "$APPDATA/tls/trust-bundle.pem" ]]'
if grep -Fq -- '--entrypoint cat ghcr.io/siderolabs/omni' "$ROOT/setup.sh"; then
  fail 'setup must not assume the minimal Omni image contains cat'
fi
assert_file_contains "$ROOT/README.md" '[Complete Unraid installation guide](docs/unraid-install.md)'
for option in --address --admin-email --appdata --hostname --auth --oidc-provider-url --oidc-client-id --force-config; do
  assert_file_contains "$ROOT/docs/options.md" "$option"
done

printf '%s\n' 'Exercising repeatable Unraid installer...'
INSTALL_DIR="$TMP_ROOT/installer"
OMNI_SETUP_TEST_MODE=1 OMNI_DEX_PASSWORD='installer-test-password' \
  OMNI_TEMPLATE_DIR="$INSTALL_DIR/templates" "$ROOT/install-unraid.sh" \
  --appdata "$INSTALL_DIR/appdata" --address 192.168.60.10 \
  --admin-email installer@example.com --auth dex >/dev/null
[[ -f "$INSTALL_DIR/templates/my-omni.xml" ]] || fail 'installer did not install Omni template'
[[ -f "$INSTALL_DIR/templates/my-omni-dex.xml" ]] || fail 'installer did not install Dex template'
INSTALL_BEFORE=$(shasum "$INSTALL_DIR/appdata/account-id" "$INSTALL_DIR/appdata/omni.asc")
OMNI_SETUP_TEST_MODE=1 OMNI_DEX_PASSWORD='ignored-on-replay' \
  OMNI_TEMPLATE_DIR="$INSTALL_DIR/templates" "$ROOT/install-unraid.sh" \
  --appdata "$INSTALL_DIR/appdata" --address 192.168.60.10 \
  --admin-email installer@example.com --auth dex >/dev/null
INSTALL_AFTER=$(shasum "$INSTALL_DIR/appdata/account-id" "$INSTALL_DIR/appdata/omni.asc")
[[ "$INSTALL_BEFORE" == "$INSTALL_AFTER" ]] || fail 'replayed installer changed persistent identity'

run_setup() {
  OMNI_SETUP_TEST_MODE=1 "$ROOT/setup.sh" "$@" >/dev/null
}

validate_common_yaml() {
  local file=$1 expected_provider=$2
  ruby -ryaml -e '
    cfg = YAML.safe_load(File.read(ARGV[0]))
    abort "embedded etcd disabled" unless cfg.dig("storage", "default", "etcd", "embedded") == true
    abort "elections enabled" unless cfg.dig("storage", "default", "etcd", "runElections") == false
    abort "wrong sqlite path" unless cfg.dig("storage", "sqlite", "path") == "/config/data/omni.db"
    abort "wrong API endpoint" unless cfg.dig("services", "api", "endpoint") == "0.0.0.0:8443"
    abort "wrong machine endpoint" unless cfg.dig("services", "machineAPI", "endpoint") == "0.0.0.0:8090"
    abort "wrong machine advertised URL" unless cfg.dig("services", "machineAPI", "advertisedURL") == "grpc://#{ARGV[2]}:8090"
    abort "machine API unexpectedly has TLS certificate" if cfg.dig("services", "machineAPI").key?("certFile")
    abort "machine API unexpectedly has TLS key" if cfg.dig("services", "machineAPI").key?("keyFile")
    abort "wrong event port" unless cfg.dig("services", "siderolink", "eventSinkPort") == 8091
    abort "wrong proxy endpoint" unless cfg.dig("services", "kubernetesProxy", "endpoint") == "0.0.0.0:8100"
    abort "workload proxy enabled" unless cfg.dig("services", "workloadProxy", "enabled") == false
    abort "wrong provider" unless cfg.dig("auth", "oidc", "providerURL") == ARGV[1]
  ' "$file" "$expected_provider" "$3"
}

printf '%s\n' 'Exercising Dex setup and idempotence...'
DEX_DIR="$TMP_ROOT/dex"
OMNI_DEX_PASSWORD='correct horse battery staple' run_setup \
  --appdata "$DEX_DIR" --address 192.168.50.10 \
  --admin-email admin@example.com --auth dex
validate_common_yaml "$DEX_DIR/omni.yaml" 'https://192.168.50.10:5556' '192.168.50.10'
assert_file_contains "$DEX_DIR/omni.yaml" 'advertisedURL: "https://192.168.50.10:8443"'
ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "$DEX_DIR/dex/dex.yaml"
assert_file_contains "$DEX_DIR/dex/dex.yaml" 'https://192.168.50.10:8443/oidc/consume'
# shellcheck disable=SC2016 # Assert the literal appdata expression in setup.sh.
assert_file_contains "$ROOT/setup.sh" 'chown root:1001 "$APPDATA/tls/server.key"'
[[ $(ruby -e 'printf "%o", File.stat(ARGV[0]).mode & 0777' "$DEX_DIR/tls/server.key") == 640 ]] || \
  fail 'shared TLS server key is not readable by the non-root Dex container user'
openssl x509 -in "$DEX_DIR/tls/server.crt" -noout -ext subjectAltName | grep -Fq 'IP Address:192.168.50.10'
BEFORE=$(shasum "$DEX_DIR/account-id" "$DEX_DIR/omni.asc" "$DEX_DIR/tls/ca.key" "$DEX_DIR/tls/server.key" "$DEX_DIR/omni.yaml")
OMNI_DEX_PASSWORD='a different ignored password' run_setup \
  --appdata "$DEX_DIR" --address 192.168.50.10 \
  --admin-email admin@example.com --auth dex
AFTER=$(shasum "$DEX_DIR/account-id" "$DEX_DIR/omni.asc" "$DEX_DIR/tls/ca.key" "$DEX_DIR/tls/server.key" "$DEX_DIR/omni.yaml")
[[ "$BEFORE" == "$AFTER" ]] || fail 'idempotent setup changed persistent identity or configuration'

printf '%s\n' 'Exercising Authentik setup...'
AUTHENTIK_DIR="$TMP_ROOT/authentik"
OMNI_OIDC_CLIENT_SECRET='authentik-secret' run_setup \
  --appdata "$AUTHENTIK_DIR" --hostname omni-auth.test --address 10.20.30.40 \
  --admin-email owner@example.com --auth authentik \
  --oidc-provider-url https://auth.test/application/o/omni/ --oidc-client-id omni-client
validate_common_yaml "$AUTHENTIK_DIR/omni.yaml" 'https://auth.test/application/o/omni/' '10.20.30.40'
assert_file_contains "$AUTHENTIK_DIR/omni.yaml" 'clientID: "omni-client"'

printf '%s\n' 'Exercising generic OIDC setup and explicit config regeneration...'
OIDC_DIR="$TMP_ROOT/oidc"
OMNI_OIDC_CLIENT_SECRET='generic-secret' run_setup \
  --appdata "$OIDC_DIR" --hostname omni-oidc.test --address 172.16.1.5 \
  --admin-email oidc@example.com --auth oidc \
  --oidc-provider-url https://idp.test/realms/home --oidc-client-id generic-client
validate_common_yaml "$OIDC_DIR/omni.yaml" 'https://idp.test/realms/home' '172.16.1.5'
IDENTITY_BEFORE=$(shasum "$OIDC_DIR/account-id" "$OIDC_DIR/omni.asc" "$OIDC_DIR/tls/ca.key" "$OIDC_DIR/tls/server.key")
OMNI_OIDC_CLIENT_SECRET='replacement-secret' run_setup \
  --appdata "$OIDC_DIR" --hostname omni-oidc.test --address 172.16.1.5 \
  --admin-email oidc@example.com --auth oidc \
  --oidc-provider-url https://new-idp.test/issuer --oidc-client-id replacement-client --force-config
IDENTITY_AFTER=$(shasum "$OIDC_DIR/account-id" "$OIDC_DIR/omni.asc" "$OIDC_DIR/tls/ca.key" "$OIDC_DIR/tls/server.key")
[[ "$IDENTITY_BEFORE" == "$IDENTITY_AFTER" ]] || fail '--force-config rotated identity material'
validate_common_yaml "$OIDC_DIR/omni.yaml" 'https://new-idp.test/issuer' '172.16.1.5'
compgen -G "$OIDC_DIR/omni.yaml.bak.*" >/dev/null || fail 'config regeneration did not create a backup'

printf '%s\n' 'All tests passed.'
