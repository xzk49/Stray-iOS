#!/usr/bin/env python3
import argparse,json,subprocess
from pathlib import Path
def main():
 p=argparse.ArgumentParser();p.add_argument('--platform',choices=['ios','iossim'],required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
 sdk='iphonesimulator' if a.platform=='iossim' else 'iphoneos';target='arm64-apple-ios17.0-simulator' if a.platform=='iossim' else 'arm64-apple-ios17.0'
 root=Path(subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip());a.out.mkdir(parents=True,exist_ok=True);source=Path(__file__).parent
 builds=[('libStrayCoreGraphics','DisplayBridge.m',['-Wl,-reexport_framework,CoreGraphics','-framework','UIKit','-framework','QuartzCore']),('libStrayCoreVideo','DisplayLinkBridge.m',['-Wl,-reexport_framework,CoreVideo','-framework','UIKit','-framework','QuartzCore']),('libStrayIOKit','RegistryBridge.m',['-Wl,-reexport_framework,IOKit']),('libStrayObjC','ObjCRuntimeBridge.s',['-Wl,-reexport_library,'+str(root/'usr/lib/libobjc.A.tbd')]),('libStraySystem','SystemBridge.m',['-Wl,-reexport_library,'+str(root/'usr/lib/libSystem.tbd')])]
 for name,file,flags in builds:
  out=a.out/(name+'.dylib');cmd=['xcrun','--sdk',sdk,'clang','-target',target,'-isysroot',str(root),'-dynamiclib','-g','-O2','-Werror','-Wno-deprecated-declarations']
  if file.endswith('.m'):cmd+=['-fobjc-arc','-framework','Foundation']
  if name=='libStraySystem':
   cmd+=[str(source/'GuestPaths.m'),str(source/'MoviePathBridge.m'),str(source/'MetalDeviceBridge.m'),str(source/'MetalBufferStorage.m'),str(source/'MetalLifecycle.m'),str(source/'MetalPipelineTiming.m'),str(source/'BinkShaderBridge.m'),str(source/'GameFrameCapture.m'),str(source/'RenderDiagnostics.m'),str(source/'TraceArchive.m'),'-framework','Metal','-framework','QuartzCore','-framework','UIKit','-framework','CoreGraphics']
   for guest,native in [('Dlopen','dlopen'),('Open','open'),('Fopen','fopen'),('Stat','stat'),('Access','access'),('Opendir','opendir'),('Chdir','chdir'),('Mkdir','mkdir'),('Unlink','unlink'),('Rename','rename')]:cmd+=['-Wl,-alias,_StrayGuest'+guest+',_'+native]
  subprocess.run(cmd+[str(source/file),'-o',str(out),'-Wl,-install_name,@rpath/'+out.name]+flags,check=True)
  subprocess.run(['xcrun','dyld_info','-validate_only',str(out)],check=True)
 audio=a.out/'libStrayAudio.dylib'
 cmd=['xcrun','--sdk',sdk,'clang','-target',target,'-isysroot',str(root),'-dynamiclib','-g','-O2','-Werror','-Wno-deprecated-declarations','-fobjc-arc',str(source/'AudioBridge.m'),'-framework','Foundation','-framework','UIKit','-framework','AVFAudio','-Wl,-reexport_framework,AudioToolbox','-Wl,-reexport_framework,CoreAudio','-o',str(audio),'-Wl,-install_name,@rpath/'+audio.name]
 for bridge,native in [('StrayAudioObjectGetPropertyData','AudioObjectGetPropertyData'),('StrayAudioObjectSetPropertyData','AudioObjectSetPropertyData'),('StrayAUGraphAddNode','AUGraphAddNode'),('StrayAUGraphSetNodeInputCallback','AUGraphSetNodeInputCallback'),('StrayAUGraphStart','AUGraphStart'),('StrayAUGraphStop','AUGraphStop'),('StrayDisposeAUGraph','DisposeAUGraph')]:cmd+=['-Wl,-alias,_'+bridge+',_'+native]
 subprocess.run(cmd,check=True);subprocess.run(['xcrun','dyld_info','-validate_only',str(audio)],check=True)
 facade=a.out/'libStrayCoreAudio.dylib'
 subprocess.run(['xcrun','--sdk',sdk,'clang','-target',target,'-isysroot',str(root),'-dynamiclib',str(source/'CoreAudioFacade.m'),'-o',str(facade),'-Wl,-install_name,@rpath/'+facade.name,'-Wl,-reexport_library,'+str(audio)],check=True)
 subprocess.run(['xcrun','dyld_info','-validate_only',str(facade)],check=True)
 (a.out/'runtime-build.json').write_text(json.dumps({'platform':a.platform,'target':target,'sdk':str(root),'libraries':[name+'.dylib' for name,_,_ in builds]+[audio.name,facade.name]},indent=2)+'\n')
 print(a.out)
if __name__=='__main__':main()
