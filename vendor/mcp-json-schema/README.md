# MCP JSON Schema validator

Ajv 8.20.0 provides JSON Schema draft-07, 2019-09 and 2020-12 validation.
The embedded bundle runs in macOS JavaScriptCore. Production does not require
Node, npm, a network service or executable code from a skill/MCP server.
Schemas are passed as JSON values, not evaluated as JavaScript. Remote schema
references are never fetched. Standard formats are validated using ajv-formats 3.0.1, including the email, URI, date and date-time formats used by MCP elicitation.

To regenerate the checked-in bundle (Node is a development dependency only):

```sh
cd vendor/mcp-json-schema
npm ci --ignore-scripts --no-audit --no-fund
./node_modules/.bin/esbuild entry.js --bundle --minify --platform=browser --target=es2020 --outfile=../../src/ai/vendor/mcp_schema.js
```

Versions and integrity hashes are pinned in package-lock.json. Licenses for
Ajv and its bundled runtime dependencies are in licenses/. esbuild 0.28.2 is
used only to generate the bundle and is not shipped in the app.
