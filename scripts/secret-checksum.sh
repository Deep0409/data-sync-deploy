#!/usr/bin/env bash
# Writes the current AWS Secrets Manager version ID of the Redis secret into
# the SECRET_CHECKSUM annotation of the production overlay, so that a rotated
# secret rolls the pods.
#
# Why a version ID and not a hash of the password: a hash is derived from the
# secret and can be brute-forced offline by anyone who can read git or
# `kubectl get pods`. The version ID is a random identifier that changes on
# every rotation and reveals nothing about the password.
#
#   scripts/secret-checksum.sh                 look up the version and sync ESO first
#   scripts/secret-checksum.sh --version ID    write a known version ID, skip all checks
#
# Environment: AWS_SECRET_ID (brightedge/production/data-sync/redis),
#              AWS_REGION (us-east-1), NAMESPACE (data-sync),
#              EXTERNAL_SECRET (data-sync-redis), KUBE_CONTEXT (optional)
#
# Permissions needed: secretsmanager:ListSecretVersionIds on the secret, and
# get/patch on the ExternalSecret. Never read access to the password itself.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
patch="${root}/standard/data-sync/production/patch-secret-checksum.yaml"
aws_secret_id="${AWS_SECRET_ID:-brightedge/production/data-sync/redis}"
aws_region="${AWS_REGION:-us-east-1}"
namespace="${NAMESPACE:-data-sync}"
external_secret="${EXTERNAL_SECRET:-data-sync-redis}"
sync_timeout_seconds=120

kube() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    kubectl --context "${KUBE_CONTEXT}" -n "${namespace}" "$@"
  else
    kubectl -n "${namespace}" "$@"
  fi
}

# AWSCURRENT is the stage label Secrets Manager puts on the live version.
current_version_id() {
  aws secretsmanager list-secret-version-ids \
    --region "${aws_region}" \
    --secret-id "${aws_secret_id}" \
    --query "Versions[?contains(VersionStages, 'AWSCURRENT')].VersionId" \
    --output text
}

# The pods must only roll once the Kubernetes Secret holds the new password.
# Otherwise new pods start with the old one, and since the annotation has
# already changed, nothing would ever restart them again. So force ESO to
# re-read AWS now and wait until it reports a successful sync after that point.
sync_external_secret() {
  local requested_at refreshed_at ready
  # RFC 3339 UTC strings compare correctly as plain strings.
  requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  kube annotate externalsecret "${external_secret}" "force-sync=$(date +%s)" --overwrite > /dev/null

  for _ in $(seq "${sync_timeout_seconds}"); do
    refreshed_at="$(kube get externalsecret "${external_secret}" -o jsonpath='{.status.refreshTime}')"
    ready="$(kube get externalsecret "${external_secret}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [[ "${ready}" == "True" && ! "${refreshed_at}" < "${requested_at}" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "ExternalSecret ${external_secret} did not sync within ${sync_timeout_seconds}s; not touching the patch." >&2
  exit 1
}

if [[ "${1:-}" == "--version" ]]; then
  [[ -n "${2:-}" ]] || { echo "usage: $0 [--version ID]" >&2; exit 2; }
  version_id="$2"
  # Secrets Manager version IDs are UUIDs. Checking also keeps stray characters
  # out of the sed expression below.
  [[ "${version_id}" =~ ^[0-9a-fA-F-]{32,64}$ ]] || { echo "not a version ID: ${version_id}" >&2; exit 2; }
else
  version_id="$(current_version_id)"
  [[ -n "${version_id}" && "${version_id}" != "None" ]] || { echo "no AWSCURRENT version for ${aws_secret_id}" >&2; exit 1; }
  sync_external_secret
fi

# `sed -i` behaves differently on BSD (macOS) and GNU, so write via a temp file.
tmp="$(mktemp)"
sed -E "s/(SECRET_CHECKSUM: )\"[^\"]*\"/\1\"${version_id}\"/" "${patch}" > "${tmp}"
cat "${tmp}" > "${patch}"
rm -f "${tmp}"

echo "SECRET_CHECKSUM=${version_id}"
