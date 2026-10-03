#!/usr/bin/env python3
"""Select UE4's existing private-buffer/staging path on the Metal simulator.

This is a single audited ARM64 policy change, not a feature capability override.
The source remains untouched. Device builds must not use this variant.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('source', type=Path)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
if a.source.resolve() == a.out.resolve(): p.error('Use a separate output')
data = bytearray(a.source.read_bytes())
assert struct.unpack_from('<II', data) == (0xfeedfacf, 0x100000c)
count = struct.unpack_from('<I', data, 16)[0]
cursor = 32
platform = None
file_offset = None
address = 0x10122f6a0
for _ in range(count):
    kind, size = struct.unpack_from('<II', data, cursor)
    if kind == 0x32: platform = struct.unpack_from('<I', data, cursor + 8)[0]
    if kind == 0x19:
        vmaddr, vmsize, offset, length = struct.unpack_from('<4Q', data, cursor + 24)
        if vmaddr <= address < vmaddr + length: file_offset = offset + address - vmaddr
    cursor += size
assert platform == 7, 'Simulator-only policy'
assert file_offset is not None
before = bytes.fromhex('4a118b1a')  # csel w10,w10,w11,ne
after = bytes.fromhex('4a008052')   # mov w10,#2 (MTLStorageModePrivate)
assert data[file_offset:file_offset + 4] == before, 'Unexpected source instruction'
data[file_offset:file_offset + 4] = after
a.out.parent.mkdir(parents=True, exist_ok=True)
a.out.write_bytes(data)
report = {'source': str(a.source.resolve()), 'prepared': str(a.out.resolve()),
          'platform': 'iossim', 'address': hex(address), 'file_offset': file_offset,
          'before': before.hex(), 'after': after.hex(),
          'source_sha256': hashlib.sha256(a.source.read_bytes()).hexdigest(),
          'prepared_sha256': hashlib.sha256(data).hexdigest(),
          'reason': 'Metal simulator requires private buffers for linear textures. UE4 already stages private buffer uploads.',
          'gameplay_verified': False}
a.out.with_suffix('.policy.json').write_text(json.dumps(report, indent=2) + '\n')
print(a.out)
