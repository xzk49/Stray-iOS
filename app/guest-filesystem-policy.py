#!/usr/bin/env python3
"""Adapt the Mac-only volume rejection after installing guest case lookup.

NSURL still reports the actual native filesystem properties. Only the branch
that displays the unsupported-volume alert is changed; the adjacent screen and
application initialization remains intact. Requires libStraySystem path aliases.
"""
import argparse, hashlib, json, struct
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('source',type=Path)
p.add_argument('--out',type=Path,required=True)
a=p.parse_args()
if a.source.resolve()==a.out.resolve():p.error('Use a separate copy')
data=bytearray(a.source.read_bytes());cursor=32;platform=None;offset=None
address=0x10168daa8
assert struct.unpack_from('<II',data)==(0xfeedfacf,0x100000c)
for _ in range(struct.unpack_from('<I',data,16)[0]):
    kind,size=struct.unpack_from('<II',data,cursor)
    if kind==0x32:platform=struct.unpack_from('<I',data,cursor+8)[0]
    if kind==0x19:
        vmaddr,vmsize,fileoff,length=struct.unpack_from('<4Q',data,cursor+24)
        if vmaddr<=address<vmaddr+length:offset=fileoff+address-vmaddr
    cursor+=size
assert platform in (2,7) and offset is not None
before=bytes.fromhex('00010034') # cbz w0, 0x10168dac8
after=bytes.fromhex('08000014')  # b 0x10168dac8, with guest path adaptation
assert data[offset:offset+4]==before,'Unexpected source instruction'
data[offset:offset+4]=after
a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_bytes(data)
report={'source':str(a.source.resolve()),'prepared':str(a.out.resolve()),
    'source_sha256':hashlib.sha256(a.source.read_bytes()).hexdigest(),
    'prepared_sha256':hashlib.sha256(data).hexdigest(),'platform':platform,
    'address':hex(address),'file_offset':offset,'before':before.hex(),'after':after.hex(),
    'reason':'Use guest case-insensitive path resolution instead of rejecting the native iOS volume',
    'requires':'libStraySystem guest filesystem aliases','gameplay_verified':False}
a.out.with_suffix('.filesystem.json').write_text(json.dumps(report,indent=2)+'\n')
print(a.out)
