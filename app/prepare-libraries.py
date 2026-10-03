#!/usr/bin/env python3
"""Prepare only the audited guest dylibs for an iOS loader diagnostic."""
import argparse
import hashlib
import json
import struct
import subprocess
from pathlib import Path


def run(*args):
    subprocess.run(list(map(str, args)), check=True, capture_output=True)


def text_hash(path):
    data = path.read_bytes()
    if struct.unpack_from('<I', data)[0] != 0xFEEDFACF:
        raise ValueError('Expected thin little-endian 64-bit Mach-O')
    count = struct.unpack_from('<I', data, 16)[0]
    cursor = 32
    for _ in range(count):
        kind, size = struct.unpack_from('<II', data, cursor)
        if kind == 0x19:
            sections = struct.unpack_from('<I', data, cursor + 64)[0]
            for i in range(sections):
                at = cursor + 72 + 80 * i
                if data[at:at+16].split(b'\0')[0] == b'__text':
                    length, offset = struct.unpack_from('<QI', data, at + 40)
                    return hashlib.sha256(data[offset:offset+length]).hexdigest()
        cursor += size
    raise ValueError('No __text section')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('audit', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--include-main', action='store_true', help='Also stage a metadata-only main-image loader experiment; never call its entry point')
    parser.add_argument('--platform', choices=('ios', 'iossim'), default='ios', help='Use separate output directories for device and simulator experiments')
    args = parser.parse_args()
    audit = json.loads(args.audit.read_text())
    if audit['errors']:
        parser.error('Audit must have completed without errors')
    root = Path(audit['app']).resolve()
    out = args.out.resolve()
    if out == root or root in out.parents:
        parser.error('Prepared copies must be outside the source bundle')
    libraries = [b for b in audit['binaries'] if b.get('file_type') == 'DYLIB']
    names = {Path(b['path']).name for b in libraries}
    out.mkdir(parents=True, exist_ok=True)
    records = []
    for binary in libraries:
        if binary['architectures'] != ['arm64'] or any(binary['encryption_ids']):
            raise ValueError('Only audited, unencrypted, thin ARM64 libraries are accepted')
        # This diagnostic intentionally accepts only guest-to-guest dependencies,
        # libc++ and libSystem. It implements no desktop API compatibility.
        for dependency in binary['dependencies']:
            dep = dependency['path']
            if dep not in {'/usr/lib/libSystem.B.dylib', '/usr/lib/libc++.1.dylib'} and not (
                dep.startswith('@rpath/') and Path(dep).name in names):
                raise ValueError('Library requires a separate API review: ' + dep)
        source = root / binary['path']
        if hashlib.sha256(source.read_bytes()).hexdigest() != binary['sha256']:
            raise ValueError('Source changed after audit: ' + str(source))
        target = out / source.name
        before = text_hash(source)
        run('xcrun', 'vtool', '-set-build-version', args.platform, '17.0', '26.5', '-replace', '-output', target, source)
        for dependency in binary['dependencies']:
            dep = dependency['path']
            if dep.startswith('@rpath/'):
                run('xcrun', 'install_name_tool', '-change', dep, '@loader_path/' + Path(dep).name, target)
        run('xcrun', 'install_name_tool', '-id', '@rpath/' + source.name, target)
        if text_hash(target) != before:
            raise ValueError('Unexpected change to CPU instructions: ' + str(target))
        run('xcrun', 'dyld_info', '-validate_only', target)
        records.append({'source': str(source), 'prepared': str(target),
                        'source_sha256': binary['sha256'],
                        'prepared_sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                        'original_and_prepared_text_sha256': before})
    main_copy = None
    if args.include_main:
        binary = next(b for b in audit['binaries'] if b['path'] == audit['main_executable'])
        if binary['architectures'] != ['arm64'] or any(binary['encryption_ids']):
            raise ValueError('Only audited unencrypted ARM64 main images are accepted')
        source = root / binary['path']
        if hashlib.sha256(source.read_bytes()).hexdigest() != binary['sha256']:
            raise ValueError('Main image changed after audit')
        target = out / 'StrayGuest.dylib'
        before = text_hash(source)
        run('xcrun', 'vtool', '-set-build-version', args.platform, '17.0', '26.5', '-replace', '-output', target, source)
        mappings = []
        for dependency in binary['dependencies']:
            old = dependency['path']
            new = old
            if old.startswith('@rpath/') and Path(old).name in names:
                new = '@loader_path/' + Path(old).name
            elif dependency['framework_in_iphone_sdk'] and not dependency['desktop_framework']:
                parts = old.split('/Versions/')
                if len(parts) == 2:
                    new = parts[0] + '/' + parts[1].split('/', 1)[1]
            if new != old:
                run('xcrun', 'install_name_tool', '-change', old, new, target)
                mappings.append([old, new])
        if text_hash(target) != before:
            raise ValueError('Unexpected change to main CPU instructions')
        run('xcrun', 'dyld_info', '-validate_only', target)
        main_copy = {'source': str(source), 'prepared': str(target),
                     'source_sha256': binary['sha256'],
                     'prepared_sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                     'original_and_prepared_text_sha256': before,
                     'file_type_retained': binary['file_type'], 'dependency_mappings': mappings,
                     'desktop_api_compatibility_implemented': False}
    (out / 'manifest.json').write_text(json.dumps({'game_entry_called': False,
        'platform': args.platform,
        'purpose': 'Guest library loader diagnostic only; not a playable game port',
        'libraries': records, 'main_loader_experiment': main_copy}, indent=2) + '\n')
    print(f'Prepared {len(records)} library copies; all __text hashes unchanged. {out}')


if __name__ == '__main__':
    main()
