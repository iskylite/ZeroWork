"""Compose exported DOM snapshots; UI paint always comes from the HTML export."""
from pathlib import Path
from html import escape
import json
import re
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
OUT = Path(tempfile.gettempdir()) / 'zerowork-app-update-previews'
PALETTES = json.loads((ROOT.parent / 'theme-presets.json').read_text())['themes']
THEMES = ('dark', 'light', 'sauber')
FONT = 'Inter,-apple-system,BlinkMacSystemFont,PingFang SC,sans-serif'
NS = '{http://www.w3.org/2000/svg}'


def sheet(filename, title, rows):
    snapshots = {}
    for state, _ in rows:
        for theme in THEMES:
            raw = (OUT / f'{theme}-{state}.svg').read_text()
            document = ET.fromstring(raw)
            meta = json.loads(document.find(f'.//{NS}metadata').text)
            assert meta['theme'] == theme and meta['state'] == state
            snapshots[theme, state] = raw, meta['region']
    heights = [max(snapshots[t, s][1]['height'] for t in THEMES) + 64 for s, _ in rows]
    height = 92 + sum(heights) + 24 * (len(rows) - 1) + 36
    ink, muted = (PALETTES['light'][k] for k in ('--fg-1', '--fg-2'))
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="1712" height="{height}" viewBox="0 0 1712 {height}" role="img"><title>{escape(title)}</title><desc>同一 HTML 的三主题计算样式导出；任务、回执与恢复路径均为本地模拟。</desc><rect width="1712" height="{height}" fill="{PALETTES["light"]["--bg-app"]}"/>',
           f'<text x="28" y="40" font-family="{FONT}" font-size="24" font-weight="650" fill="{ink}">{escape(title)}</text>',
           f'<text x="28" y="67" font-family="{FONT}" font-size="13" fill="{muted}">共享主题变量与实际 DOM 布局渲染 · 可编辑 SVG · 本地模拟，不执行更新或恢复</text>']
    y = 92
    for (state, label), panel_height in zip(rows, heights):
        for column, theme in enumerate(THEMES):
            x = 24 + 560 * column
            raw, region = snapshots[theme, state]
            body = raw[raw.index('>') + 1:raw.rfind('</svg>')]
            prefix = f'{theme}-{state}-'
            body = re.sub(r'id="([^"]+)"', lambda m: f'id="{prefix}{m[1]}"', body)
            body = re.sub(r'url\(#([^\)]+)\)', lambda m: f'url(#{prefix}{m[1]})', body)
            palette = PALETTES[theme]
            out.append(f'<rect x="{x}" y="{y}" width="544" height="{panel_height}" rx="14" fill="{palette["--bg-app"]}"/><text x="{x+12}" y="{y+29}" font-family="{FONT}" font-size="14" font-weight="600" fill="{palette["--fg-1"]}">{theme.capitalize()} / {escape(label)}</text>')
            viewbox = ' '.join(str(region[k]) for k in ('x', 'y', 'width', 'height'))
            out.append(f'<svg x="{x+12}" y="{y+46}" width="{region["width"]}" height="{region["height"]}" viewBox="{viewbox}">{body}</svg>')
        y += panel_height + 24
    out.append('</svg>')
    result = '\n'.join(out)
    ET.fromstring(result)
    (OUT / filename).write_text(result)


if __name__ == '__main__':
    sheet('theme-comparison.svg', 'ZeroWork 0.3 · 结束任务并安装', [('confirm', '结束任务确认'), ('closing', '正在结束任务')])
    sheet('recovery-comparison.svg', 'ZeroWork 0.3 · 取消确认与失败恢复', [('cancel_pending', '等待取消确认'), ('restore_failed', '恢复失败'), ('incompatible_data', '数据已变更，禁止回旧版')])
    print('Generated two theme comparison SVGs from exported DOM regions.')
