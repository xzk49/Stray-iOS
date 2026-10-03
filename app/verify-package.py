#!/usr/bin/env python3
"""Verify a full IPA against the staged app and audited game resources."""
import argparse
import hashlib
import json
import plistlib
import struct
import zipfile
from datetime import datetime, timezone
from pathlib import Path


def text_section(data):
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected thin ARM64 Mach-O')
    count = struct.unpack_from('<I', data, 16)[0]
    offset = 32
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        if command == 0x19:
            sections = struct.unpack_from('<I', data, offset + 64)[0]
            for i in range(sections):
                section = offset + 72 + i * 80
                if data[section:section + 16].rstrip(b'\0') == b'__text':
                    address, length, file_offset = struct.unpack_from('<QQI', data, section + 32)
                    return address, file_offset, data[file_offset:file_offset + length]
        offset += size
    raise ValueError('No __text section')


def digest(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staging', type=Path, required=True)
    parser.add_argument('--package', type=Path, required=True)
    args = parser.parse_args()
    app = args.staging / 'StrayProbe.app'
    package = json.loads((args.package / 'package.json').read_text())
    manifest = json.loads((args.staging / 'manifest.json').read_text())
    assets = json.loads((args.staging / 'assets.json').read_text())
    ipa = Path(package['ipa'])
    if digest(ipa) != package['ipa_sha256']:
        raise ValueError('IPA hash differs from package metadata')
    audited = {'GuestGame/' + item['path']: item for item in assets['resources']}
    files = {str(p.relative_to(app)): p for p in app.rglob('*') if p.is_file()}
    checked = []
    prefix = 'Payload/StrayProbe.app/'
    with zipfile.ZipFile(ipa) as archive:
        members = {i.filename[len(prefix):]: i for i in archive.infolist() if not i.is_dir() and i.filename.startswith(prefix)}
        if set(members) != set(files):
            raise ValueError('IPA file inventory differs from staged app')
        for name, info in members.items():
            expected = audited[name]['sha256'] if name in audited else digest(files[name])
            if info.file_size != files[name].stat().st_size:
                raise ValueError('Wrong file size: ' + name)
            with archive.open(info) as stream:
                actual = hashlib.file_digest(stream, 'sha256').hexdigest()
            # Reading every entry through EOF also verifies its ZIP CRC.
            if actual != expected:
                raise ValueError('Wrong file hash: ' + name)
            if name in audited and info.file_size != audited[name]['size']:
                raise ValueError('Wrong original resource size: ' + name)
            checked.append(name)
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        if not info.get('StrayLaunchGame') or '-NullRHI' in info.get('StrayExtraArguments', []):
            raise ValueError('Expected real game Metal startup')
    source = Path(manifest['instruction_policy_changes'][0]['source']).read_bytes()
    address, offset, original = text_section(source)
    expected = bytearray(original)
    policies = []
    for policy in manifest['instruction_policy_changes']:
        start = policy['file_offset'] - offset
        before, after = bytes.fromhex(policy['before']), bytes.fromhex(policy['after'])
        if expected[start:start + len(before)] != before:
            raise ValueError('Policy source mismatch: ' + policy['address'])
        expected[start:start + len(after)] = after
        policies.append({k: policy[k] for k in ('address', 'before', 'after')})
    staged_address, _, staged_text = text_section((app / 'Frameworks/StrayGuest.dylib').read_bytes())
    if address != staged_address or staged_text != expected:
        raise ValueError('Unexpected CPU instruction change')
    shader_manifest = json.loads((app / 'StrayShaderLibraries/manifest.json').read_text())
    for library in shader_manifest['libraries']:
        if digest(app / 'StrayShaderLibraries' / library['filename']) != library['ios_sha256']:
            raise ValueError('Bink shader manifest mismatch')
    result = {'verified_at_utc': datetime.now(timezone.utc).isoformat(),
              'ipa_sha256': package['ipa_sha256'], 'size_bytes': ipa.stat().st_size,
              'zip_crc_verified': True, 'all_archive_files_sha256_verified': True,
              'archive_file_count': len(checked), 'original_resource_count': len(audited),
              'full_resource_sizes_verified': True, 'framework_count': len(list((app / 'Frameworks').glob('*.dylib'))),
              'host_matches_staged_app': True, 'game_entry_enabled': True, 'nullrhi': False,
              'instruction_policies_verified': policies, 'no_other_main_text_changes': True,
              'bink_shader_libraries_verified': len(shader_manifest['libraries']),
              'gameplay_verified': False}
    (args.package / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
