"""All game data, signing settings and device reports stay in ignored local files."""
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'app'
BUILD = ROOT / 'build'
CONFIG = ROOT / 'config.local.json'
PIN = ROOT / 'data/supported-game.json'


def run(*command, capture=False):
    result = subprocess.run([str(x) for x in command], check=True, text=True,
                            capture_output=capture)
    return result.stdout.strip() if capture else None


def script(name, *args):
    run(sys.executable, APP / name, *args)


def read_config():
    if not CONFIG.is_file():
        raise ValueError('Run ./stray setup --game /path/to/Stray.app --bundle-id YOUR_ID first.')
    return json.loads(CONFIG.read_text())


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def source_fingerprint():
    hasher = hashlib.sha256()
    paths = [PIN, ROOT / 'stray']
    for directory in (APP, ROOT / 'tools'):
        paths.extend(p for p in directory.rglob('*') if p.is_file() and 'xcuserdata' not in p.parts and
                     p.suffix in {'.py', '.m', '.h', '.s', '.inc', '.plist', '.entitlements', '.pbxproj', '.json'})
    for path in sorted(paths):
        hasher.update(str(path.relative_to(ROOT)).encode())
        hasher.update(path.read_bytes())
    return hasher.hexdigest()


def receipt(kind):
    path = BUILD / (kind + '-receipt.json')
    if not path.is_file():
        raise ValueError(f'Run ./stray {kind} first.')
    result = json.loads(path.read_text())
    if result['source_fingerprint'] != source_fingerprint():
        raise ValueError('Sources changed. Run ./stray prepare and ./stray build again.')
    if result['game_path'] != str(Path(read_config()['game_path']).resolve()):
        raise ValueError('Game source changed. Run ./stray prepare and ./stray build again.')
    return result


def write_receipt(kind, **extra):
    result = {'source_fingerprint': source_fingerprint(),
              'game_path': str(Path(read_config()['game_path']).resolve()), **extra}
    (BUILD / (kind + '-receipt.json')).write_text(json.dumps(result, indent=2) + '\n')


