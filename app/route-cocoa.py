#!/usr/bin/env python3
"""Route the audited, import-free Cocoa dependency to a Foundation reexport library.

This implements the observed Cocoa load requirement, not the AppKit API surface.
"""
import argparse
import hashlib
import importlib.util
import json
import shutil
import subprocess
from pathlib import Path

OLD = '/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa'
NEW = '@loader_path/libStrayCocoa.dylib'
FOUNDATION = '/System/Library/Frameworks/Foundation.framework/Foundation'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.source.resolve() == args.out.resolve():
        parser.error('Use a separate prepared copy')
    imports = subprocess.run(['xcrun', 'dyld_info', '-arch', 'arm64', '-imports', str(args.source)],
                             capture_output=True, text=True, check=True).stdout
    cocoa_imports = [line for line in imports.splitlines() if '(from Cocoa)' in line]
    if cocoa_imports:
        parser.error('Cocoa has bound imports and requires a symbol-level compatibility implementation')
    dependencies = subprocess.run(['xcrun', 'otool', '-L', str(args.source)],
                                  capture_output=True, text=True, check=True).stdout
    if OLD not in dependencies or FOUNDATION not in dependencies:
        parser.error('Expected original Cocoa load dependency')
    spec = importlib.util.spec_from_file_location('stray_prepare', Path(__file__).with_name('prepare-libraries.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    before = module.text_hash(args.source)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(args.source, args.out)
    subprocess.run(['xcrun', 'install_name_tool', '-change', OLD, NEW,
                   '-change', FOUNDATION, '@loader_path/libStrayFoundation.dylib', str(args.out)],
                   capture_output=True, check=True)
    if module.text_hash(args.out) != before:
        raise ValueError('Unexpected change to CPU instructions')
    subprocess.run(['xcrun', 'dyld_info', '-validate_only', str(args.out)], capture_output=True, check=True)
    report = {'source': str(args.source.resolve()), 'prepared': str(args.out.resolve()),
              'source_sha256': hashlib.sha256(args.source.read_bytes()).hexdigest(),
              'prepared_sha256': hashlib.sha256(args.out.read_bytes()).hexdigest(),
              'original_and_prepared_text_sha256': before, 'cocoa_static_import_count': 0,
              'dependency_mapping': {OLD: NEW, FOUNDATION: '@loader_path/libStrayFoundation.dylib'},
              'dependency_ordinal_preserved': True,
              'appkit_compatibility_implemented': False,
              'runtime_symbol_lookups_and_gameplay_verified': False}
    args.out.with_suffix('.cocoa.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Mapped import-free Cocoa dependency to the Foundation forwarding library; CPU instructions unchanged.')


if __name__ == '__main__':
    main()
