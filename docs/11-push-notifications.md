# Push Notifications (Web Push / VAPID)

When a new message lands at the `/api/incoming-mail` webhook, the Laravel
client fans out a **Web Push** notification to every local user who:

1. has an email address listed in the inbound envelope-to set, **and**
2. has registered a browser push subscription with this server.

Web Push works in all evergreen browsers (Chrome, Edge, Firefox, Safari 16+)
and notifications appear at the OS level — even when the DartMail tab is
closed.

## 1. Pieces involved

| Layer | Where |
|---|---|
| Package | `laravel-notification-channels/webpush ^10.5` (composer) |
| VAPID keys | `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` in `laravel-client/.env` |
| Subscription table | `push_subscriptions` (added by `2026_05_16_031803_create_push_subscriptions_table`) |
| User trait | `HasPushSubscriptions` on [`App\Models\User`](../laravel-client/app/Models/User.php) |
| Notification | [`App\Notifications\NewMailNotification`](../laravel-client/app/Notifications/NewMailNotification.php) |
| Dispatch site | [`WebhookController@ingest`](../laravel-client/app/Http/Controllers/WebhookController.php) |
| Subscribe API | `POST /push/subscribe`, `POST /push/unsubscribe` ([`PushSubscriptionController`](../laravel-client/app/Http/Controllers/PushSubscriptionController.php)) |
| Browser code | [`public/sw.js`](../laravel-client/public/sw.js), [`public/js/push.js`](../laravel-client/public/js/push.js) |
| Sidebar toggle | [`App\Livewire\Push\Toggle`](../laravel-client/app/Livewire/Push/Toggle.php) |
| Tests | [`tests/Feature/PushNotificationTest.php`](../laravel-client/tests/Feature/PushNotificationTest.php) |

## 2. One-time server setup

PHP must have **OpenSSL** with EC support and the **sodium** extension. On
WAMP the OpenSSL config file is sometimes not picked up automatically, so
point at it before generating VAPID keys:

```powershell
$env:OPENSSL_CONF = "C:\wamp64\bin\php\php8.4.0\extras\ssl\openssl.cnf"
cd laravel-client
php artisan webpush:vapid     # writes VAPID_PUBLIC_KEY/PRIVATE_KEY into .env
php artisan migrate           # creates push_subscriptions
```

For production simply ensure `extension=sodium` is enabled and `openssl.cnf`
is at the path baked into PHP.

## 3. How the browser subscription dance works

```
                  ┌─────────────────────────────────┐
   user clicks    │ /js/push.js: dartmailPush.subscribe() │
   "Enable" ─────►│   1. registers /sw.js                │
                  │   2. requests Notification permission│
                  │   3. pushManager.subscribe(VAPID pub) │
                  │   4. POST /push/subscribe (CSRF)     │
                  └────────────┬────────────────────────┘
                               ▼
              PushSubscriptionController@store
              → User->updatePushSubscription($endpoint, $p256dh, $auth)
              → row written to push_subscriptions
```

`/sw.js` listens for `push` events from the browser's push service and
calls `self.registration.showNotification(title, options)`.

## 4. Fan-out path on incoming mail

```
dart_email_server   POST /api/incoming-mail (bearer)
        │
        ▼
WebhookController@ingest
        │
        │  1. validate + persist IncomingMessage
        │  2. lowercase + filter envelopeTo
        │  3. User::whereIn('email', …)->whereHas('pushSubscriptions')->get()
        │  4. Notification::send($users, new NewMailNotification($message))
        ▼
NewMailNotification@toWebPush
        │
        ▼
WebPushChannel → minishlink/web-push → browser push service → /sw.js → OS notification
```

Users whose mailbox is on this server but who have **not** opted in to
notifications are silently skipped. Users whose subscription endpoint has
expired are auto-pruned by the channel.

## 5. User-facing UX

The sidebar bottom shows a small "🔔 Notifications · Enable" button (added
by [`livewire.push.toggle`](../laravel-client/resources/views/livewire/push/toggle.blade.php)).
States:

| Status | Button | What it means |
|---|---|---|
| `idle` | Enable | Permission not yet granted, or subscription deleted |
| `subscribed` | Disable | Active subscription exists; clicking unsubscribes |
| `denied` | Blocked | Browser permission denied — user must reset it in browser settings |
| `unsupported` | N/A | Browser has no `serviceWorker` / `PushManager` |

## 6. Local testing tips

- Browsers require **HTTPS** for service workers, **except** `http://localhost`
  which is treated as secure. Develop on `http://localhost`, not `127.0.0.1`.
- To clear state, open DevTools → Application → Service Workers → Unregister,
  then Application → Storage → Clear site data.
- `php artisan webpush:send-test {user_id}` (provided by the package) is
  the fastest way to confirm the end-to-end pipe works without faking a
  webhook payload.

## 7. Test suite

```bash
cd laravel-client
php artisan test --filter=PushNotificationTest
```

Covers: storing/removing subscriptions, 401 when unauthenticated, and
fan-out from the inbound webhook to only those local recipients that have
an active subscription. Full suite is currently **65 passed**.

## 8. Rotating VAPID keys

`php artisan webpush:vapid --force` writes a fresh pair into `.env`. All
existing subscriptions become invalid (the browser binds them to the
public key). Users must re-subscribe — clicking the sidebar toggle is
enough since `/js/push.js` re-runs the dance with the new key.
