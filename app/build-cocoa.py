#!/usr/bin/env python3
"""Build the Cocoa umbrella forwarding library for one explicit iOS platform."""
import argparse
import json
import subprocess
from pathlib import Path


def run(command):
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{command}\n{result.stdout}\n{result.stderr}')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['ios', 'iossim'], required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    sdk = 'iphonesimulator' if args.platform == 'iossim' else 'iphoneos'
    target = 'arm64-apple-ios17.0-simulator' if args.platform == 'iossim' else 'arm64-apple-ios17.0'
    sdkpath = run(['xcrun', '--sdk', sdk, '--show-sdk-path']).strip()
    args.out.mkdir(parents=True, exist_ok=True)
    adapter = args.out / 'libStrayFoundation.dylib'
    run(['xcrun', '--sdk', sdk, 'clang', '-target', target, '-isysroot', sdkpath,
         '-dynamiclib', '-fobjc-arc', '-Werror', '-Wall', '-Wextra',
         str(Path(__file__).with_name('AppleEventBridge.m')),
         str(Path(__file__).with_name('GameBundleBridge.m')), '-o', str(adapter),
         '-Wl,-alias,_OBJC_CLASS_$_StrayGameBundle,_OBJC_CLASS_$_NSBundle',
         '-framework', 'UIKit', '-Wl,-install_name,@rpath/libStrayFoundation.dylib',
         '-Wl,-reexport_framework,Foundation'])
    run(['xcrun', 'dyld_info', '-validate_only', str(adapter)])
    output = args.out / 'libStrayCocoa.dylib'
    run(['xcrun', '--sdk', sdk, 'clang', '-target', target, '-isysroot', sdkpath,
         '-dynamiclib', '-fobjc-arc', '-Werror', '-Wall', '-Wextra',
         str(Path(__file__).with_name('CocoaBridge.m')), '-o', str(output),
         '-Wl,-install_name,@rpath/libStrayCocoa.dylib',
         '-framework', 'Foundation', '-Wl,-reexport_library,' + str(adapter),
         '-Wl,-rpath,@loader_path'])
    run(['xcrun', 'dyld_info', '-validate_only', str(output)])
    commands = run(['xcrun', 'otool', '-l', str(output)])
    if 'LC_REEXPORT_DYLIB' not in commands:
        raise ValueError('Foundation reexport missing')
    (args.out / 'cocoa-build.json').write_text(json.dumps({
        'platform': args.platform, 'sdk': sdkpath, 'target': target,
        'library': str(output.resolve()), 'foundation_reexport': True,
        'local_quit_event_registration': True, 'apple_event_ipc': False,
        'desktop_appkit_implemented': False}, indent=2) + '\n')
    print(output)


if __name__ == '__main__':
    main()
