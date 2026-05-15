# 6. Outbound client and pool

How a message leaves this process. Two layers:

* [`lib/src/smtp_client.dart`](../../lib/src/smtp_client.dart) — the
  `sendMail()` function and `SMTPConnectionWrapper` (one connection,
  one or many messages).
* [`lib/src/pool.dart`](../../lib/src/pool.dart) — `OutboundPool`,
  which keeps `SMTPConnectionWrapper`s alive, applies per-domain
  concurrency limits, and runs the retry curve.

`sendMail()` is fine for one-shot programs. The `OutboundPool` is what
a long-lived server uses.

---

## 6.1. `sendMail(opts)` — one call, one result

```dart
Future<SendMailResult> sendMail(SendMailOptions options);
```

`SendMailOptions` carries everything needed to compose **and** to
deliver:

```dart
SendMailOptions(
  // composition (all optional if `raw` is supplied)
  from:    AddressObj(address: 'alice@example.com'),
  to:      [AddressObj(address: 'bob@example.org')],
  cc:      …, bcc: …,
  subject: 'Hi',
  text:    'plain body',
  html:    '<p>html</p>',
  attachments: …,
  headers: …,

  // OR pre-composed bytes
  raw:     Uint8List.fromList(...),

  // delivery
  relay:         RelayOptions(host: 'smtp.gmail.com', port: 587, username: …, password: …),
  // …or omit relay entirely for direct-MX delivery
  localHostname: 'mx.example.com',
  ignoreTls:     false,
  timeout:       30000,
);
```

Behaviour:

1. If `raw` is null, internally calls `composeMessageTyped(...)`
   (chapter 5) and substitutes the resulting bytes.
2. **Group recipients by domain.** `bob@example.org` and
   `carol@example.org` go in one batch; `dan@other.example` is
   separate.
3. For each batch:
   * `relay != null` → `host = relay.host`, single connection.
   * Otherwise → `resolveMX(domain)` returns sorted `MxRecord`s,
     iterated in priority order until one accepts.
4. Open / reuse a `SMTPConnectionWrapper`, drive the conversation.
5. Aggregate `accepted` / `rejected` results into `SendMailResult`.

```dart
class SendMailResult {
  final String messageId;             // Message-ID emitted by the composer
  final List<DomainAccepted> accepted; // per (domain, host) success records
  final List<DomainRejected> rejected; // per (domain) failure records
}
```

A *partial* success is normal: a single `sendMail` call may succeed
for some recipient domains and fail for others.

---

## 6.2. `SMTPConnectionWrapper` — one TCP connection

File: [`lib/src/smtp_client.dart`](../../lib/src/smtp_client.dart),
line ~89.

State machine of a single outbound conversation:

```
TCP connect ──► read 220 ──► EHLO ──► [STARTTLS ──► EHLO]
                                          │
                                          ▼
                                  [AUTH PLAIN | LOGIN]
                                          │
                                          ▼
                              loop per message:
                                  MAIL FROM
                                  RCPT TO ×N
                                  DATA
                                  bytes + "\r\n.\r\n"
                                  read 250
                                          │
                                          ▼
                                       QUIT
```

The wrapper distinguishes:

* **Permanent (5xx)** failures → marked `rejected`, the wrapper
  continues with remaining recipients (unless the failure was
  pre-DATA, in which case the whole batch is dropped).
* **Transient (4xx)** failures → marked `tempfail`. `OutboundPool`
  reschedules per the retry curve.
* **Connection-level errors** (timeout, RST, TLS handshake fail) →
  the wrapper marks itself `dead` and the pool will reopen.

Reply parsing uses `parseReplyBlockTyped` (chapter 3) so multi-line
greetings/EHLO responses are handled identically to the inbound side.

---

## 6.3. MX resolution

`resolveMX(domain)`:

1. `dns_cache.mxRecords(domain)` (chapter 9). Cached per
   `PoolOptions.mxCacheTTL` (default 5 min).
2. Empty result → fabricate one record of `(priority: 10, exchange: domain)` so an A-record-only host still works ("implicit MX").
3. Sort by `priority` ascending.

> **Note:** there is no priority-tied randomisation yet (RFC 5321 §5.1
> recommends shuffling within an equal-priority group). Real load is
> typically dominated by relays anyway; if you operate without a
> relay, watch `'sent'`/`'bounce'` and consider implementing this.

---

## 6.4. `OutboundPool` — multi-message orchestration

File: [`lib/src/pool.dart`](../../lib/src/pool.dart).

