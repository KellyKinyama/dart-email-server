# Laravel 12 web client for dart_email_server

A minimal-but-working Laravel 12 application that:

* **sends** mail through `dart_email_server`'s SMTP submission port (Laravel's built-in mailer);
* **reads** mail from `dart_email_server`'s IMAP listener (`webklex/php-imap`);
* (alt) reads via **POP3** through a tiny in-repo client at [`app/Services/Pop3MailboxService.php`](app/Services/Pop3MailboxService.php);
* **receives** push notifications from `dart_email_server`'s `'mail'` event via the webhook at `POST /api/incoming-mail`;
* exposes a small **Blade UI** with three pages: Inbox, Webhook log, Compose.

> Position: this is a *web client* talking to the Dart server next door
> (the parent folder `..`). It is not a re-implementation of email
> protocols in PHP.

---

## Layout

| Path | Purpose |
|------|---------|
| [`config/dart_email.php`](config/dart_email.php) | Single source of truth for SMTP / IMAP / POP3 / webhook settings |
| [`app/Services/ImapMailboxService.php`](app/Services/ImapMailboxService.php) | Lists and fetches messages over IMAP |
| [`app/Services/Pop3MailboxService.php`](app/Services/Pop3MailboxService.php) | Pure-PHP POP3 client for the alternative path |
| [`app/Mail/GenericOutboundMail.php`](app/Mail/GenericOutboundMail.php) | Mailable used by the compose form |
| [`app/Models/IncomingMessage.php`](app/Models/IncomingMessage.php) | Persisted webhook deliveries |
| [`app/Http/Controllers/InboxController.php`](app/Http/Controllers/InboxController.php) | `/inbox` — IMAP-backed |
| [`app/Http/Controllers/WebhookController.php`](app/Http/Controllers/WebhookController.php) | `/api/incoming-mail` ingest + `/webhook` browser |
| [`app/Http/Controllers/ComposeController.php`](app/Http/Controllers/ComposeController.php) | `/compose` form |
| [`resources/views/`](resources/views/) | Blade UI |
| [`database/migrations/2026_05_15_000001_create_incoming_messages_table.php`](database/migrations/2026_05_15_000001_create_incoming_messages_table.php) | `incoming_messages` table |

Routes (see [routes/web.php](routes/web.php)):

| Method | Path | Name |
|--------|------|------|
| GET  | `/` | redirects to inbox |
| GET  | `/inbox?folder=INBOX` | `inbox.index` |
| GET  | `/inbox/{folder}/{uid}` | `inbox.show` |
| GET  | `/compose` | `compose.create` |
| POST | `/compose` | `compose.store` |
| POST | `/api/incoming-mail` | `webhook.ingest` (CSRF-exempt, bearer-auth) |
| GET  | `/webhook` | `webhook.index` |
| GET  | `/webhook/{message}` | `webhook.show` |

---

## Quick start

```powershell
# 1. Install deps (already done if you scaffolded with this repo).
composer install

# 2. Create the SQLite DB + run migrations.
New-Item database/database.sqlite -ItemType File -Force
php artisan migrate

# 3. In another terminal, start the Dart side. The bridge example runs
#    SMTP 2525, IMAP 2143, POP3 2110 and POSTs accepted mail to this app.
cd ..
dart run examples/laravel_bridge.dart

# 4. Back in this folder, serve the UI.
php artisan serve --port=8000

# 5. Visit http://127.0.0.1:8000
```

Default credentials baked into the bridge: `demo@example.com` / `demo`.

---

## Environment variables

The `.env` shipped with the project pre-fills sensible defaults; override
per environment:

```
MAIL_MAILER=smtp
MAIL_HOST=127.0.0.1
MAIL_PORT=2525
MAIL_USERNAME=demo@example.com
MAIL_PASSWORD=demo
MAIL_FROM_ADDRESS=demo@example.com

DART_MAIL_IMAP_HOST=127.0.0.1
DART_MAIL_IMAP_PORT=2143
DART_MAIL_IMAP_USER=demo@example.com
DART_MAIL_IMAP_PASS=demo

DART_MAIL_POP3_HOST=127.0.0.1
DART_MAIL_POP3_PORT=2110
DART_MAIL_POP3_USER=demo@example.com
DART_MAIL_POP3_PASS=demo

DART_MAIL_WEBHOOK_SECRET=change-me
```

The webhook secret **must match** the `_webhookSecret` constant in
[`../examples/laravel_bridge.dart`](../examples/laravel_bridge.dart).

---

## How sending works

1. User submits `/compose`.
2. `ComposeController` builds a `GenericOutboundMail` mailable.
3. Laravel's `smtp` transport (Symfony Mailer under the hood) opens a
   connection to `MAIL_HOST:MAIL_PORT`.
4. `dart_email_server` accepts on port 2525 (relay) or 2587 (auth-required
   submission).
5. The Dart server emits its `'mail'` (relay) or `'smtpSession'`/`'mail'`
   (submission) event; the bridge example stores the bytes in the
   in-memory mailbox and POSTs to this app's webhook.

## How reading works (IMAP)

1. User opens `/inbox`.
2. `InboxController` asks `ImapMailboxService` for messages.
3. The service uses `webklex/php-imap` to LIST/FETCH against
   `dart_email_server`'s IMAP listener.
4. The Blade view renders the headers and body.

## How webhook ingest works

1. The Dart server's `'mail'` listener (in
   [`../examples/laravel_bridge.dart`](../examples/laravel_bridge.dart))
   POSTs JSON with the message + auth verdicts and a bearer token.
2. `WebhookController::ingest` validates the bearer secret, persists to
   `incoming_messages`, returns `200 {accepted: true}`.
3. `/webhook` lists what has been received.

This path is independent of IMAP — it gives you a permanent log of
*everything dart_email_server accepted*, even if the mailbox store
later evicts it.

---

## Switching IMAP off and using POP3

```php
use App\Services\Pop3MailboxService;

$pop = Pop3MailboxService::fromConfig();
$pop->connect();
$sizes = $pop->listSizes();
foreach ($sizes as $i => $bytes) {
    $raw = $pop->retrieve($i);
    // store / parse / display
}
$pop->quit();
```

POP3 here is intentionally read-only (no DELE in the wrapper). Add it
yourself if your workflow needs it.

---

## Production notes

* Replace the bearer secret with a long random value and rotate it.
* Wire IMAP TLS (`DART_MAIL_IMAP_PORT=993`,
  `DART_MAIL_IMAP_ENC=ssl`) once `dart_email_server` is configured with
  a real certificate.
* Move `IncomingMessage` to a queued job if you expect high inbound
  rate — the webhook ingest currently writes synchronously.
* Replace SQLite with MySQL/PostgreSQL when you cross a single host.
