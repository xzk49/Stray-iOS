#!/usr/bin/env python3
import argparse,importlib.util,json,shutil,subprocess
from pathlib import Path
def main():
 p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
 if a.source.resolve()==a.out.resolve():p.error('Use a separate copy')
 old='/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit';new='@loader_path/libStrayAppKit.dylib'
 if old not in subprocess.check_output(['xcrun','otool','-L',str(a.source)],text=True):p.error('Missing original AppKit dependency')
 spec=importlib.util.spec_from_file_location('prepare',Path(__file__).with_name('prepare-libraries.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 before=m.text_hash(a.source);a.out.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(a.source,a.out)
 subprocess.run(['xcrun','install_name_tool','-change',old,new,str(a.out)],check=True,capture_output=True)
 if before!=m.text_hash(a.out):raise ValueError('CPU instructions changed')
 subprocess.run(['xcrun','dyld_info','-validate_only',str(a.out)],check=True,capture_output=True)
 a.out.with_suffix('.appkit.json').write_text(json.dumps({'dependency_mapping':{old:new},'original_and_prepared_text_sha256':before,'ordinals_preserved':True},indent=2)+'\n')
 print('Routed AppKit to UIKit adapter; CPU instructions unchanged.')
if __name__=='__main__':main()
