#!/usr/bin/env bash
# Download 3D scans from The Metropolitan Museum of Art
# Usage: ./met-dl.sh <object_id_or_url> [format]
# Example: ./met-dl.sh 547802
# Example: ./met-dl.sh https://www.metmuseum.org/art/collection/search/547802
# Example: ./met-dl.sh 547802 fbx
#
# Formats: glb (default), fbx, usdz, all

set -euo pipefail
cd "$(dirname "$0")"

DOWNLOAD_DELAY=5

# Extract object ID from URL or use as-is
INPUT="${1:-}"
FORMAT="${2:-glb}"

usage() {
    echo "Usage: $0 <object_id_or_url> [format]" >&2
    echo "   or: $0 <format>    # batch download all object IDs from object_ids.txt" >&2
    echo "Formats: glb (default), fbx, usdz, all" >&2
}

if [ -z "$INPUT" ]; then
    usage
    exit 1
fi

case "$INPUT" in
    glb|fbx|usdz|all|GLB|FBX|USDZ|ALL)
        if [ "$#" -eq 1 ]; then
            exec ./batch-dl.sh "$INPUT"
        fi
        ;;
esac

OBJECT_ID=$(printf '%s\n' "$INPUT" | sed -nE 's#.*\/([0-9]+)$#\1#p')
if [ -z "$OBJECT_ID" ]; then
    OBJECT_ID="$INPUT"
fi

URL="https://www.metmuseum.org/art/collection/search/${OBJECT_ID}"
echo "Fetching metadata for object ${OBJECT_ID}..."

HTML=$(curl -sf "$URL") || { echo "Error: Could not fetch $URL"; exit 1; }

# Extract vntanaAssets JSON
ASSETS=$(echo "$HTML" | python3 -c "
import sys, re, json

html = sys.stdin.read()
idx = html.find('vntanaAssets')
if idx < 0:
    print('ERROR: No 3D model found for this object', file=sys.stderr)
    sys.exit(1)

chunk = html[idx:idx+20000]
chunk = chunk.replace('\\\\\\\\', '\\\\').replace('\\\\\"', '\"')
arr_start = chunk.find('[')
if arr_start < 0 or chunk[arr_start-4:arr_start].rstrip().endswith('null'):
    # vntanaAssets is null for this object
    print('ERROR: No 3D model available for this object (vntanaAssets is null)', file=sys.stderr)
    sys.exit(1)
depth = 0
in_str = False
escape = False
end = -1
for i, c in enumerate(chunk[arr_start:]):
    if escape:
        escape = False
        continue
    if c == '\\\\':
        escape = True
        continue
    if c == '\"' and not escape:
        in_str = not in_str
    if not in_str:
        if c == '[': depth += 1
        elif c == ']':
            depth -= 1
            if depth == 0:
                end = arr_start + i + 1
                break

if end < 0:
    print('ERROR: Could not parse asset data', file=sys.stderr)
    sys.exit(1)

assets = json.loads(chunk[arr_start:end])
print(json.dumps(assets))
") || exit 1

# Parse and download
echo "$ASSETS" | python3 -c "
import sys, json

assets = json.loads(sys.stdin.read())
format_arg = '${FORMAT}'.upper()

for asset in assets:
    name = asset.get('name', 'unknown')
    uuid = asset['uuid']
    client = asset['clientSlug']
    orig_name = asset['asset'].get('assetOriginalName', '')
    orig_size = asset['asset'].get('assetOriginalSize', 0)
    orig_comps = None

    print(f'Asset: {name}')
    print(f'  Original: {orig_name} ({orig_size/1024/1024:.1f} MB)')

    models = asset['asset'].get('models', [])
    for m in models:
        fmt = m['conversionFormat']
        blob = m['modelBlobId']
        size = m.get('modelSize', 0)
        opt = m.get('optimizationThreeDComponents', {})
        orig = m.get('originalThreeDComponents', {})
        polys = opt.get('poly', '?')
        orig_polys = orig.get('poly', '?')
        verts = opt.get('vertex', '?')

        url = f'https://api.vntana.com/assets/products/{uuid}/organizations/The-Metropolitan-Museum-of-Art/clients/{client}/{blob}'
        print(f'  {fmt}: {size/1024/1024:.1f} MB | {polys:,} polys (original: {orig_polys:,}) | {verts:,} verts')
        print(f'    {url}')

    print()
" || exit 1

# Download the requested format(s)
echo "$ASSETS" | python3 -c "
import sys, json

assets = json.loads(sys.stdin.read())
format_arg = '${FORMAT}'.upper()

lines = []
for asset in assets:
    uuid = asset['uuid']
    client = asset['clientSlug']
    name = asset.get('name', 'unknown').replace(' ', '_').replace('/', '_')
    models = asset['asset'].get('models', [])
    for m in models:
        fmt = m['conversionFormat']
        blob = m['modelBlobId']
        ext = fmt.lower()
        if format_arg == 'ALL' or fmt == format_arg:
            url = f'https://api.vntana.com/assets/products/{uuid}/organizations/The-Metropolitan-Museum-of-Art/clients/{client}/{blob}'
            filename = f'{name}.{ext}'
            lines.append(f'{url} {filename}')

for l in lines:
    print(l)
" | while read -r dl_url filename; do
    if [ -z "${dl_url:-}" ] || [ -z "${filename:-}" ]; then
        continue
    fi

    ext="${filename##*.}"
    out_dir=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
    mkdir -p "${out_dir}"
    out_path="${out_dir}/${filename}"
    echo "Downloading ${out_path}..."
    curl -f --progress-bar -o "${out_path}" "${dl_url}" || echo "  Failed to download ${out_path}"
    sleep "$DOWNLOAD_DELAY"
done

echo "Done!"
