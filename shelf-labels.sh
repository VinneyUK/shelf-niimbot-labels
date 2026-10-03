#!/bin/bash
# shelf-labels.sh — print Niimbot labels for Shelf assets, through Home Assistant.
# https://github.com/VinneyUK/shelf-niimbot-labels
#
# Give an asset the print tag (default "QRP") in Shelf and, within a minute,
# its label comes out of your Niimbot. Run this every minute (cron, or User
# Scripts on Unraid). Each run:
#   1. asks Shelf's database for assets with the print tag
#   2. sends each one to the printer through Home Assistant's niimbot.print
#   3. once Home Assistant says it printed, swaps the print tag for the done
#      tag (default "QRU"), so Shelf shows which assets have a label
# If a print fails (printer off, out of range, Home Assistant down) the tag
# stays and the run stops; the next run tries again.
#
#   ./shelf-labels.sh            print everything tagged
#   ./shelf-labels.sh --list     show what would print, touch nothing
#   ./shelf-labels.sh --preview  render in Home Assistant without printing
#                                (see the "Last Label Made" image there)
#   ./shelf-labels.sh --version
#
# Settings live in label-printer.env next to this script.
# Each print run also writes status.json and history.jsonl into data/labels/,
# which the optional status page reads.

set -uo pipefail

VERSION="1.0.0"

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="${CONF:-$DIR/label-printer.env}"
SHELF_ENV="${SHELF_ENV:-$DIR/.env}"

MODE=print
case "${1:-}" in
  "")        ;;
  --list)    MODE=list ;;
  --preview) MODE=preview ;;
  --version) echo "shelf-labels $VERSION"; exit 0 ;;
  *) echo "Usage: $0 [--list|--preview|--version]"; exit 1 ;;
esac

log() { echo "$*"; logger -t shelf-labels "$*" 2>/dev/null || true; }
die() { log "ERROR: $*"; exit 1; }

# ------------------------------------------------------------------ settings
[ -f "$CONF" ] || die "no settings file at $CONF"
set -a; . "$CONF"; set +a

TAG_NAME="${TAG_NAME:-QRP}"
DONE_TAG="${DONE_TAG-QRU}"          # tag added after printing; blank = add nothing
LABEL_WIDTH="${LABEL_WIDTH:-320}"   # 320 = 40 mm label, 240 = 30 mm
DENSITY="${DENSITY:-}"              # blank = printer default
ROTATE="${ROTATE:-90}"              # 270 if labels come out upside down
LEFT_MARGIN="${LEFT_MARGIN:-8}"     # space before the QR code, in dots (8 = 1 mm)
DB_CONTAINER="${DB_CONTAINER:-shelf-db}"   # the Postgres container Shelf uses
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-postgres}"

# The address Shelf is opened at. Every QR code links here, so it must be the
# same as Shelf's own SERVER_URL. If it isn't set, read it from a Shelf .env
# file next to this script, if there is one.
SERVER_URL="${SHELF_URL:-}"
if [ -z "$SERVER_URL" ] && [ -f "$SHELF_ENV" ]; then
  SERVER_URL=$(grep -E '^SERVER_URL=' "$SHELF_ENV" | cut -d= -f2-)
fi
[ -n "$SERVER_URL" ] || die "set SHELF_URL in $CONF to the address you open Shelf at"

[[ "$LABEL_WIDTH" =~ ^[0-9]+$ ]] && [ "$LABEL_WIDTH" -ge 200 ] || die "LABEL_WIDTH must be a number, 200 or more"
[ -z "$DENSITY" ] || [[ "$DENSITY" =~ ^[0-9]+$ ]] || die "DENSITY must be a number or blank"
[[ "$ROTATE" =~ ^(90|270)$ ]] || die "ROTATE must be 90 or 270"
# Same name for both would reprint every label forever
[ "${DONE_TAG,,}" != "${TAG_NAME,,}" ] || die "DONE_TAG and TAG_NAME must be different"
[[ "$LEFT_MARGIN" =~ ^[0-9]+$ ]] && [ "$LEFT_MARGIN" -le 40 ] || die "LEFT_MARGIN must be a number from 0 to 40"

