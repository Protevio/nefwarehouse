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
# Read out of the running container rather than by mounting the volume by name.
#
# The first version of this named the volume directly, and got the name wrong:
# Compose prefixes volumes with the project directory, so it is infra_wms_uploads
# and not nefwarehouse_wms_uploads. Docker does not complain about that — it
# creates the volume you asked for, empty, and tars nothing. The backup reported
# success every night and contained 87 bytes.
#
# Asking the container for the contents of its own folder cannot go wrong that
# way: if the path is incorrect, tar fails loudly instead of quietly archiving
# an empty directory that Docker invented on the spot.
docker compose exec -T wms tar czf - -C /app/uploads . > "$OUT/uploads-$STAMP.tar.gz"

# ── does it actually contain anything? ──────────────────────────────────────
#
# A backup that fails is a problem you fix. A backup that succeeds and is empty
# is a problem you find out about on the day you need it.
DB_SIZE=$(stat -c%s "$OUT/db-$STAMP.sql.gz")
UP_SIZE=$(stat -c%s "$OUT/uploads-$STAMP.tar.gz")
PHOTOS=$(docker compose exec -T wms sh -c 'find /app/uploads -type f | wc -l' | tr -d '\r')

if [ "$DB_SIZE" -lt 2000 ]; then
  echo "[$STAMP] FAILED: the database dump is only $DB_SIZE bytes." >&2
  exit 1
fi

# An empty archive is about a hundred bytes. Anything that small when there are
# photographs on disk means it archived nothing.
if [ "$PHOTOS" -gt 0 ] && [ "$UP_SIZE" -lt 1000 ]; then
  echo "[$STAMP] FAILED: $PHOTOS photographs on disk but the archive is $UP_SIZE bytes." >&2
  exit 1
fi

echo "[$STAMP] database $DB_SIZE bytes, $PHOTOS photograph(s) in $UP_SIZE bytes"

echo "[$STAMP] clearing anything older than $KEEP_DAYS days"
find "$OUT" -name 'db-*.sql.gz'      -mtime +$KEEP_DAYS -delete
find "$OUT" -name 'uploads-*.tar.gz' -mtime +$KEEP_DAYS -delete

echo "[$STAMP] done:"
ls -lh "$OUT" | tail -4

# Worth saying out loud: a backup that has never been restored is a hope, not a
# backup. Restore one into a spare database once, so you know the file works.
