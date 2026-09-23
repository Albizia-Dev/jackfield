(function (scope) {
  'use strict';
  const databaseName = scope.JackfieldDatabaseName || 'jackfield-v1';
  const stores = ['snapshots', 'inbox', 'outbox', 'receipts', 'meta'];
  let settings = { leaseMs: 45000, heartbeatMs: 15000 };
  let deadlineTimer = null;
  const presentingCalls = new Set();
  const endingPresentations = new Set();

  function configFingerprint(config) {
    return config && JSON.stringify([config.endpoint, config.auth?.type, config.auth?.token,
      config.timeToLiveMs, config.maxPendingEvents]);
  }

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

  function orderedEvents(items) {
    return items.filter(item => !item.acknowledged && item.event).map(item => item.event)
      .sort((a, b) => a.callId.localeCompare(b.callId) || a.sequence - b.sequence || a.eventId.localeCompare(b.eventId));
  }

  async function pending(owner, token, clientId) {
    return transaction(['meta', 'inbox'], 'readonly', async tx => {
      const lease = await request(tx.objectStore('meta').get('owner'));
      if (!lease || lease.owner !== owner || lease.token !== token || lease.expiresAt <= Date.now() || clientId && lease.clientId !== clientId) return null;
      return orderedEvents(await request(tx.objectStore('inbox').getAll()));
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
      const replay = renewing ? [] : orderedEvents(await request(tx.objectStore('inbox').getAll()));
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
      return { admitted: await admitCallback(tx, event) };
    });
    if (!persisted) return;
    try { await publish(event); }
    finally { if (persisted.admitted) await scheduleOutbox(); }
  }

  async function admitCallback(tx, event) {
    const meta = tx.objectStore('meta');
    const config = await request(meta.get('callbackConfig'));
    if (!config) return false;
    const existing = await request(tx.objectStore('outbox').getAll());
    if (existing.filter(item => item.state === 'pending' || item.state === 'sending').length >= config.maxPendingEvents) {
      meta.put({ id: 'httpDiagnostic', code: 'queueFull', eventId: event.eventId });
      return false;
    }
    tx.objectStore('outbox').put({ id: event.eventId, event, state: 'pending', attempt: 0, nextAt: 0,
      expiresAt: Date.parse(event.occurredAt) + config.timeToLiveMs });
    return true;
  }

  async function closeCallNotifications(callId) {
    const notifications = await scope.registration.getNotifications?.({ tag: callId }) || [];
    for (const notification of notifications) {
      if (notification.tag === callId) notification.close();
    }
  }

  async function markPresentationFailed(callId) {
    await transaction(['snapshots'], 'readwrite', async tx => {
      const store = tx.objectStore('snapshots');
      const current = await request(store.get(callId));
      if (current?.state === 'presenting') store.put({ ...current, state: 'presentationFailed' });
    });
  }

  async function showCallNotification(callId, title, options) {
    try { await scope.registration.showNotification(title, options); }
    catch (error) {
      await markPresentationFailed(callId);
      throw error;
    }
    try {
      const state = await transaction(['snapshots'], 'readwrite', async tx => {
        const store = tx.objectStore('snapshots');
        const current = await request(store.get(callId));
        if (current?.state === 'presenting') {
          if (endingPresentations.has(callId)) {
            store.put({ ...current, state: 'presentationFailed' });
            return 'presentationFailed';
          }
          store.put({ ...current, state: 'ringing' });
          return 'ringing';
        }
        return current?.state;
      });
      if (state === 'ringing') return true;
      await closeCallNotifications(callId);
      return false;
    } catch (error) {
      try { await closeCallNotifications(callId); }
      finally { await markPresentationFailed(callId).catch(() => {}); }
      throw error;
    }
  }

  async function terminalize(callId, reason, expectedActionId) {
    if (presentingCalls.has(callId)) endingPresentations.add(callId);
    let result;
    try {
      result = await transaction(['snapshots', 'inbox', 'outbox', 'meta', 'receipts'], 'readwrite', async tx => {
        const snapshots = tx.objectStore('snapshots');
        const current = await request(snapshots.get(callId));
        if (!current) return null;
        if (current.state === 'ended' || current.state === 'failed') return { snapshot: current };
        if (expectedActionId && (current.state !== 'connecting' || current.actionId !== expectedActionId)) return { snapshot: current };
        const event = { version: 1, type: 'ended', callId, eventId: scope.crypto.randomUUID(),
          sequence: (current.sequence || 0) + 1, occurredAt: new Date().toISOString(), reason };
        const snapshot = { ...current, state: reason === 'failed' ? 'failed' : 'ended', sequence: event.sequence };
        snapshots.put(snapshot);
        if (expectedActionId) {
          const receipts = tx.objectStore('receipts');
          const receipt = await request(receipts.get(expectedActionId));
          if (receipt) receipts.put({ ...receipt, expired: true });
        }
        tx.objectStore('inbox').put({ id: event.eventId, event, acknowledged: false });
        return { snapshot, event, admitted: await admitCallback(tx, event) };
      });
      if (result?.event) {
        try { await publish(result.event); }
        catch (_) { await diagnostic('publishFailure', result.event.eventId); }
        if (result.admitted) await scheduleOutbox();
      }
    } finally {
      await closeCallNotifications(callId);
    }
    if (result?.event) await safeDrain();
    return result?.snapshot || null;
  }

  async function scheduleDeadlineRecovery() {
    if (deadlineTimer !== null) scope.clearTimeout(deadlineTimer);
    deadlineTimer = null;
    const nextAt = await transaction(['snapshots', 'receipts'], 'readonly', async tx => {
      const snapshots = tx.objectStore('snapshots');
      const receipts = await request(tx.objectStore('receipts').getAll());
      let earliest = null;
      for (const receipt of receipts) {
        if (receipt.completed || receipt.expired || !Number.isFinite(receipt.deadline)) continue;
        const snapshot = await request(snapshots.get(receipt.callId));
        if (snapshot?.state !== 'connecting' || snapshot.actionId !== receipt.id) continue;
        earliest = earliest === null ? receipt.deadline : Math.min(earliest, receipt.deadline);
      }
      return earliest;
    });
    if (nextAt === null) return;
    deadlineTimer = scope.setTimeout(() => {
      deadlineTimer = null;
      void recoverDeadlines().catch(() => diagnostic('deadlineRecoveryFailure', ''));
    },
      Math.max(0, nextAt - Date.now()));
    deadlineTimer?.unref?.();
    try { await scope.registration.periodicSync?.register('jackfield-deadline', { minInterval: 900000 }); }
    catch (_) { /* periodic sync is optional */ }
  }

  async function recoverDeadlines() {
    const expired = await transaction(['receipts'], 'readonly', async tx =>
      (await request(tx.objectStore('receipts').getAll()))
        .filter(receipt => !receipt.completed && !receipt.expired && Number.isFinite(receipt.deadline) && receipt.deadline <= Date.now()));
    for (const receipt of expired) await terminalize(receipt.callId, 'failed', receipt.id);
    await scheduleDeadlineRecovery();
  }

  async function reconcilePresentations() {
    const presenting = await transaction(['snapshots'], 'readonly', async tx =>
      (await request(tx.objectStore('snapshots').getAll()))
        .filter(snapshot => snapshot.state === 'presenting' && !presentingCalls.has(snapshot.callId)));
    if (!presenting.length) return;
    const visible = await scope.registration.getNotifications?.() || [];
    for (const snapshot of presenting) {
      const shown = visible.some(notification => notification.tag === snapshot.callId);
      await transaction(['snapshots'], 'readwrite', async tx => {
        const store = tx.objectStore('snapshots');
        const current = await request(store.get(snapshot.callId));
        if (current?.state === 'presenting' && !presentingCalls.has(snapshot.callId))
          store.put({ ...current, state: shown ? 'ringing' : 'presentationFailed' });
      });
    }
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
    await reconcilePresentations();
    if (presentingCalls.has(payload.callId)) return;
    presentingCalls.add(payload.callId);
    try {
      const accepted = await transaction(['meta', 'snapshots', 'inbox'], 'readwrite', async tx => {
        const binding = await request(tx.objectStore('meta').get('pushBinding'));
        if (!binding || binding.installationId !== payload.installationId || binding.sessionId !== payload.sessionId) return 'binding';
        const snapshots = tx.objectStore('snapshots');
        const inbox = tx.objectStore('inbox');
        const prior = await request(snapshots.get(payload.callId));
        const invitation = await request(inbox.get(payload.eventId));
        if (prior) {
          if (prior.state !== 'presentationFailed' || invitation?.invitation?.eventId !== payload.eventId ||
              prior.installationId !== payload.installationId || prior.sessionId !== payload.sessionId ||
              prior.caller?.id !== payload.caller.id || prior.media !== payload.media) return 'duplicate';
          snapshots.put({ ...prior, state: 'presenting' });
          return 'accepted';
        }
        if (invitation) return 'duplicate';
        snapshots.put({ id: payload.callId, callId: payload.callId, caller: payload.caller, media: payload.media,
          installationId: payload.installationId, sessionId: payload.sessionId,
          state: 'presenting', sequence: 0, actionReceipts: [] });
        inbox.put({ id: payload.eventId, invitation: payload, acknowledged: true });
        return 'accepted';
      });
      if (accepted === 'binding') {
        await scope.registration.showNotification('Call unavailable', { body: 'Invitation could not be opened.' });
        return;
      }
      if (accepted !== 'accepted') return;
      const shown = await showCallNotification(payload.callId, payload.caller.displayName, {
        body: 'Incoming call', tag: payload.callId, data: { callId: payload.callId, eventId: payload.eventId },
        actions: [{ action: 'answer', title: 'Answer' }, { action: 'reject', title: 'Reject' }],
      });
      if (!shown) return;
      await safeDrain();
    } finally {
      presentingCalls.delete(payload.callId);
      endingPresentations.delete(payload.callId);
    }
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
    if (!ended) await scheduleDeadlineRecovery();
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
      if (configFingerprint(old) !== configFingerprint(callbacks)) {
        const generation = await request(store.get('callbackGeneration'));
        store.put({ id: 'callbackGeneration', value: (generation?.value || 0) + 1 });
        store.delete('authPaused');
      }
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
          const generation = await request(meta.get('callbackGeneration'));
          return { item: claimed, config, configKey: configFingerprint(config), configGeneration: generation?.value || 0 };
        }
        return { waiting: true };
      });
      if (job.skip) return;
      if (job.waiting) { await scheduleOutbox(); return; }
      const { item, config, configKey, configGeneration } = job;
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
      const staleConfig = await transaction(['outbox', 'meta'], 'readwrite', async tx => {
        const outbox = tx.objectStore('outbox');
        const current = await request(outbox.get(item.id));
        if (!current || current.claimToken !== item.claimToken || current.state !== 'sending') return false;
        const meta = tx.objectStore('meta');
        const generation = await request(meta.get('callbackGeneration'));
        if (configFingerprint(await request(meta.get('callbackConfig'))) !== configKey ||
            (generation?.value || 0) !== configGeneration) {
          outbox.put({ ...current, state: 'pending', nextAt: 0 });
          return true;
        }
        const now = Date.now();
        const attempt = current.attempt + 1;
        if (status >= 200 && status < 300) {
          outbox.put({ ...current, state: 'delivered', attempt, httpStatus: status, completedAt: now });
        } else if (status === 401 || status === 403) {
          meta.put({ id: 'authPaused', value: true });
          outbox.put({ ...current, state: 'pending', attempt, httpStatus: status, nextAt: now });
        } else if (now >= current.expiresAt || status >= 300 && status < 500 && status !== 429) {
          outbox.put({ ...current, state: 'terminal', attempt, httpStatus: status, outcome: now >= current.expiresAt ? 'expired' : 'httpError', completedAt: now });
        } else {
          const base = retryAfter || Math.min(900000, 1000 * 2 ** Math.min(attempt - 1, 10));
          const delay = Math.min(900000, Math.round(base * (0.8 + Math.random() * 0.2)));
          outbox.put({ ...current, state: 'pending', attempt, httpStatus: status, nextAt: Math.min(now + delay, current.expiresAt) });
        }
        return false;
      });
      if (staleConfig) continue;
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
    if (message.command === 'completeAction' || message.command === 'end') await recoverDeadlines();
    switch (message.command) {
      case 'initialize':
        await configure(message.callbacks || null);
        await reconcilePresentations();
        await recoverDeadlines();
        return { status: 'success', value: null };
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
        await reconcilePresentations();
        if (presentingCalls.has(call.callId)) return { status: 'failure', error: { code: 'invalidState' } };
        presentingCalls.add(call.callId);
        const snapshot = { callId: call.callId, state: 'ringing', media: call.media, caller: call.caller, actionReceipts: [] };
        try {
          const created = await transaction(['snapshots'], 'readwrite', async tx => {
            const store = tx.objectStore('snapshots');
            const current = await request(store.get(call.callId));
            if (current && (current.state !== 'presentationFailed' || current.caller?.id !== call.caller.id || current.media !== call.media)) return false;
            store.put({ id: call.callId, ...snapshot, state: 'presenting', sequence: 0 });
            return true;
          });
          if (!created) return { status: 'failure', error: { code: 'invalidState' } };
          let shown;
          try {
            shown = await showCallNotification(call.callId, call.caller.displayName,
              { body: 'Incoming call', tag: call.callId, data: { callId: call.callId },
                actions: [{ action: 'answer', title: 'Answer' }, { action: 'reject', title: 'Reject' }] });
          } catch (_) { return { status: 'failure', error: { code: 'platformFailure' } }; }
          if (!shown) return { status: 'failure', error: { code: 'invalidState' } };
          return { status: 'success', value: snapshot };
        } finally {
          presentingCalls.delete(call.callId);
          endingPresentations.delete(call.callId);
        }
      }
      case 'end': {
        const reason = message.reason || 'local';
        if (!['local', 'remote', 'rejected', 'missed', 'failed'].includes(reason))
          return { status: 'failure', error: { code: 'protocolFailure' } };
        const snapshot = await terminalize(message.callId, reason);
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
          if (receipt.expired || Date.now() > receipt.deadline || current.state !== 'connecting' || current.actionId !== message.actionId) return null;
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
    scope.addEventListener('activate', event => event.waitUntil(Promise.all([reconcilePresentations(), recoverDeadlines()])));
    const onBackgroundSync = event => {
      if (event.tag === 'jackfield-outbox') event.waitUntil(safeDrain());
      if (event.tag === 'jackfield-deadline') event.waitUntil(recoverDeadlines());
    };
    scope.addEventListener('sync', onBackgroundSync);
    scope.addEventListener('periodicsync', onBackgroundSync);
    scope.addEventListener('message', event => {
      if (!event.data || event.data.jackfield !== 1 || !event.ports?.[0]) return;
      event.waitUntil(command(event.data, event.source?.id).then(result => event.ports[0].postMessage({ version: 1, ...result }))
        .catch(() => event.ports[0].postMessage({ version: 1, status: 'failure', error: { code: 'platformFailure' } })));
    });
  }

  scope.JackfieldWorker = { install, pending, claim, acknowledge, configure, drainOutbox, command };
})(self);
