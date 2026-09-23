import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { indexedDB as fakeIndexedDB } from 'fake-indexeddb';

const source = await readFile(new URL('../../web/jackfield_worker.js', import.meta.url), 'utf8').catch(() => '');

function harness() {
  const listeners = new Map();
  const notifications = [];
  const clients = [];
  const scope = {
    JackfieldDatabaseName: `jackfield-test-${crypto.randomUUID()}`,
    indexedDB: fakeIndexedDB,
    crypto: globalThis.crypto,
    URL,
    Date,
    Promise,
    setTimeout,
    clearTimeout,
    fetch: async () => ({ status: 204, headers: { get: () => null } }),
    registration: { showNotification: async (title, options) => notifications.push({ title, ...options }) },
    clients: { matchAll: async () => clients, openWindow: async () => null },
    addEventListener: (name, listener) => listeners.set(name, listener),
  };
  scope.self = scope;
  vm.runInNewContext(source, scope);
  return { scope, listeners, notifications, clients };
}

const call = (overrides = {}) => ({
  version: 1, type: 'incoming', callId: 'call-1', eventId: 'event-1',
  installationId: 'installation-1', sessionId: 'session-1',
  caller: { id: 'u1', displayName: 'Alice' }, media: 'video',
  expiresAt: new Date(Date.now() + 60000).toISOString(), ...overrides,
});

async function pushCall(h, payload = call()) {
  await dispatch(h.listeners, 'push', { data: { json: () => payload } });
}

async function bind(h) {
  return h.scope.JackfieldWorker.command({ version: 1, command: 'bindPush', installationId: 'installation-1', sessionId: 'session-1' });
}

async function dispatch(listeners, name, fields) {
  const work = [];
  listeners.get(name)({ ...fields, waitUntil: promise => work.push(promise) });
  await Promise.all(work);
}

