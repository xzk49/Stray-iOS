#!/usr/bin/env python3
"""Rebuild only the three audited Bink Metal libraries for iOS from their AIR.

Uses Apple's Metal compiler, preserving the original shader function bodies,
types and bindings. The original game and embedded macOS libraries are unchanged.
"""
import argparse, hashlib, json, re, struct, subprocess, sys
from pathlib import Path

LIBRARIES = [
    ('bink-vertex', 0x3c995e0, 3569, '15c22098183171a5a935f2b72b234172a8b4cf2f57e544d7cc25380262bf4468', 1),
    ('bink-ictcp', 0x3c9a3d1, 38944, '2110c579afc3b84e47de1173cbd47fc5e14712d05a4b38fb5a04fdac4f1d1f7e', 8),
    ('bink-sdr', 0x3ca3bf1, 16384, '182c3b35035b32da9689be0a6f84763718ab4c4e16e6789f4721878820743123', 4),
]

def run(args):
    result=subprocess.run([str(v) for v in args], text=True, capture_output=True)
    if result.returncode:print(result.stderr,file=sys.stderr)
    result.check_returncode();return result.stdout

def program(ir):
    # Ignore renumbered metadata references; retain arithmetic, memory operations,
    # argument and return types, function attributes, and all resource bindings.
    start=ir.index('; Function Attrs:')
    end=ir.index('!llvm.module.flags')
    text=ir[start:end]
    return re.sub(r'!([0-9]+)', '!ID', text)

def bindings(ir):
    # Metadata numbering can change after an obsolete compile option is removed.
    lines=[line.split(' = ',1)[1] for line in ir.splitlines()
           if re.match(r'!\d+ = ',line) and ('air.arg_' in line or 'air.location_index' in line or 'air.struct_type_info' in line)]
    return [re.sub(r'!([0-9]+)', '!ID', line) for line in lines]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('source',type=Path);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--metal',type=Path,required=True,help='Actual Metal toolchain compiler, not the Xcode launcher')
    a=p.parse_args();a.out.mkdir(parents=True,exist_ok=True)
    compiler=a.metal.resolve();optimizer=compiler.parent/'air-opt'
    data=a.source.read_bytes();reports=[]
    target=['-target','air64-apple-ios12.0','-std=ios-metal2.1']
    for name,offset,length,source_hash,count in LIBRARIES:
        embedded=data[offset:offset+length]
        assert hashlib.sha256(embedded).hexdigest()==source_hash, f'Unexpected {name} source'
        assert struct.unpack_from('<Q',embedded,16)[0]==length
        files=[];functions=[];checks=[]
        for i,match in enumerate(re.finditer(b'BC\xc0\xde',embedded)):
            pos=match.start()-20;header=struct.unpack_from('<5I',embedded,pos)
            assert header[0]==0x0b17c0de and header[2]==20 and pos+20+header[3]<=length
            source=a.out/f'{name}-{i}-mac.air';rebuilt=a.out/f'{name}-{i}-ios.air'
            original_ir=a.out/f'{name}-{i}-mac.ll';rebuilt_ir=a.out/f'{name}-{i}-ios.ll'
            source.write_bytes(embedded[pos:pos+20+header[3]])
            # The old library has one obsolete compile option rejected by the
            # modern AIR verifier. Read it for comparison without changing it.
            run([optimizer,'-S','-disable-verify',source,'-o',original_ir])
            run([compiler,*target,'-O0','-c','-x','ir',source,'-o',rebuilt])
            run([optimizer,'-S',rebuilt,'-o',rebuilt_ir])
            old=original_ir.read_text();new=rebuilt_ir.read_text()
            assert 'air64-apple-macosx10.14.0' in old
            assert 'air64_v21-apple-ios12.0.0' in new
            assert program(old)==program(new), f'Shader program changed: {name}-{i}'
            assert bindings(old)==bindings(new), f'Shader resource bindings changed: {name}-{i}'
            assert re.findall(r'^%.* = type .*$',old,re.M)==re.findall(r'^%.* = type .*$',new,re.M)
            function=re.search(r'^define .*?@([^ (]+)\(',new,re.M).group(1)
            functions.append(function);files.append(rebuilt)
            checks.append({'function':function,'program_and_bindings_unchanged':True,
                           'program_sha256':hashlib.sha256(program(new).encode()).hexdigest()})
        assert len(files)==count
        library=a.out/(name+'.metallib')
        run([compiler,*target,*files,'-o',library])
        output=library.read_bytes()
        assert output[:6]==b'MTLB\x01\x00', 'Expected native iOS Metal library'
        assert sorted(re.findall(rb'NAME.{2}([^\x00]+)\x00',output))==sorted(f.encode() for f in functions)
        reports.append({'filename':library.name,'source_sha256':source_hash,'source_length':length,
                        'ios_sha256':hashlib.sha256(output).hexdigest(),'ios_length':len(output),
                        'functions':functions,'checks':checks})
    report={'format':1,'target':'air64_v21-apple-ios12.0.0','metal_language':'2.1',
            'compiler':str(compiler),'compiler_version':run([compiler,'--version']).strip(),
            'libraries':reports,'device_library_loading_verified':False,'video_playback_verified':False}
    (a.out/'manifest.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'libraries':len(reports),'functions':sum(len(r['functions']) for r in reports),'out':str(a.out)},indent=2))

if __name__=='__main__':main()