```dart
class OutboundPool {
  OutboundPool(PoolOptions opts);

  // event surface (re-emitted by Server)
  void on(String event, EvCallback cb);

  // submit a message; returns a synthetic queue ID
  int enqueueTyped({
    required String from,
    required List<String> to,
    required Uint8List raw,
    RelayOptions? relay,
    Map<String, dynamic>? headers,
  });

  void closeAll();
}
```

`PoolOptions` knobs (with defaults):

| Option | Default | Effect |
|---|---|---|
| `maxPerDomain` | `3` | Concurrent open connections to one MX exchange |
| `maxMessagesPerConn` | `100` | Recycle the connection after N successful deliveries (some receivers throttle long-lived TCP) |
| `idleTimeout` | `30 000` ms | Close an idle connection rather than keep it alive |
| `rateLimitPerMinute` | `60` | Per-MX delivery cap; excess waits |
| `reconnectDelay` | `1 000` ms | Backoff when a fresh connection failed at TCP/TLS layer |
| `mxCacheTTL` | `300 000` ms | How long `resolveMX` answers are reused |
| `retryDelays` | `[60s, 5m, 30m, 2h, 4h]` | Schedule for `tempfail` retries — index = retry count, exhaustion = bounce |
| `localHostname` | `'localhost'` | Used in EHLO + composed `Message-ID` |
| `ignoreTLS` | `false` | Skip STARTTLS even if advertised (testing only!) |
| `timeout` | `30 000` ms | Per-command socket timeout |

### How a message moves through the pool

```
enqueueTyped(msg)
   │
   ▼
group recipients by domain → set of "domain jobs"
   │
   ▼
for each domain job:
   ├── relay set?
   │     └── pool[relay.host] ← reuse / open a new wrapper
   │           (subject to maxPerDomain)
   ├── otherwise:
   │     ├── resolveMX(domain)
   │     └── pool[mx.exchange] ← reuse / open
   │
   ▼
PoolEntry { conn, busy, messageCount, idleTimer, alive, mx }
   │  busy = true while sending
   ▼
SMTPConnectionWrapper.send(...)
   │
   ▼
   2xx → emit 'sent', { msgId, host, accepted, rejected }
   4xx → schedule retry: Timer(retryDelays[n], () => re-enqueue)
   5xx → emit 'bounce',  { msgId, host, recipients, code, message }
        (your code typically calls buildDsn(...) here, chapter 10)
```

`PoolEntry` is reset to `busy = false` and idle-timer-armed after each
message. When `messageCount >= maxMessagesPerConn`, the entry is
closed and dropped from the pool's free-list.

---

## 6.5. Server integration

`Server` constructs an `OutboundPool` from `ServerOptions.pool` (or
defaults) and re-emits its three lifecycle events on its own bus:

```dart
context.pool!.on('sent',   (info) => _ev.emit('sent',   info));
context.pool!.on('bounce', (info) => _ev.emit('bounce', info));
context.pool!.on('retry',  (info) => _ev.emit('retry',  info));
```

This is why your application listens to `server.on('bounce', ...)`
even though the bounce comes from the pool — there's exactly one
event surface to subscribe to.

---

## 6.6. The retry curve in practice

```
T+0          attempt 1   →   tempfail
T+60s        attempt 2   →   tempfail
T+5m         attempt 3   →   tempfail
T+35m        attempt 4   →   tempfail
T+2h35m      attempt 5   →   tempfail
T+6h35m      attempt 6   →   tempfail
                          ↓
                     give up → emit 'bounce'
```

Each retry uses a *fresh* MX list (the cache may have expired and the
top-priority host may have come back). If you want exponential backoff
to a longer horizon, override `PoolOptions.retryDelays` with a longer
list — the pool simply walks the list and bounces when it runs off
the end.

---

## 6.7. Common operational gotchas

* **ISP blocks port 25 outbound.** Most consumer ISPs do. If
  `sendMail` hangs on `connect`, you're hitting this. Use a relay
  (port 587 with submission auth) instead.
* **No reverse DNS for your sending IP.** Big receivers will reply
  `554 5.7.1 reverse DNS does not match`. Configure rDNS at your VPS
  provider; chapter 4 §4.5 explains.
* **Missing SPF/DKIM for your sending domain.** Tempfailed
  indefinitely. `addDomain` plus the helpers in
  [`build_domain_material.dart`](../../examples/build_domain_material.dart)
  generate the records you need to publish.
* **`ignoreTLS: true`** in production. Don't. Only useful when
  pointing at a local mail trap.

---

Next: [Chapter 7 — IMAP session](./07-IMAP-SESSION.md).
