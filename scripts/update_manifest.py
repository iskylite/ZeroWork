#!/usr/bin/env python3
"""Provision a private Ed25519 release key once; build signed update.json offline."""
import argparse, base64, hashlib, json, os, pathlib, re, subprocess, zipfile
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives import serialization
ROOT = pathlib.Path(__file__).resolve().parents[1]
STATE = pathlib.Path.home() / 'Library/Application Support/com.zerowork.signing'
KEY = STATE / 'update-ed25519.key'
TRUST = ROOT / 'src/update/trust.json'
def encode(value): return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
def setup():
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    if TRUST.exists():
        if not KEY.exists(): raise SystemExit('Public trust exists. Restore its original private key; refusing rotation.')
        verify_key(); print('Existing update signing key verified'); return
    if not KEY.exists():
        fd = os.open(KEY, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as f:
            f.write(Ed25519PrivateKey.generate().private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())); f.flush(); os.fsync(f.fileno())
    public = Ed25519PrivateKey.from_private_bytes(KEY.read_bytes()).public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    identity = subprocess.check_output(['python3', str(ROOT/'scripts/macos_signing.py'), 'identity'], text=True).strip()
    TRUST.write_bytes(encode({'key_id': hashlib.sha256(public).hexdigest()[:16], 'public_key': base64.b64encode(public).decode(), 'certificate_sha1': identity.upper()}) + b'\n')
    print('Created public update trust. Private key stays outside repository with mode 0600.')
def verify_key():
    trust = json.loads(TRUST.read_bytes())
    key = Ed25519PrivateKey.from_private_bytes(KEY.read_bytes())
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    if base64.b64decode(trust['public_key']) != public: raise SystemExit('Update key does not match embedded public trust')
    if KEY.stat().st_mode & 0o077: raise SystemExit('Private update key must have mode 0600')
    identity = subprocess.check_output(['python3', str(ROOT/'scripts/macos_signing.py'), 'identity'], text=True).strip()
    if identity.upper() != trust['certificate_sha1']: raise SystemExit('Code-signing identity changed; explicit trust migration required')
    return trust, key
def verify_manifest(archive, envelope):
    archive = pathlib.Path(archive)
    if len(envelope) > 65536: raise SystemExit('Update envelope exceeds 64 KiB')
    obj = json.loads(envelope)
    if set(obj) != {'key_id', 'payload_base64', 'signature_base64'}: raise SystemExit('Invalid update envelope fields')
    trust = json.loads(TRUST.read_bytes())
    if obj['key_id'] != trust['key_id']: raise SystemExit('Unknown update signing key')
    if len(obj['payload_base64'].encode()) > 60000: raise SystemExit('Update payload exceeds client limit')
    payload = base64.b64decode(obj['payload_base64'], validate=True)
    Ed25519PublicKey.from_public_bytes(base64.b64decode(trust['public_key'], validate=True)).verify(base64.b64decode(obj['signature_base64'], validate=True), payload)
    m = json.loads(payload)
    fields = {'schema','version','minimum_os','arch','url','bytes','expanded_bytes','sha256','notes','release_url'}
    if set(m) != fields or type(m['schema']) is not int or m['schema'] != 1 or m['arch'] != 'arm64': raise SystemExit('Invalid update payload')
    version = m['version']
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version): raise SystemExit('Automatic updates accept stable X.Y.Z releases only')
    if archive.name != f'ZeroWork-{version}-arm64.zip': raise SystemExit('ZIP filename/version mismatch')
    expected_url = f'https://github.com/iskylite/ZeroWork/releases/download/v{version}/{archive.name}'
    if m['url'] != expected_url or m['release_url'] != f'https://github.com/iskylite/ZeroWork/releases/tag/v{version}': raise SystemExit('Update URL/version mismatch')
    if type(m['bytes']) is not int or not 0 < m['bytes'] <= 1024**3 or m['bytes'] != archive.stat().st_size: raise SystemExit('Update ZIP size mismatch')
    with archive.open('rb') as source:
        if m['sha256'] != hashlib.file_digest(source, 'sha256').hexdigest(): raise SystemExit('Update ZIP SHA256 mismatch')
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        names = [e.filename for e in entries]
        if len(names) != len(set(names)) or any(not n.startswith('ZeroWork.app/') or '..' in pathlib.PurePosixPath(n).parts for n in names): raise SystemExit('Invalid ZIP paths')
        expanded = sum(e.file_size for e in entries)
        if type(m['expanded_bytes']) is not int or not 0 < expanded <= 2*1024**3 or m['expanded_bytes'] != expanded: raise SystemExit('Expanded ZIP size mismatch')
        import plistlib
        info = plistlib.loads(zipped.read('ZeroWork.app/Contents/Info.plist'))
        if info.get('CFBundleIdentifier') != 'com.zerowork.app' or info.get('ZeroWorkReleaseVersion') != version: raise SystemExit('Archived app version/identity mismatch')
        if m['minimum_os'] != info.get('LSMinimumSystemVersion'): raise SystemExit('Minimum macOS version mismatch')
        if 'ZeroWork.app/Contents/Helpers/ZeroWorkUpdater' not in names: raise SystemExit('Update helper missing from ZIP')
    if not isinstance(m['notes'], str) or len(m['notes'].encode()) > 16384 or '\0' in m['notes']: raise SystemExit('Invalid release notes')
    return m

