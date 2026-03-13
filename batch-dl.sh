#!/usr/bin/env bash
# Batch download all Met 3D scans
# Polite: 1s delay between metadata fetches, 5s between downloads
# Resumes: skips already-downloaded files

set -euo pipefail
cd "$(dirname "$0")"

FORMAT="${1:-glb}"
IDS_FILE="object_ids.txt"
LOG_FILE="download_log.txt"
CATALOG_FILE="catalog.json"
DOWNLOAD_DELAY=5

refresh_ids_from_catalog() {
    if [ ! -f "$CATALOG_FILE" ]; then
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp)

    python3 - "$CATALOG_FILE" "$tmp_file" <<'PY'
import json
import sys

catalog_path, ids_path = sys.argv[1], sys.argv[2]
with open(catalog_path, "r", encoding="utf-8") as f:
    data = json.load(f)

object_ids = []
for entry in data:
    object_id = entry.get("object_id")
    if object_id is not None:
        object_ids.append(str(object_id))

object_ids = sorted(set(object_ids), key=int)

with open(ids_path, "w", encoding="utf-8") as f:
    for object_id in object_ids:
        f.write(object_id + "\n")

print(len(object_ids))
PY
    local count
    count=$(wc -l < "$tmp_file" | tr -d ' ')

    if [ "$count" -eq 0 ]; then
        rm -f "$tmp_file"
        return 1
    fi

    mv "$tmp_file" "$IDS_FILE"
    printf '%s\n' "$count"
}

refresh_ids_from_met() {
    local tmp_file
    tmp_file=$(mktemp)

    for offset in 0 40 80 120; do
        curl -sf "https://www.metmuseum.org/art/collection/search?showOnly=has3d&offset=${offset}&perPage=40" \
            | grep -oE '/art/collection/search/[0-9]+' \
            | grep -oE '[0-9]+'
    done | sort -un > "$tmp_file"

    if [ ! -s "$tmp_file" ]; then
        rm -f "$tmp_file"
        return 1
    fi

    mv "$tmp_file" "$IDS_FILE"
}

if [ ! -s "$IDS_FILE" ]; then
    echo "object_ids.txt is missing or empty; rebuilding it..."

    if count=$(refresh_ids_from_catalog); then
        echo "Recovered ${count} object IDs from catalog.json."
    elif refresh_ids_from_met; then
        count=$(wc -l < "$IDS_FILE" | tr -d ' ')
        echo "Fetched ${count} object IDs from the Met website."
    else
        echo "Error: could not populate ${IDS_FILE} from catalog.json or the Met website." >&2
        exit 1
    fi
fi

total=$(grep -c . "$IDS_FILE")
current=0
skipped=0
downloaded=0
failed=0

echo "Downloading ${total} Met 3D objects (format: ${FORMAT})"
echo "$(date): Batch download started (format: ${FORMAT})" >> "$LOG_FILE"

while read -r object_id; do
    current=$((current + 1))

    # Fetch metadata
    html=$(curl -sf "https://www.metmuseum.org/art/collection/search/${object_id}" 2>/dev/null) || {
        echo "  [${current}/${total}] ${object_id}: FAILED to fetch page"
        echo "FAIL_PAGE ${object_id}" >> "$LOG_FILE"
        failed=$((failed + 1))
        sleep 1
        continue
    }

    # Extract vntanaAssets and download URLs
    result=$(echo "$html" | python3 -c "
import sys, re, json

html = sys.stdin.read()
idx = html.find('vntanaAssets')
if idx < 0:
    sys.exit(1)

chunk = html[idx:idx+30000]
chunk = chunk.replace('\\\\\\\\', '\\\\').replace('\\\\\"', '\"')
arr_start = chunk.find('[')
if arr_start < 0:
    sys.exit(1)

depth = 0; in_str = False; escape = False; end = -1
for i, c in enumerate(chunk[arr_start:]):
    if escape: escape = False; continue
    if c == '\\\\': escape = True; continue
    if c == '\"' and not escape: in_str = not in_str
    if not in_str:
        if c == '[': depth += 1
        elif c == ']':
            depth -= 1
            if depth == 0: end = arr_start + i + 1; break

if end < 0:
    sys.exit(1)

assets = json.loads(chunk[arr_start:end])
fmt = '${FORMAT}'.upper()

for asset in assets:
    uuid = asset.get('uuid', '')
    client = asset.get('clientSlug', 'masters')
    name = asset.get('name', 'unknown')
    models = asset.get('asset', {}).get('models', [])
    orig = asset.get('asset', {}).get('assetOriginalName', '')
    orig_size = asset.get('asset', {}).get('assetOriginalSize', 0)
    for m in models:
        if fmt == 'ALL' or m['conversionFormat'] == fmt:
            blob = m['modelBlobId']
            ext = m['conversionFormat'].lower()
            size_mb = m.get('modelSize', 0) / 1024 / 1024
            polys = m.get('optimizationThreeDComponents', {}).get('poly', '?')
            orig_polys = m.get('originalThreeDComponents', {}).get('poly', '?')
            url = f'https://api.vntana.com/assets/products/{uuid}/organizations/The-Metropolitan-Museum-of-Art/clients/{client}/{blob}'
            safe_name = re.sub(r'[^a-zA-Z0-9._-]', '_', name)
            filename = f'${object_id}_{safe_name}.{ext}'
            print(f'{url}\t{filename}\t{size_mb:.1f}\t{polys}\t{orig_polys}')
" 2>/dev/null) || {
        echo "  [${current}/${total}] ${object_id}: no 3D data"
        echo "NO_3D ${object_id}" >> "$LOG_FILE"
        sleep 1
        continue
    }

    printf '%s\n' "$result" | while IFS=$'\t' read -r url filename size_mb polys orig_polys; do
        if [ -z "${url:-}" ] || [ -z "${filename:-}" ]; then
            continue
        fi

        ext="${filename##*.}"
        out_dir=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
        out_path="${out_dir}/${filename}"
        mkdir -p "$out_dir"

        if [ -f "$out_path" ]; then
            echo "  [${current}/${total}] ${out_path}: already exists, skipping"
            echo "SKIP ${object_id} ${out_path}" >> "$LOG_FILE"
            continue
        fi

        echo "  [${current}/${total}] ${out_path} (${size_mb} MB, ${polys} polys, was ${orig_polys})"
        if curl -sf -o "${out_path}" "${url}"; then
            echo "OK ${object_id} ${out_path}" >> "$LOG_FILE"
        else
            echo "    FAILED to download"
            echo "FAIL_DL ${object_id} ${out_path}" >> "$LOG_FILE"
            rm -f "${out_path}"
        fi
        sleep "$DOWNLOAD_DELAY"
    done

    sleep 1

done < "$IDS_FILE"

echo ""
echo "Done! Check download_log.txt for details."
echo "$(date): Batch download finished" >> "$LOG_FILE"
