#!/usr/bin/env python3
"""Guard UE4's Mac PCI GPU descriptor access on an iOS device.

The original device fault was a null descriptor read at 0x10121a060, address
0x28. Native Metal selected the A19 and identified Apple as its vendor already.
Repack the existing metadata block to add a null guard. Existing non-null
vendor/device/VRAM handling is retained; all Metal feature queries are unchanged.
"""
import argparse,hashlib,json,struct
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__);p.add_argument('source',type=Path);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
if a.source.resolve()==a.out.resolve():p.error('Use a separate copy')
data=bytearray(a.source.read_bytes());cursor=32;platform=None;offset=None;address=0x10121a060
assert struct.unpack_from('<II',data)==(0xfeedfacf,0x100000c)
for _ in range(struct.unpack_from('<I',data,16)[0]):
    kind,size=struct.unpack_from('<II',data,cursor)
    if kind==0x32:platform=struct.unpack_from('<I',data,cursor+8)[0]
    if kind==0x19:
        vmaddr,vmsize,fileoff,length=struct.unpack_from('<4Q',data,cursor+24)
        if vmaddr<=address<vmaddr+length:offset=fileoff+address-vmaddr
    cursor+=size
assert platform==2 and offset is not None,'This policy is only for the audited iOS device build'
before_words=[0xb9402a68,0xb0020ea9,0x912d2129,0xb9400129,0x6b09011f,0x54000121,0xb9402e68,0xb0020ea9,0x912d3129,0xb9000128,0xb9403268,0xd36cad08,0xa902a39f,0xa901ff88]
# x10 is a caller-saved scratch register, not read after this metadata block.
# The ADRP remains on the original instruction page. Vendor/device field offsets
# are the original 0xb48/0xb4c; the guards both target 0x10121a098.
after_words=[0xb40001d3,0xb9402a68,0xb0020ea9,0xb94b492a,0x6b0a011f,0x54000121,0xb9402e68,0xb90b4d28,0xb9403268,0xd36cad08,0xa902a39f,0xa901ff88,0xd503201f,0xd503201f]
before=struct.pack('<14I',*before_words);after=struct.pack('<14I',*after_words)
assert data[offset:offset+len(before)]==before,'Unexpected source instructions'
data[offset:offset+len(after)]=after
a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_bytes(data)
report={'source':str(a.source.resolve()),'prepared':str(a.out.resolve()),'source_sha256':hashlib.sha256(a.source.read_bytes()).hexdigest(),'prepared_sha256':hashlib.sha256(data).hexdigest(),'platform':platform,'address':hex(address),'file_offset':offset,'length':len(after),'before':before.hex(),'after':after.hex(),'reason':'Guard missing Mac PCI GPU metadata while retaining native Metal device/feature queries','evidence':'casefold/original-fault.json: SIGSEGV at descriptor + 0x28, x19 = 0','gameplay_verified':False}
a.out.with_suffix('.gpu-metadata.json').write_text(json.dumps(report,indent=2)+'\n');print(a.out)