def manifest(args):
    trust, key = verify_key()
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', args.version): raise SystemExit('Automatic updates accept stable X.Y.Z releases only')
    archive = pathlib.Path(args.archive)
    if archive.name != f'ZeroWork-{args.version}-arm64.zip': raise SystemExit('ZIP filename/version mismatch')
    with zipfile.ZipFile(archive) as z:
        expanded = sum(x.file_size for x in z.infolist())
        if any(not x.filename.startswith('ZeroWork.app/') or '..' in pathlib.PurePosixPath(x.filename).parts for x in z.infolist()): raise SystemExit('ZIP must contain only ZeroWork.app')
    notes = pathlib.Path(args.notes).read_text() if args.notes else 'ZeroWork ' + args.version
    if len(notes.encode()) > 16384: raise SystemExit('Release notes exceed 16 KiB')
    payload = encode({'schema':1, 'version':args.version, 'minimum_os':'13.0', 'arch':'arm64', 'url':f'https://github.com/iskylite/ZeroWork/releases/download/v{args.version}/{archive.name}', 'bytes':archive.stat().st_size, 'expanded_bytes':expanded, 'sha256':hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest(), 'notes':notes, 'release_url':f'https://github.com/iskylite/ZeroWork/releases/tag/v{args.version}'})
    envelope = {'key_id':trust['key_id'], 'payload_base64':base64.b64encode(payload).decode(), 'signature_base64':base64.b64encode(key.sign(payload)).decode()}
    out = pathlib.Path(args.output or archive.parent/'update.json')
    if out.exists(): raise SystemExit('Refusing to overwrite '+str(out))
    raw = encode(envelope)+b'\n'
    verify_manifest(archive, raw)
    out.write_bytes(raw); print(out)
p = argparse.ArgumentParser(description=__doc__)
s = p.add_subparsers(dest='action', required=True)
s.add_parser('setup'); s.add_parser('verify-key')
m=s.add_parser('manifest');m.add_argument('archive');m.add_argument('--version', required=True);m.add_argument('--notes');m.add_argument('--output')
v=s.add_parser('verify');v.add_argument('archive');v.add_argument('envelope')
a=p.parse_args()
if a.action=='setup': setup()
elif a.action=='verify-key': verify_key(); print('Release trust verified')
elif a.action=='verify': verify_manifest(a.archive, pathlib.Path(a.envelope).read_bytes()); print('Signed update artifacts verified')
else: manifest(a)
