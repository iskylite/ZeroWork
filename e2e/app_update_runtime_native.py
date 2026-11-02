#!/usr/bin/env python3
"""Exercise the real runtime -> helper bridge using disposable signed apps.

Build: zig build build-update-tools -j2 -Dtest-mode=true -Doptimize=ReleaseFast --prefix /tmp/zw-update-tools
Run: python3 e2e/app_update_runtime_native.py --bin-dir /tmp/zw-update-tools/bin
"""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, **kwargs)


def read(path):
    try:
        return json.loads(path.read_bytes())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def wait(predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.03)
    raise AssertionError('Timed out waiting for runtime helper result')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=pathlib.Path, default=ROOT / 'zig-out/bin')
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'dist/update-runtime-validation')
    args = parser.parse_args()
    fixture = (args.bin_dir / 'update-fixture').resolve()
    helper = (args.bin_dir / 'ZeroWorkUpdater').resolve()
    identity = run(['python3', ROOT / 'scripts/macos_signing.py', 'identity'], cwd=ROOT, text=True).stdout.strip()
    trust = read(ROOT / 'src/update/trust.json')
    key = Ed25519PrivateKey.from_private_bytes((pathlib.Path.home() / 'Library/Application Support/com.zerowork.signing/update-ed25519.key').read_bytes())
    args.output.mkdir(parents=True, exist_ok=True)
    checks = []

    def app(path, version):
        (path / 'Contents/MacOS').mkdir(parents=True)
        (path / 'Contents/Helpers').mkdir()
        shutil.copy2(fixture, path / 'Contents/MacOS/ZeroWork')
        shutil.copy2(helper, path / 'Contents/Helpers/ZeroWorkUpdater')
        run(['codesign', '--force', '--sign', identity, '--identifier', 'com.zerowork.updater', path / 'Contents/Helpers/ZeroWorkUpdater'])
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.zerowork.app', 'CFBundleExecutable': 'ZeroWork',
            'CFBundlePackageType': 'APPL', 'CFBundleName': 'ZeroWork runtime fixture',
            'ZeroWorkReleaseVersion': version, 'CFBundleVersion': version,
            'CFBundleShortVersionString': version.split('-')[0],
        }))
        run(['codesign', '--force', '--sign', identity, '--identifier', 'com.zerowork.app', path])

    scenarios = ('prepare-immediate-cancel', 'prepared-cancel', 'cancel-wins-late-commit',
                 'commit-wins-late-cancel', 'prepare-failed-cancel')
    for scenario in scenarios:
        with tempfile.TemporaryDirectory(prefix='zw-runtime-' + scenario + '-') as temporary:
            base = pathlib.Path(temporary).resolve()
            target = base / 'ZeroWork.app'
            candidate = base / 'candidate/ZeroWork.app'
            data = base / 'data'
            data.mkdir()
            app(target, '0.3.0-rc1')
            app(candidate, '0.3.1')
            archive = base / 'update.zip'
            run(['ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr', candidate, archive])
            import zipfile
            with zipfile.ZipFile(archive) as zipped:
                expanded = sum(entry.file_size for entry in zipped.infolist())
            payload = {'schema': 1, 'version': '0.3.1', 'minimum_os': '14.0', 'arch': 'arm64',
                       'url': 'https://github.com/iskylite/ZeroWork/releases/download/v0.3.1/ZeroWork-0.3.1-arm64.zip',
                       'release_url': 'https://github.com/iskylite/ZeroWork/releases/tag/v0.3.1',
                       'bytes': archive.stat().st_size, 'expanded_bytes': expanded,
                       'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(), 'notes': 'Disposable signed runtime bridge fixture'}
            raw = json.dumps(payload, separators=(',', ':'), sort_keys=True).encode()
            envelope = base / 'envelope.json'
            envelope.write_text(json.dumps({'key_id': trust['key_id'], 'payload_base64': base64.b64encode(raw).decode(),
                                            'signature_base64': base64.b64encode(key.sign(raw)).decode()}))
            digest = hashlib.sha256((str(target) + '\n' + str(data)).encode()).hexdigest()[:32]
            root = pathlib.Path.home() / 'Library/Application Support/com.zerowork.updater' / digest
            assert not root.exists(), 'Disposable test root must be new'
            env = os.environ | {'ZW_UPDATE_HEADLESS': '1', 'ZW_UPDATE_FIXTURE_DATA': str(data)}
            if scenario == 'prepare-immediate-cancel':
                env['ZW_UPDATE_TEST_PREPARE_HOLD'] = str(base / 'release-prepare')
            parent = None
            stdout_file = (base / 'runtime.stdout').open('w')
            stderr_file = (base / 'runtime.stderr').open('w')
            try:
                parent = subprocess.Popen([str(target / 'Contents/MacOS/ZeroWork'), '--runtime', scenario,
                                           str(data), str(envelope), str(archive)], env=env,
                                          stdout=stdout_file, stderr=stderr_file, text=True)
                # Reap the parent promptly: a zombie still has a process birth
                # identity on macOS. Helper output uses files, not inherited pipes.
                parent.wait(timeout=45)
                stdout = (base / 'runtime.stdout').read_text()
                stderr = (base / 'runtime.stderr').read_text()
                assert parent.returncode == 0, (scenario, parent.returncode, stdout, stderr)
                result = json.loads(stdout.strip())
                active = read(root / 'active.json')
                txn = pathlib.Path(active['transaction']) if active else None
                if scenario == 'commit-wins-late-cancel':
                    final = wait(lambda: (record if (record := read(txn / 'record.json')).get('stage') == 'healthy' else None))
                    assert final['decision'] == 'committed'
                    assert pathlib.Path(final['backup']).exists()
                    expected_version = '0.3.1'
                else:
                    final = read(txn / 'record.json') if txn else {}
                    assert result['state'] == 9
                    assert not final or (final['decision'] == 'cancelled' and final['stage'] == 'cancelled')
                    # Parent has now exited: a cancelled prepare must never turn
                    # that ordinary exit into permission to replace the app.
                    time.sleep(.15)
                    expected_version = '0.3.0-rc1'
                info = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
                assert info['ZeroWorkReleaseVersion'] == expected_version
                run([fixture, '--verify-app', target, expected_version])
                result['final_stage'] = final.get('stage', 'no-active-transaction')
                result['target_version_after_parent_exit'] = expected_version
                result['status'] = 'passed'
                checks.append(result)
                (args.output / (scenario + '.json')).write_text(json.dumps({'runtime': result, 'record': final}, indent=2) + '\n')
                print(scenario + ': passed', flush=True)
            finally:
                if parent and parent.poll() is None:
                    parent.terminate()
                    try:
                        parent.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        parent.kill()
                        parent.wait()
                active = read(root / 'active.json')
                record = read(pathlib.Path(active['transaction']) / 'record.json') if active else {}
                for role in ('helper', 'new'):
                    pid, birth = record.get(role + '_pid', 0), record.get(role + '_birth', 0)
                    if pid and birth:
                        actual = int(run([fixture, '--birth', pid], text=True).stdout.strip())
                        if actual == birth:
                            try:
                                os.kill(pid, signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                shutil.rmtree(root, ignore_errors=True)
                stdout_file.close()
                stderr_file.close()
    report = {'status': 'passed', 'scope': 'real runtime bridge and helper; disposable signed .app and data only', 'checks': checks}
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
