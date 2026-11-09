// MCP input/output schemas default to JSON Schema 2020-12.
import Ajv2020 from 'ajv/dist/2020.js';
import Ajv2019 from 'ajv/dist/2019.js';
import Ajv07 from 'ajv';
import addFormats from 'ajv-formats';
const options = {strict:false, allErrors:false, validateFormats:true, addUsedSchema:false, ownProperties:true, logger:false};
const validators = [new Ajv2020(options), new Ajv2019(options), new Ajv07(options)];
for (const ajv of validators) addFormats(ajv);
const cache = new Map();
globalThis.zwMcpSchema = function(schemaText, instanceText) {
  try {
    let validate = cache.get(schemaText);
    if (!validate) {
      const schema = JSON.parse(schemaText);
      if (schema === null || typeof schema !== 'object' || Array.isArray(schema)) return -1;
      const dialect = schema.$schema || '';
      const ajv = /2019-09/.test(dialect) ? validators[1] : /draft-0[67]/.test(dialect) ? validators[2] : validators[0];
      validate = ajv.compile(schema);
      if (cache.size >= 128) cache.clear();
      cache.set(schemaText, validate);
    }
    return instanceText === null || validate(JSON.parse(instanceText)) ? 1 : 0;
  } catch (_) { return -1; }
};
