import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

// Native screenshot tests consume the same palette definitions as the app.
export const nativeThemeData = JSON.parse(execFileSync('python3', [
  fileURLToPath(new URL('./native_theme_data.py', import.meta.url)),
], {encoding: 'utf8'}));
