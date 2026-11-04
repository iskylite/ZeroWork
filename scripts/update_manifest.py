#!/usr/bin/env python3
"""Provision a private Ed25519 release key once; build signed update.json offline."""
import argparse, base64, hashlib, json, os, pathlib, re, subprocess, zipfile
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
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
    out.write_bytes(encode(envelope)+b'\n'); print(out)
p = argparse.ArgumentParser(description=__doc__)
s = p.add_subparsers(dest='action', required=True)
s.add_parser('setup'); s.add_parser('verify-key')
m=s.add_parser('manifest');m.add_argument('archive');m.add_argument('--version', required=True);m.add_argument('--notes');m.add_argument('--output')
a=p.parse_args()
if a.action=='setup': setup()
elif a.action=='verify-key': verify_key(); print('Release trust verified')
else: manifest(a)