async function records(name, store) {
  const db = await new Promise((resolve, reject) => {
    const req = fakeIndexedDB.open(name);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  const values = await new Promise((resolve, reject) => {
    const req = db.transaction(store).objectStore(store).getAll();
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  db.close();
  return values;
}

test('push persists before notification and uses stable event identity', async () => {
  const { scope, listeners, notifications } = harness();
  scope.JackfieldWorker.install();
  await bind({scope});
  await dispatch(listeners, 'push', { data: { json: () => call() } });
  assert.equal((await records(scope.JackfieldDatabaseName, 'inbox')).length, 1);
  const lease = await scope.JackfieldWorker.claim('tab');
  assert.equal((await scope.JackfieldWorker.pending('tab', lease.token)).length, 0);
  assert.equal(notifications[0].data.eventId, 'event-1');
});

test('push rejects missing binding, wrong session, replay, stale call and ended call', async () => {
  const h = harness();
  h.scope.JackfieldWorker.install();
  await pushCall(h);
  assert.equal(h.notifications.at(-1).title, 'Call unavailable');
  await bind(h);
  await pushCall(h, call({ sessionId: 'other' }));
  assert.equal(h.notifications.length, 2);
  await pushCall(h);
  await pushCall(h);
  await pushCall(h, call({ eventId: 'event-2' }));
  assert.equal(h.notifications.length, 3);
  await h.scope.JackfieldWorker.command({ version: 1, command: 'end', callId: 'call-1' });
  await pushCall(h, call({ eventId: 'event-3' }));
  assert.equal(h.notifications.length, 3);
  assert.equal((await records(h.scope.JackfieldDatabaseName, 'snapshots'))[0].state, 'ended');
});

test('push requires caller identity and bounded future expiry', async () => {
  const h = harness();
  h.scope.JackfieldWorker.install();
  await bind(h);
  for (const payload of [call({ caller: { displayName: 'Alice' } }), call({ expiresAt: new Date(Date.now() + 86400000).toISOString() })]) {
    await pushCall(h, payload);
    assert.equal(h.notifications.at(-1).title, 'Call unavailable');
  }
  assert.equal((await records(h.scope.JackfieldDatabaseName, 'snapshots')).length, 0);
});

test('concurrent tabs elect one owner and permit takeover after expiry', async () => {
  const { scope } = harness();
  const [a, b] = await Promise.all([scope.JackfieldWorker.claim('a'), scope.JackfieldWorker.claim('b')]);
  assert.equal([a, b].filter(Boolean).length, 1);
  assert.equal(await scope.JackfieldWorker.claim(a ? 'b' : 'a'), false);
});

test('notification answer persists action before delivery', async () => {
  const { scope, listeners, clients } = harness();
  scope.JackfieldWorker.install();
  clients.push({ postMessage: () => {} });
  await scope.JackfieldWorker.command({ version: 1, command: 'reportIncoming', call: { callId: 'call-1', caller: { id: 'u1', displayName: 'Alice' }, media: 'audio' } });
  await dispatch(listeners, 'notificationclick', { action: 'answer', notification: { data: { callId: 'call-1', eventId: 'event-1' }, close: () => {} } });
  const lease = await scope.JackfieldWorker.claim('tab');
  const events = await scope.JackfieldWorker.pending('tab', lease.token);
  assert.equal(events.length, 1);
  assert.equal(events[0].type, 'answer_requested');
});

test('callback overflow retains Flutter event and action receipt', async () => {
  const { scope, listeners } = harness();
  scope.JackfieldWorker.install();
  scope.fetch = async () => { throw new Error('offline'); };
  await scope.JackfieldWorker.configure({
    endpoint: 'https://callbacks.example.test/events',
    auth: { type: 'bearer', token: 'scoped-token' },
    timeToLiveMs: 60000,
    maxPendingEvents: 1,
  });
  await scope.JackfieldWorker.command({ version: 1, command: 'reportIncoming', call: { callId: 'call-1', caller: { id: 'u1', displayName: 'Alice' }, media: 'audio' } });
  const notification = { data: { callId: 'call-1' }, close: () => {} };
  await dispatch(listeners, 'notificationclick', { action: 'answer', notification });
  await scope.JackfieldWorker.command({ version: 1, command: 'reportIncoming', call: { callId: 'call-2', caller: { id: 'u1', displayName: 'Alice' }, media: 'audio' } });
  await dispatch(listeners, 'notificationclick', { action: 'reject', notification: { data: { callId: 'call-2' }, close: () => {} } });
  assert.equal((await records(scope.JackfieldDatabaseName, 'outbox')).length, 1);
  assert.equal((await records(scope.JackfieldDatabaseName, 'inbox')).length, 2);
  assert.equal((await records(scope.JackfieldDatabaseName, 'snapshots')).find(s => s.callId === 'call-2').state, 'ended');
});

test('callback uses envelope, terminal redirect and occurredAt TTL', async () => {
  const h = harness();
  h.scope.JackfieldWorker.install();
  const requests = [];
  h.scope.fetch = async (_, options) => { requests.push(options); return { status: 302, headers: { get: () => null } }; };
  await h.scope.JackfieldWorker.configure({ endpoint: 'https://callbacks.example.test/events', auth: { type: 'bearer', token: 'token' }, timeToLiveMs: 60000, maxPendingEvents: 10 });
  await h.scope.JackfieldWorker.command({ version: 1, command: 'reportIncoming', call: { callId: 'call-1', caller: { id: 'u1', displayName: 'Alice' }, media: 'video' } });
  await dispatch(h.listeners, 'notificationclick', { action: 'answer', notification: { data: { callId: 'call-1' }, close() {} } });
  assert.equal(requests[0].redirect, 'error');
  assert.equal(JSON.parse(requests[0].body).event.type, 'answer_requested');
  assert.equal(JSON.parse(requests[0].body).version, 1);
  assert.equal((await records(h.scope.JackfieldDatabaseName, 'outbox'))[0].state, 'terminal');
});

test('lease requires token for pending and ACK and rotates on takeover', async () => {
  const h = harness();
  h.scope.JackfieldWorker.install({ leaseMs: 10 });
  await h.scope.JackfieldWorker.command({ version: 1, command: 'reportIncoming', call: { callId: 'call-1', caller: { id: 'u1', displayName: 'Alice' }, media: 'audio' } });
  await dispatch(h.listeners, 'notificationclick', { action: 'answer', notification: { data: { callId: 'call-1' }, close() {} } });
  const a = await h.scope.JackfieldWorker.command({ version: 1, command: 'claim', owner: 'a' });
  assert.equal(a.status, 'success');
  const unauthorized = await h.scope.JackfieldWorker.command({ version: 1, command: 'pending', owner: 'b', token: a.value.token });
  assert.equal(unauthorized.status, 'failure');
  const ok = await h.scope.JackfieldWorker.command({ version: 1, command: 'pending', owner: 'a', token: a.value.token });
  assert.equal(ok.value.length, 1);
  await new Promise(resolve => setTimeout(resolve, 15));
  const b = await h.scope.JackfieldWorker.command({ version: 1, command: 'claim', owner: 'b' });
  assert.equal(b.value.pending.length, 1);
  const stale = await h.scope.JackfieldWorker.command({ version: 1, command: 'acknowledge', owner: 'a', token: a.value.token, eventIds: [ok.value[0].eventId] });
  assert.equal(stale.status, 'failure');
});

test('answer completion is idempotent and preserves caller and media on reject', async () => {
  const h = harness();
  h.scope.JackfieldWorker.install();
  await h.scope.JackfieldWorker.command({ version: 1, command: 'reportIncoming', call: { callId: 'call-1', caller: { id: 'u1', displayName: 'Alice' }, media: 'video' } });
  await dispatch(h.listeners, 'notificationclick', { action: 'answer', notification: { data: { callId: 'call-1' }, close() {} } });
  const pending = await records(h.scope.JackfieldDatabaseName, 'snapshots');
  assert.equal(pending[0].state, 'connecting');
  assert.equal(pending[0].media, 'video');
  assert.ok(pending[0].actionDeadline);
  const answer = (await records(h.scope.JackfieldDatabaseName, 'receipts')).find(r => r.deadline);
  const command = { version: 1, command: 'completeAction', actionId: answer.id, succeeded: true };
  assert.equal((await h.scope.JackfieldWorker.command(command)).status, 'success');
  assert.equal((await h.scope.JackfieldWorker.command(command)).status, 'success');
  assert.equal((await records(h.scope.JackfieldDatabaseName, 'snapshots'))[0].actionReceipts.length, 1);
});

test('concurrent notification clicks produce one action', async () => {
  const h = harness();
  h.scope.JackfieldWorker.install();
  await h.scope.JackfieldWorker.command({ version: 1, command: 'reportIncoming', call: { callId: 'call-1', caller: { id: 'u1', displayName: 'Alice' }, media: 'audio' } });
  const click = action => dispatch(h.listeners, 'notificationclick', { action, notification: { data: { callId: 'call-1' }, close() {} } });
  await Promise.all([click('answer'), click('reject')]);
  assert.equal((await records(h.scope.JackfieldDatabaseName, 'inbox')).filter(r => r.event).length, 1);
});

test('concurrent drains claim once and preserve per-call ordering', async () => {
  const h = harness();
  h.scope.JackfieldWorker.install();
  const requests = [];
  let release;
  h.scope.fetch = async (_, options) => {
    requests.push(JSON.parse(options.body).event.sequence);
    await new Promise(resolve => { release = resolve; });
    return { status: 204, headers: { get: () => null } };
  };
  await h.scope.JackfieldWorker.configure({ endpoint: 'https://callbacks.example.test/events', auth: { type: 'bearer', token: 'token' }, timeToLiveMs: 60000, maxPendingEvents: 10 });
  await h.scope.JackfieldWorker.command({ version: 1, command: 'reportIncoming', call: { callId: 'call-1', caller: { id: 'u1', displayName: 'Alice' }, media: 'audio' } });
  const click = dispatch(h.listeners, 'notificationclick', { action: 'answer', notification: { data: { callId: 'call-1' }, close() {} } });
  while (requests.length === 0) await new Promise(resolve => setTimeout(resolve, 1));
  await h.scope.JackfieldWorker.drainOutbox();
  assert.deepEqual(requests, [1]);
  release();
  await click;
});

test('retry outcome and HTTP diagnostic are durable independently of Flutter inbox', async () => {
  const h = harness();
  h.scope.JackfieldWorker.install();
  h.scope.registration.sync = { register: async () => { throw new Error('unsupported'); } };
  h.scope.fetch = async () => ({ status: 503, headers: { get: name => name === 'Retry-After' ? '2' : null } });
  await h.scope.JackfieldWorker.configure({ endpoint: 'https://callbacks.example.test/events', auth: { type: 'bearer', token: 'token' }, timeToLiveMs: 60000, maxPendingEvents: 10 });
  await h.scope.JackfieldWorker.command({ version: 1, command: 'reportIncoming', call: { callId: 'call-1', caller: { id: 'u1', displayName: 'Alice' }, media: 'audio' } });
  await dispatch(h.listeners, 'notificationclick', { action: 'answer', notification: { data: { callId: 'call-1' }, close() {} } });
  const item = (await records(h.scope.JackfieldDatabaseName, 'outbox'))[0];
  assert.equal(item.state, 'pending');
  assert.equal(item.attempt, 1);
  assert.ok(item.nextAt > Date.now());
  assert.ok(item.expiresAt - Date.parse(item.event.occurredAt) === 60000);
  assert.equal((await records(h.scope.JackfieldDatabaseName, 'inbox')).filter(r => r.event).length, 1);
});

test('scheduler failure records HTTP diagnostic and keeps action receipt', async () => {
  const h = harness();
  h.scope.JackfieldWorker.install();
  h.scope.registration.sync = { register: async () => { throw new Error('scheduler unavailable'); } };
  await h.scope.JackfieldWorker.configure({ endpoint: 'https://callbacks.example.test/events', auth: { type: 'bearer', token: 'token' }, timeToLiveMs: 60000, maxPendingEvents: 10 });
  await h.scope.JackfieldWorker.command({ version: 1, command: 'reportIncoming', call: { callId: 'call-1', caller: { id: 'u1', displayName: 'Alice' }, media: 'audio' } });
  await dispatch(h.listeners, 'notificationclick', { action: 'answer', notification: { data: { callId: 'call-1' }, close() {} } });
  assert.equal((await records(h.scope.JackfieldDatabaseName, 'receipts')).filter(r => r.deadline).length, 1);
  assert.equal((await records(h.scope.JackfieldDatabaseName, 'inbox')).filter(r => r.event).length, 1);
  assert.equal((await records(h.scope.JackfieldDatabaseName, 'meta')).find(r => r.id === 'httpDiagnostic').code, 'schedulerFailure');
});

test('ended snapshot retains caller and media and cannot ring again', async () => {
  const h = harness();
  h.scope.JackfieldWorker.install();
  await bind(h);
  await pushCall(h);
  await h.scope.JackfieldWorker.command({ version: 1, command: 'end', callId: 'call-1' });
  await pushCall(h, call({ eventId: 'event-2' }));
  const snapshot = (await records(h.scope.JackfieldDatabaseName, 'snapshots'))[0];
  assert.equal(snapshot.state, 'ended');
  assert.equal(snapshot.media, 'video');
  assert.equal(snapshot.caller.id, 'u1');
  assert.equal(h.notifications.length, 1);
});

test('notification from a previous login session cannot create an action', async () => {
  const h = harness();
  h.scope.JackfieldWorker.install();
  await bind(h);
  await pushCall(h);
  await h.scope.JackfieldWorker.command({ version: 1, command: 'bindPush', installationId: 'installation-1', sessionId: 'session-2' });
  await dispatch(h.listeners, 'notificationclick', { action: 'answer', notification: { data: { callId: 'call-1' }, close() {} } });
  assert.equal((await records(h.scope.JackfieldDatabaseName, 'inbox')).filter(r => r.event).length, 0);
});

test('reportIncoming cannot revive an ended call', async () => {
  const h = harness();
  h.scope.JackfieldWorker.install();
  const message = { version: 1, command: 'reportIncoming', call: { callId: 'call-1', caller: { id: 'u1', displayName: 'Alice' }, media: 'video' } };
  await h.scope.JackfieldWorker.command(message);
  await h.scope.JackfieldWorker.command({ version: 1, command: 'end', callId: 'call-1' });
  const again = await h.scope.JackfieldWorker.command(message);
  assert.equal(again.status, 'failure');
  assert.equal((await records(h.scope.JackfieldDatabaseName, 'snapshots'))[0].state, 'ended');
  assert.equal(h.notifications.length, 1);
});

test('bridge refuses an unrelated worker registration', async () => {
  const bridgeSource = await readFile(new URL('../../web/jackfield_bridge.js', import.meta.url), 'utf8');
  const window = { crypto: { randomUUID: () => 'owner' } };
  const navigator = { serviceWorker: { addEventListener() {}, getRegistration: async () => ({ active: { postMessage() {} } }) } };
  vm.runInNewContext(bridgeSource, { window, navigator, URL, atob, MessageChannel: class {}, setTimeout, clearTimeout });
  await assert.rejects(window.JackfieldBridge.invoke(JSON.stringify({ command: 'initialize' })), /host worker registration unavailable/);
});

test('notification permission requests are available only through an explicit gesture entrypoint', async () => {
  const bridgeSource = await readFile(new URL('../../web/jackfield_bridge.js', import.meta.url), 'utf8');
  const requests = [];
  const window = {
    crypto: { randomUUID: () => 'owner' },
    Notification: { permission: 'default', requestPermission: () => { requests.push(true); return Promise.resolve('granted'); } },
  };
  const navigator = { serviceWorker: { addEventListener() {}, getRegistration: async () => null } };
  vm.runInNewContext(bridgeSource, { window, navigator, URL, atob, MessageChannel: class {}, setTimeout, clearTimeout });
  assert.equal(window.JackfieldBridge.permission(), 'default');
  assert.deepEqual(requests, []);
  await window.JackfieldBridge.requestPermissionFromGesture();
  assert.equal(requests.length, 1);
});

test('push subscription is opt-in and returns the provider endpoint', async () => {
  const bridgeSource = await readFile(new URL('../../web/jackfield_bridge.js', import.meta.url), 'utf8');
  const calls = [];
  const subscription = { endpoint: 'https://push.example.test/subscription' };
  const registration = { pushManager: {
    getSubscription: async () => null,
    subscribe: async options => { calls.push(options); return subscription; },
  } };
  const window = {
    crypto: { randomUUID: () => 'owner' },
    JackfieldHostWorkerRegistration: Promise.resolve({ ...registration, active: {} }),
    PushManager: class {},
    Notification: { permission: 'default', requestPermission: async () => 'granted' },
  };
  const navigator = { serviceWorker: { addEventListener() {}, getRegistration: async () => registration } };
  vm.runInNewContext(bridgeSource, { window, navigator, URL, atob, MessageChannel: class {}, setTimeout, clearTimeout });
  assert.equal(calls.length, 0);
  const endpoint = await window.JackfieldBridge.subscribePush('AQID');
  assert.equal(endpoint, subscription.endpoint);
  assert.deepEqual(calls[0].userVisibleOnly, true);
  assert.deepEqual(Array.from(calls[0].applicationServerKey), [1, 2, 3]);
});