def verify_game(game):
    game = Path(game).expanduser().resolve()
    if game == ROOT or game in ROOT.parents or game == BUILD or BUILD in game.parents:
        raise ValueError('Keep the source game outside the repository and build directory.')
    pin = json.loads(PIN.read_text())
    info = plistlib.loads((game / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != (pin['version'], pin['build']):
        raise ValueError('Only the pinned ARM64 Stray 1.6 (102) installation is supported.')
    actual = set()
    for path in game.rglob('*'):
        if path.is_symlink():
            raise ValueError('Unexpected source symlink: ' + str(path.relative_to(game)))
        if path.is_file() and path.name != '.DS_Store':
            actual.add(str(path.relative_to(game)))
    if actual != {item['path'] for item in pin['files']}:
        raise ValueError('Source file inventory differs from the supported game. See data/supported-game.json.')
    for item in pin['files']:
        path = game / item['path']
        if path.stat().st_size != item['size'] or digest(path) != item['sha256']:
            raise ValueError('Source size/SHA-256 mismatch: ' + item['path'])
    print(f"Verified {len(pin['files'])} original files; Stray {pin['version']} ({pin['build']}).")
    return game


def metal_compiler(config):
    configured = config.get('metal_compiler')
    if configured:
        compiler = Path(configured).expanduser().resolve()
    else:
        version = run('xcrun', 'metal', '--version', capture=True)
        match = re.search(r'^InstalledDir: (.+)$', version, re.M)
        if not match:
            raise ValueError('Cannot locate the Metal compiler. Install the Xcode Metal Toolchain component.')
        compiler = Path(match[1]) / 'metal'
    if not compiler.is_file() or not (compiler.parent / 'air-opt').is_file():
        raise ValueError('Set metal_compiler to the actual toolchain bin/metal with sibling air-opt.')
    return compiler


def setup(args):
    config = read_config() if CONFIG.exists() else json.loads((ROOT / 'config.example.json').read_text())
    for key in ('game_path', 'bundle_id', 'team_id', 'profile_path', 'signing_identity', 'device_id', 'metal_compiler'):
        value = getattr(args, key, None)
        if value is not None:
            config[key] = str(Path(value).expanduser().resolve()) if key in {'game_path', 'profile_path', 'metal_compiler'} else value
    if not config.get('game_path') or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', config['bundle_id'] or ''):
        raise ValueError('Provide --game /path/to/Stray.app and your own --bundle-id.')
    if config['bundle_id'] == 'dev.example.stray':
        raise ValueError('Replace the example bundle ID with your own App ID.')
    CONFIG.write_text(json.dumps(config, indent=2) + '\n')
    os.chmod(CONFIG, 0o600)
    print('Saved ignored config.local.json. Signing and device details remain local.')


def doctor(_):
    if sys.version_info < (3, 11) or sys.platform != 'darwin':
        raise ValueError('Use macOS with Python 3.11 or newer.')
    if run('uname', '-m', capture=True) != 'arm64':
        raise ValueError('Use an Apple Silicon Mac.')
    print(run('xcodebuild', '-version', capture=True))
    print('iOS SDK:', run('xcrun', '--sdk', 'iphoneos', '--show-sdk-version', capture=True))
    print('Metal:', metal_compiler(json.loads(CONFIG.read_text()) if CONFIG.exists() else {}))
    print('Python:', sys.version.split()[0])
    print('Available disk GiB:', round(shutil.disk_usage(ROOT).free / 2**30, 1))
    print('Source checks and host build do not establish game compatibility on an untested device.')


def export_icon(game):
    icon = BUILD / 'icon.iconset'
    if icon.exists():
        shutil.rmtree(icon)
    run('iconutil', '-c', 'iconset', '-o', icon, game / 'Contents/Resources/Stray.icns')
    source = icon / 'icon_512x512@2x.png'
    if not source.is_file():
        raise ValueError('The supported icon is missing its 1024-pixel image.')
    exporter = BUILD / 'export-icon'
    run('xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', APP / 'export-icon.m',
        '-framework', 'AppKit', '-framework', 'ImageIO', '-o', exporter)
    run(exporter, source, APP / 'Assets.xcassets/AppIcon.appiconset/AppIcon.png')


def prepare(_):
    config = read_config()
    game = verify_game(config['game_path'])
    compiler = metal_compiler(config)
    BUILD.mkdir(exist_ok=True)
    # Invalidate later stages before starting; interrupted preparation is not reusable.
    for kind in ('prepare', 'build', 'package'):
        (BUILD / (kind + '-receipt.json')).unlink(missing_ok=True)
    script('audit.py', game, '--out', BUILD / 'audit')
    script('prepare-libraries.py', BUILD / 'audit/audit.json', '--include-main',
           '--platform', 'ios', '--out', BUILD / 'guest')
    script('convert-main-loader.py', BUILD / 'guest/StrayGuest.dylib', '--out', BUILD / 'converted/StrayGuest.dylib')
    previous = BUILD / 'converted/StrayGuest.dylib'
    policies = []
    for name, suffix in [('layout', '.layout.json'), ('filesystem', '.filesystem.json'), ('gpu-metadata', '.gpu-metadata.json')]:
        target = BUILD / name / 'StrayGuest.dylib'
        script('guest-' + name + '-policy.py', previous, '--out', target)
        policies.append(str(target.with_suffix(suffix)))
        previous = target
    for name in ('cocoa', 'keyboard', 'appkit', 'runtime'):
        script('build-' + name + '.py', '--platform', 'ios', '--out', BUILD / name)
    script('rebuild-bink-shaders.py', game / json.loads(PIN.read_text())['main_executable'],
           '--metal', compiler, '--out', BUILD / 'shaders')
    export_icon(game)
    write_receipt('prepare', main=str(previous), policies=policies)
    print('Preparation complete. Original game files remain unchanged.')


def build(_):
    config = read_config()
    prepared = receipt('prepare')
    (BUILD / 'build-receipt.json').unlink(missing_ok=True)
    (BUILD / 'package-receipt.json').unlink(missing_ok=True)
    run('xcodebuild', '-project', APP / 'StrayProbe.xcodeproj', '-scheme', 'StrayProbe',
        '-configuration', 'Debug', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
        '-derivedDataPath', BUILD / 'host', 'CODE_SIGNING_ALLOWED=NO',
        'PRODUCT_BUNDLE_IDENTIFIER=' + config['bundle_id'], 'DEVELOPMENT_TEAM=' + (config.get('team_id') or ''), 'build')
    host = BUILD / 'host/Build/Products/Debug-iphoneos/StrayProbe.app'
    stage = BUILD / 'staging'
    command = ['--platform', 'ios', '--app', host, '--main', prepared['main'],
               '--guest-libraries', BUILD / 'guest', '--audit', BUILD / 'audit/audit.json',
               '--out', stage, '--launch-game']
    for name in ('cocoa', 'keyboard', 'appkit', 'runtime'):
        command += ['--' + name, BUILD / name]
    for policy in prepared['policies']:
        command += ['--policy-report', policy]
    script('stage-compatibility.py', *command)
    script('bundle-game-assets.py', '--source', config['game_path'], '--staging', stage)
    output = stage / 'StrayProbe.app'
    shutil.copytree(BUILD / 'shaders', output / 'StrayShaderLibraries',
                    ignore=shutil.ignore_patterns('*.air', '*.ll'), dirs_exist_ok=True)
    info_path = output / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['CFBundleVersion'] = '21'
    info['UIFileSharingEnabled'] = True
    info['LSSupportsOpeningDocumentsInPlace'] = True
    info_path.write_bytes(plistlib.dumps(info))
    # Reject any input changes during preparation/copy, including all resources.
    verify_game(config['game_path'])
    write_receipt('build', bundle_id=config['bundle_id'], application=str(output))
    print('Unsigned full-resource app:', output)


def package(_):
    config = read_config()
    built = receipt('build')
    if built['bundle_id'] != config['bundle_id']:
        raise ValueError('Bundle ID changed. Run ./stray build again.')
    if not config.get('profile_path') or not config.get('signing_identity'):
        raise ValueError('Configure --profile and --identity using ./stray setup. See docs/BUILD.md.')
    raw = Path(config['profile_path']).read_bytes()
    profile = plistlib.loads(raw[raw.index(b'<?xml'):raw.index(b'</plist>') + 8])
    if config.get('team_id') and profile['TeamIdentifier'][0] != config['team_id']:
        raise ValueError('Provisioning profile belongs to a different team.')
    if not profile['Entitlements'].get('com.apple.developer.kernel.increased-memory-limit'):
        raise ValueError('Use a profile that grants Increased Memory Limit. See docs/BUILD.md.')
    script('package-diagnostic.py', '--app', built['application'], '--libraries', BUILD / 'staging',
           '--profile', config['profile_path'], '--identity', config['signing_identity'],
           '--out', BUILD / 'package', '--in-place', '--ipa-name', 'Stray-v21-local.ipa')
    script('verify-package.py', '--staging', BUILD / 'staging', '--package', BUILD / 'package')
    write_receipt('package', bundle_id=config['bundle_id'])
    print('Verified local IPA:', BUILD / 'package/Stray-v21-local.ipa')


def check(args):
    run(sys.executable, ROOT / 'tools/check-source.py')
    tests = BUILD / 'tests'
    tests.mkdir(parents=True, exist_ok=True)
    run('xcrun', 'clang', '-Wall', '-Wextra', '-Werror', APP / 'tests/thermal-frame-policy.c', '-o', tests / 'thermal')
    run(tests / 'thermal')
    run('xcrun', 'clang', '-Wall', '-Wextra', '-Werror', APP / 'tests/movie-profile.c', '-o', tests / 'movie-headers')
    run(tests / 'movie-headers')
    run('xcrun', 'clang', '-fobjc-arc', APP / 'tests/game-settings-profile.m', '-framework', 'Foundation', '-o', tests / 'settings')
    run(tests / 'settings')
    if args.game:
        game = verify_game(args.game)
        run('xcrun', 'clang', '-fobjc-arc', '-Wno-incompatible-pointer-types',
            APP / 'tests/movie-path-bridge.m', APP / 'MoviePathBridge.m', APP / 'GuestPaths.m',
            '-framework', 'Foundation', '-o', tests / 'movies')
        run(tests / 'movies', game / 'Contents/UE4/Hk_project/Content/Movies')
    print('Source/policy tests passed. This does not measure native gameplay FPS.')


def device(config, args):
    result = getattr(args, 'device', None) or config.get('device_id')
    if not result:
        raise ValueError('Use --device ID from ./stray devices or configure --device with ./stray setup.')
    return result


def install(args):
    config = read_config()
    packaged = receipt('package')
    if packaged['bundle_id'] != config['bundle_id']:
        raise ValueError('Bundle ID changed. Rebuild and package first.')
    run('codesign', '--verify', '--deep', '--strict', BUILD / 'staging/StrayProbe.app')
    run('xcrun', 'devicectl', 'device', 'install', 'app', '--device', device(config, args), BUILD / 'staging/StrayProbe.app')


def launch(args):
    config = read_config()
    run('xcrun', 'devicectl', 'device', 'process', 'launch', '--device', device(config, args), config['bundle_id'])


def main():
    parser = argparse.ArgumentParser(description='Stray iOS v21 local source workflow (experimental).')
    commands = parser.add_subparsers(dest='command', required=True)
    setup_parser = commands.add_parser('setup', help='Save private local game/signing configuration.')
    for flag, dest in [('game', 'game_path'), ('bundle-id', 'bundle_id'), ('team', 'team_id'),
                       ('profile', 'profile_path'), ('identity', 'signing_identity'),
                       ('device', 'device_id'), ('metal', 'metal_compiler')]:
        setup_parser.add_argument('--' + flag, dest=dest)
    for name, help_text in [('doctor', 'Check local toolchains.'), ('prepare', 'Verify and prepare local game copies.'),
                            ('build', 'Build an unsigned full-resource app.'), ('package', 'Sign and verify a local IPA.'),
                            ('devices', 'List connected devices.'), ('install', 'Install the locally signed app.'),
                            ('launch', 'Launch the installed app.'), ('check', 'Run source and policy tests.')]:
        sub = commands.add_parser(name, help=help_text)
        if name in {'install', 'launch'}:
            sub.add_argument('--device')
        if name == 'check':
            sub.add_argument('--game', help='Also verify the real movie-resource pairs.')
    args = parser.parse_args()
    try:
        if args.command == 'devices':
            run('xcrun', 'devicectl', 'list', 'devices')
        else:
            globals()[args.command](args)
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        parser.exit(1, 'Error: ' + str(error) + '\n')
