#!/bin/bash
#
# Sets the DM-CRM settings that provisioning can't (list values): the light
# and dark colour themes and the column-resize code snippet.
#
# Each setting is only written when it is empty, so theme changes made later
# in Admin Area > User interface > Theming are kept. Pass --force to write
# them anyway. Restart the server afterwards (update-existing-crm.sh does).
#
# Usage (from the repo root): branding/tools/apply-branding-settings.sh [--force]

set -euo pipefail
export MSYS_NO_PATHCONV=1

FORCE=${1:-}

# the CLI prints the value on stderr, mixed with log lines
TOOLS=$(cd "$(dirname "$0")" && pwd)
. "$TOOLS/target.sh"
# BRANDING_CONTAINER targets one server container (e.g. a rehearsal copy);
# by default the compose project's server service is used
if [ -n "${BRANDING_CONTAINER:-}" ]; then
  cli() { on_target "$DOCKER exec $BRANDING_CONTAINER corteza-server $*"; }
else
  cli() { on_target "cd $COMPOSE_DIR && $DOCKER compose exec -T server corteza-server $*"; }
fi
get() { { cli settings get "$(printf %q "$1")" 2>&1 || true; } | { grep -v "\"level\"" || true; } | tr -d "[:space:]"; }
set_setting() { cli settings set "$(printf %q "$1")" "$(printf %q "$2")" 2>&1 | grep -v "\"level\"" | grep -v "^$" || true; }

LIGHT='{\"black\":\"#0B1026\",\"white\":\"#FFFFFF\",\"primary\":\"#4F46E5\",\"secondary\":\"#64748B\",\"success\":\"#16A34A\",\"warning\":\"#F59E0B\",\"danger\":\"#DC2626\",\"light\":\"#F5F7FB\",\"extra-light\":\"#E2E8F0\",\"body-bg\":\"#F5F7FB\",\"sidebar-bg\":\"#FFFFFF\",\"topbar-bg\":\"#F5F7FB\"}'
DARK='{\"black\":\"#F1F5F9\",\"white\":\"#0B1026\",\"primary\":\"#6366F1\",\"secondary\":\"#94A3B8\",\"success\":\"#22C55E\",\"warning\":\"#FBBF24\",\"danger\":\"#EF4444\",\"light\":\"#1E2440\",\"extra-light\":\"#2C3354\",\"body-bg\":\"#0B1026\",\"sidebar-bg\":\"#111735\",\"topbar-bg\":\"#0B1026\"}'

THEMES="[{\"id\":\"light\",\"title\":\"Light\",\"values\":\"$LIGHT\"},{\"id\":\"dark\",\"title\":\"Dark\",\"values\":\"$DARK\"}]"
# the font snippet loads Figtree (Google Fonts) for branding/dm-crm-ui.scss
SNIPPETS='[{"name":"DM-CRM column resize","script":"<script src=\"/branding/column-resize.js\"></script>","enabled":true},{"name":"DM-CRM font (Figtree)","script":"<script>(function(){var h=document.head;[[\"preconnect\",\"https://fonts.googleapis.com\"],[\"preconnect\",\"https://fonts.gstatic.com\"],[\"stylesheet\",\"https://fonts.googleapis.com/css2?family=Figtree:wght@400;500;600;700&display=swap\"]].forEach(function(a){var l=document.createElement(\"link\");l.rel=a[0];l.href=a[1];if(a[1].indexOf(\"gstatic\")>0){l.crossOrigin=\"anonymous\"}h.appendChild(l)})})()</script>","enabled":true}]'

apply() {
  local name=$1 value=$2 current
  current=$(get "$name")
  if [ "$FORCE" = "--force" ] || [ -z "$current" ] || [ "$current" = "[]" ] || [ "$current" = "null" ]; then
    set_setting "$name" "$value"
    echo "set $name"
  else
    echo "kept $name (already set)"
  fi
}

apply ui.studio.themes "$THEMES"

# snippets are replaced while the font snippet is missing (installs set up
# before it existed); otherwise kept like the themes
current=$(get code-snippets)
if [[ "$current" != *family=Figtree* ]]; then
  set_setting code-snippets "$SNIPPETS"
  echo "set code-snippets (adds the font snippet)"
else
  apply code-snippets "$SNIPPETS"
fi

# custom CSS (branding/dm-crm-ui.scss) as the "general" entry. It is
# replaced while it is empty or still an older DM-CRM version (its first
# line is the version marker); CSS edited in the admin area without that
# marker is kept.
CSS_FILE="$TOOLS/../dm-crm-ui.scss"
marker=$(head -1 "$CSS_FILE" | tr -d '/* [:space:]')
css=$(perl -0777 -pe 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g; s/\n/\\n/g' "$CSS_FILE")
current=$(get ui.studio.custom-css)
general=$(printf '%s' "$current" | grep -o '"id":"general","values":"[^"]\{0,40\}' || true)
if [ "$FORCE" = "--force" ] || [ -z "$current" ] || [ "$current" = "[]" ] || [ "$current" = "null" ] \
   || [ "$general" = '"id":"general","values":"' ] \
   || { [[ "$general" == *DM-CRMUIv* ]] && [[ "$general" != *"$marker"* ]]; }; then
  set_setting ui.studio.custom-css "[{\"id\":\"general\",\"values\":\"$css\"},{\"id\":\"light\",\"values\":\"\"},{\"id\":\"dark\",\"values\":\"\"}]"
  echo "set ui.studio.custom-css ($marker)"
else
  echo "kept ui.studio.custom-css (already set)"
fi
