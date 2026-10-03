#!/usr/bin/env python3
"""Make import-free desktop umbrella dependencies optional for loader diagnostics.

This does not implement their APIs or establish that gameplay never uses them.
"""
import argparse
import hashlib
import importlib.util
import json
import re
import struct
import subprocess
from pathlib import Path

DEPENDENCIES = {
    'AudioUnit': '/System/Library/Frameworks/AudioUnit.framework/AudioUnit',
    'OpenGL': '/System/Library/Frameworks/OpenGL.framework/Versions/A/OpenGL'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.source.resolve() == args.out.resolve(): parser.error('Use a separate copy')
    imports = subprocess.run(['xcrun', 'dyld_info', '-imports', str(args.source)],
        capture_output=True, text=True, check=True).stdout
    for framework in DEPENDENCIES:
        if re.search(r'\(from ' + framework + r'\)', imports):
            parser.error(f'{framework} has bound imports; requires real compatibility')
    data = bytearray(args.source.read_bytes())
    magic, cpu, _, _, ncmds, sizeofcmds = struct.unpack_from('<6I', data)
    if magic != 0xfeedfacf or cpu != 0x100000c: parser.error('Expected a thin ARM64 image')
    offset = 32; changed = []
    for _ in range(ncmds):
        kind, size = struct.unpack_from('<2I', data, offset)
        if size < 8 or offset + size > 32 + sizeofcmds: raise ValueError('Invalid command bounds')
        if kind == 0xc:  # LC_LOAD_DYLIB; keep the same ordinal and command size.
            name_offset = struct.unpack_from('<I', data, offset + 8)[0]
            if name_offset < 24 or name_offset >= size: raise ValueError('Invalid dylib name')
            name = data[offset + name_offset:offset + size].split(b'\0')[0].decode()
            if name in DEPENDENCIES.values():
                struct.pack_into('<I', data, offset, 0x80000018)  # LC_LOAD_WEAK_DYLIB
                changed.append(name)
        offset += size
    if set(changed) != set(DEPENDENCIES.values()): parser.error('Expected both desktop dependencies')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(data)
    spec = importlib.util.spec_from_file_location('stray_prepare', Path(__file__).with_name('prepare-libraries.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    before = module.text_hash(args.source)
    if before != module.text_hash(args.out): raise ValueError('CPU instruction mismatch')
    subprocess.run(['xcrun', 'dyld_info', '-validate_only', str(args.out)], check=True, capture_output=True)
    args.out.with_suffix('.optional.json').write_text(json.dumps({
        'source': str(args.source.resolve()), 'prepared': str(args.out.resolve()),
        'source_sha256': hashlib.sha256(args.source.read_bytes()).hexdigest(),
        'prepared_sha256': hashlib.sha256(data).hexdigest(),
        'original_and_prepared_text_sha256': before, 'optional_dependencies': changed,
        'static_import_count': 0, 'ordinals_preserved': True,
        'apis_implemented': False, 'runtime_lookups_and_gameplay_verified': False}, indent=2) + '\n')
    print('Made import-free AudioUnit/OpenGL dependencies optional for diagnostics.')


if __name__ == '__main__':
    main()
