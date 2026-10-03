#!/usr/bin/env python3
"""Install a diagnostic in an already booted simulator and archive its results."""
import argparse
import json
import shutil
import re
import subprocess
import time
from pathlib import Path


def simctl(*args, check=True):
    return subprocess.run(['xcrun', 'simctl', *map(str, args)],
                          capture_output=True, text=True, check=check)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--bundle-id', default='dev.example.stray')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--observe-seconds', type=float, default=0,
                        help='Observe the game after loader checks; does not assert gameplay success')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    out = args.out.resolve()
    simctl('terminate', args.device, args.bundle_id, check=False)
    simctl('install', args.device, args.app.resolve())
    container = Path(simctl('get_app_container', args.device, args.bundle_id, 'data').stdout.strip())
    report_path = container / 'Documents/environment.json'
    # Remove only the previous generated diagnostic report, so stale output is
    # never mistaken for a result from this new launch.
    report_path.unlink(missing_ok=True)
    launch = simctl('launch', '--terminate-running-process',
        '--stdout=' + str(out / 'stdout.log'), '--stderr=' + str(out / 'stderr.log'),
        args.device, args.bundle_id)
    (out / 'launch.txt').write_text(launch.stdout + launch.stderr)
    pid_match = re.search(r': (\d+)', launch.stdout)
    pid = int(pid_match.group(1)) if pid_match else None
    deadline = time.monotonic() + 45
    report = None
    completed = False
    while time.monotonic() < deadline:
        if report_path.exists():
            try:
                report = json.loads(report_path.read_text())
                stage = report.get('guest_libraries', '')
                completed = bool(report.get('error') or report.get('guest_main_error') or
                    report.get('guest_main_loaded') or stage.startswith('Loader stopped') or
                    stage == 'Diagnostic guest libraries not bundled' or
                    (stage.startswith('All 12') and not (args.app / 'Frameworks/StrayGuest.dylib').exists()))
                if completed:
                    break
            except (OSError, json.JSONDecodeError):
                pass
        time.sleep(0.2)
    if args.observe_seconds:
        time.sleep(args.observe_seconds)
        if report_path.exists():
            report = json.loads(report_path.read_text())
    processes = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True)
    alive = processes.returncode == 0 and 'StrayProbe' in processes.stdout
    log_path = container / 'Documents/Stray.log'
    if log_path.exists():
        shutil.copy2(log_path, out / 'Stray.log')
    if report_path.exists():
        shutil.copy2(report_path, out / 'environment.json')
    stderr=(out/'stderr.log').read_text(errors='replace') if (out/'stderr.log').exists() else ''
    failures=[line for line in stderr.splitlines() if any(marker in line for marker in
        ['failed assertion', 'uncaught exception', 'unrecognized selector'])]
    fatal_spin='Spinning after fatal error' in stderr
    (out / 'run.json').write_text(json.dumps({'simulator': args.device,
        'bundle_identifier': args.bundle_id, 'diagnostic_finished': completed,
        'game_entry_called': report.get('game_entry_called') if report else None,
        'process_id': pid, 'process_alive_after_observation': alive,
        'observed_seconds': args.observe_seconds,
        'runtime_failures': failures, 'fatal_error_spin': fatal_spin,
        'gameplay_verified': False}, indent=2) + '\n')
    time.sleep(0.5)
    simctl('io', args.device, 'screenshot', out / 'screen.png')
    print(json.dumps(report, indent=2, ensure_ascii=False))
    if not completed:
        raise SystemExit('Diagnostic did not finish within 45 seconds; inspect the saved stage and logs')


if __name__ == '__main__':
    main()
