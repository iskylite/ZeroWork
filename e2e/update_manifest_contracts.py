#!/usr/bin/env python3
"""Validate stable release artifacts with temporary ZIPs; never publish or rotate keys."""
import json
import pathlib
import plistlib
import subprocess
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/update_manifest.py'


def run(*args, ok=True):
    result = subprocess.run(['python3', str(SCRIPT), *map(str, args)], capture_output=True, text=True)
    assert (result.returncode == 0) == ok, result.stdout + result.stderr
    return result


with tempfile.TemporaryDirectory(prefix='zw-release-contracts-') as directory:
    base = pathlib.Path(directory)
    archive = base / 'ZeroWork-0.3.0-arm64.zip'
    envelope = base / 'update.json'
    with zipfile.ZipFile(archive, 'w') as zipped:
        zipped.writestr('ZeroWork.app/Contents/Info.plist', plistlib.dumps({
            'CFBundleIdentifier': 'com.zerowork.app', 'ZeroWorkReleaseVersion': '0.3.0',
            'LSMinimumSystemVersion': '13.0',
        }))
        zipped.writestr('ZeroWork.app/Contents/Helpers/ZeroWorkUpdater', b'contract fixture')
    run('manifest', archive, '--version', '0.3.0', '--output', envelope)
    run('verify', archive, envelope)
    checks = ['stable ZIP/envelope generation and public-key verification']
    run('manifest', archive, '--version', '0.3.0', '--output', envelope, ok=False)
    checks.append('existing envelope is never overwritten')
    run('manifest', archive, '--version', '0.3.0-rc22', '--output', base / 'rc.json', ok=False)
    assert not (base / 'rc.json').exists()
    checks.append('RC manifest is rejected')
    obj = json.loads(envelope.read_bytes())
    obj['signature_base64'] = 'A' * 88
    damaged = base / 'bad-signature.json'
    damaged.write_text(json.dumps(obj))
    run('verify', archive, damaged, ok=False)
    checks.append('tampered signature is rejected')
    with archive.open('ab') as output:
        output.write(b'tampered')
    run('verify', archive, envelope, ok=False)
    checks.append('modified ZIP is rejected')
    # A validly signed manifest must still match the app's version and minimum OS.
    for name, fields in [('version', {'ZeroWorkReleaseVersion': '0.2.0'}), ('minimum-os', {'LSMinimumSystemVersion': '14.0'})]:
        invalid = base / name
        invalid.mkdir()
        bad_zip = invalid / archive.name
        info = {'CFBundleIdentifier': 'com.zerowork.app', 'ZeroWorkReleaseVersion': '0.3.0', 'LSMinimumSystemVersion': '13.0'} | fields
        with zipfile.ZipFile(bad_zip, 'w') as zipped:
            zipped.writestr('ZeroWork.app/Contents/Info.plist', plistlib.dumps(info))
            zipped.writestr('ZeroWork.app/Contents/Helpers/ZeroWorkUpdater', b'contract fixture')
        run('manifest', bad_zip, '--version', '0.3.0', '--output', invalid / 'update.json', ok=False)
        assert not (invalid / 'update.json').exists()
        checks.append(name + ' mismatch is rejected before output')
    print(json.dumps({'status': 'passed', 'checks': checks}, ensure_ascii=False, indent=2))
