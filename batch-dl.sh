#!/bin/bash
# Batch download all Met 3D scans
# Polite: 1s delay between metadata fetches, 0.5s between downloads
# Resumes: skips already-downloaded files

set -euo pipefail
cd "$(dirname "$0")"

FORMAT="${1:-glb}"
IDS_FILE="object_ids.txt"
LOG_FILE="download_log.txt"

total=$(wc -l < "$IDS_FILE")
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

    echo "$result" | while IFS=$'\t' read -r url filename size_mb polys orig_polys; do
        if [ -f "$filename" ]; then
            echo "  [${current}/${total}] ${filename}: already exists, skipping"
            echo "SKIP ${object_id} ${filename}" >> "$LOG_FILE"
            continue
        fi

        echo "  [${current}/${total}] ${filename} (${size_mb} MB, ${polys} polys, was ${orig_polys})"
        if curl -sf -o "${filename}" "${url}"; then
            echo "OK ${object_id} ${filename}" >> "$LOG_FILE"
        else
            echo "    FAILED to download"
            echo "FAIL_DL ${object_id} ${filename}" >> "$LOG_FILE"
            rm -f "${filename}"
        fi
        sleep 0.5
    done

    sleep 1

done < "$IDS_FILE"

echo ""
echo "Done! Check download_log.txt for details."
echo "$(date): Batch download finished" >> "$LOG_FILE"
