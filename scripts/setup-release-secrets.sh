#!/usr/bin/env bash
# One-time: gives the release workflow (.github/workflows/release.yml) what it
# needs to sign and notarize, as secrets of the repo's `release` environment,
# which it creates so that only main can deploy to it. Nothing is printed,
# and every credential is checked before it's uploaded.
#
#   scripts/setup-release-secrets.sh path/to/DeveloperID.p12
#
# The .p12 first: in Keychain Access, under My Certificates, select
# "Developer ID Application: JONATHAN MARK ASMAR (Z4PL6853AL)", File > Export
# Items…, save as .p12 with a password. The app-specific password comes from
# account.apple.com (Sign-In and Security > App-Specific Passwords).
set -euo pipefail
cd "$(dirname "$0")/.."

p12="${1:?usage: scripts/setup-release-secrets.sh path/to/DeveloperID.p12}"
[[ -f "$p12" ]] || { echo "no such file: $p12" >&2; exit 1; }
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
team=Z4PL6853AL

read -rsp "Password you set on the .p12: " p12_password
echo
read -rp "Apple ID (email): " apple_id
read -rsp "App-specific password: " app_password
echo

# The .p12 opens with that password and holds a Developer ID identity: tried
# in a throwaway keychain, the way the workflow will.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/silt-secrets.XXXXXX")"
keychain="$scratch/check.keychain-db"
cleanup() {
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -rf "${scratch:?}"
}
trap cleanup EXIT
security create-keychain -p check "$keychain"
if ! security import "$p12" -P "$p12_password" -t cert -f pkcs12 -k "$keychain" > /dev/null 2>&1; then
  echo "the .p12 didn't open with that password" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning "$keychain" | grep -q "Developer ID Application:.*($team)"; then
  echo "the .p12 has no Developer ID Application identity for team $team" >&2
  exit 1
fi
echo "Certificate: OK"

# The Apple ID and app-specific password are accepted by the notary service.
if ! xcrun notarytool history --apple-id "$apple_id" --password "$app_password" --team-id "$team" > /dev/null 2>&1; then
  echo "the notary service didn't accept that Apple ID and app-specific password" >&2
  exit 1
fi
echo "Notary credentials: OK"

# The environment, deployable from main only.
gh api -X PUT "repos/$repo/environments/release" --input - > /dev/null <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
if ! gh api "repos/$repo/environments/release/deployment-branch-policies" \
  --jq '.branch_policies[].name' | grep -qx main; then
  gh api -X POST "repos/$repo/environments/release/deployment-branch-policies" \
    -f name=main -f type=branch > /dev/null
fi
echo "Environment: release (main only)"

base64 -i "$p12" | gh secret set SIGNING_CERTIFICATE_P12 --repo "$repo" --env release
printf '%s' "$p12_password" | gh secret set SIGNING_CERTIFICATE_PASSWORD --repo "$repo" --env release
printf '%s' "$apple_id" | gh secret set NOTARY_APPLE_ID --repo "$repo" --env release
printf '%s' "$app_password" | gh secret set NOTARY_PASSWORD --repo "$repo" --env release
echo "Secrets set on $repo (release environment). Delete the .p12 once you're done with it."
