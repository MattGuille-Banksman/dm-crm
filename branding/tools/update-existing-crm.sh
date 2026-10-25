#!/bin/bash
#
# Upgrades an existing DM-CRM instance to the definitions in
# server/provision/750_crm without touching records.
#
#   1. module changes through the REST API (apply-crm-module-changes.ps1)
#   2. an import package that skips modules/fields and unchanged workflows
#      and replaces only the listed pages and workflows (prepare-crm-update.sh)
#   3. the replaced workflows' triggers are deleted first, since the import
#      re-creates them
#   4. the server is restarted so workflows and triggers are reloaded
#
# Take a database backup first.
#
# Usage (from the repo root, Git Bash on Windows):
#   branding/tools/update-existing-crm.sh <server container> <database> <base url> <admin email>
# e.g.
#   branding/tools/update-existing-crm.sh corteza-server-1 corteza http://localhost:18080 you@example.com

set -euo pipefail
export MSYS_NO_PATHCONV=1

CONTAINER=$1
DB=$2
BASE_URL=$3
ADMIN=$4

REPLACE_PAGES="RecordContact RecordCompany RecordEmailTemplate RecordEmailCampaign CrmSettings CrmSegments RecordSegment RecordSegmentMember RecordContactDefault RecordCompanyDefault RecordEmailTemplateDefault RecordEmailCampaignDefault CrmSettingsDefault CrmSegmentsDefault RecordSegmentDefault RecordSegmentMemberDefault"
REPLACE_WORKFLOWS="crm_contact_defaults crm_campaign_build_recipients"

TOOLS=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
q() { docker compose exec -T db psql -U corteza -d "$DB" -At -c "$1"; }
win() { cygpath -w "$1"; }

wait_healthy() {
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")" = healthy ] && return 0
    sleep 3
  done
  echo "server did not become healthy" >&2
  return 1
}

echo "== 1/4 module changes (API)"
docker exec "$CONTAINER" corteza-server auth jwt "$ADMIN" 2>&1 \
  | grep -oE '[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}' | tail -1 | tr -d '\n' > "$WORK/token"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(win "$TOOLS/apply-crm-module-changes.ps1")" \
  -BaseUrl "$BASE_URL" -TokenFile "$(win "$WORK/token")"

echo "== 2/4 import package"
export EXISTING_WORKFLOWS
EXISTING_WORKFLOWS=$(q "select coalesce(string_agg(handle, ' '), '') from automation_workflows where handle like 'crm_%' and deleted_at is null;")
bash "$TOOLS/prepare-crm-update.sh" server/provision/750_crm "$WORK/pkg" "$REPLACE_PAGES" "$REPLACE_WORKFLOWS"
# the importer overwrites existing settings even with --skip-existing (and
# empties list values), so settings never go through the import
rm -f "$WORK/pkg/1700_settings.yaml"

echo "== 3/4 import"
list=$(printf "'%s'," $REPLACE_WORKFLOWS); list=${list%,}
q "delete from automation_triggers where rel_workflow in (select id from automation_workflows where handle in ($list));"
# a fresh target folder each run: docker cp into an existing folder nests the
# package inside it, and the import would then also read the old files
DEST="/tmp/crm-update-$(date +%Y%m%d%H%M%S)-$$"
docker cp "$(win "$WORK/pkg")" "$CONTAINER:$DEST"
docker exec "$CONTAINER" corteza-server import --skip-existing "$DEST" 2>&1 | grep -v '"level":"warn"' || true

echo "== 4/4 branding settings and restart"
if [ "$DB" = corteza ]; then
  # settings are written through the main compose service
  bash "$TOOLS/apply-branding-settings.sh"
fi
docker restart "$CONTAINER" > /dev/null
wait_healthy
rm -f "$WORK/token"
echo "done"
