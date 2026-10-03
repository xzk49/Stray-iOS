#!/usr/bin/env python3
"""Verify the publishable source inventory; never inspect ignored local data."""
import ast
import json
import plistlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {'build', '.git', '__pycache__', 'xcuserdata'}
LOCAL_FILES = {'config.local.json', 'app/Assets.xcassets/AppIcon.appiconset/AppIcon.png'}
FORBIDDEN = {'.ipa', '.dylib', '.pak', '.bk2', '.uasset', '.metallib', '.air', '.ll',
             '.mobileprovision', '.p12', '.cer', '.log', '.ips', '.pyc', '.png', '.icns', '.xcuserstate'}


def public_files():
    if (ROOT / '.git').exists():
        output = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z'])
        return [ROOT / name.decode() for name in output.split(b'\0') if name]
    return sorted(p for p in ROOT.rglob('*') if p.is_file() and not EXCLUDED.intersection(p.relative_to(ROOT).parts)
                  and str(p.relative_to(ROOT)) not in LOCAL_FILES and p.name != '.DS_Store')


def main():
    files = public_files()
    assert files, 'Source inventory is empty'
    for path in files:
        relative = path.relative_to(ROOT)
        assert path.suffix not in FORBIDDEN and not EXCLUDED.intersection(relative.parts), f'Local artifact tracked: {relative}'
        assert str(relative) not in LOCAL_FILES, f'Private local settings tracked: {relative}'
        text = path.read_text()
        private_paths = r'/Users/[A-Za-z0-9._-]+/|' + '/private/' + r'tmp/|0000[0-9A-F]{4}-[0-9A-F]{16}'
        assert not re.search(private_paths, text), f'Private path/device ID: {relative}'
        assert not re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}', text), f'Credential: {relative}'
        if path.suffix == '.py':
            ast.parse(text, filename=str(relative))
        if path.suffix == '.json':
            json.loads(text)
        if path.suffix in {'.plist', '.entitlements'}:
            plistlib.loads(path.read_bytes())
    project = (ROOT / 'app/StrayProbe.xcodeproj/project.pbxproj').read_text()
    assert 'DEVELOPMENT_TEAM = "";' in project, 'Signing team must be configured locally'
    pin = json.loads((ROOT / 'data/supported-game.json').read_text())
    assert len(pin['files']) == 29 and len({f['path'] for f in pin['files']}) == 29
    print(f'Publishable source verified: {len(files)} UTF-8 files; no game artifacts or local configuration.')


if __name__ == '__main__':
    main()
