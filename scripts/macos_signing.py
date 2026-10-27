#!/usr/bin/env python3
"""Provision once, then resolve ZeroWork's local code-signing identity."""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile

STATE = Path.home() / 'Library/Application Support/com.zerowork.signing'
IDENTITY = STATE / 'identity.sha1'
CERTIFICATE = STATE / 'certificate.pem'


def run(args, capture=False):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE if capture else None)
    if result.returncode:
        raise SystemExit(f'{Path(args[0]).name} failed (exit {result.returncode}); signing identity was not replaced')
    return result.stdout.strip() if capture else ''


def available(fingerprint):
    identities = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], True)
    return re.search(r'\b' + re.escape(fingerprint) + r'\b', identities, re.I) is not None


def resolve():
    if not IDENTITY.exists():
        raise SystemExit('Run python3 scripts/macos_signing.py setup once before packaging')
    fingerprint = IDENTITY.read_text().strip()
    if not re.fullmatch(r'[0-9A-Fa-f]{40}', fingerprint) or not available(fingerprint):
        raise SystemExit('Saved signing identity is unavailable; restore its certificate and private key. Do not generate a replacement.')
    return fingerprint


def setup():
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    if IDENTITY.exists():
        print(resolve())
        return
    if CERTIFICATE.exists():
        raise SystemExit('An incomplete setup exists. Inspect the imported identity before retrying; automatic key rotation is disabled.')
    keychain = run(['/usr/bin/security', 'default-keychain', '-d', 'user'], True).strip('"')
    with tempfile.TemporaryDirectory(prefix='zerowork-signing-') as directory:
        temp = Path(directory)
        config = temp / 'certificate.cnf'
        config.write_text('''[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = ZeroWork Local Code Signing
O = ZeroWork Local
[extensions]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
''')
        key, cert = temp / 'private-key.pem', temp / 'certificate.pem'
        run(['/usr/bin/openssl', 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-nodes',
             '-days', '3650', '-sha256', '-config', str(config), '-keyout', str(key), '-out', str(cert)])
        key.chmod(0o600)
        # Retain only the public certificate on disk. The key remains in Keychain.
        CERTIFICATE.write_bytes(cert.read_bytes())
        run(['/usr/bin/security', 'import', str(cert), '-k', keychain, '-t', 'cert'])
        run(['/usr/bin/security', 'import', str(key), '-k', keychain, '-t', 'priv', '-T', '/usr/bin/codesign'])
        # User-domain trust is restricted to code signing, not TLS or other policies.
        run(['/usr/bin/security', 'add-trusted-cert', '-r', 'trustRoot', '-p', 'codeSign', '-k', keychain, str(cert)])
        der = subprocess.check_output(['/usr/bin/openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
        fingerprint = hashlib.sha1(der).hexdigest().upper()
        if not available(fingerprint):
            raise SystemExit('Identity imported but not yet valid for code signing; finish system authorization before retrying')
        IDENTITY.write_text(fingerprint + '\n')
        IDENTITY.chmod(0o600)
        print(f'Configured persistent identity: {fingerprint}')
        print(f'Public certificate: {CERTIFICATE}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['setup', 'identity'])
    args = parser.parse_args()
    if args.action == 'setup':
        setup()
    else:
        print(resolve())
