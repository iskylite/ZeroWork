#!/usr/bin/env python3
"""Verify agent access across rebuild/reinstall using only a random owned scope.
Biometrics are injected in this probe only; --real-auth uses LocalAuthentication.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid
from build_credential_agent import build

ROOT = Path(__file__).resolve().parent.parent
SOURCE = r'''
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <Security/Security.h>
#ifndef REAL_AUTH
#define ZW_CREDENTIALS_CONFIRM_EXTERNAL 1
static int confirmations;
static OSStatus confirm_vault(void) { confirmations++; return errSecSuccess; }
#endif
#include "macos_credentials.m"
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    const char *reference = "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const unsigned char fixture[] = "zerowork-owned-signing-fixture";
    int status = 0, matches = 0;
    if (!strcmp(argv[1], "seed")) {
        status = zw_credentials_add(argv[2], reference, fixture, sizeof(fixture) - 1);
        // Exercise updates and a payload larger than the socket buffer too.
        const char *second = "zw1_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        unsigned char large[256 * 1024]; memset(large, 'x', sizeof(large));
        if (!status) status = zw_credentials_add(argv[2], second, large, sizeof(large));
    } else if (!strcmp(argv[1], "erase")) {
        status = zw_credentials_erase(argv[2]);
    } else if (!strcmp(argv[1], "direct-agent")) {
        char path[PATH_MAX]; uint32_t size = sizeof(path);
        if (_NSGetExecutablePath(path, &size)) return 3;
        *strrchr(path, '/') = 0; strcat(path, "/../Helpers/ZeroWorkCredentials");
        char *arguments[] = { path, NULL }, *environment[] = { NULL }; pid_t pid;
        if (posix_spawn(&pid, path, NULL, NULL, arguments, environment)) return 3;
        int result; if (waitpid(pid, &result, 0) != pid) return 3;
        status = WIFEXITED(result) ? WEXITSTATUS(result) : -1;
    } else if (!strcmp(argv[1], "read")) {
        unsigned char *data = NULL; size_t length = 0;
        status = zw_credentials_get(argv[2], reference, &data, &length);
        matches = !status && length == sizeof(fixture) - 1 && !memcmp(data, fixture, length);
        zw_credentials_free(data, length);
        if (!status) {
            status = zw_credentials_get(argv[2], reference, &data, &length);
            zw_credentials_free(data, length);
        }
        if (!status) {
            status = zw_credentials_get(argv[2], "zw1_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", &data, &length);
            matches = matches && !status && length == 256 * 1024;
            for (size_t i = 0; matches && i < length; i++) if (data[i] != 'x') matches = 0;
            zw_credentials_free(data, length);
        }
    } else return 2;
    printf("{\"build\":%d,\"status\":%d,\"matches\":%s", BUILD_VERSION, status, matches ? "true" : "false");
#ifndef REAL_AUTH
    printf(",\"confirmations\":%d", confirmations);
#else
    LAContext *capability = [[LAContext alloc] init];
    BOOL biometrics = [capability canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:nil];
    printf(",\"biometrics_available\":%s,\"biometry_type\":%ld", biometrics ? "true" : "false", (long)capability.biometryType);
    [capability release];
#endif
    puts("}"); return 0;
}
'''


def run(arguments):
    result = subprocess.run(arguments, text=True, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=210)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout.strip()


def signature(path):
    return subprocess.run(['/usr/bin/codesign', '-d', '-r-', '-vvv', str(path)],
                          text=True, capture_output=True, check=True).stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--real-auth', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    identity = run(['python3', str(ROOT / 'scripts/macos_signing.py'), 'identity'])
    service = 'com.zerowork.app.credentials.instance.' + hashlib.sha256(uuid.uuid4().bytes).hexdigest()
    report = {'service': service, 'biometrics': 'real' if args.real_auth else 'injected in probe only',
              'keychain_ui': 'prohibited', 'clients': {}}
    with tempfile.TemporaryDirectory(prefix='zerowork-update-test-') as directory:
        temp = Path(directory)
        source = temp / 'client.m'; source.write_text(SOURCE)
        clients = {}
        for name, version, identifier in [('a', 1, 'com.zerowork.signing-test'),
                                          ('b', 2, 'com.zerowork.signing-test'),
                                          ('other', 2, 'com.zerowork.signing-test.other')]:
            app = temp / (name + '.app')
            executable = app / 'Contents/MacOS/Probe'
            executable.parent.mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Probe',
                'CFBundleName': 'ZeroWork Credential Check', 'CFBundlePackageType': 'APPL',
                'ZeroWorkCredentialAgent': True,
            }))
            command = ['/usr/bin/xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
                       '-DBUILD_VERSION=' + str(version), '-I', str(ROOT / 'src/platform'),
                       str(source), '-framework', 'Security', '-framework', 'CoreFoundation',
                       '-o', str(executable)]
            if args.real_auth:
                command += ['-DREAL_AUTH=1', '-framework', 'Foundation', '-framework', 'LocalAuthentication']
            run(command)
            if name == 'other':
                helper = app / 'Contents/Helpers/ZeroWorkCredentials'
                helper.parent.mkdir(parents=True)
                shutil.copy2(clients['a'] / 'Contents/Helpers/ZeroWorkCredentials', helper)
            else:
                helper = build(app, identifier, identity)
            run(['/usr/bin/codesign', '--force', '--sign', identity, '--identifier', identifier, str(app)])
            run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
            report['clients'][name] = {'sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
                                       'signature': signature(executable), 'agent_signature': signature(helper)}
            clients[name] = app
        helper_hash = lambda name: re.search(r'^CDHash=(.+)$', report['clients'][name]['agent_signature'], re.M)[1]
        assert helper_hash('a') == helper_hash('b')
        assert report['clients']['a']['sha256'] != report['clients']['b']['sha256']
        report['agent_hash_stable'] = True
        installed = temp / 'Installed.app'

        def install(name):
            if installed.exists(): shutil.rmtree(installed)
            shutil.copytree(clients[name], installed)

        def operation(action, app=None):
            return json.loads(run([str((app or installed) / 'Contents/MacOS/Probe'), action, service]))

        install('a')
        try:
            report['seed_a'] = operation('seed'); assert report['seed_a']['status'] == 0
            report['restart_a'] = operation('read'); assert report['restart_a']['matches']
            install('b')
            report['update_b'] = operation('read'); assert report['update_b']['matches']
            report['relocated_b'] = operation('read', clients['b']); assert report['relocated_b']['matches']
            report['other_identity'] = operation('read', clients['other']); assert report['other_identity']['status'] != 0
            report['other_parent_direct'] = operation('direct-agent', clients['other']); assert report['other_parent_direct']['status'] == 1
            direct = subprocess.run([str(installed / 'Contents/Helpers/ZeroWorkCredentials')], stdin=subprocess.DEVNULL, capture_output=True)
            assert direct.returncode == 1
            report['unsigned_parent_denied'] = True
            helper = installed / 'Contents/Helpers/ZeroWorkCredentials'
            original = helper.read_bytes()
            run(['/usr/bin/codesign', '--force', '--sign', '-', str(helper)])
            report['adhoc_helper'] = operation('read'); assert report['adhoc_helper']['status'] != 0
            helper.write_bytes(original)
            if not args.real_auth:
                for key in ['restart_a', 'update_b', 'relocated_b']:
                    assert report[key]['confirmations'] == 1
            report['update_without_keychain_authorization'] = True
        finally:
            install('a')
            report['cleanup'] = operation('erase')
            (args.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
            assert report['cleanup']['status'] == 0
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
