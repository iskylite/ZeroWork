#!/usr/bin/env python3
"""Reject setter chains while allowing component mounting and view adapters."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
METHOD = re.compile(r'pub\s+fn\s+(\w+)\s*\(\s*self\s*:\s*\*?(?:const\s+)?(\w+Builder)\b([^{};]*)\{')


def violations(source):
    # Match multiline declarations as well as pointer receivers. Mount/view
    # adapters are not setters, but may never return another Builder chain.
    source = re.sub(r'//[^\n]*', '', source)
    for match in METHOD.finditer(source):
        name, builder, tail = match.groups()
        depth = 1
        end = None
        for i, char in enumerate(tail):
            if char == '(':
                depth += 1
            elif char == ')':
                depth -= 1
                if depth == 0:
                    end = i
                    break
        result = tail[end + 1:].strip() if end is not None else ''
        adapter = re.fullmatch(re.escape(builder[:-7]) + r'(?:Cells|Rows)\(.+\)', result)
        returns_builder = re.search(r'\b\w+Builder\b|@This\(\)', result) is not None
        mount = name in ('mount', 'mountResult', 'mountWithState', 'mountIn', 'mountBody', 'mountWithContext', 'viewMount', 'build')
        mount_result = mount and result.startswith('!') and result != '!void'
        if returns_builder or not (mount_result or (name in ('cells', 'rows') and adapter)):
            yield source.count('\n', 0, match.start()) + 1, name, builder


def self_test():
    allowed = [
        'pub fn viewMount(self: InputBuilder, scope: *Scope, cx: *Cx) !InputResult {',
        'pub fn cells(self: TableBuilder, ctx: anytype, comptime f: anytype) TableCells(@TypeOf(ctx), f) {',
        'pub fn rows(self: VirtualListBuilder, ctx: anytype, comptime f: anytype) VirtualListRows(@TypeOf(ctx), f) {',
    ]
    forbidden = [
        'pub fn color(self: ButtonBuilder, color: Color) ButtonBuilder {',
        'pub fn disabled(\n self: *ButtonBuilder,\n value: bool\n) void {',
        'pub fn viewMount(self: ButtonBuilder, value: bool) ButtonBuilder {',
        'pub fn cells(self: TableBuilder, value: bool) TableBuilder {',
        'pub fn arbitrary(self: InputBuilder) !InputResult {',
        'pub fn viewMount(self: InputBuilder, value: bool) void {',
        'pub fn mount(self: InputBuilder, value: bool) !void {',
        'pub fn cells(self: TableBuilder, ctx: anytype) WrongCells(ctx) {',
    ]
    for declaration in allowed:
        assert not list(violations(declaration)), declaration
    for declaration in forbidden:
        assert list(violations(declaration)), declaration
    print('component builder method mutation tests: PASS')


if __name__ == '__main__':
    self_test()
    bad = []
    for path in sorted((ROOT / 'src/ui/components').rglob('*.zig')):
        for line, name, builder in violations(path.read_text()):
            bad.append(f'{path.relative_to(ROOT)}:{line}: {builder}.{name}')
    if bad:
        print('\n'.join(bad), file=sys.stderr)
        sys.exit(1)
    print('component builder method contract: PASS')
