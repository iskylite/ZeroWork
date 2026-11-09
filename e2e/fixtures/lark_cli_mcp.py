#!/usr/bin/env python3
"""Live, read-only Feishu MCP acceptance fixture backed by an authorized CLI.

Not the official Lark OpenAPI MCP server. No credential export or app changes.
Use LARK_CLI to select the installed executable; credentials remain in lark-cli.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

CLI = os.environ.get('LARK_CLI', str(Path.home() / '.local/bin/lark-cli'))
TOOLS = [
    {'name': 'lark_identity', 'description': 'Read the current Feishu user identity through the existing CLI login.',
     'inputSchema': {'type': 'object', 'additionalProperties': False},
     'outputSchema': {'type': 'object', 'properties': {'ok': {'type': 'boolean'}}, 'required': ['ok']},
     'annotations': {'readOnlyHint': True}},
    {'name': 'lark_document_outline', 'description': 'Read only the first heading level of an explicitly selected existing Feishu document.',
     'inputSchema': {'type': 'object', 'properties': {'doc': {'type': 'string', 'minLength': 1}, 'max_depth': {'type': 'integer', 'minimum': 1, 'maximum': 2}}, 'required': ['doc', 'max_depth'], 'additionalProperties': False},
     'outputSchema': {'type': 'object', 'properties': {'ok': {'type': 'boolean'}}, 'required': ['ok']},
     'annotations': {'readOnlyHint': True}},
    {'name': 'lark_drive_search', 'description': 'Search a small page of the current user’s Feishu documents without changing them.',
     'inputSchema': {'type': 'object', 'properties': {
         'query': {'type': 'string', 'maxLength': 30},
         'limit': {'type': 'integer', 'minimum': 1, 'maximum': 20},
         'only_title': {'type': 'boolean'},
         'folder_tokens': {'anyOf': [{'type': 'array', 'items': {'type': 'string'}}, {'type': 'null'}]},
     }, 'required': ['query', 'limit'], 'additionalProperties': False},
     'outputSchema': {'type': 'object', 'properties': {'ok': {'type': 'boolean'}}, 'required': ['ok']},
     'annotations': {'readOnlyHint': True}},
]


def call(name, args):
    if name == 'lark_identity':
        if args:
            raise ValueError('Identity tool accepts no arguments')
        argv = [CLI, 'whoami', '--as', 'user']
    elif name == 'lark_document_outline':
        if set(args) != {'doc', 'max_depth'} or not isinstance(args['doc'], str) or type(args['max_depth']) is not int or not 1 <= args['max_depth'] <= 2:
            raise ValueError('Invalid outline parameters')
        argv = [CLI, 'docs', '+fetch', '--doc', args['doc'], '--scope', 'outline', '--max-depth', str(args['max_depth']), '--as', 'user']
    elif name == 'lark_drive_search':
        if (set(args) - {'query', 'limit', 'only_title', 'folder_tokens'} or
                not isinstance(args.get('query'), str) or len(args['query']) > 30 or
                type(args.get('limit')) is not int or not 1 <= args['limit'] <= 20):
            raise ValueError('Invalid search parameters')
        argv = [CLI, 'drive', '+search', '--as', 'user', '--query', args['query'], '--page-size', str(args['limit']), '--json']
        if args.get('only_title'):
            argv.append('--only-title')
        folders = args.get('folder_tokens')
        if folders is not None:
            if not isinstance(folders, list) or not all(isinstance(x, str) and ',' not in x for x in folders):
                raise ValueError('Invalid folder tokens')
            argv += ['--folder-tokens', ','.join(folders)]
    else:
        raise ValueError('Unknown read-only tool')
    env = dict(os.environ, LARKSUITE_CLI_NO_UPDATE_NOTIFIER='1', LARKSUITE_CLI_NO_SKILLS_NOTIFIER='1')
    process = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=90)
    raw = process.stdout if process.returncode == 0 else process.stderr
    try:
        data = json.loads(raw)
    except ValueError:
        data = {'message': 'CLI returned a non-JSON response', 'exit_code': process.returncode}
    if name == 'lark_identity' and process.returncode == 0:
        data = {'identity': data.get('identity'), 'tokenStatus': data.get('tokenStatus')}
    ok = process.returncode == 0 and data.get('ok', True)
    result = {'ok': bool(ok), 'identity': data.get('identity', 'user'), 'data': data}
    return {'content': [{'type': 'text', 'text': json.dumps(result, ensure_ascii=False)}], 'structuredContent': result, 'isError': not ok}


for line in sys.stdin:
    try:
        request = json.loads(line)
        method, rid, params = request.get('method'), request.get('id'), request.get('params', {})
        trace = os.environ.get('ZW_MCP_TRACE')
        if trace:
            fd = os.open(trace, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, 'a') as stream:
                stream.write(json.dumps({'method': method, 'tool': params.get('name')}) + '\n')
        if rid is None:
            continue
        if method == 'initialize':
            result = {'protocolVersion': '2025-11-25', 'capabilities': {'tools': {}},
                      'serverInfo': {'name': 'zerowork-live-lark-cli-test', 'version': '1.0.0'}}
        elif method == 'ping':
            result = {}
        elif method == 'tools/list':
            result = {'tools': TOOLS}
        elif method == 'tools/call':
            result = call(params['name'], params.get('arguments', {}))
        else:
            raise ValueError('Unsupported method')
        response = {'jsonrpc': '2.0', 'id': rid, 'result': result}
    except Exception as error:
        response = {'jsonrpc': '2.0', 'id': request.get('id') if 'request' in locals() else None,
                    'error': {'code': -32602, 'message': str(error)}}
    print(json.dumps(response, ensure_ascii=False), flush=True)
