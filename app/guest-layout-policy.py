#!/usr/bin/env python3
"""Use the retained Contents/UE4 layout inside an iOS resource directory.

UE4's Mac BaseDir otherwise requires the bundle directory name to end in .app.
The real resource directory is GuestGame, because an unsigned nested macOS app
cannot be embedded as an iOS resource. Only this directory-name branch changes.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('source',type=Path)
p.add_argument('--out',type=Path,required=True)
a=p.parse_args()
if a.source.resolve()==a.out.resolve():p.error('Use a separate copy')
data=bytearray(a.source.read_bytes())
assert struct.unpack_from('<II',data)==(0xfeedfacf,0x100000c)
cursor=32;platform=None;offset=None;address=0x101371bc8
for _ in range(struct.unpack_from('<I',data,16)[0]):
    kind,size=struct.unpack_from('<II',data,cursor)
    if kind==0x32:platform=struct.unpack_from('<I',data,cursor+8)[0]
    if kind==0x19:
        vmaddr,vmsize,fileoff,length=struct.unpack_from('<4Q',data,cursor+24)
        if vmaddr<=address<vmaddr+length:offset=fileoff+address-vmaddr
    cursor+=size
assert platform in (2,7) and offset is not None
before=bytes.fromhex('e00b0034') # cbz w0, alternate non-app layout
after=bytes.fromhex('1f2003d5')  # nop: retain macOS Contents/UE4 layout
assert data[offset:offset+4]==before,'Unexpected source instruction'
data[offset:offset+4]=after
a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_bytes(data)
report={'source':str(a.source.resolve()),'prepared':str(a.out.resolve()),
        'source_sha256':hashlib.sha256(a.source.read_bytes()).hexdigest(),
        'prepared_sha256':hashlib.sha256(data).hexdigest(),
        'address':hex(address),'file_offset':offset,'before':before.hex(),'after':after.hex(),
        'platform':platform,'reason':'Use Contents/UE4 resource layout without a nested .app bundle',
        'gameplay_verified':False}
a.out.with_suffix('.layout.json').write_text(json.dumps(report,indent=2)+'\n')
print(a.out)
