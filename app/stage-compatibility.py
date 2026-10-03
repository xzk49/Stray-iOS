#!/usr/bin/env python3
"""Prepare a reproducible diagnostic app containing the current Cocoa/keyboard subset."""
import argparse
import json
import re
import plistlib
import shutil
import struct
import subprocess
import sys
from pathlib import Path


def image_platform(path):
    with path.open('rb') as file:
        header = file.read(32)
        magic, cpu, _, _, ncmds, sizeofcmds = struct.unpack_from('<6I', header)
        if magic != 0xfeedfacf or cpu != 0x100000c:
            raise ValueError(f'Expected a thin ARM64 image: {path}')
        commands = file.read(sizeofcmds)
    offset = 0
    for _ in range(ncmds):
        kind, size = struct.unpack_from('<2I', commands, offset)
        if size < 8 or offset + size > len(commands): raise ValueError('Invalid load command')
        if kind == 0x32: return struct.unpack_from('<I', commands, offset + 8)[0]
        offset += size
    raise ValueError(f'Missing explicit build platform: {path}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['ios', 'iossim'], required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--main', type=Path, required=True)
    parser.add_argument('--guest-libraries', type=Path, required=True)
    parser.add_argument('--cocoa', type=Path, required=True)
    parser.add_argument('--keyboard', type=Path, required=True)
    parser.add_argument('--appkit', type=Path)
    parser.add_argument('--runtime', type=Path)
    parser.add_argument('--game-root', type=Path)
    parser.add_argument('--launch-game', action='store_true')
    parser.add_argument('--extra-argument', action='append', default=[])
    parser.add_argument('--policy-report', type=Path, action='append', default=[])
    parser.add_argument('--audit', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).parent
    app = args.out / 'StrayProbe.app'
    if args.app.resolve() == app.resolve(): parser.error('Use a separate staged application')
    for directory, filename in [(args.cocoa, 'cocoa-build.json'), (args.keyboard, 'keyboard-build.json')]:
        if json.loads((directory / filename).read_text())['platform'] != args.platform:
            parser.error(f'Wrong bridge platform: {directory}')
    manifest = json.loads((args.guest_libraries / 'manifest.json').read_text())
    if manifest.get('platform') not in [None, args.platform]: parser.error('Wrong guest library platform')
    expected_platform = 7 if args.platform == 'iossim' else 2
    binaries = [Path(item['prepared']) for item in manifest['libraries']] + [args.main]
    binaries.extend(directory / name for directory, names in [
        (args.cocoa, ['libStrayCocoa.dylib', 'libStrayFoundation.dylib']),
        (args.keyboard, ['libStrayKeyboard.dylib', 'libStrayCoreServices.dylib'])] for name in names)
    if args.appkit: binaries.append(args.appkit / 'libStrayAppKit.dylib')
    if args.runtime:binaries.extend(args.runtime.glob('*.dylib'))
    if any(image_platform(binary) != expected_platform for binary in binaries):
        parser.error('Actual binary platform does not match staging platform')
    args.out.mkdir(parents=True, exist_ok=True)
    stages = [args.out / 'cocoa' / 'StrayGuest.dylib', args.out / 'keyboard' / 'StrayGuest.dylib',
              args.out / 'optional' / 'StrayGuest.dylib']
    previous = args.main
    for script, destination in zip(['route-cocoa.py', 'route-keyboard.py', 'optional-unused-frameworks.py'], stages):
        subprocess.run([sys.executable, str(source / script), str(previous), '--out', str(destination)], check=True)
        previous = destination
    if args.appkit:
        destination=args.out / 'appkit' / 'StrayGuest.dylib'
        subprocess.run([sys.executable,str(source/'route-appkit.py'),str(previous),'--out',str(destination)],check=True)
        previous=destination
    if args.runtime:
        destination=args.out/'runtime'/'StrayGuest.dylib'
        subprocess.run([sys.executable,str(source/'route-runtime.py'),str(previous),'--out',str(destination)],check=True)
        previous=destination
    shutil.copytree(args.app, app, dirs_exist_ok=True)
    info=plistlib.loads((app/'Info.plist').read_bytes())
    if args.game_root:info['StrayGameRoot']=str(args.game_root.resolve())
    info['StrayLaunchGame']=args.launch_game
    info['StrayExtraArguments']=args.extra_argument
    (app/'Info.plist').write_bytes(plistlib.dumps(info))
    frameworks = app / 'Frameworks'
    if frameworks.exists(): shutil.rmtree(frameworks)
    frameworks.mkdir()
    libraries = []
    for item in manifest['libraries']:
        original = Path(item['prepared'])
        target = frameworks / original.name
        shutil.copy2(original, target)
        libraries.append({**item, 'prepared': str(target.resolve())})
    target = frameworks / 'StrayGuest.dylib'
    shutil.copy2(previous, target)
    bridges = []
    for directory, names in [(args.cocoa, ['libStrayCocoa.dylib', 'libStrayFoundation.dylib']),
                             (args.keyboard, ['libStrayKeyboard.dylib', 'libStrayCoreServices.dylib'])]:
        for name in names:
            prepared = frameworks / name
            shutil.copy2(directory / name, prepared)
            bridges.append({'prepared': str(prepared.resolve())})
    if args.appkit:
        prepared=frameworks / 'libStrayAppKit.dylib';shutil.copy2(args.appkit/prepared.name,prepared)
        bridges.append({'prepared':str(prepared.resolve())})
    if args.runtime:
        for binary in args.runtime.glob('*.dylib'):
            prepared=frameworks/binary.name;shutil.copy2(binary,prepared);bridges.append({'prepared':str(prepared.resolve())})
    imports = subprocess.run(['xcrun', 'dyld_info', '-imports', str(args.main)],
        capture_output=True, text=True, check=True).stdout
    foundation = re.findall(r'(\S+)\s+\(from Foundation\)', imports)
    (app / 'foundation-imports.json').write_text(json.dumps([item[1:] for item in foundation]) + '\n')
    appkit=re.findall(r'(\S+)\s+\(from AppKit\)',imports)
    (app / 'appkit-imports.json').write_text(json.dumps([item[1:] for item in appkit])+'\n')
    audit=json.loads(args.audit.read_text())
    original=Path(audit['app'])/audit['main_executable']
    deps=subprocess.check_output(['xcrun','otool','-L',str(previous)],text=True)
    paths={}
    for line in deps.splitlines()[1:]:
        path=line.strip().split(' (')[0];name=Path(path).name
        if name.endswith('.dylib'):name=name.removesuffix('.dylib').split('.')[0]
        paths[name]=path
    aliases={'Foundation':'libStrayFoundation','Cocoa':'libStrayCocoa','AppKit':'libStrayAppKit','Carbon':'libStrayKeyboard','CoreServices':'libStrayCoreServices'}
    if args.runtime:aliases.update({'CoreGraphics':'libStrayCoreGraphics','CoreVideo':'libStrayCoreVideo','IOKit':'libStrayIOKit','libobjc':'libStrayObjC','libSystem':'libStraySystem','AudioToolbox':'libStrayAudio','CoreAudio':'libStrayCoreAudio'})
    grouped={}
    for symbol,weak,framework in re.findall(r'(_\S+)\s+(\[weak-import\]\s+)?\(from ([^)]+)\)',imports):
        path=paths.get(aliases.get(framework,framework))
        if path:
            group=grouped.setdefault(framework,{'path':path,'symbols':[],'weak_symbols':[]})
            group['symbols'].append(symbol[1:])
            if weak:group['weak_symbols'].append(symbol[1:])
    (app/'framework-imports.json').write_text(json.dumps(grouped,indent=2)+'\n')
    shutil.copy2(args.keyboard / 'keyboard-reference.json', app / 'keyboard-reference.json')
    staged_manifest = {'platform': args.platform, 'libraries': libraries,
        'main_loader_experiment': {'prepared': str(target.resolve())},
        'compatibility_libraries': bridges, 'game_entry_called': False,
        'full_assets_bundled': False, 'application': str(app.resolve()),
        'instruction_policy_changes': [json.loads(path.read_text()) for path in args.policy_report],
        'source_audit': str(args.audit.resolve())}
    (args.out / 'manifest.json').write_text(json.dumps(staged_manifest, indent=2) + '\n')
    if args.platform == 'iossim':
        for binary in frameworks.glob('*.dylib'):
            subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(binary)],
                check=True, capture_output=True)
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True, capture_output=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
    print(app)


if __name__ == '__main__':
    main()
