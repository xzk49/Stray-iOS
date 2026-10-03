#!/usr/bin/env python3
"""Route only the audited Carbon/CoreServices keyboard imports to their bridges."""
import argparse
import importlib.util
import json
import re
import shutil
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.source.resolve() == args.out.resolve():
        parser.error('Use a separate prepared copy')
    imports = subprocess.run(['xcrun', 'dyld_info', '-imports', str(args.source)],
        capture_output=True, text=True, check=True).stdout
    expected = {'Carbon': {'_LMGetKbdType', '_TISCopyCurrentKeyboardLayoutInputSource',
        '_TISGetInputSourceProperty', '_kTISPropertyUnicodeKeyLayoutData'},
        'CoreServices': {'_UCKeyTranslate'}}
    for framework, symbols in expected.items():
        actual = set(re.findall(r'(\S+)\s+\(from ' + framework + r'\)', imports))
        if actual != symbols:
            parser.error(f'Unexpected {framework} imports: {actual}')
    mappings = {
        '/System/Library/Frameworks/Carbon.framework/Versions/A/Carbon': '@loader_path/libStrayKeyboard.dylib',
        '/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices': '@loader_path/libStrayCoreServices.dylib'}
    deps = subprocess.run(['xcrun', 'otool', '-L', str(args.source)], capture_output=True, text=True, check=True).stdout
    if any(path not in deps for path in mappings): parser.error('Expected desktop framework dependencies')
    spec = importlib.util.spec_from_file_location('stray_prepare', Path(__file__).with_name('prepare-libraries.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    before = module.text_hash(args.source)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(args.source, args.out)
    command = ['xcrun', 'install_name_tool']
    for old, new in mappings.items(): command.extend(['-change', old, new])
    subprocess.run(command + [str(args.out)], check=True, capture_output=True)
    if module.text_hash(args.out) != before: raise ValueError('CPU instruction mismatch')
    subprocess.run(['xcrun', 'dyld_info', '-validate_only', str(args.out)], check=True, capture_output=True)
    args.out.with_suffix('.keyboard.json').write_text(json.dumps({
        'source': str(args.source.resolve()), 'prepared': str(args.out.resolve()),
        'dependency_mapping': mappings, 'dependency_ordinals_preserved': True,
        'original_and_prepared_text_sha256': before, 'fixed_layout': 'US-ANSI',
        'dead_key_composition_implemented': False}, indent=2) + '\n')
    print('Routed five keyboard imports; CPU instructions unchanged.')


if __name__ == '__main__':
    main()
