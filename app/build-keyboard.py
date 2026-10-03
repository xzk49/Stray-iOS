#!/usr/bin/env python3
"""Generate Apple's US key map on Mac, then build the observed Carbon/CoreServices API subset."""
import argparse
import hashlib
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
    source = Path(__file__).parent
    args.out.mkdir(parents=True, exist_ok=True)
    generator = args.out / 'snapshot-keyboard'
    snapshot = args.out / 'StrayUSKeyboard.inc'
    run(['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-Wno-deprecated-declarations',
         str(source / 'snapshot-keyboard.m'), '-framework', 'Carbon', '-framework', 'Foundation',
         '-o', str(generator)])
    run([str(generator.resolve()), str(snapshot.resolve()),
         str((args.out / 'keyboard-reference.json').resolve())])
    sdk = 'iphonesimulator' if args.platform == 'iossim' else 'iphoneos'
    target = 'arm64-apple-ios17.0-simulator' if args.platform == 'iossim' else 'arm64-apple-ios17.0'
    sdkpath = run(['xcrun', '--sdk', sdk, '--show-sdk-path']).strip()
    output = args.out / 'libStrayKeyboard.dylib'
    run(['xcrun', '--sdk', sdk, 'clang', '-target', target, '-isysroot', sdkpath,
         '-dynamiclib', '-fobjc-arc', '-Werror', '-Wall', '-Wextra', '-O2', '-I', str(args.out),
         str(source / 'KeyboardBridge.m'), '-o', str(output), '-framework', 'Foundation',
         '-Wl,-install_name,@rpath/libStrayKeyboard.dylib'])
    run(['xcrun', 'dyld_info', '-validate_only', str(output)])
    # Separate names preserve guest dependency ordinals; one reexports the other.
    forwarding = args.out / 'libStrayCoreServices.dylib'
    marker = args.out / 'core-services.c'
    marker.write_text('// CoreServices keyboard subset forwarded to the Carbon bridge.\n')
    run(['xcrun', '--sdk', sdk, 'clang', '-target', target, '-isysroot', sdkpath,
         '-dynamiclib', str(marker), '-o', str(forwarding),
         '-Wl,-install_name,@rpath/libStrayCoreServices.dylib',
         '-Wl,-reexport_library,' + str(output), '-Wl,-rpath,@loader_path'])
    run(['xcrun', 'dyld_info', '-validate_only', str(forwarding)])
    (args.out / 'keyboard-build.json').write_text(json.dumps({
        'platform': args.platform, 'sdk': sdkpath, 'target': target,
        'native_reference_case_count': 131072,
        'native_reference_sha256': hashlib.sha256(snapshot.read_bytes()).hexdigest(),
        'fixed_layout': 'com.apple.keylayout.US', 'keyboard_type': 40,
        'options': 'kUCKeyTranslateNoDeadKeysMask',
        'dead_key_composition_implemented': False, 'ime_implemented': False}, indent=2) + '\n')
    print(output)


if __name__ == '__main__':
    main()