# Shorter labels get slightly smaller text so more of the name fits
if [ "$LABEL_WIDTH" -ge 300 ]; then TITLE_SIZE=20; TITLE_MAX=40
else TITLE_SIZE=18; TITLE_MAX=$(( (LABEL_WIDTH - 106 - LEFT_MARGIN) * 30 / 134 )); fi
if [ "$MODE" != list ]; then
  [ -n "${HA_URL:-}" ]            || die "HA_URL not set in $CONF"
  [ -n "${HA_TOKEN:-}" ]          || die "HA_TOKEN not set in $CONF"
  [ -n "${NIIMBOT_DEVICE_ID:-}" ] || die "NIIMBOT_DEVICE_ID not set in $CONF"
fi
HA_URL="${HA_URL%/}"

LABEL_DATA="${LABEL_DATA:-$DIR/data/labels}"
STATUS_FILE="$LABEL_DATA/status.json"
HISTORY_FILE="$LABEL_DATA/history.jsonl"
ERROR_FILE="$LABEL_DATA/.last_error.json"
HISTORY_KEEP=500

# JSON-escape a string (for error messages, which come from outside)
json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/}; s=${s//$'\t'/\\t}
  printf '"%s"' "$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
}
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Printer details from Home Assistant: every entity on the Niimbot device.
# Returns a JSON array, or null if HA can't be asked.
printer_status() {
  [[ "$NIIMBOT_DEVICE_ID" =~ ^[A-Za-z0-9]+$ ]] || { echo null; return; }
  local tpl out
  tpl="{% set ns = namespace(items=[]) %}{% for e in device_entities('$NIIMBOT_DEVICE_ID') %}{% set ns.items = ns.items + [{'entity': e, 'name': state_attr(e, 'friendly_name'), 'state': states(e), 'unit': state_attr(e, 'unit_of_measurement'), 'device_class': state_attr(e, 'device_class')}] %}{% endfor %}{{ ns.items | tojson }}"
  out=$(curl -sS -m 10 -X POST "$HA_URL/api/template" \
          -H "Authorization: Bearer $HA_TOKEN" -H "Content-Type: application/json" \
          --data-binary "{\"template\": $(json_str "$tpl")}" 2>/dev/null)
  out=$(printf '%s' "$out" | tr -d '\n')
  if [[ "$out" == \[*\] ]]; then printf '%s' "$out"; else echo null; fi
}

# Write the status page's view of things. Args: current-job JSON (or null),
# then the JSON for each job still waiting.
PRINTER=null
write_status() {
  [ "$MODE" = print ] || return 0
  local current=$1; shift
  local queue="" item err=null
  for item in "$@"; do queue="${queue:+$queue,}$item"; done
  [ -s "$ERROR_FILE" ] && err=$(cat "$ERROR_FILE")
  printf '{"updated":"%s","server_url":%s,"tag":%s,"label_width":%s,"title_size":%s,"left_margin":%s,"printer":%s,"current":%s,"queue":[%s],"last_error":%s}\n' \
    "$(now)" "$(json_str "$SERVER_URL")" "$(json_str "$TAG_NAME")" "$LABEL_WIDTH" "$TITLE_SIZE" "$LEFT_MARGIN" \
    "$PRINTER" "$current" "$queue" "$err" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}
record_error() {  # message, job JSON (or null)
  printf '{"at":"%s","message":%s,"job":%s}' "$(now)" "$(json_str "$1")" "${2:-null}" > "$ERROR_FILE"
}
record_printed() {  # job JSON, result
  printf '{"at":"%s","result":"%s","job":%s}\n' "$(now)" "$2" "$1" >> "$HISTORY_FILE"
  if [ "$(wc -l < "$HISTORY_FILE")" -gt $((HISTORY_KEEP + 50)) ]; then
    tail -n "$HISTORY_KEEP" "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
  fi
}

# Only one run at a time: a slow print must not overlap the next minute's run
exec 9>/tmp/shelf-labels.lock
flock -n 9 || exit 0

if [ "$MODE" = print ]; then
  mkdir -p "$LABEL_DATA"
  PRINTER=$(printer_status)
fi

