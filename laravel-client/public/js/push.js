// public/js/push.js — register/unregister the DartMail push subscription.
//
// The page exposes window.__DARTMAIL_PUSH = { vapidPublicKey, subscribeUrl, unsubscribeUrl, csrf }.
// A small UI (Livewire component) calls window.dartmailPush.subscribe() /
// .unsubscribe() / .status().

(function () {
  const cfg = window.__DARTMAIL_PUSH || {};

  function urlBase64ToUint8Array(base64String) {
    const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
    const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
    const raw = atob(base64);
    const out = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; ++i) out[i] = raw.charCodeAt(i);
    return out;
  }

  async function getRegistration() {
    if (!('serviceWorker' in navigator) || !('PushManager' in window)) {
      throw new Error('Push notifications are not supported in this browser.');
    }
    return navigator.serviceWorker.register('/sw.js');
  }

  async function postJson(url, body) {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-TOKEN': cfg.csrf || '',
        'Accept': 'application/json',
      },
      credentials: 'same-origin',
      body: JSON.stringify(body || {}),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
  }

  async function subscribe() {
    const reg = await getRegistration();
    if (Notification.permission === 'denied') {
      throw new Error('Notification permission has been denied. Re-enable it in the browser settings.');
    }
    if (Notification.permission !== 'granted') {
      const perm = await Notification.requestPermission();
      if (perm !== 'granted') throw new Error('Permission not granted.');
    }

    const sub = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(cfg.vapidPublicKey),
    });

    const json = sub.toJSON();
    await postJson(cfg.subscribeUrl, {
      endpoint: json.endpoint,
      keys: { p256dh: json.keys.p256dh, auth: json.keys.auth },
    });
    return true;
  }

  async function unsubscribe() {
    const reg = await getRegistration();
    const sub = await reg.pushManager.getSubscription();
    if (!sub) return false;
    await postJson(cfg.unsubscribeUrl, { endpoint: sub.endpoint });
    await sub.unsubscribe();
    return true;
  }

  async function status() {
    if (!('serviceWorker' in navigator) || !('PushManager' in window)) return 'unsupported';
    if (Notification.permission === 'denied') return 'denied';
    const reg = await navigator.serviceWorker.getRegistration();
    if (!reg) return 'idle';
    const sub = await reg.pushManager.getSubscription();
    return sub ? 'subscribed' : 'idle';
  }

  window.dartmailPush = { subscribe, unsubscribe, status };
})();
