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
get() { { docker compose exec -T server corteza-server settings get "$1" 2>&1 || true; } | { grep -v '"level"' || true; } | tr -d '[:space:]'; }
set_setting() { docker compose exec -T server corteza-server settings set "$1" "$2" 2>&1 | grep -v '"level"' | grep -v '^$' || true; }

LIGHT='{\"black\":\"#0B1026\",\"white\":\"#FFFFFF\",\"primary\":\"#4F46E5\",\"secondary\":\"#64748B\",\"success\":\"#16A34A\",\"warning\":\"#F59E0B\",\"danger\":\"#DC2626\",\"light\":\"#F5F7FB\",\"extra-light\":\"#E2E8F0\",\"body-bg\":\"#F5F7FB\",\"sidebar-bg\":\"#FFFFFF\",\"topbar-bg\":\"#F5F7FB\"}'
DARK='{\"black\":\"#F1F5F9\",\"white\":\"#0B1026\",\"primary\":\"#6366F1\",\"secondary\":\"#94A3B8\",\"success\":\"#22C55E\",\"warning\":\"#FBBF24\",\"danger\":\"#EF4444\",\"light\":\"#1E2440\",\"extra-light\":\"#2C3354\",\"body-bg\":\"#0B1026\",\"sidebar-bg\":\"#111735\",\"topbar-bg\":\"#0B1026\"}'

THEMES="[{\"id\":\"light\",\"title\":\"Light\",\"values\":\"$LIGHT\"},{\"id\":\"dark\",\"title\":\"Dark\",\"values\":\"$DARK\"}]"
SNIPPETS='[{"name":"DM-CRM column resize","script":"<script src=\"/branding/column-resize.js\"></script>","enabled":true}]'

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
apply code-snippets "$SNIPPETS"
