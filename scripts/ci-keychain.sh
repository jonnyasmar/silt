#!/usr/bin/env bash
# The release workflow's temporary signing keychain.
#   scripts/ci-keychain.sh import   create it, import the Developer ID .p12, list it
#   scripts/ci-keychain.sh delete   delete it
# Environment for `import`: SIGNING_CERTIFICATE_P12 (base64),
# SIGNING_CERTIFICATE_PASSWORD, RUNNER_TEMP, and GITHUB_ENV (KEYCHAIN_PATH
# reaches later steps through it). Nothing here prints a credential.
set -euo pipefail

case "${1:-}" in
  import)
    : "${SIGNING_CERTIFICATE_P12:?SIGNING_CERTIFICATE_P12 is not set}"
    : "${SIGNING_CERTIFICATE_PASSWORD:?SIGNING_CERTIFICATE_PASSWORD is not set}"
    : "${RUNNER_TEMP:?RUNNER_TEMP is not set}"
    keychain="$RUNNER_TEMP/silt-signing.keychain-db"
    certificate="$RUNNER_TEMP/certificate.p12"
    password="$(openssl rand -base64 24)"
    printf '%s' "$SIGNING_CERTIFICATE_P12" | base64 --decode > "$certificate"
    security create-keychain -p "$password" "$keychain"
    # Longer than the job can run, so it can't lock itself while
    # notarization is still waiting on Apple.
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$password" "$keychain"
    security import "$certificate" -P "$SIGNING_CERTIFICATE_PASSWORD" \
      -t cert -f pkcs12 -k "$keychain" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
      -s -k "$password" "$keychain" > /dev/null
    # Ours first, then whatever the runner already searches.
    existing=()
    while IFS= read -r entry; do
      entry="${entry#\"}"
      entry="${entry%\"}"
      if [[ -n "$entry" ]]; then existing+=("$entry"); fi
    done < <(security list-keychains -d user | sed 's/^ *//')
    security list-keychains -d user -s "$keychain" "${existing[@]}"
    rm -f "$certificate"
    if [[ -n "${GITHUB_ENV:-}" ]]; then echo "KEYCHAIN_PATH=$keychain" >> "$GITHUB_ENV"; fi
    security find-identity -v -p codesigning "$keychain"
    ;;
  delete)
    rm -f "${RUNNER_TEMP:-/nonexistent}/certificate.p12"
    if [[ -n "${KEYCHAIN_PATH:-}" && -f "$KEYCHAIN_PATH" ]]; then security delete-keychain "$KEYCHAIN_PATH"; fi
    ;;
  *)
    echo "Usage: ci-keychain.sh import|delete" >&2
    exit 2
    ;;
esac
