"""Run one Grok-only native production Client/Manager image acceptance.

Load the single explicit Grok model and endpoint from private production TOML.
Copy sources into a private temporary tree to bind the same production config;
never use an implicit gateway or a fallback model.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib

p = argparse.ArgumentParser()
p.add_argument('--config', required=True)
p.add_argument('--out', required=True)
a = p.parse_args()
root = Path(__file__).resolve().parent.parent
private = Path(a.config).resolve()
assert private.stat().st_mode & 0o077 == 0
config = tomllib.loads(private.read_text())
providers = config['ai']['providers']
assert len(providers) == 1 and len(providers[0]['models']) == 1
provider = providers[0]
model = provider['models'][0]['name']
assert model.startswith('grok/') and 'gpt' not in model.lower()
assert provider['endpoint'].endswith('/chat/completions')
assert 1 <= provider['models'][0]['image_token_reservation'] <= 131072
out = Path(a.out).resolve()
out.mkdir(parents=True, exist_ok=True)
assert not (out / 'result.json').exists()
with tempfile.TemporaryDirectory(prefix='zw-grok-native-') as d:
    tree = Path(d)
    os.chmod(tree, 0o700)
    shutil.copytree(root / 'src', tree / 'src')
    test = tree / 'src/ai/plugin_gateway_live_tests.zig'
    source = test.read_text()
    start = source.index('        var config = @import("provider_config.zig").defaults(.openai_compat);')
    end = source.index('        var binding:', start)
    source = source[:start] + '''        const config_path = env.get(env.ctx, "ZEROWORK_GROK_CONFIG") orelse return error.MissingProductionConfig;
        const config_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, ea, .limited(65536));
        const settings = try @import("../config/config.zig").Config.parseWithAllocator(ea, config_bytes);
        const config = try @import("provider_config.zig").fromSettings(settings.ai);
        try std.testing.expectEqualStrings(model_id, config.model);
        try std.testing.expect(config.image_token_reservation != null);
''' + source[end:]
    source = source.replace('try std.testing.expect(evidence.items.len >= 2);', 'try std.testing.expectEqual(@as(usize, 1), evidence.items.len);')
    test.write_text(source)
    (out / 'grok-native-test-source.zig').write_text(source)
    env = dict(os.environ, ZEROWORK_AI_GATEWAY_LIVE='1', ZEROWORK_AI_GATEWAY_KEY=provider['api_key'], ZEROWORK_AI_GATEWAY_MODEL=model, ZEROWORK_AI_GATEWAY_CHAT_ENDPOINT=provider['endpoint'], ZEROWORK_AI_GATEWAY_MODELS_ENDPOINT=provider['endpoint'].removesuffix('/chat/completions')+'/models', ZEROWORK_AI_GATEWAY_EVIDENCE=str(out / 'result.json'), ZEROWORK_GROK_MODEL=model, ZEROWORK_GROK_CONFIG=str(private))
    sdk = '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
    command = ['zig', 'test', str(tree / 'src/ai_gateway_runner.zig'), '--test-filter', 'API2 LIVE', '-lc', '-framework', 'CoreFoundation', '-framework', 'ImageIO', '-framework', 'CoreGraphics', '-F', sdk + '/System/Library/Frameworks', '-I', sdk + '/usr/include', '-L', sdk + '/usr/lib']
    with (out / 'native-client.log').open('w') as log:
        run = subprocess.run(command, cwd=root, env=env, stdout=log, stderr=log)
    (out / 'invocation.json').write_text(json.dumps({'model': model, 'production_config_loaded': True, 'endpoint': provider['endpoint'], 'image_token_reservation': provider['models'][0]['image_token_reservation'], 'reservation_meaning': 'conservative per-image admission estimate, not actual usage', 'route_count': 1, 'gpt_fallback': False, 'exit_code': run.returncode}, indent=2))
    print(json.dumps({'model': model, 'exit_code': run.returncode, 'evidence': str(out)}))
    raise SystemExit(run.returncode)
