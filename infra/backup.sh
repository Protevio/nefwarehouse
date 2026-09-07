#!/usr/bin/env bash
#
# A backup of everything that cannot be rebuilt: the database, and the
# photographs. The code is in git and the containers are in a Dockerfile, so
# neither is worth copying.
#
#   bash /srv/nefwarehouse/infra/backup.sh
#
# Add it to cron to run nightly:
#   0 2 * * * bash /srv/nefwarehouse/infra/backup.sh >> /srv/nefwarehouse/backups/log 2>&1

set -euo pipefail

ROOT="/srv/nefwarehouse"
OUT="$ROOT/backups"
STAMP="$(date +%Y-%m-%d-%H%M)"
KEEP_DAYS=21

mkdir -p "$OUT"
cd "$ROOT/infra"

# shellcheck disable=SC1091
source ./env/postgres.env

echo "[$STAMP] database"
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists \
  | gzip > "$OUT/db-$STAMP.sql.gz"

echo "[$STAMP] photographs"
# Read straight off the volume through a throwaway container, so this works
# whether or not the app is running.
docker run --rm \
  -v nefwarehouse_wms_uploads:/uploads:ro \
  -v "$OUT":/out \
  alpine:3 tar czf "/out/uploads-$STAMP.tar.gz" -C /uploads .

echo "[$STAMP] clearing anything older than $KEEP_DAYS days"
find "$OUT" -name 'db-*.sql.gz'      -mtime +$KEEP_DAYS -delete
find "$OUT" -name 'uploads-*.tar.gz' -mtime +$KEEP_DAYS -delete

echo "[$STAMP] done:"
ls -lh "$OUT" | tail -4

# Worth saying out loud: a backup that has never been restored is a hope, not a
# backup. Restore one into a spare database once, so you know the file works.