# ---------------------------------------------------------- find the assets
# The whole Home Assistant request is built in Postgres, so names with quotes,
# backslashes or emoji are escaped correctly. Output: one line per asset,
#   asset id <TAB> tag id <TAB> SAM id <TAB> name <TAB> job (for the status
#   page) <TAB> request body
PREVIEW=false; [ "$MODE" = preview ] && PREVIEW=true

ROWS=$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -X -q -At \
  -v ON_ERROR_STOP=1 \
  -v tag="$TAG_NAME" -v url="$SERVER_URL" -v device="${NIIMBOT_DEVICE_ID:-}" \
  -v width="$LABEL_WIDTH" -v density="$DENSITY" -v rotate="$ROTATE" -v preview="$PREVIEW" \
  -v title_size="$TITLE_SIZE" -v title_max="$TITLE_MAX" -v m="$LEFT_MARGIN" <<'SQL'
WITH tagged AS (
  SELECT a.id                                           AS asset_id,
         t.id                                           AS tag_id,
         coalesce(a."sequentialId", '')                 AS sam,
         regexp_replace(a.title, '\s+', ' ', 'g')       AS title,
         CASE WHEN length(regexp_replace(a.title, '\s+', ' ', 'g')) > :title_max
              THEN rtrim(left(regexp_replace(a.title, '\s+', ' ', 'g'), :title_max - 1)) || '…'
              ELSE regexp_replace(a.title, '\s+', ' ', 'g') END AS label_title,
         q.id                                           AS qr_id
  FROM "Asset" a
  JOIN "_AssetToTag" at ON at."A" = a.id
  JOIN "Tag" t          ON t.id = at."B"
  JOIN LATERAL (
    SELECT id FROM "Qr" WHERE "assetId" = a.id
    ORDER BY "createdAt" DESC LIMIT 1
  ) q ON true
  WHERE lower(t.name) = lower(:'tag')
)
SELECT asset_id || E'\t' || tag_id || E'\t' || sam || E'\t' || title || E'\t' ||
  jsonb_build_object('asset', asset_id, 'sam', sam, 'title', title, 'label_title', label_title,
                     'qr', rtrim(:'url','/') || '/qr/' || qr_id)::text || E'\t' ||
  (jsonb_build_object(
     'device_id', :'device',
     'rotate',    :rotate,
     'width',     :width,
     'height',    96,
     'preview',   :'preview'::boolean,
     'payload', jsonb_build_array(
       jsonb_build_object('type','qrcode', 'data', rtrim(:'url','/') || '/qr/' || qr_id,
                          'x',2 + :m, 'y',1, 'boxsize',3, 'border',1, 'eclevel','l',
                          'width',93, 'height',93),   -- longer links are scaled to fit
       jsonb_build_object('type','text', 'value', sam,
                          'x',102 + :m, 'y',4, 'size',16, 'font','ppb.ttf'),
       jsonb_build_object('type','text',
                          'value', label_title,
                          'x',102 + :m, 'y',27, 'size',:title_size, 'spacing',2,
                          'max_width', :width - 106 - :m, 'font','ppb.ttf')
     )
   ) || jsonb_strip_nulls(jsonb_build_object('density', nullif(:'density', '')::int))
  )::text
FROM tagged
ORDER BY sam = '', sam, title;
SQL
) || {
  [ "$MODE" = print ] && { record_error "Couldn't read Shelf's database. Is the $DB_CONTAINER container running, and are DB_CONTAINER, DB_USER and DB_NAME right?"; write_status null; }
  die "couldn't read Shelf's database: check $DB_CONTAINER is running, and DB_CONTAINER, DB_USER and DB_NAME in $CONF"
}

