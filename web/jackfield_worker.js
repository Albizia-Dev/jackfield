(function (scope) {
  'use strict';
  const databaseName = scope.JackfieldDatabaseName || 'jackfield-v1';
  const stores = ['snapshots', 'inbox', 'outbox', 'receipts', 'meta'];
  let settings = { leaseMs: 45000, heartbeatMs: 15000 };

  function request(req) {
    return new Promise((resolve, reject) => {
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }

  function database() {
    return new Promise((resolve, reject) => {
      const req = scope.indexedDB.open(databaseName, 1);
      req.onupgradeneeded = () => {
        for (const name of stores) {
          if (!req.result.objectStoreNames.contains(name)) req.result.createObjectStore(name, { keyPath: 'id' });
        }
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }

  async function transaction(names, mode, work) {
    const db = await database();
    try {
      const tx = db.transaction(names, mode);
      const done = new Promise((resolve, reject) => {
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error || new Error('storage transaction aborted'));
      });
      try {
        const value = await work(tx);
        await done;
        return value;
      } catch (error) {
        try { tx.abort(); } catch (_) { /* transaction already finished */ }
        await done.catch(() => {});
        throw error;
      }
    } finally {
      db.close();
    }
  }

  async function pending() {
    return transaction(['inbox'], 'readonly', async tx =>
      (await request(tx.objectStore('inbox').getAll())).filter(item => !item.acknowledged && item.event).map(item => item.event));
  }

  async function claim(owner) {
    if (!owner) return false;
    return transaction(['meta'], 'readwrite', async tx => {
      const store = tx.objectStore('meta');
      const current = await request(store.get('owner'));
      const now = Date.now();
      if (current && current.owner !== owner && current.expiresAt > now) return false;
      store.put({ id: 'owner', owner, expiresAt: now + settings.leaseMs });
      return true;
    });
  }

  async function acknowledge(eventIds) {
    return transaction(['inbox'], 'readwrite', async tx => {
      const store = tx.objectStore('inbox');
      for (const id of eventIds) {
        const item = await request(store.get(id));
        if (item) store.put({ ...item, acknowledged: true });
      }
    });
  }

  function validPush(value) {
    return value && value.version === 1 && value.type === 'incoming' &&
      typeof value.callId === 'string' && value.callId.length > 0 &&
      typeof value.eventId === 'string' && value.eventId.length > 0 &&
      value.caller && typeof value.caller.displayName === 'string' &&
      ['audio', 'video'].includes(value.media) &&
      Number.isFinite(Date.parse(value.expiresAt)) && Date.parse(value.expiresAt) > Date.now();
  }

  async function publish(event) {
    const clients = await scope.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of clients) client.postMessage({ jackfield: 1, type: 'event', event });
  }

  async function persistEvent(event, snapshot, receipt) {
    await transaction(['snapshots', 'inbox', 'outbox', 'meta', 'receipts'], 'readwrite', async tx => {
      const inbox = tx.objectStore('inbox');
      if (await request(inbox.get(event.eventId))) return;
      inbox.put({ id: event.eventId, event, acknowledged: false });
      if (snapshot) tx.objectStore('snapshots').put({ id: snapshot.callId, ...snapshot });
      if (receipt) tx.objectStore('receipts').put(receipt);
      const config = await request(tx.objectStore('meta').get('callbackConfig'));
      if (config) {
        const existing = await request(tx.objectStore('outbox').getAll());
        if (existing.length >= config.maxPendingEvents) throw new Error('callback queue full');
        tx.objectStore('outbox').put({ id: event.eventId, event, attempt: 0, createdAt: Date.now(), nextAt: 0 });
      }
    });
    await publish(event);
  }

  async function push(event) {
    let payload;
    try { payload = event.data && event.data.json(); } catch (_) { payload = null; }
    if (!validPush(payload)) {
      await scope.registration.showNotification('Call unavailable', { body: 'Invitation could not be opened.' });
      return;
    }
    const snapshot = { callId: payload.callId, caller: payload.caller, media: payload.media, state: 'ringing', actionReceipts: [] };
    await transaction(['snapshots', 'inbox'], 'readwrite', async tx => {
      tx.objectStore('snapshots').put({ id: payload.callId, ...snapshot });
      tx.objectStore('inbox').put({ id: payload.eventId, invitation: payload, acknowledged: true });
    });
    await scope.registration.showNotification(payload.caller.displayName, {
      body: 'Incoming call', tag: payload.callId, data: { callId: payload.callId, eventId: payload.eventId },
      actions: [{ action: 'answer', title: 'Answer' }, { action: 'reject', title: 'Reject' }],
    });
    await drainOutbox();
  }

  async function click(event) {
    event.notification.close();
    const { callId } = event.notification.data || {};
    if (!callId || !['answer', 'reject'].includes(event.action)) return;
    const actionId = scope.crypto.randomUUID();
    const eventId = scope.crypto.randomUUID();
    const now = new Date();
    const ended = event.action === 'reject';
    const wire = ended
      ? { version: 1, type: 'ended', callId, eventId, sequence: 1, occurredAt: now.toISOString(), reason: 'rejected' }
      : { version: 1, type: 'answer_requested', callId, actionId, eventId, sequence: 1, occurredAt: now.toISOString(), deadline: new Date(now.getTime() + 30000).toISOString() };
    await persistEvent(wire, ended ? { callId, state: 'ended', media: 'audio', actionReceipts: [] } : null,
      ended ? null : { id: actionId, callId, deadline: Date.parse(wire.deadline), completed: false });
    await drainOutbox();
  }

  async function configure(callbacks) {
    if (callbacks) {
      const url = new URL(callbacks.endpoint);
      if (url.protocol !== 'https:' || url.username || url.password || url.hash ||
          callbacks.auth?.type !== 'bearer' || !callbacks.auth.token ||
          !Number.isSafeInteger(callbacks.timeToLiveMs) || callbacks.timeToLiveMs <= 0 ||
          !Number.isSafeInteger(callbacks.maxPendingEvents) || callbacks.maxPendingEvents <= 0) {
        throw new Error('invalid callback configuration');
      }
    }
    await transaction(['meta'], 'readwrite', async tx => {
      const store = tx.objectStore('meta');
      const old = await request(store.get('callbackConfig'));
      if (callbacks) store.put({ id: 'callbackConfig', ...callbacks });
      else store.delete('callbackConfig');
      if (!old || !callbacks || old.auth.token !== callbacks.auth.token) store.delete('authPaused');
    });
  }

  async function drainOutbox() {
    const state = await transaction(['meta', 'outbox'], 'readonly', async tx => ({
      config: await request(tx.objectStore('meta').get('callbackConfig')),
      paused: await request(tx.objectStore('meta').get('authPaused')),
      queue: await request(tx.objectStore('outbox').getAll()),
    }));
    if (!state.config || state.paused) return;
    const now = Date.now();
    const ordered = state.queue.sort((a, b) => a.createdAt - b.createdAt);
    const firstByCall = new Set();
    for (const item of ordered) {
      if (firstByCall.has(item.event.callId)) continue;
      firstByCall.add(item.event.callId);
      if (item.nextAt > now) continue;
      if (now - item.createdAt >= state.config.timeToLiveMs) {
        await transaction(['outbox'], 'readwrite', tx => tx.objectStore('outbox').delete(item.id));
        continue;
      }
      let status = 0;
      let retryAfter = 0;
      try {
        const response = await scope.fetch(state.config.endpoint, {
          method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${state.config.auth.token}`, 'Idempotency-Key': item.id },
          body: JSON.stringify(item.event),
        });
        status = response.status;
        const header = response.headers.get('Retry-After');
        retryAfter = header && /^\d+$/.test(header) ? Number(header) * 1000 : 0;
      } catch (_) { /* network failure is retryable */ }
      await transaction(['outbox', 'meta', 'receipts'], 'readwrite', async tx => {
        if (status >= 200 && status < 300 || status >= 400 && status < 500 && ![401, 403, 429].includes(status)) {
          tx.objectStore('outbox').delete(item.id);
          tx.objectStore('receipts').put({ id: item.id, httpStatus: status });
        } else if (status === 401 || status === 403) {
          tx.objectStore('meta').put({ id: 'authPaused', value: true });
        } else {
          const attempt = item.attempt + 1;
          const delay = Math.min(900000, retryAfter || 1000 * 2 ** Math.min(attempt - 1, 10));
          tx.objectStore('outbox').put({ ...item, attempt, nextAt: Date.now() + delay });
        }
      });
      if (status === 401 || status === 403) break;
    }
  }

  async function command(message) {
    if (message.version !== 1) throw new Error('unsupported version');
    switch (message.command) {
      case 'initialize': await configure(message.callbacks || null); return { status: 'success', value: null };
      case 'claim': return { status: 'success', value: await claim(message.owner) };
      case 'pending': return { status: 'success', value: await pending() };
      case 'acknowledge': await acknowledge(message.eventIds || []); return { status: 'success', value: null };
      case 'drain': await drainOutbox(); return { status: 'success', value: null };
      case 'reportIncoming': {
        const call = message.call;
        if (!call || !call.callId || !call.caller?.displayName || !['audio', 'video'].includes(call.media))
          return { status: 'failure', error: { code: 'protocolFailure' } };
        const snapshot = { callId: call.callId, state: 'ringing', media: call.media, caller: call.caller, actionReceipts: [] };
        await transaction(['snapshots'], 'readwrite', tx => tx.objectStore('snapshots').put({ id: call.callId, ...snapshot }));
        await scope.registration.showNotification(call.caller.displayName, { body: 'Incoming call', tag: call.callId, data: { callId: call.callId }, actions: [{ action: 'answer', title: 'Answer' }, { action: 'reject', title: 'Reject' }] });
        return { status: 'success', value: snapshot };
      }
      case 'end': {
        const snapshot = await transaction(['snapshots'], 'readwrite', async tx => {
          const store = tx.objectStore('snapshots');
          const current = await request(store.get(message.callId));
          if (!current) return null;
          const next = { ...current, state: 'ended' };
          store.put(next);
          return next;
        });
        if (!snapshot) return { status: 'failure', error: { code: 'invalidState' } };
        return { status: 'success', value: snapshot };
      }
      case 'completeAction': {
        const snapshot = await transaction(['snapshots', 'receipts'], 'readwrite', async tx => {
          const receiptStore = tx.objectStore('receipts');
          const receipt = await request(receiptStore.get(message.actionId));
          if (!receipt || Date.now() > receipt.deadline) return null;
          const store = tx.objectStore('snapshots');
          const current = await request(store.get(receipt.callId));
          if (!current) return null;
          const next = { ...current, state: message.succeeded ? 'active' : 'ended', actionId: message.actionId,
            actionReceipts: [...(current.actionReceipts || []), { actionId: message.actionId, succeeded: message.succeeded }] };
          store.put(next);
          receiptStore.put({ ...receipt, completed: true });
          return next;
        });
        return snapshot ? { status: 'success', value: null } : { status: 'failure', error: { code: 'deadlineExceeded' } };
      }
      default: return { status: 'failure', error: { code: 'unsupported' } };
    }
  }

  function install(options = {}) {
    settings = { leaseMs: options.leaseMs || 45000, heartbeatMs: options.heartbeatMs || 15000 };
    scope.addEventListener('push', event => event.waitUntil(push(event)));
    scope.addEventListener('notificationclick', event => event.waitUntil(click(event)));
    scope.addEventListener('message', event => {
      if (!event.data || event.data.jackfield !== 1 || !event.ports?.[0]) return;
      event.waitUntil(command(event.data).then(result => event.ports[0].postMessage({ version: 1, ...result }))
        .catch(() => event.ports[0].postMessage({ version: 1, status: 'failure', error: { code: 'platformFailure' } })));
    });
  }

  scope.JackfieldWorker = { install, pending, claim, acknowledge, configure, drainOutbox, command };
})(self);
