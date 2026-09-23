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
  await dispatch(listeners, 'push', { data: { json: () => ({ version: 1, type: 'incoming', callId: 'call-1', eventId: 'event-1', caller: { id: 'u1', displayName: 'Alice' }, media: 'audio', expiresAt: new Date(Date.now() + 60000).toISOString() }) } });
  assert.equal((await records(scope.JackfieldDatabaseName, 'inbox')).length, 1);
  assert.equal((await scope.JackfieldWorker.pending()).length, 0);
  assert.equal(notifications[0].data.eventId, 'event-1');
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
  await dispatch(listeners, 'notificationclick', { action: 'answer', notification: { data: { callId: 'call-1', eventId: 'event-1' }, close: () => {} } });
  const events = await scope.JackfieldWorker.pending();
  assert.equal(events.length, 1);
  assert.equal(events[0].type, 'answer_requested');
});

test('callback outbox enforces its configured bound transactionally', async () => {
  const { scope, listeners } = harness();
  scope.JackfieldWorker.install();
  scope.fetch = async () => { throw new Error('offline'); };
  await scope.JackfieldWorker.configure({
    endpoint: 'https://callbacks.example.test/events',
    auth: { type: 'bearer', token: 'scoped-token' },
    timeToLiveMs: 60000,
    maxPendingEvents: 1,
  });
  const notification = { data: { callId: 'call-1' }, close: () => {} };
  await dispatch(listeners, 'notificationclick', { action: 'answer', notification });
  await assert.rejects(dispatch(listeners, 'notificationclick', { action: 'reject', notification }));
  assert.equal((await records(scope.JackfieldDatabaseName, 'outbox')).length, 1);
  assert.equal((await records(scope.JackfieldDatabaseName, 'inbox')).length, 1);
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
