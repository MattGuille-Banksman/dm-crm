#!/bin/bash
#
# Builds an import package that updates an EXISTING DM-CRM instance safely.
#
# Corteza's envoy importer has two problems with existing resources:
#   - module fields are matched by name across ALL modules, so existing
#     fields can be moved between modules: never let it touch modules
#     (apply module changes with apply-crm-module-changes.ps1 instead)
#   - triggers have no identifier, so every import re-creates them
#
# So the package marks every module, field, unchanged workflow and its
# triggers as skip, and only the listed pages/workflows as replace. Before
# importing, delete the triggers of the replaced workflows (they are
# re-created from the package).
#
# Usage: prepare-crm-update.sh <source 750_crm dir> <output dir> \
#          "<pages and layouts to replace>" "<workflows to replace>"

set -eu

SRC=$1
OUT=$2
REPLACE_PAGES=" $3 "
REPLACE_WORKFLOWS=" $4 "

mkdir -p "$OUT"
cp "$SRC"/*.yaml "$OUT"/

# modules and fields: never written
awk '
  /^modules:$/ { inmods = 1 }
  { print }
  inmods && /^  [A-Za-z]+:$/       { print "    (envoy): { skipIf: \"true\" }" }
  inmods && /^      [a-z_0-9]+:$/  { print "        (envoy): { skipIf: \"true\" }" }
' "$SRC/1100_modules.yaml" > "$OUT/1100_modules.yaml"

# pages and page layouts: replace the listed ones, keep the rest
awk -v want="$REPLACE_PAGES" '
  { print }
  match($0, /^ *[A-Za-z_]+:$/) {
    key = $0; sub(/^ */, "", key); sub(/:$/, "", key)
    indent = $0; sub(/[^ ].*$/, "", indent)
    if (index(want, " " key " ") > 0) print indent "  (envoy): { onExisting: replace }"
  }
' "$SRC/1400_pages.yaml" > "$OUT/1400_pages.yaml"

# workflows: replace the listed ones; new ones are created; existing ones and
# their triggers are skipped. Existing-ness is decided by the caller passing
# EXISTING_WORKFLOWS (space separated handles) in the environment.
awk -v want="$REPLACE_WORKFLOWS" -v existing=" ${EXISTING_WORKFLOWS:-} " '
  /^  crm_[a-z_]+:$/ {
    wf = $1; sub(":", "", wf)
    mode = "create"
    if (index(want, " " wf " ") > 0) mode = "replace"
    else if (index(existing, " " wf " ") > 0) mode = "skip"
    print
    if (mode == "replace") print "    (envoy): { onExisting: replace }"
    if (mode == "skip")    print "    (envoy): { skipIf: \"true\" }"
    next
  }
  { print }
  mode == "skip" && /^      - resourceType: / { print "        (envoy): { skipIf: \"true\" }" }
' "$SRC/1600_workflows.yaml" > "$OUT/1600_workflows.yaml"

echo "prepared $OUT"
grep -c "onExisting: replace" "$OUT/1400_pages.yaml" | sed 's/^/  pages replaced: /'
grep -c "onExisting: replace" "$OUT/1600_workflows.yaml" | sed 's/^/  workflows replaced: /'
grep -c "^    (envoy): { skipIf" "$OUT/1600_workflows.yaml" | sed 's/^/  workflows skipped: /'
