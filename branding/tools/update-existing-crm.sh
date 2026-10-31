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
#
# Local Docker:
#   branding/tools/update-existing-crm.sh corteza-server-1 corteza http://localhost:18080 you@example.com
# Oracle server (over SSH; see target.sh):
#   SSH_HOST=ubuntu@140.238.103.97 branding/tools/update-existing-crm.sh \
#     oracle-server-1 corteza https://140.238.103.97.sslip.io you@example.com
# A base URL of http://localhost:<port> on a remote target is reached through
# an SSH tunnel.

set -euo pipefail
export MSYS_NO_PATHCONV=1

CONTAINER=$1
DB=$2
BASE_URL=$3
ADMIN=$4

# every CRM page and page layout is replaced from the YAML (pages hold no
# data; changes made with the page builder are overwritten)
REPLACE_PAGES=$(grep -oE '^ +(Crm|Record)[A-Za-z]+:$' server/provision/750_crm/1400_pages.yaml | tr -d ' :' | tr '\n' ' ')
REPLACE_WORKFLOWS="crm_contact_defaults crm_campaign_build_recipients"

TOOLS=$(cd "$(dirname "$0")" && pwd)
. "$TOOLS/target.sh"
WORK=$(mktemp -d)
TUNNEL_PID=
cleanup() {
  rm -f "$WORK/token"
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
}
trap cleanup EXIT

q() { dc "exec -T db psql -U corteza -d $DB -At -c \"$1\""; }
win() { cygpath -w "$1"; }

wait_healthy() {
  for _ in $(seq 1 60); do
    [ "$(on_target "$DOCKER inspect -f '{{.State.Health.Status}}' $CONTAINER")" = healthy ] && return 0
    sleep 3
  done
  echo "server did not become healthy" >&2
  return 1
}

# remote target with a localhost URL: forward the port over SSH
if [ -n "${SSH_HOST:-}" ] && [[ "$BASE_URL" =~ ^http://localhost:([0-9]+) ]]; then
  port=${BASH_REMATCH[1]}
  ssh -i "$SSH_KEY" -o BatchMode=yes -N -L "$port:localhost:$port" "$SSH_HOST" &
  TUNNEL_PID=$!
  sleep 3
fi

echo "== 1/4 module changes (API)"
on_target "$DOCKER exec $CONTAINER corteza-server auth jwt $ADMIN" 2>&1 \
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
# crm-user used to be allowed every record in the namespace; it now gets
# per-module rules (1050_access_control.yaml) so AI settings stay admin-only
q "delete from rbac_rules where rel_role in (select id from roles where handle = 'crm-user') and ((resource like 'corteza::compose:record/%/*/*') or (resource like 'corteza::compose:module/%/*' and operation in ('record.create', 'records.search')));"
# a fresh folder each run: docker cp into an existing folder nests the
# package inside it, and the import would then also read the old files
DEST="/tmp/crm-update-$(date +%Y%m%d%H%M%S)-$$"
if [ -n "${SSH_HOST:-}" ]; then
  staged=$(to_target "$WORK/pkg")
  on_target "$DOCKER cp $staged $CONTAINER:$DEST && rm -rf $staged"
else
  docker cp "$(win "$WORK/pkg")" "$CONTAINER:$DEST"
fi
on_target "$DOCKER exec $CONTAINER corteza-server import --skip-existing $DEST" 2>&1 | grep -v '"level":"warn"' || true
# AI settings hold the API key: deny them to every signed-in user
# (administrators are allowed by their own role, which is checked first).
# The importer can't resolve the built-in authenticated role and writes such
# rules against role 0, so they are written here instead.
q "delete from rbac_rules where rel_role = 0;"
q "insert into rbac_rules (rel_role, resource, operation, access)
   select a.id, 'corteza::compose:' || x.res || '/' || m.rel_namespace || '/' || m.id || x.suffix, x.op, 0
   from compose_module m
   join compose_namespace n on n.id = m.rel_namespace and n.slug = 'crm'
   cross join roles a
   cross join (values ('module', '', 'record.create'), ('module', '', 'records.search'),
                      ('record', '/*', 'read'), ('record', '/*', 'update'),
                      ('record', '/*', 'delete'), ('record', '/*', 'revisions.search')) as x(res, suffix, op)
   where m.handle = 'AiSettings' and m.deleted_at is null and a.handle = 'authenticated'
   on conflict do nothing;"
# the AI generator reads the admin-only AI settings, so it runs as the admin
q "update automation_workflows set run_as = (select id from users where email = '$ADMIN' and deleted_at is null) where handle = 'crm_campaign_generate_content';"

echo "== 4/4 branding settings and restart"
if [ "$DB" = corteza ]; then
  # settings are written through the main compose service
  bash "$TOOLS/apply-branding-settings.sh"
fi
on_target "$DOCKER restart $CONTAINER" > /dev/null
wait_healthy

echo "== starter lists"
# after the restart, so the list filter workflow is loaded
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(win "$TOOLS/create-starter-lists.ps1")" \
  -BaseUrl "$BASE_URL" -TokenFile "$(win "$WORK/token")"
echo "done"
