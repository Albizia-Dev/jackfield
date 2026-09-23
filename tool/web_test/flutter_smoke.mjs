import assert from 'node:assert/strict';
import { access, readFile } from 'node:fs/promises';
import path from 'node:path';

const [jsBuild, wasmBuild] = process.argv.slice(2);
if (!jsBuild || !wasmBuild) throw new Error('usage: node flutter_smoke.mjs <js-build> <wasm-build>');

async function exists(file) {
  try { await access(file); return true; } catch { return false; }
}

for (const [directory, mode] of [[jsBuild, 'javascript'], [wasmBuild, 'wasm']]) {
  const index = await readFile(path.join(directory, 'index.html'), 'utf8');
  assert.match(index, /jackfield_host_worker\.js/, `${mode} build should register the host worker`);
  assert.equal(await exists(path.join(directory, 'jackfield_host_worker.js')), true, `${mode} build should include host worker`);
  assert.equal(await exists(path.join(directory, 'assets/packages/jackfield/web/jackfield_worker.js')), true, `${mode} build should include worker asset`);
  assert.equal(await exists(path.join(directory, 'assets/packages/jackfield/web/jackfield_bridge.js')), true, `${mode} build should include bridge asset`);
  if (mode === 'javascript') {
    assert.equal(await exists(path.join(directory, 'main.dart.js')), true, 'JavaScript build should contain compiled Dart');
  } else {
    assert.equal(await exists(path.join(directory, 'main.dart.wasm')), true, 'Wasm build should contain compiled Wasm');
  }
}
process.stdout.write('JavaScript and Wasm Flutter web artifacts include Jackfield worker integration.\n');
