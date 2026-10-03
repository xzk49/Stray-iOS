#!/usr/bin/env python3
"""Experimental metadata-only conversion of the staged main image to MH_DYLIB.

This does not implement the game startup path or any desktop APIs.
"""
import argparse
import hashlib
import importlib.util
import json
import shutil
import struct
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Already retargeted, thin ARM64 main image')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.source.resolve() == args.out.resolve():
        parser.error('Use a separate copy for this experiment')
    spec = importlib.util.spec_from_file_location('stray_prepare', Path(__file__).with_name('prepare-libraries.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    original_text = module.text_hash(args.source)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(args.source, args.out)
    remove = subprocess.run(['codesign', '--remove-signature', str(args.out)], capture_output=True, text=True)
    # Unsigned inputs need no removal; reject other codesign failures.
    if remove.returncode and 'not signed' not in remove.stderr:
        raise RuntimeError(remove.stderr)
    data = bytearray(args.out.read_bytes())
    if struct.unpack_from('<III', data, 0) != (0xFEEDFACF, 0x0100000C, 0):
        raise ValueError('Expected ordinary thin ARM64 Mach-O')
    if struct.unpack_from('<I', data, 12)[0] != 2:
        raise ValueError('Expected an MH_EXECUTE source')
    count, old_size = struct.unpack_from('<II', data, 16)
    limit = 32 + old_size
    cursor = 32
    commands = []
    removed = []
    first_section = len(data)
    segment_count = 0
    pagezero_removed = False
    chained_fixups = None
    for _ in range(count):
        kind, size = struct.unpack_from('<II', data, cursor)
        if size < 8 or size % 8 or cursor + size > limit:
            raise ValueError('Invalid load command')
        command = bytes(data[cursor:cursor+size])
        skip = kind in (0xE, 0x80000028)  # LC_LOAD_DYLINKER and LC_MAIN
        if kind == 0x19:
            segment = command[8:24].split(b'\0')[0]
            skip |= segment == b'__PAGEZERO'
            if segment == b'__PAGEZERO':
                if segment_count != 0:
                    raise ValueError('Only a first, unmapped PAGEZERO segment is supported')
                pagezero_removed = True
            segment_count += 1
            sections = struct.unpack_from('<I', command, 64)[0]
            for i in range(sections):
                at = 72 + i * 80
                length, offset = struct.unpack_from('<QI', command, at + 40)
                if offset and length:
                    first_section = min(first_section, offset)
        if kind == 0x80000034:
            chained_fixups = struct.unpack_from('<II', command, 8)
        if skip:
            removed.append(hex(kind))
        else:
            commands.append(command)
        cursor += size
    if cursor != limit:
        raise ValueError('Command count/size mismatch')
    name = ('@rpath/' + args.out.name).encode() + b'\0'
    size = (24 + len(name) + 7) & ~7
    commands.append(struct.pack('<IIIIII', 0xD, size, 24, 0, 0x10000, 0x10000) + name.ljust(size-24, b'\0'))
    updated = b''.join(commands)
    if 32 + len(updated) > first_section:
        raise ValueError('Insufficient space for updated load commands')
    data[32:32+max(old_size, len(updated))] = updated.ljust(max(old_size, len(updated)), b'\0')
    struct.pack_into('<III', data, 12, 6, len(commands), len(updated))
    flags = struct.unpack_from('<I', data, 24)[0]
    struct.pack_into('<I', data, 24, flags & ~0x200000)  # Clear MH_PIE.
    # Chained-fixup starts are indexed by load-command segment order. Removing
    # PAGEZERO requires dropping its empty starts entry without moving payloads.
    fixups_adjusted = False
    if pagezero_removed and chained_fixups:
        payload, payload_size = chained_fixups
        starts_offset = struct.unpack_from('<I', data, payload + 4)[0]
        starts = payload + starts_offset
        seg_count = struct.unpack_from('<I', data, starts)[0]
        if seg_count != segment_count or starts + 4 + 4 * seg_count > payload + payload_size:
            raise ValueError('Unexpected chained-fixup segment table')
        offsets = struct.unpack_from('<' + 'I' * seg_count, data, starts + 4)
        if offsets[0] != 0:
            raise ValueError('PAGEZERO has unexpected fixup records')
        struct.pack_into('<I', data, starts, seg_count - 1)
        struct.pack_into('<' + 'I' * seg_count, data, starts + 4, *offsets[1:], 0)
        fixups_adjusted = True
    args.out.write_bytes(data)
    if module.text_hash(args.out) != original_text:
        raise ValueError('CPU instruction hash changed')
    validation = subprocess.run(['xcrun', 'dyld_info', '-validate_only', str(args.out)], capture_output=True, text=True)
    if validation.returncode:
        raise RuntimeError(validation.stdout + validation.stderr)
    report = {'source': str(args.source.resolve()), 'prepared': str(args.out.resolve()),
              'source_sha256': hashlib.sha256(args.source.read_bytes()).hexdigest(),
              'prepared_sha256': hashlib.sha256(args.out.read_bytes()).hexdigest(),
              'original_and_prepared_text_sha256': original_text,
              'file_type_before': 'MH_EXECUTE', 'file_type_after': 'MH_DYLIB',
              'removed_load_command_types': removed, 'game_entry_called': False,
              'chained_fixup_segment_table_adjusted': fixups_adjusted,
              'desktop_api_compatibility_implemented': False}
    args.out.with_suffix('.conversion.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Converted experimental main-loader copy; CPU instruction hash unchanged.')


if __name__ == '__main__':
    main()
