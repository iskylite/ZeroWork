#!/usr/bin/env bash
# Negative publication fixtures must fail without printing secret values.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import pathlib, subprocess, tempfile
script = pathlib.Path('scripts/check_public_source.sh').read_text()
required = ['LICENSE', 'LICENSING.md', 'templates/LICENSE', 'examples/LICENSE',
 'src/ui/icons_oss/LICENSE', 'vendor/unicode/LICENSE.txt', 'vendor/zls/LICENSE',
 'vendor/zls/PROVENANCE.md', 'vendor/zls/tests/build_system/zig017.py',
 'tools/fixtures/fonts/Lora-OFL.txt', 'tools/yix_lsp.zig', 'tests/yix/lsp/smoke.py']
with tempfile.TemporaryDirectory(prefix='zenit-public-contract-') as temp:
 root = pathlib.Path(temp)
 def fixture(name):
  directory = root / name
  (directory / 'scripts').mkdir(parents=True)
  (directory / 'scripts/check_public_source.sh').write_text(script)
  for path in required:
   file = directory / path
   file.parent.mkdir(parents=True, exist_ok=True)
   file.write_text('fixture\n')
  return directory
 def check(name, mutate, expected, git=False):
  directory = fixture(name)
  if git:
   subprocess.run(['git','init','-q',str(directory)],check=True)
   (directory/'.gitignore').write_text('zig-out/\n.env\n')
  mutate(directory)
  result = subprocess.run(['bash','scripts/check_public_source.sh'],cwd=directory,capture_output=True,text=True)
  assert (result.returncode==0)==expected, (name,result.stdout,result.stderr)
  assert 'A'*36 not in result.stdout+result.stderr, 'secret contents printed'
  print('PASS '+name)
 def write(directory, name, content='fixture\n'):
  file=directory/name;file.parent.mkdir(parents=True,exist_ok=True);file.write_text(content)
 check('clean archive',lambda d:None,True)
 check('missing ZLS license',lambda d:(d/'vendor/zls/LICENSE').unlink(),False)
 check('private icon pack',lambda d:write(d,'private/icons/a.svg'),False)
 check('internal audit',lambda d:write(d,'docs/reviews/findings.md'),False)
 check('calibration capture',lambda d:write(d,'scripts/glass_native_model/capture.json'),False)
 check('research notes',lambda d:write(d,'docs/research/glass.md'),False)
 check('material calibration',lambda d:write(d,'e2e/glass-material-calibrate.ts'),False)
 check('research report',lambda d:write(d,'e2e/glass-review-report.ts'),False)
 check('native comparison',lambda d:write(d,'e2e/native_liquid_glass.swift'),False)
 check('cache in archive',lambda d:write(d,'zig-pkg/dependency/build.zig'),False)
 check('symlink',lambda d:(d/'linked').symlink_to(d/'LICENSE'),False)
 check('credential',lambda d:write(d,'config.txt','gh'+'p_'+'A'*36),False)
 check('local absolute path',lambda d:write(d,'notes.txt','/Users/'+'developer/private/file'),False)
 check('ignored local build output',lambda d:write(d,'zig-out/bin/example.exe'),True,git=True)
 def staged_secret(d):
  write(d,'.env','gh'+'p_'+'A'*36)
  subprocess.run(['git','-C',str(d),'add','-f','.env'],check=True)
 check('force-staged secret',staged_secret,False,git=True)
 print('Public source contract: 15/15 PASS')
PY
