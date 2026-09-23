(function (scope) {
  'use strict';
  const listeners = new Set();
  const owner = scope.crypto.randomUUID();
  let heartbeat;
  let owned = false;
  let token = null;

  async function registration() {
    if (!('serviceWorker' in navigator)) throw new Error('service worker unavailable');
    if (!scope.JackfieldHostWorkerRegistration) throw new Error('host worker registration unavailable');
    const registered = await scope.JackfieldHostWorkerRegistration;
    if (!registered?.active) throw new Error('host worker is not active');
    return registered;
  }

  async function invoke(json) {
    const message = JSON.parse(json);
    const worker = (await registration()).active;
    if (message.command === 'pending' || message.command === 'acknowledge') {
      if (!owned || !token) throw new Error('delivery lease unavailable');
      message.owner = owner;
      message.token = token;
    }
    return new Promise((resolve, reject) => {
      const channel = new MessageChannel();
      const timeout = setTimeout(() => { channel.port1.close(); reject(new Error('worker timeout')); }, 10000);
      channel.port1.onmessage = event => {
        clearTimeout(timeout);
        channel.port1.close();
        resolve(JSON.stringify(event.data));
      };
      worker.postMessage({ jackfield: 1, version: 1, ...message }, [channel.port2]);
    });
  }

  async function claim() {
    const result = JSON.parse(await invoke(JSON.stringify({ command: 'claim', owner })));
    owned = result.status === 'success' && !!result.value;
    token = owned ? result.value.token : null;
    if (owned) for (const event of result.value.pending || []) {
      for (const listener of listeners) listener(JSON.stringify(event));
    }
    if (!heartbeat) {
      heartbeat = setInterval(() => {
        claim().catch(() => { owned = false; token = null; });
        invoke(JSON.stringify({ command: 'drain' })).catch(() => {});
      }, 15000);
    }
    return owned;
  }

  function decodeApplicationServerKey(value) {
    if (value instanceof ArrayBuffer) return value;
    if (typeof value !== 'string' || !value) throw new Error('invalid application server key');
    const padded = value.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(value.length / 4) * 4, '=');
    const binary = atob(padded);
    return Uint8Array.from(binary, character => character.charCodeAt(0));
  }

  async function subscribePush(applicationServerKey) {
    if (!('serviceWorker' in navigator) || !scope.Notification || !scope.PushManager) {
      throw new Error('Push API unavailable');
    }
    if (scope.Notification.permission !== 'granted') {
      const permission = await scope.Notification.requestPermission();
      if (permission !== 'granted') throw new Error('notification permission denied');
    }
    const host = await registration();
    if (!host.pushManager) throw new Error('host worker unavailable');
    let subscription = await host.pushManager.getSubscription();
    if (!subscription) {
      subscription = await host.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: decodeApplicationServerKey(applicationServerKey),
      });
    }
    const endpoint = subscription.endpoint;
    for (const listener of listeners) listener(JSON.stringify({ type: 'pushToken', provider: 'webPush', value: endpoint, removed: false }));
    return endpoint;
  }

  navigator.serviceWorker?.addEventListener('message', event => {
    if (event.data?.jackfield !== 1 || event.data.type !== 'event') return;
    if (owned) for (const listener of listeners) listener(JSON.stringify(event.data.event));
  });

  scope.JackfieldBridge = {
    invoke,
    claim,
    listen(listener) { listeners.add(listener); },
    permission() { return scope.Notification?.permission || 'unsupported'; },
    async requestPermissionFromGesture() { return scope.Notification.requestPermission(); },
    subscribePush,
    async pushEndpoint() {
      const host = await registration();
      return (await host.pushManager?.getSubscription())?.endpoint || '';
    },
  };
})(window);
