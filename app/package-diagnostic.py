#!/usr/bin/env python3
"""Sign a locally built diagnostic with an existing matching device profile."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import zipfile
from datetime import datetime, timezone
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--libraries', type=Path, required=True)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--in-place', action='store_true', help='Sign the separate staged app without copying its resources again')
    parser.add_argument('--ipa-name', default='StrayDiagnostic.ipa')
    args = parser.parse_args()
    info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    raw = args.profile.read_bytes()
    start = raw.index(b'<?xml')
    end = raw.index(b'</plist>', start) + 8
    # Metadata extraction is not a CMS signature verification. Device installation
    # validates Apple's provisioning profile; codesign verifies the app below.
    profile = plistlib.loads(raw[start:end])
    app_id = profile['Entitlements']['application-identifier']
    expected = profile['TeamIdentifier'][0] + '.' + info['CFBundleIdentifier']
    if app_id != expected:
        parser.error('Profile does not match the diagnostic bundle identifier')
    expiration = profile['ExpirationDate'].replace(tzinfo=timezone.utc)
    if expiration <= datetime.now(timezone.utc):
        parser.error('Provisioning profile has expired')
    certificate_hashes = [hashlib.sha1(cert).hexdigest().upper() for cert in profile['DeveloperCertificates']]
    if args.identity.upper() not in certificate_hashes:
        parser.error('Signing identity fingerprint does not match a certificate in the profile')
    manifest = json.loads((args.libraries / 'manifest.json').read_text())
    selected = [Path(item['prepared']) for item in manifest['libraries']]
    if manifest.get('main_loader_experiment'):
        selected.append(Path(manifest['main_loader_experiment']['prepared']))
    selected.extend(Path(item['prepared']) for item in manifest.get('compatibility_libraries', []))
    args.out.mkdir(parents=True, exist_ok=True)
    app = args.app if args.in_place else args.out / 'StrayProbe.app'
    if not args.in_place: shutil.copytree(args.app, app, dirs_exist_ok=True)
    frameworks = app / 'Frameworks'
    frameworks.mkdir(exist_ok=True)
    for library in selected:
        target = frameworks / library.name
        if library.resolve() != target.resolve(): shutil.copy2(library, target)
        subprocess.run(['codesign', '--force', '--sign', args.identity,
                        '--timestamp=none', str(target)], check=True, capture_output=True)
    shutil.copy2(args.profile, app / 'embedded.mobileprovision')
    entitlements = args.out / 'Entitlements.plist'
    entitlements.write_bytes(plistlib.dumps(profile['Entitlements']))
    subprocess.run(['codesign', '--force', '--sign', args.identity, '--timestamp=none',
                    '--entitlements', str(entitlements), str(app)], check=True, capture_output=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
    if Path(args.ipa_name).name != args.ipa_name: parser.error('IPA name must be a basename')
    ipa = args.out / args.ipa_name
    with zipfile.ZipFile(ipa, 'w', compression=zipfile.ZIP_STORED if manifest.get('full_assets_bundled') else zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob('*')):
            if path.is_file() or path.is_dir():
                archive.write(path, Path('Payload/StrayProbe.app') / path.relative_to(app))
    result = {'purpose': 'Original Stray entry and full-resource device startup test' if info.get('StrayLaunchGame') else 'Metal and guest loader diagnostics',
              'game_entry_enabled': bool(info.get('StrayLaunchGame')), 'full_assets_bundled': bool(manifest.get('full_assets_bundled')),
              'instruction_policy_changes': manifest.get('instruction_policy_changes',[]),
              'bundle_identifier': info['CFBundleIdentifier'],
              'guest_image_count': len(manifest['libraries']) + bool(manifest.get('main_loader_experiment')),
              'compatibility_image_count': len(manifest.get('compatibility_libraries', [])),
              'profile_expiration_utc': expiration.isoformat(), 'codesign_verified': True,
              'device_installation_verified': False, 'gameplay_verified': False,
              'ipa': str(ipa.resolve())}
    with ipa.open('rb') as file: result['ipa_sha256']=hashlib.file_digest(file,'sha256').hexdigest()
    (args.out / 'package.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f"Signed {result['guest_image_count']} guest images, {result['compatibility_image_count']} compatibility images and diagnostic app. IPA: {ipa}")


if __name__ == '__main__':
    main()
