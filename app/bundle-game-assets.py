#!/usr/bin/env python3
"""Embed and hash-check Stray's non-code resources in a separately staged app."""
import argparse
import hashlib
import json
import plistlib
import shutil
from pathlib import Path

def digest(path):
    with path.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source', type=Path, required=True)
p.add_argument('--staging', type=Path, required=True)
a = p.parse_args()
manifest_path = a.staging / 'manifest.json'
manifest = json.loads(manifest_path.read_text())
app = Path(manifest['application'])
root = app / 'GuestGame'
if a.source.resolve() == root.resolve(): p.error('Source must remain separate')
records, omitted = [], []
for source in sorted((a.source / 'Contents').rglob('*')):
    relative = source.relative_to(a.source)
    target = root / relative
    if source.is_symlink(): raise ValueError(f'Unexpected resource symlink: {source}')
    if source.is_dir(): target.mkdir(parents=True, exist_ok=True); continue
    with source.open('rb') as f: magic = f.read(4)
    if magic in [bytes.fromhex(s) for s in ['cffaedfe','cefaedfe','cafebabe','bebafeca','cafebabf']]:
        omitted.append(str(relative)); continue
    target.parent.mkdir(parents=True, exist_ok=True)
    sha = digest(source)
    if not target.exists() or target.stat().st_size != source.stat().st_size or digest(target) != sha:
        shutil.copy2(source, target)
    if digest(target) != sha: raise ValueError(f'Resource hash mismatch: {relative}')
    records.append({'path': str(relative), 'size': source.stat().st_size, 'sha256': sha})
info_path = app / 'Info.plist'
info = plistlib.loads(info_path.read_bytes())
info.pop('StrayGameRoot', None)
info['StrayGameRelativeRoot'] = 'GuestGame'
info['CFBundleDisplayName'] = 'Stray Test'
info['UISupportedInterfaceOrientations'] = ['UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight']
info_path.write_bytes(plistlib.dumps(info))
manifest['full_assets_bundled'] = True
manifest['resource_bytes'] = sum(r['size'] for r in records)
manifest['resource_count'] = len(records)
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
report = {'source': str(a.source.resolve()), 'application': str(app.resolve()),
          'resources': records, 'omitted_native_code': omitted,
          'reason_for_code_omission': 'Retargeted guest code resides in the signed Frameworks directory.',
          'bytes': manifest['resource_bytes'], 'gameplay_verified': False}
(a.staging / 'assets.json').write_text(json.dumps(report, indent=2) + '\n')
print(f"Verified {len(records)} resources, {report['bytes']} bytes; omitted {len(omitted)} original code images.")
