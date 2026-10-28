#!/usr/bin/env python3
"""Receipt rejects stale sources, archives, configuration and build flags."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('receipt', Path(__file__).with_name('verify_ssh_deps.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.original_root, self.original_receipt = m.ROOT, m.RECEIPT
        m.ROOT = self.root; m.RECEIPT = self.root/'receipt.json'
        for path in (*m.ARTIFACTS, 'vendor/libssh2/src/example.c', 'scripts/build_ssh_deps.sh', 'scripts/verify_ssh_deps.py'):
            p = self.root/path; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('fixture\n')
        (self.root/'.gitignore').write_text('*.a\nlibssh2_config.h\n')
        self.assertEqual(self.run_check('--record'), 0)

    def tearDown(self):
        m.ROOT, m.RECEIPT = self.original_root, self.original_receipt
        self.temp.cleanup()

    def run_check(self, *args):
        with patch('sys.argv', ['verify_ssh_deps.py', *args]), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return m.main()

    def test_unchanged(self): self.assertEqual(self.run_check(), 0)
    def test_source(self):
        (self.root/'vendor/libssh2/src/example.c').write_text('changed')
        self.assertEqual(self.run_check(), 1)
    def test_archive(self):
        (self.root/m.ARTIFACTS[0]).write_text('stale')
        self.assertEqual(self.run_check(), 1)
    def test_config(self):
        (self.root/m.ARTIFACTS[2]).write_text('changed')
        self.assertEqual(self.run_check(), 1)
    def test_environment(self):
        with patch.dict(os.environ, {'CFLAGS': '-O0 -DTEST_CHANGED'}):
            self.assertEqual(self.run_check(), 1)
    def test_missing(self):
        m.RECEIPT.unlink()
        self.assertEqual(self.run_check(), 1)

if __name__ == '__main__': unittest.main()
