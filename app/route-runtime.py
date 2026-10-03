#!/usr/bin/env python3
import argparse,importlib.util,json,shutil,subprocess
from pathlib import Path
MAPPINGS={
 '/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox':'@loader_path/libStrayAudio.dylib',
 '/System/Library/Frameworks/CoreAudio.framework/CoreAudio':'@loader_path/libStrayCoreAudio.dylib',
 '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics':'@loader_path/libStrayCoreGraphics.dylib',
 '/System/Library/Frameworks/CoreVideo.framework/CoreVideo':'@loader_path/libStrayCoreVideo.dylib',
 '/System/Library/Frameworks/IOKit.framework/IOKit':'@loader_path/libStrayIOKit.dylib',
 '/usr/lib/libobjc.A.dylib':'@loader_path/libStrayObjC.dylib',
 '/usr/lib/libSystem.B.dylib':'@loader_path/libStraySystem.dylib'}
def main():
 p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
 if a.source.resolve()==a.out.resolve():p.error('Use a separate copy')
 deps=subprocess.check_output(['xcrun','otool','-L',str(a.source)],text=True)
 if any(old not in deps for old in MAPPINGS):p.error('Expected all audited system dependencies')
 spec=importlib.util.spec_from_file_location('prepare',Path(__file__).with_name('prepare-libraries.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 before=m.text_hash(a.source);a.out.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(a.source,a.out)
 cmd=['xcrun','install_name_tool']
 for old,new in MAPPINGS.items():cmd+=['-change',old,new]
 subprocess.run(cmd+[str(a.out)],check=True,capture_output=True)
 if before!=m.text_hash(a.out):raise ValueError('CPU instructions changed')
 subprocess.run(['xcrun','dyld_info','-validate_only',str(a.out)],check=True,capture_output=True)
 a.out.with_suffix('.runtime.json').write_text(json.dumps({'dependency_mapping':MAPPINGS,'original_and_prepared_text_sha256':before,'ordinals_preserved':True},indent=2)+'\n')
 print('Routed display, vsync and ABI adapters; CPU instructions unchanged.')
if __name__=='__main__':main()
