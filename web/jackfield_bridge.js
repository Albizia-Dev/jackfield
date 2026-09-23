(function (scope) {
  'use strict';
  const listeners = new Set();
  const owner = scope.crypto.randomUUID();
  let heartbeat;
  let owned = false;

  async function invoke(json) {
    const message = JSON.parse(json);
    if (!('serviceWorker' in navigator)) throw new Error('service worker unavailable');
    const registration = await navigator.serviceWorker.getRegistration();
    const worker = registration?.active || registration?.waiting || registration?.installing;
    if (!worker) throw new Error('host worker unavailable');
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
    owned = result.status === 'success' && result.value === true;
    if (owned && !heartbeat) {
      heartbeat = setInterval(() => { claim().catch(() => { owned = false; }); }, 15000);
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
    const registration = await navigator.serviceWorker.getRegistration();
    if (!registration?.pushManager) throw new Error('host worker unavailable');
    let subscription = await registration.pushManager.getSubscription();
    if (!subscription) {
      subscription = await registration.pushManager.subscribe({
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
      const registration = await navigator.serviceWorker.getRegistration();
      return (await registration?.pushManager.getSubscription())?.endpoint || '';
    },
  };
})(window);
