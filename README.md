# Met Museum 3D Scan Downloader

Downloads 3D scans from The Metropolitan Museum of Art's collection via their Vntana-hosted assets. Models are CC0 (public domain) under the Met's Open Access policy.

## Quick start

### 1. Get object IDs

The included `object_ids.txt` has all ~129 objects with 3D scans as of March 2026. To refresh:

```bash
for offset in 0 40 80 120; do
  curl -s "https://www.metmuseum.org/art/collection/search?showOnly=has3d&offset=${offset}&perPage=40" \
    | grep -oE '/art/collection/search/[0-9]+' | grep -oE '[0-9]+'
done | sort -un > object_ids.txt
```

### 2. Download models

Single object:
```bash
./met-dl.sh 547802           # GLB (default)
./met-dl.sh 547802 fbx       # FBX
./met-dl.sh 547802 all       # all formats (GLB, FBX, USDZ)
./met-dl.sh https://www.metmuseum.org/art/collection/search/547802  # URL also works
```

All objects:
```bash
./batch-dl.sh glb             # download all as GLB
./batch-dl.sh all             # download all objects in all formats
./met-dl.sh all               # shorthand for the batch command above
```

The batch script is resumable — it skips files that already exist.

Downloads are organized by file type automatically:

```text
glb/
fbx/
usdz/
```

### 3. Verify downloads

```bash
# count files and total size
find glb -type f -name '*.glb' | wc -l
du -sh glb

# check a specific file isn't corrupted (needs blender CLI or gltf-validator)
npx gltf-validator glb/somefile.glb
```

### 4. Build metadata catalog

```bash
./build-catalog.sh
```

Produces `catalog.json` with full Met API metadata (title, artist, date, medium, dimensions, culture, period, etc.) and Vntana asset info (filenames, download URLs, poly counts) for every object.

## What you get

- **Format:** GLB (glTF-binary), also FBX and USDZ available
- **Poly count:** ~100k per model (Vntana-decimated from originals that range 1M–35M)
- **Textures:** Baked, embedded in the GLB
- **License:** CC0 public domain
- **Total size:** ~600 MB for all GLBs

## Files

| File | Purpose |
|------|---------|
| `object_ids.txt` | List of Met object IDs with 3D scans |
| `met-dl.sh` | Download single object |
| `batch-dl.sh` | Download all objects |
| `build-catalog.sh` | Build catalog.json from Met API + Vntana data |
| `catalog.json` | Full metadata for all objects |
| `download_log.txt` | Log of batch download results |