# Collect the jobs first, so the status page can show the whole queue
ASSETS=(); TAGS=(); LABELS=(); JOBS=(); BODIES=()
while IFS=$'\t' read -r -u 3 asset tag sam title job body; do
  [ -n "$asset" ] || continue
  # Ids are database-generated; refuse anything that isn't a plain id before
  # it goes anywhere near a query.
  if ! [[ "$asset" =~ ^[A-Za-z0-9_-]+$ && "$tag" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log "skipping a row with an unexpected id"
    continue
  fi
  ASSETS+=("$asset"); TAGS+=("$tag"); LABELS+=("${sam:-no ID} — $title")
  JOBS+=("$job"); BODIES+=("$body")
done 3<<<"$ROWS"

if [ ${#ASSETS[@]} -eq 0 ]; then
  [ "$MODE" = print ] && rm -f "$ERROR_FILE"   # nothing waiting, so nothing is stuck
  write_status null
  [ -t 1 ] && echo "Nothing tagged '$TAG_NAME'."
  exit 0
fi

# ------------------------------------------------------------------- print
write_status null "${JOBS[@]}"
printed=0
for i in "${!ASSETS[@]}"; do
  asset=${ASSETS[$i]}; tag=${TAGS[$i]}; label=${LABELS[$i]}; job=${JOBS[$i]}

  if [ "$MODE" = list ]; then
    echo "$label"
    continue
  fi

  write_status "$job" "${JOBS[@]:$((i + 1))}"

  code=$(curl -sS -m 180 -o /tmp/shelf-labels.resp -w '%{http_code}' \
           -X POST "$HA_URL/api/services/niimbot/print" \
           -H "Authorization: Bearer $HA_TOKEN" \
           -H "Content-Type: application/json" \
           --data-binary "${BODIES[$i]}" 2>/tmp/shelf-labels.err)

  if [ "$code" != 200 ]; then
    why=$(head -c 300 /tmp/shelf-labels.resp 2>/dev/null; head -c 200 /tmp/shelf-labels.err 2>/dev/null)
    log "FAILED $label (HTTP $code) ${why} — tag kept, will retry next run"
    if [ "$code" = 000 ]; then
      record_error "Couldn't reach Home Assistant at $HA_URL. ${why}" "$job"
    else
      record_error "Home Assistant couldn't print it (HTTP $code). Is the printer on and in range? ${why}" "$job"
    fi
    write_status null "${JOBS[@]:$i}"
    exit 1
  fi

  if [ "$MODE" = preview ]; then
    log "previewed $label (not printed, tag kept)"
    continue
  fi

  rm -f "$ERROR_FILE"
  # One statement, so it's all-or-nothing: remove the print tag, and add the
  # done tag from the same workspace as the asset. Output: removed found added
  result=$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -X -q -At \
    -v ON_ERROR_STOP=1 -v asset="$asset" -v tag="$tag" -v done="$DONE_TAG" 2>&1 <<'SQL'
WITH del AS (
  DELETE FROM "_AssetToTag" WHERE "A" = :'asset' AND "B" = :'tag' RETURNING 1
), done_tag AS (
  SELECT t.id FROM "Tag" t
  JOIN "Asset" a ON a."organizationId" = t."organizationId"
  WHERE a.id = :'asset' AND :'done' <> '' AND lower(t.name) = lower(:'done')
  ORDER BY t.id LIMIT 1
), ins AS (
  INSERT INTO "_AssetToTag" ("A", "B") SELECT :'asset', id FROM done_tag
  ON CONFLICT DO NOTHING RETURNING 1
)
SELECT (SELECT count(*) FROM del) || ' ' || (SELECT count(*) FROM done_tag) || ' ' || (SELECT count(*) FROM ins);
SQL
)
  if ! [[ "$result" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]; then
    log "printed $label but couldn't update its tags ($result) — remove $TAG_NAME in Shelf or it will print again"
    record_printed "$job" tag_kept
    record_error "Printed $label but couldn't remove its $TAG_NAME tag, so it will print again. Remove the tag in Shelf." "$job"
  else
    read -r _removed found _added <<<"$result"
    if [ -z "$DONE_TAG" ]; then
      log "printed $label"
      record_printed "$job" printed
    elif [ "$found" = 1 ]; then
      log "printed $label (now tagged $DONE_TAG)"
      record_printed "$job" printed
    else
      log "printed $label, but there's no $DONE_TAG tag in Shelf to mark it with"
      record_printed "$job" no_done_tag
      record_error "Printed $label, but couldn't mark it $DONE_TAG because Shelf has no tag called $DONE_TAG. Create it in Shelf; labels printed meanwhile won't be marked." "$job"
    fi
  fi
  printed=$((printed + 1))
  sleep 1
done

write_status null
[ "$MODE" = print ] && [ "$printed" -gt 0 ] && log "done: $printed label(s)"
exit 0
