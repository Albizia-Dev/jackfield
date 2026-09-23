import assert from 'node:assert/strict';
import { access, readFile } from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const [jsBuild, wasmBuild] = process.argv.slice(2);
if (!jsBuild || !wasmBuild) throw new Error('usage: node flutter_smoke.mjs <js-build> <wasm-build>');

async function exists(file) {
  try { await access(file); return true; } catch { return false; }
}

for (const [directory, mode] of [[jsBuild, 'javascript'], [wasmBuild, 'wasm']]) {
  const index = await readFile(path.join(directory, 'index.html'), 'utf8');
  assert.match(index, /jackfield_host_worker\.js/, `${mode} build should register the host worker`);
  const bootstrapScript = [...index.matchAll(/<script>([\s\S]*?)<\/script>/g)]
    .map(match => match[1]).find(script => script.includes('JackfieldHostWorkerRegistration'));
  assert.ok(bootstrapScript, `${mode} build should contain host bootstrap`);
  for (const serviceWorker of [undefined, { register: async () => { throw new Error('registration rejected'); } }]) {
    const appended = [];
    const window = {};
    const document = { baseURI: 'https://example.test/app/', createElement: () => ({}), body: { appendChild: script => appended.push(script) } };
    vm.runInNewContext(bootstrapScript, { window, document, navigator: serviceWorker ? { serviceWorker } : {}, URL, Error });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(appended[0]?.src, 'flutter_bootstrap.js', `${mode} should bootstrap without a usable worker`);
  }
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
