#!/usr/bin/env python3
import argparse,json,subprocess
from pathlib import Path

def main():
 p=argparse.ArgumentParser();p.add_argument('--platform',choices=['ios','iossim'],required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
 sdk='iphonesimulator' if a.platform=='iossim' else 'iphoneos'
 target='arm64-apple-ios17.0-simulator' if a.platform=='iossim' else 'arm64-apple-ios17.0'
 root=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
 a.out.mkdir(parents=True,exist_ok=True);source=Path(__file__).parent
 output=a.out/'libStrayAppKit.dylib'
 cmd=['xcrun','--sdk',sdk,'clang','-target',target,'-isysroot',root,'-dynamiclib','-fobjc-arc','-g','-O2','-Werror','-Wno-deprecated-declarations',str(source/'AppKitBridge.m'),str(source/'AppKitServices.m'),str(source/'TouchGamepad.m'),'-o',str(output),'-Wl,-install_name,@rpath/libStrayAppKit.dylib','-Wl,-reexport_framework,UIKit','-Wl,-reexport_framework,Foundation','-framework','QuartzCore','-framework','Metal','-framework','ImageIO','-framework','CoreGraphics','-framework','GameController']
 for name in ["Font","Color"]:
  cmd.append(f"-Wl,-alias,_OBJC_CLASS_$_Stray{name},_OBJC_CLASS_$_NS{name}")
  cmd.append(f"-Wl,-alias,_OBJC_METACLASS_$_Stray{name},_OBJC_METACLASS_$_NS{name}")
 subprocess.run(cmd,check=True)
 subprocess.run(['xcrun','dyld_info','-validate_only',str(output)],check=True)
 (a.out/'appkit-build.json').write_text(json.dumps({'platform':a.platform,'target':target,'sdk':root,'library':str(output.resolve())},indent=2)+'\n')
 print(output)
if __name__=='__main__':main()
