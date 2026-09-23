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

  async function pending(owner, token, clientId) {
    return transaction(['meta', 'inbox'], 'readonly', async tx => {
      const lease = await request(tx.objectStore('meta').get('owner'));
      if (!lease || lease.owner !== owner || lease.token !== token || lease.expiresAt <= Date.now() || clientId && lease.clientId !== clientId) return null;
      return (await request(tx.objectStore('inbox').getAll())).filter(item => !item.acknowledged && item.event).map(item => item.event);
    });
  }

  async function claim(owner, clientId = owner) {
    if (!owner) return false;
    return transaction(['meta', 'inbox'], 'readwrite', async tx => {
      const store = tx.objectStore('meta');
      const current = await request(store.get('owner'));
      const now = Date.now();
      if (current && current.owner !== owner && current.expiresAt > now) return false;
      const renewing = current && current.owner === owner && current.clientId === clientId && current.expiresAt > now;
      const token = renewing ? current.token : scope.crypto.randomUUID();
      store.put({ id: 'owner', owner, clientId, token, expiresAt: now + settings.leaseMs });
      const replay = renewing ? [] :
        (await request(tx.objectStore('inbox').getAll())).filter(item => !item.acknowledged && item.event).map(item => item.event);
      return { token, pending: replay };
    });
  }

  async function acknowledge(owner, token, eventIds, clientId) {
    return transaction(['meta', 'inbox'], 'readwrite', async tx => {
      const lease = await request(tx.objectStore('meta').get('owner'));
      if (!lease || lease.owner !== owner || lease.token !== token || lease.expiresAt <= Date.now() || clientId && lease.clientId !== clientId) return false;
      const store = tx.objectStore('inbox');
      for (const id of eventIds) {
        const item = await request(store.get(id));
        if (item) store.put({ ...item, acknowledged: true });
      }
      return true;
    });
  }

  function validPush(value) {
    return value && value.version === 1 && value.type === 'incoming' &&
      typeof value.installationId === 'string' && value.installationId.length > 0 &&
      typeof value.sessionId === 'string' && value.sessionId.length > 0 &&
      typeof value.callId === 'string' && value.callId.length > 0 &&
      typeof value.eventId === 'string' && value.eventId.length > 0 &&
      value.caller && typeof value.caller.id === 'string' && value.caller.id.length > 0 &&
      typeof value.caller.displayName === 'string' && value.caller.displayName.length > 0 &&
      ['audio', 'video'].includes(value.media) &&
      Number.isFinite(Date.parse(value.expiresAt)) && Date.parse(value.expiresAt) > Date.now() &&
      Date.parse(value.expiresAt) - Date.now() <= 300000;
  }

  async function publish(event) {
    const clients = await scope.clients.matchAll({ type: 'window', includeUncontrolled: true });
    await transaction(['meta'], 'readonly', async tx => {
      const lease = await request(tx.objectStore('meta').get('owner'));
      if (!lease || lease.expiresAt <= Date.now()) return;
      const client = clients.find(candidate => candidate.id === lease.clientId);
      if (client) client.postMessage({ jackfield: 1, type: 'event', token: lease.token, event });
    });
  }

  async function persistEvent(event, snapshot, receipt) {
    const persisted = await transaction(['snapshots', 'inbox', 'receipts', 'meta', 'outbox'], 'readwrite', async tx => {
      const inbox = tx.objectStore('inbox');
      if (await request(inbox.get(event.eventId))) return false;
      if (snapshot) {
        const previous = await request(tx.objectStore('snapshots').get(event.callId));
        if (!previous || previous.state !== 'ringing') return false;
        if (previous.installationId) {
          const binding = await request(tx.objectStore('meta').get('pushBinding'));
          if (!binding || binding.installationId !== previous.installationId || binding.sessionId !== previous.sessionId) return false;
        }
      }
      inbox.put({ id: event.eventId, event, acknowledged: false });
      if (snapshot) tx.objectStore('snapshots').put({ id: snapshot.callId, ...snapshot });
      if (receipt) tx.objectStore('receipts').put(receipt);
      const meta = tx.objectStore('meta');
      const config = await request(meta.get('callbackConfig'));
      if (!config) return { admitted: false };
      const existing = await request(tx.objectStore('outbox').getAll());
      if (existing.filter(item => item.state === 'pending' || item.state === 'sending').length >= config.maxPendingEvents) {
        meta.put({ id: 'httpDiagnostic', code: 'queueFull', eventId: event.eventId });
        return { admitted: false };
      }
      tx.objectStore('outbox').put({ id: event.eventId, event, state: 'pending', attempt: 0, nextAt: 0,
        expiresAt: Date.parse(event.occurredAt) + config.timeToLiveMs });
      return { admitted: true };
    });
    if (!persisted) return;
    try { await publish(event); }
    finally { if (persisted.admitted) await scheduleOutbox(); }
  }

  async function diagnostic(code, eventId) {
    try { await transaction(['meta'], 'readwrite', tx => tx.objectStore('meta').put({ id: 'httpDiagnostic', code, eventId })); } catch (_) { /* Flutter event remains durable */ }
  }

  async function scheduleOutbox() {
    try {
      const dueAt = await transaction(['meta', 'outbox'], 'readwrite', async tx => {
        const meta = tx.objectStore('meta');
        if (!await request(meta.get('callbackConfig')) || await request(meta.get('authPaused'))) return null;
        const queued = (await request(tx.objectStore('outbox').getAll())).filter(item => ['pending', 'sending'].includes(item.state));
        if (!queued.length) {
          meta.delete('nextHttpAt');
          return null;
        }
        const earliest = Math.min(...queued.map(item => Math.min(item.state === 'sending' ? item.claimUntil : item.nextAt, item.expiresAt)));
        meta.put({ id: 'nextHttpAt', value: earliest });
        return earliest;
      });
      if (dueAt === null) return;
      try { await scope.registration.sync?.register('jackfield-outbox'); }
      catch (_) { await diagnostic('schedulerFailure', ''); }
      try { await scope.registration.periodicSync?.register('jackfield-outbox', { minInterval: 900000 }); }
      catch (_) { /* one-shot Sync and a live tab may still drain */ }
    } catch (_) { await diagnostic('schedulerFailure', ''); }
  }

  async function push(event) {
    let payload;
    try { payload = event.data && event.data.json(); } catch (_) { payload = null; }
    if (!validPush(payload)) {
      await scope.registration.showNotification('Call unavailable', { body: 'Invitation could not be opened.' });
      return;
    }
    const accepted = await transaction(['meta', 'snapshots', 'inbox'], 'readwrite', async tx => {
      const binding = await request(tx.objectStore('meta').get('pushBinding'));
      if (!binding || binding.installationId !== payload.installationId || binding.sessionId !== payload.sessionId) return 'binding';
      const snapshots = tx.objectStore('snapshots');
      const inbox = tx.objectStore('inbox');
      if (await request(inbox.get(payload.eventId))) return 'duplicate';
      if (await request(snapshots.get(payload.callId))) return 'duplicate';
      snapshots.put({ id: payload.callId, callId: payload.callId, caller: payload.caller, media: payload.media,
        installationId: payload.installationId, sessionId: payload.sessionId,
        state: 'ringing', sequence: 0, actionReceipts: [] });
      inbox.put({ id: payload.eventId, invitation: payload, acknowledged: true });
      return 'accepted';
    });
    if (accepted === 'binding') {
      await scope.registration.showNotification('Call unavailable', { body: 'Invitation could not be opened.' });
      return;
    }
    if (accepted !== 'accepted') return;
    await scope.registration.showNotification(payload.caller.displayName, {
      body: 'Incoming call', tag: payload.callId, data: { callId: payload.callId, eventId: payload.eventId },
      actions: [{ action: 'answer', title: 'Answer' }, { action: 'reject', title: 'Reject' }],
    });
    await safeDrain();
  }

  async function click(event) {
    event.notification.close();
    const { callId } = event.notification.data || {};
    if (!callId || !['answer', 'reject'].includes(event.action)) return;
    const current = await transaction(['snapshots'], 'readonly', async tx => request(tx.objectStore('snapshots').get(callId)));
    if (!current || current.state !== 'ringing') return;
    if (current.installationId) {
      const binding = await transaction(['meta'], 'readonly', async tx => request(tx.objectStore('meta').get('pushBinding')));
      if (!binding || binding.installationId !== current.installationId || binding.sessionId !== current.sessionId) return;
    }
    const actionId = scope.crypto.randomUUID();
    const eventId = scope.crypto.randomUUID();
    const now = new Date();
    const ended = event.action === 'reject';
    const wire = ended
      ? { version: 1, type: 'ended', callId, eventId, sequence: (current.sequence || 0) + 1, occurredAt: now.toISOString(), reason: 'rejected' }
      : { version: 1, type: 'answer_requested', callId, actionId, eventId, sequence: (current.sequence || 0) + 1, occurredAt: now.toISOString(), deadline: new Date(now.getTime() + 30000).toISOString() };
    await persistEvent(wire, { ...current, state: ended ? 'ended' : 'connecting', sequence: wire.sequence,
      ...(!ended ? { actionId, actionDeadline: wire.deadline } : {}) },
      ended ? null : { id: actionId, callId, deadline: Date.parse(wire.deadline), completed: false });
    await safeDrain();
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
    await scheduleOutbox();
  }

  async function drainOutbox() {
    for (;;) {
      const job = await transaction(['meta', 'outbox'], 'readwrite', async tx => {
        const meta = tx.objectStore('meta');
        const config = await request(meta.get('callbackConfig'));
        if (!config || await request(meta.get('authPaused'))) return { skip: true };
        const queue = (await request(tx.objectStore('outbox').getAll()))
          .filter(item => item.state === 'pending' || item.state === 'sending')
          .sort((a, b) => a.event.callId.localeCompare(b.event.callId) || a.event.sequence - b.event.sequence);
        const now = Date.now();
        const seen = new Set();
        for (const item of queue) {
          if (seen.has(item.event.callId)) continue;
          if (now >= item.expiresAt) {
            tx.objectStore('outbox').put({ ...item, state: 'terminal', outcome: 'expired', completedAt: now });
            continue;
          }
          seen.add(item.event.callId);
          if (item.state === 'sending') {
            if (item.claimUntil > now) continue;
          } else if (item.nextAt > now) continue;
          const token = scope.crypto.randomUUID();
          const claimed = { ...item, state: 'sending', claimToken: token, claimUntil: now + 30000 };
          tx.objectStore('outbox').put(claimed);
          return { item: claimed, config };
        }
        return { waiting: true };
      });
      if (job.skip) return;
      if (job.waiting) { await scheduleOutbox(); return; }
      const { item, config } = job;
      let status = 0;
      let retryAfter = 0;
      try {
        const response = await scope.fetch(config.endpoint, {
          method: 'POST', redirect: 'manual',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${config.auth.token}`, 'Idempotency-Key': item.id },
          body: JSON.stringify({ version: 1, event: item.event }),
        });
        status = response.type === 'opaqueredirect' ? 302 : response.status;
        const header = response.headers?.get('Retry-After');
        if (header) {
          const parsed = /^\d+$/.test(header) ? Number(header) * 1000 : Date.parse(header) - Date.now();
          if (Number.isFinite(parsed) && parsed > 0) retryAfter = parsed;
        }
      } catch (_) { /* network failure is retryable */ }
      await transaction(['outbox', 'meta'], 'readwrite', async tx => {
        const outbox = tx.objectStore('outbox');
        const current = await request(outbox.get(item.id));
        if (!current || current.claimToken !== item.claimToken || current.state !== 'sending') return;
        const now = Date.now();
        const attempt = current.attempt + 1;
        if (status >= 200 && status < 300) {
          outbox.put({ ...current, state: 'delivered', attempt, httpStatus: status, completedAt: now });
        } else if (status === 401 || status === 403) {
          tx.objectStore('meta').put({ id: 'authPaused', value: true });
          outbox.put({ ...current, state: 'pending', attempt, httpStatus: status, nextAt: now });
        } else if (now >= current.expiresAt || status >= 300 && status < 500 && status !== 429) {
          outbox.put({ ...current, state: 'terminal', attempt, httpStatus: status, outcome: now >= current.expiresAt ? 'expired' : 'httpError', completedAt: now });
        } else {
          const base = retryAfter || Math.min(900000, 1000 * 2 ** Math.min(attempt - 1, 10));
          const delay = Math.min(900000, Math.round(base * (0.8 + Math.random() * 0.2)));
          outbox.put({ ...current, state: 'pending', attempt, httpStatus: status, nextAt: Math.min(now + delay, current.expiresAt) });
        }
      });
      if (status === 401 || status === 403) return;
      if (status === 0 || status === 429 || status >= 500) {
        await scheduleOutbox();
        return;
      }
    }
  }

  async function safeDrain() {
    try { await drainOutbox(); } catch (_) { await diagnostic('deliveryFailure', ''); }
  }

  async function command(message, clientId) {
    if (message.version !== 1) throw new Error('unsupported version');
    switch (message.command) {
      case 'initialize': await configure(message.callbacks || null); return { status: 'success', value: null };
      case 'claim': return { status: 'success', value: await claim(message.owner, clientId || message.owner) };
      case 'pending': {
        const events = await pending(message.owner, message.token, clientId);
        return events ? { status: 'success', value: events } : { status: 'failure', error: { code: 'invalidState' } };
      }
      case 'acknowledge': return await acknowledge(message.owner, message.token, message.eventIds || [], clientId)
        ? { status: 'success', value: null } : { status: 'failure', error: { code: 'invalidState' } };
      case 'bindPush': {
        if (!message.installationId || !message.sessionId) return { status: 'failure', error: { code: 'protocolFailure' } };
        await transaction(['meta'], 'readwrite', tx => tx.objectStore('meta').put({ id: 'pushBinding', installationId: message.installationId, sessionId: message.sessionId }));
        return { status: 'success', value: null };
      }
      case 'drain': await safeDrain(); return { status: 'success', value: null };
      case 'diagnostics': {
        const value = await transaction(['meta', 'outbox', 'inbox'], 'readonly', async tx => ({
          httpDiagnostic: await request(tx.objectStore('meta').get('httpDiagnostic')),
          authPaused: !!(await request(tx.objectStore('meta').get('authPaused'))),
          pendingHttpEvents: (await request(tx.objectStore('outbox').getAll())).filter(item => ['pending', 'sending'].includes(item.state)).length,
          pendingFlutterEvents: (await request(tx.objectStore('inbox').getAll())).filter(item => item.event && !item.acknowledged).length,
        }));
        return { status: 'success', value };
      }
      case 'reportIncoming': {
        const call = message.call;
        if (!call || !call.callId || !call.caller?.id || !call.caller.displayName || !['audio', 'video'].includes(call.media))
          return { status: 'failure', error: { code: 'protocolFailure' } };
        const snapshot = { callId: call.callId, state: 'ringing', media: call.media, caller: call.caller, actionReceipts: [] };
        const created = await transaction(['snapshots'], 'readwrite', async tx => {
          const store = tx.objectStore('snapshots');
          if (await request(store.get(call.callId))) return false;
          store.put({ id: call.callId, ...snapshot, sequence: 0 });
          return true;
        });
        if (!created) return { status: 'failure', error: { code: 'invalidState' } };
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
          if (!receipt) return null;
          const store = tx.objectStore('snapshots');
          const current = await request(store.get(receipt.callId));
          if (!current) return null;
          if (receipt.completed) return current;
          if (Date.now() > receipt.deadline || current.state !== 'connecting' || current.actionId !== message.actionId) return null;
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
    const onOutboxSync = event => {
      if (event.tag === 'jackfield-outbox') event.waitUntil(safeDrain());
    };
    scope.addEventListener('sync', onOutboxSync);
    scope.addEventListener('periodicsync', onOutboxSync);
    scope.addEventListener('message', event => {
      if (!event.data || event.data.jackfield !== 1 || !event.ports?.[0]) return;
      event.waitUntil(command(event.data, event.source?.id).then(result => event.ports[0].postMessage({ version: 1, ...result }))
        .catch(() => event.ports[0].postMessage({ version: 1, status: 'failure', error: { code: 'platformFailure' } })));
    });
  }

  scope.JackfieldWorker = { install, pending, claim, acknowledge, configure, drainOutbox, command };
})(self);
