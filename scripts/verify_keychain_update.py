#!/usr/bin/env python3
"""Exercise the production Keychain bridge across two differently built clients.
Only random, test-owned services are touched. Reads prohibit authentication UI.
"""
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
SOURCE = r'''
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "macos_credentials.m"
#ifndef BUILD_VERSION
#error BUILD_VERSION is required
#endif
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    const char *reference = "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const unsigned char fixture[] = "zerowork-owned-signing-fixture";
    int status = 0, matches = 0;
    if (!strcmp(argv[1], "seed")) {
        status = zw_credentials_add(argv[2], reference, fixture, sizeof(fixture) - 1);
    } else if (!strcmp(argv[1], "erase")) {
        status = zw_credentials_erase(argv[2]);
    } else if (!strcmp(argv[1], "read")) {
        unsigned char *data = NULL;
        size_t length = 0;
        status = zw_credentials_get(argv[2], reference, &data, &length);
        matches = !status && length == sizeof(fixture) - 1 && !memcmp(data, fixture, length);
        zw_credentials_free(data, length);
    } else return 2;
    printf("{\"build\":%d,\"pid\":%d,\"status\":%d,\"matches\":%s}\n",
           BUILD_VERSION, getpid(), status, matches ? "true" : "false");
    return 0;
}
'''


def run(args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(result.stdout.strip())
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    identity = run(['python3', str(ROOT / 'scripts/macos_signing.py'), 'identity'])
    service = 'com.zerowork.tests.signing-update.' + str(uuid.uuid4())
    report = {'service': service, 'identity': identity, 'uses_production_bridge': True,
              'authentication_ui': 'prohibited', 'started_epoch': time.time(), 'clients': {}}
    with tempfile.TemporaryDirectory(prefix='zerowork-update-test-') as directory:
        temp = Path(directory)
        source = temp / 'client.m'
        source.write_text(SOURCE)
        clients = {}
        for name, version, identifier in [('a', 1, 'com.zerowork.signing-test'),
                                           ('b', 2, 'com.zerowork.signing-test'),
                                           ('other', 2, 'com.zerowork.signing-test.other')]:
            executable = temp / name
            run(['/usr/bin/xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-DBUILD_VERSION=' + str(version),
                 '-I', str(ROOT / 'src/platform'), str(source), '-framework', 'Security',
                 '-framework', 'CoreFoundation', '-o', str(executable)])
            run(['/usr/bin/codesign', '--force', '--sign', identity, '--identifier', identifier, str(executable)])
            run(['/usr/bin/codesign', '--verify', '--strict', str(executable)])
            details = run(['/usr/bin/codesign', '-d', '-r-', '-vv', str(executable)])
            report['clients'][name] = {'sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
                                       'signature': details}
            clients[name] = executable
        requirement = report['clients']['a']['signature'].split('designated => ', 1)[1].splitlines()[0]
        run(['/usr/bin/codesign', '--verify', '-R', '=' + requirement, str(clients['b'])])
        report['b_satisfies_a_designated_requirement'] = True
        assert report['clients']['a']['sha256'] != report['clients']['b']['sha256']
        installed = temp / 'installed-client'
        def install(client):
            staged = temp / 'next-client'
            shutil.copy2(clients[client], staged)
            os.replace(staged, installed)
        def operation(client, action):
            executable = clients[client] if client == 'other' else installed
            return json.loads(run([str(executable), action, service]))
        install('a')
        report['same_installation_path'] = True
        try:
            report['seed_a'] = operation('a', 'seed')
            assert report['seed_a']['status'] == 0
            report['restart_a'] = operation('a', 'read')
            assert report['restart_a']['matches']
            install('b')
            report['update_b'] = operation('b', 'read')
            report['other_identity'] = operation('other', 'read')
            report['update_without_authorization'] = report['update_b']['status'] == 0 and report['update_b']['matches']
        finally:
            install('a')
            report['cleanup'] = operation('a', 'erase')
            report['finished_epoch'] = time.time()
            (args.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    if report['cleanup']['status'] != 0:
        raise SystemExit('Test-owned credential cleanup failed.')
    if report['other_identity']['status'] == 0:
        raise SystemExit('Unexpected access by a different application identity.')
    if not report['update_without_authorization']:
        raise SystemExit('Update read still requires authorization; self-signing alone did not pass.')


if __name__ == '__main__':
    main()
