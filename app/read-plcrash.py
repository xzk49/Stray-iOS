#!/usr/bin/env python3
"""Read original fault state from a local PLCrashReporter v1 protobuf report.

Field definitions: microsoft/plcrashreporter Source/PLCrashReport.proto.
Does not execute game code or require installing a protobuf runtime.
"""
import argparse,json
from pathlib import Path

def varint(data,index):
    value=0
    for shift in range(0,70,7):
        byte=data[index];index+=1;value|=(byte&127)<<shift
        if byte<128:return value,index
    raise ValueError('Invalid varint')

def fields(data):
    result={};index=0
    while index<len(data):
        tag,index=varint(data,index);number,wire=tag>>3,tag&7
        if wire==0:value,index=varint(data,index)
        elif wire==2:
            length,index=varint(data,index);value=data[index:index+length];index+=length
            if len(value)!=length:raise ValueError('Truncated field')
        elif wire in (1,5):
            length=8 if wire==1 else 4;value=int.from_bytes(data[index:index+length],'little');index+=length
        else:raise ValueError(f'Unsupported wire type {wire}')
        result.setdefault(number,[]).append(value)
    return result

def one(data,field,default=None):return data.get(field,[default])[0]
def string(data,field):return one(data,field,b'').decode('utf-8','replace')
def frame(raw):
    data=fields(raw);symbol=fields(one(data,6,b''))
    return {'pc':hex(one(data,3,0)),'symbol':string(symbol,1)}

p=argparse.ArgumentParser(description=__doc__);p.add_argument('source',type=Path);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
raw=a.source.read_bytes();assert raw[:8]==b'plcrash\x01';report=fields(raw[8:]);signal=fields(one(report,6));process=fields(one(report,7,b''))
result={'source':str(a.source.resolve()),'pid':one(process,2),'signal':string(signal,1),'signal_code':string(signal,2),'fault_address':hex(one(signal,3))}
exception=fields(one(report,5,b''))
if exception:result['exception']={'name':string(exception,1),'reason':string(exception,2),'frames':[frame(v) for v in exception.get(3,[])]}
for value in report.get(3,[]):
    thread=fields(value)
    if not one(thread,3):continue
    regs=[fields(v) for v in thread.get(4,[])]
    result['crashed_thread']={'number':one(thread,1),'frames':[frame(v) for v in thread.get(2,[])],'registers':{string(v,1):hex(one(v,2)) for v in regs}}
result['guest_images']=[]
for value in report.get(4,[]):
    image=fields(value);name=string(image,3)
    if name.endswith('StrayGuest.dylib'):result['guest_images'].append({'name':name,'base_address':hex(one(image,1)),'size':one(image,2)})
a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
