#!/bin/bash
set -euo pipefail

mkdir -p /data/world /backups
export GTNH_BACKUP_MIN_FREE_GB=1
printf 'test-restic-password\n' > /backups/.gtnh-restic-password
printf 'world-data\n' > /data/world/level.dat
printf 'test-build\n' > /data/.gtnh-version

# shellcheck source=gtnh-restic.sh
. /usr/local/lib/gtnh-restic.sh
[[ "$GTNH_RESTIC_CACHE_DIR" == "/backups/.gtnh-restic-cache" ]]

GTNH_RESTIC_REPOSITORY="relative-secret-shaped-value"
if validateGTNHresticRepository; then
  echo "An unsafe Restic repository override unexpectedly passed validation." >&2
  exit 1
fi
GTNH_RESTIC_REPOSITORY="/backups/restic"

misplaced_repository='/data/misplaced[repository]'
printf 'misplaced-password\n' > /tmp/misplaced-restic-password
RESTIC_REPOSITORY="$misplaced_repository" RESTIC_PASSWORD_FILE=/tmp/misplaced-restic-password restic init >/dev/null
printf '/misplaced\\[repository\\]\n' > /backups/.gtnh-restic-source-excludes

createGTNHresticSnapshot smoke test-build test-build
snapshot_id="$GTNH_RESTIC_SNAPSHOT_ID"
if restic ls "$snapshot_id" | grep -Fq 'misplaced[repository]'; then
  echo "A detected misplaced Restic repository was included in the snapshot." >&2
  exit 1
fi

for target in retention-1 retention-2 retention-3; do
  printf '%s\n' "$target" > /data/world/retention-test.dat
  createGTNHresticSnapshot pre-upgrade test-build "$target"
done
forgetOldGTNHpreUpdateSnapshots
[[ "$(restic snapshots --host "$GTNH_RESTIC_HOSTNAME" --tag gtnh,pre-upgrade --json | jq 'length')" == "2" ]]

gtnhctl status
gtnhctl snapshots
gtnhctl logs 20
gtnhctl restore "$snapshot_id" --world world --target /tmp/gtnh-restore
[[ "$(cat /tmp/gtnh-restore/world/level.dat)" == "world-data" ]]

mkdir -p /tmp/legacy-source/World
printf 'legacy-world-data\n' > /tmp/legacy-source/World/level.dat
tar -czf /tmp/legacy-backup.tar.gz -C /tmp/legacy-source .
gtnhctl legacy-restore /tmp/legacy-backup.tar.gz --dry-run >/dev/null
gtnhctl legacy-restore /tmp/legacy-backup.tar.gz --target /tmp/legacy-restore
[[ "$(cat /tmp/legacy-restore/World/level.dat)" == "legacy-world-data" ]]

printf 'sensitive path: misplaced[repository]\n' >> /data/.gtnh-manager/events.log
if gtnhctl cleanup-misplaced-restic >/dev/null 2>&1; then
  echo "Misplaced Restic cleanup unexpectedly ran without --confirm." >&2
  exit 1
fi
gtnhctl cleanup-misplaced-restic --confirm
[[ ! -e "$misplaced_repository" ]]
if grep -Fq 'misplaced[repository]' /data/.gtnh-manager/events.log; then
  echo "Misplaced repository name was not redacted from manager logs." >&2
  exit 1
fi

gtnhctl doctor

echo "gtnhctl smoke tests passed."
