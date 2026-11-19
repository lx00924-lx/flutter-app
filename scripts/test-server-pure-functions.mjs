import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';

// Load the two actual declarations from server.ts without importing the server
// (which would start listeners, timers, and persistence work).
const source = fs.readFileSync(new URL('../server.ts', import.meta.url), 'utf8');

function loadFunction(name) {
  const start = source.indexOf(`const ${name} =`);
  assert.notEqual(start, -1, `Could not find ${name} in server.ts`);
  const end = source.indexOf('\n};', start);
  assert.notEqual(end, -1, `Could not find end of ${name} in server.ts`);
  const declaration = source.slice(start, end + 3);
  const js = ts.transpile(declaration, { target: ts.ScriptTarget.ES2022 });
  return new Function(`${js}; return ${name};`)();
}

const mediaExtOf = loadFunction('mediaExtOf');
const safeScriptUrl = loadFunction('safeScriptUrl');
const cases = [
  ['mediaExtOf jpeg', () => assert.equal(mediaExtOf('data:image/jpeg;base64,xxx'), 'jpg')],
  ['mediaExtOf png', () => assert.equal(mediaExtOf('data:image/png;base64,xxx'), 'png')],
  ['mediaExtOf svg', () => assert.equal(mediaExtOf('data:image/svg+xml;base64,xxx'), 'svg')],
  ['mediaExtOf non-data URI', () => assert.equal(mediaExtOf('https://example.com/a.png'), 'bin')],
  ['mediaExtOf empty', () => assert.equal(mediaExtOf(''), 'bin')],
  // The current implementation keeps only the origin; revisit if SERVER_BASE_URL supports subpath deployments.
  ['safeScriptUrl https keeps origin only (drops path)', () => assert.equal(safeScriptUrl('https://example.com/a/'), 'https://example.com')],
  ['safeScriptUrl local HTTP', () => assert.equal(safeScriptUrl('http://127.0.0.1:3000'), 'http://127.0.0.1:3000')],
  ['safeScriptUrl quote injection', () => assert.equal(safeScriptUrl('https://a.com/"onmouseover=alert(1)'), null)],
  ['safeScriptUrl embedded space', () => assert.equal(safeScriptUrl('https://a.com/a b'), null)],
  ['safeScriptUrl javascript scheme', () => assert.equal(safeScriptUrl('javascript:alert(1)'), null)],
  ['safeScriptUrl ftp scheme', () => assert.equal(safeScriptUrl('ftp://a.com'), null)],
  ['safeScriptUrl empty', () => assert.equal(safeScriptUrl(''), null)],
];

let failed = 0;
for (const [name, run] of cases) {
  try {
    run();
    console.log(`PASS ${name}`);
  } catch (error) {
    failed++;
    console.error(`FAIL ${name}: ${error.message}`);
  }
}
console.log(`Result: ${cases.length - failed}/${cases.length} passed`);
if (failed) process.exitCode = 1;
