#!/usr/bin/env bash
# Build a comprehensive catalog.json by merging:
# 1. Met Public API metadata (title, artist, date, medium, dimensions, etc.)
# 2. Vntana 3D asset data (filenames, download URLs, poly counts, etc.)

set -euo pipefail
cd "$(dirname "$0")"

IDS_FILE="object_ids.txt"
OUT_FILE="catalog.json"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

total=$(wc -l < "$IDS_FILE")
current=0

echo "Building catalog for ${total} objects..."

# Download all API data and HTML, then process with Python
while read -r object_id; do
    current=$((current + 1))
    echo "  [${current}/${total}] Fetching ${object_id}..."

    curl -sf "https://collectionapi.metmuseum.org/public/collection/v1/objects/${object_id}" \
        > "${TMPDIR}/${object_id}.api.json" 2>/dev/null || echo "{}" > "${TMPDIR}/${object_id}.api.json"

    curl -sf "https://www.metmuseum.org/art/collection/search/${object_id}" \
        > "${TMPDIR}/${object_id}.html" 2>/dev/null || echo "" > "${TMPDIR}/${object_id}.html"

    sleep 0.5
done < "$IDS_FILE"

echo "Processing..."

python3 - "$TMPDIR" "$IDS_FILE" "$OUT_FILE" << 'PYEOF'
import sys, os, re, json

tmpdir = sys.argv[1]
ids_file = sys.argv[2]
out_file = sys.argv[3]

with open(ids_file) as f:
    object_ids = [line.strip() for line in f if line.strip()]

catalog = []

for object_id in object_ids:
    # Load API data
    api_path = os.path.join(tmpdir, f"{object_id}.api.json")
    try:
        with open(api_path) as f:
            api = json.load(f)
    except:
        api = {}

    # Load HTML and parse Vntana assets
    html_path = os.path.join(tmpdir, f"{object_id}.html")
    try:
        with open(html_path) as f:
            html = f.read()
    except:
        html = ""

    files = []
    idx = html.find('vntanaAssets')
    if idx >= 0:
        chunk = html[idx:idx+30000]
        chunk = chunk.replace('\\\\', '\\').replace('\\"', '"')
        arr_start = chunk.find('[')
        if arr_start >= 0:
            # Check it's not null
            before = chunk[max(0,arr_start-10):arr_start].strip()
            if not before.endswith('null'):
                depth = 0; in_str = False; escape = False; end = -1
                for i, c in enumerate(chunk[arr_start:]):
                    if escape: escape = False; continue
                    if c == '\\': escape = True; continue
                    if c == '"' and not escape: in_str = not in_str
                    if not in_str:
                        if c == '[': depth += 1
                        elif c == ']':
                            depth -= 1
                            if depth == 0: end = arr_start + i + 1; break
                if end > 0:
                    try:
                        assets = json.loads(chunk[arr_start:end])
                        for asset in assets:
                            uuid = asset.get('uuid', '')
                            client = asset.get('clientSlug', 'masters')
                            name = asset.get('name', 'unknown')
                            safe_name = re.sub(r'[^a-zA-Z0-9._-]', '_', name)
                            for m in asset.get('asset', {}).get('models', []):
                                blob = m['modelBlobId']
                                fmt = m['conversionFormat'].lower()
                                files.append({
                                    'filename': f'{object_id}_{safe_name}.{fmt}',
                                    'format': m['conversionFormat'],
                                    'size_bytes': m.get('modelSize', 0),
                                    'polys': (m.get('optimizationThreeDComponents') or {}).get('poly'),
                                    'vertices': (m.get('optimizationThreeDComponents') or {}).get('vertex'),
                                    'original_polys': (m.get('originalThreeDComponents') or {}).get('poly'),
                                    'original_vertices': (m.get('originalThreeDComponents') or {}).get('vertex'),
                                    'original_file': asset.get('asset', {}).get('assetOriginalName', ''),
                                    'original_size_bytes': asset.get('asset', {}).get('assetOriginalSize', 0),
                                    'download_url': f'https://api.vntana.com/assets/products/{uuid}/organizations/The-Metropolitan-Museum-of-Art/clients/{client}/{blob}',
                                })
                    except Exception as e:
                        print(f"  Warning: failed to parse Vntana data for {object_id}: {e}", file=sys.stderr)

    # Build entry
    pick_keys = [
        'title', 'artistDisplayName', 'artistDisplayBio',
        'objectDate', 'objectBeginDate', 'objectEndDate',
        'medium', 'dimensions', 'department', 'classification',
        'culture', 'period', 'dynasty', 'reign',
        'accessionNumber', 'accessionYear', 'creditLine',
        'geographyType', 'city', 'state', 'county', 'country', 'region',
        'isPublicDomain', 'isHighlight',
        'primaryImage', 'primaryImageSmall',
        'GalleryNumber',
    ]
    picked = {k: api[k] for k in pick_keys if api.get(k) not in (None, '', False, 0)}

    entry = {
        'object_id': int(object_id),
        'met_url': f'https://www.metmuseum.org/art/collection/search/{object_id}',
        **picked,
        'files': files,
    }
    catalog.append(entry)
    title = picked.get('title', '?')
    n_files = len(files)
    print(f"  {object_id}: {title} ({n_files} files)")

with open(out_file, 'w') as f:
    json.dump(catalog, f, indent=2, ensure_ascii=False)

total_files = sum(len(o['files']) for o in catalog)
has_3d = sum(1 for o in catalog if o['files'])
print(f"\nCatalog complete: {len(catalog)} objects, {has_3d} with 3D models, {total_files} file entries")
PYEOF
