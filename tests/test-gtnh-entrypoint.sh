#!/bin/bash
set -euo pipefail

if [[ ! -f /.dockerenv ]]; then
  echo "This test must run inside the isolated GTNH container image." >&2
  exit 1
fi

function runEntrypointPreparation(){
  head -n -1 /usr/local/bin/gtnh-entrypoint.sh | /bin/sh
}

unsafe_repository="value-that-must-stay-redacted"
if output="$(GTNH_RESTIC_REPOSITORY="$unsafe_repository" runEntrypointPreparation 2>&1)"; then
  echo "An unsafe repository override unexpectedly passed entrypoint validation." >&2
  exit 1
fi
if grep -Fq "$unsafe_repository" <<< "$output"; then
  echo "The unsafe repository value leaked into entrypoint logs." >&2
  exit 1
fi

rm -rf /data/* /data/.[!.]* /data/..?* /backups/* /backups/.[!.]* /backups/..?* 2>/dev/null || true
old_password="leaked-repository-value"
new_password="rotated-restic-password"
printf '%s\n' "$old_password" > /backups/.gtnh-restic-password
RESTIC_REPOSITORY="/data/$old_password" \
  RESTIC_PASSWORD_FILE=/backups/.gtnh-restic-password \
  restic init >/dev/null

if output="$(GTNH_RESTIC_PASSWORD="$old_password" runEntrypointPreparation 2>&1)"; then
  echo "Entrypoint accepted a password known to have leaked as a repository path." >&2
  exit 1
fi
if grep -Fq "$old_password" <<< "$output"; then
  echo "The leaked password appeared in entrypoint logs." >&2
  exit 1
fi

GTNH_RESTIC_PASSWORD="$new_password" runEntrypointPreparation
[[ "$(cat /backups/.gtnh-restic-password)" == "$new_password" ]]
grep -Fqx "/$old_password" /backups/.gtnh-restic-source-excludes
grep -Fqx "/data/$old_password" /backups/.gtnh-restic-source-excludes
grep -Fqx '/data/.gtnh-manager' /backups/.gtnh-restic-source-excludes
[[ -d /backups/.gtnh-restic-cache ]]

mkdir -p /data/.gtnh-manager/restic-cache
printf 'obsolete-cache-data\n' > /data/.gtnh-manager/restic-cache/index
GTNH_RESTIC_PASSWORD="$new_password" runEntrypointPreparation
[[ ! -e /data/.gtnh-manager/restic-cache ]]

RESTIC_REPOSITORY=/backups/restic \
  RESTIC_PASSWORD_FILE=/backups/.gtnh-restic-password \
  restic init >/dev/null
if GTNH_RESTIC_PASSWORD="another-password" runEntrypointPreparation >/dev/null 2>&1; then
  echo "Entrypoint changed the password file for an initialized repository." >&2
  exit 1
fi
[[ "$(cat /backups/.gtnh-restic-password)" == "$new_password" ]]

echo "GTNH entrypoint safety tests passed."
