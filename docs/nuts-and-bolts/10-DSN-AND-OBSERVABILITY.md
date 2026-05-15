# 10. DSN and observability

The last chapter. How the server tells you (and the original sender)
that something happened — bounces, retries, accepts, connection
events, DNS warnings — and the hooks you wire into your metrics stack.

Files:

* [`lib/src/dsn.dart`](../../lib/src/dsn.dart) — `buildDsn(opts)`,
  the RFC 3461/3464 multipart/report builder.
* [`lib/src/server.dart`](../../lib/src/server.dart) — the
  `EventEmitter` surface (covered piecemeal in chapters 2 and 6;
  collated here).
* [`test/`](../../test/) — the executable specification of "what good
  looks like".

---

## 10.1. DSN — what a bounce actually looks like

A Delivery Status Notification is **not** an arbitrary "Mail Delivery
Failed" email. It is a structured `multipart/report; report-type=
delivery-status` message with three parts:

```
multipart/report; report-type=delivery-status
├── text/plain        ← human-readable explanation ("your mail to bob… failed")
├── message/delivery-status   ← machine-readable per-recipient verdict
└── message/rfc822 (or text/rfc822-headers)  ← the original mail (or just headers)
```

The **machine-readable part** is what other MTAs and bounce-handling
systems parse:

```
Reporting-MTA: dns; mx.example.com
Original-Envelope-Id: 9c84e1
Arrival-Date: Mon, 04 May 2026 12:00:00 +0000

Final-Recipient: rfc822; bob@example.org
Original-Recipient: rfc822; bob@example.org
Action: failed
Status: 5.1.1
Diagnostic-Code: smtp; 550 5.1.1 No such user
Remote-MTA: dns; mx.example.org
Last-Attempt-Date: Mon, 04 May 2026 12:00:31 +0000
```

A non-conformant "bounce" without this structure won't be processed
by mailing-list software, opt-out handlers, or reputation services.
That's why `buildDsn` exists.

---

## 10.2. `buildDsn(opts)` API

```dart
Uint8List buildDsn(DsnOptions(
  reportingMta:        'mx.example.com',
  originalEnvelopeId:  '9c84e1',
  arrivalDate:         DateTime.now(),
  originalMessage:     mail.raw,           // full message OR headers only
  returnContent:       'headers',          // 'headers' | 'full'
  recipients: [
    DsnRecipient(
      finalRecipient: 'bob@example.org',
      action:         'failed',           // 'failed' | 'delayed' | 'delivered' | 'relayed' | 'expanded'
      status:         '5.1.1',            // RFC 3463 enhanced code
      diagnostic:     '550 5.1.1 No such user',
      remoteMta:      'mx.example.org',
      lastAttempt:    DateTime.now(),
    ),
  ],
  from: 'postmaster@example.com',
  to:   'alice@example.com',              // original envelope sender
));
```

Returns a `Uint8List` you hand to `sendMail` (or `OutboundPool`) to
deliver. The function:

* Picks a Subject based on the worst recipient action
  (`failed` → "Undelivered Mail Returned to Sender";
  `delayed` → "Delivery Status Notification (Delay)").
* Generates a unique boundary (`=_dsn_<rand>`).
* Generates a Message-ID (`<dsn-<rand>@<reportingMta>>`).
* Wraps the original message in either `message/rfc822` (with the full
  body) or `text/rfc822-headers` (headers only — preferred for spam
  reports and large messages).

---

## 10.3. When to build a DSN

| Trigger | Origin | Who builds the DSN |
|---|---|---|
| Inbound MAIL FROM is unroutable | inbound `'mail'` listener returns reject | The peer MTA that sent it (not you) |
| Inbound message accepted but local user doesn't exist | your `'mail'` listener after store lookup fails | **You**, then send via outbound pool |
| Outbound 5xx after exhausting retries | `OutboundPool` → `'bounce'` event | **You**, in the `'bounce'` listener |
| Outbound delayed (4xx) for >> N hours | up to you (RFC says 4 hours = first delay notice, ~5 days = give up) | **You**, optionally |
| Mailing-list expansion | list software, not this library | n/a |

The pool's `'bounce'` payload contains everything `buildDsn` needs:

```dart
server.on('bounce', (Map info) {
  final dsn = buildDsn(DsnOptions(
    reportingMta: 'mx.example.com',
    originalEnvelopeId: info['msgId'],
    originalMessage:    info['raw'],
    returnContent:      'headers',
    recipients: (info['recipients'] as List).map((r) =>
      DsnRecipient(
        finalRecipient: r['address'],
        action: 'failed',
        status: r['enhanced'] ?? '5.0.0',
        diagnostic: r['reply'],
        remoteMta: info['host'],
        lastAttempt: DateTime.now(),
      )).toList(),
    from: 'postmaster@example.com',
    to:   info['envelopeFrom'],
  ));
  await sendMail(SendMailOptions(raw: dsn, from: …, to: [info['envelopeFrom']]));
});
```

---

## 10.4. The full event surface

Collated from chapters 2, 4, 6:

| Event | Payload | Frequency | Suitable metric |
|---|---|---|---|
| `'ready'` | none | once at startup | `server_up` gauge |
| `'error'` | `Object` | rare | counter |
| `'domainAdded'` | `String domain` | startup-ish | gauge of registered domains |
| `'dnsWarning'` | `DnsWarning(domain, message)` | after `addDomain` | log |
| `'connection'` | `ConnectionInfo` | per accept | counter, histogram by `protocol` |
| `'rateLimit'` | `RateLimitNotice` | per refusal | counter by `reason` |
| `'auth'` | `AuthInfo` | per auth attempt | counter, accept/reject ratio |
| `'smtpSession'` | `(EventEmitter, SmtpFacadeState)` | per authenticated submission | gauge of sessions |
| `'mailboxSession'` | `MailboxFacade` | per authenticated mailbox | gauge of sessions |
| `'mail'` | `MailObject` | per inbound message | counter, histogram of `size` |
| `'sent'` | `Map` | per outbound success | counter, histogram by host |
| `'bounce'` | `Map` | per outbound permanent failure | counter, alert when non-zero |
| `'retry'` | `Map` | per outbound transient retry | gauge (queue depth proxy) |

Hook these directly into Prometheus/StatsD/OpenTelemetry — the events
are synchronous, so the bookkeeping itself is sub-microsecond. Heavier
aggregation should be deferred to `Timer.run`.

---

## 10.5. Tracing a single message

For correlation across logs, every connection has a `connId` (chapter
2). Every accepted inbound message gets a Message-ID stamped by the
composer or carried verbatim from the wire. Every outbound delivery
emits the same Message-ID in `'sent' / 'bounce' / 'retry'`.

A workable tracing convention:

```
[<connId>] [<protocol>] <verb> <result> messageId=<id>
```

— produced by your listeners. The library doesn't impose a logger;
print, `dart:developer.log`, `package:logging`, all fine.

---

## 10.6. Tests as a living spec

The `test/` directory exercises every layer end to end:

| File | What it pins down |
|---|---|
| [`smtp_wire_test.dart`](../../test/smtp_wire_test.dart) | Reply parser, command parser, multi-line replies |
| [`message_test.dart`](../../test/message_test.dart) | Composer + parser round-trips, address parsing, encoded-words |
| [`edge_cases_test.dart`](../../test/edge_cases_test.dart) | Ugly real-world inputs (bare LF, missing boundary, nested multipart) |
| [`dkim_test.dart`](../../test/dkim_test.dart) | Sign + verify round-trips, canonicalisation |
| [`dsn_test.dart`](../../test/dsn_test.dart) | DSN format conforms to RFC 3461 |
| [`domain_test.dart`](../../test/domain_test.dart) | DomainMaterial + verifyDNS shape |
| [`utils_test.dart`](../../test/utils_test.dart) | IDN, address split, header folding, base64/QP edge cases |
| [`cipher_test.dart`](../../test/cipher_test.dart) | RSA / ECDSA / X25519 / AES-GCM / HKDF / hashing |
| [`email_crypto_test.dart`](../../test/email_crypto_test.dart) | DKIM with all algorithms |
| [`server_client_integration_test.dart`](../../test/server_client_integration_test.dart) | Boot a `Server`, drive it with the outbound `SmtpClient` over loopback |
| [`imap_pop3_integration_test.dart`](../../test/imap_pop3_integration_test.dart) | Boot IMAP + POP3, fetch a deposited message via both |
| [`imap_wire_test.dart`](../../test/imap_wire_test.dart) | Tokeniser, literal handling, response formatter |
| [`end_to_end_mail_flow_test.dart`](../../test/end_to_end_mail_flow_test.dart) | Compose → submit → relay → inbound → IMAP fetch |

`dart test` runs them all. Anything you add should slot into the
matching file.

---

## 10.7. Health checklist for a deployment

A short, opinionated list:

1. `addDomain(...)` for *every* domain you serve. The async
   `'dnsWarning'` event will tell you what's missing.
2. `RateLimiterConfig` with non-zero limits — a missing rate limit is
   how a botnet finds you.
3. A real TLS cert wired through `DomainMaterial.tls` (or
   `sniCallback`). Without it, the TLS-jobs in `listen()` are skipped.
4. A persistent mail store behind your `'mail'` listener and your
   `'mailboxSession'` callbacks. The bundled IMAP backing is in-memory.
5. `'bounce'` listener that calls `buildDsn` and routes the resulting
   message back to the original envelope sender via `sendMail`.
6. Metrics for `connection`, `rateLimit`, `mail`, `sent`, `bounce`,
   `retry`. Alert on `bounce > 0` rate spikes and on `retry` queue
   depth.
7. Outbound IP with **forward-confirmed reverse DNS** matching
   `localHostname`. Verify with [`examples/laravel_dev_sink.dart`](../../examples/laravel_dev_sink.dart)
   pointed at a real receiver.
8. Published SPF, DKIM, DMARC, MTA-STS for every sending domain. Use
   [`examples/build_domain_material.dart`](../../examples/build_domain_material.dart).

---

## 10.8. End of tour

You've now seen every byte path through this codebase:

* Inbound TCP → SMTP state machine → parse → SPF/DKIM/DMARC/rDNS →
  `'mail'` event → your store.
* Your code → compose → outbound pool → MX → SMTP wire → peer.
* Mailbox client → IMAP/POP3 session → your store callbacks → push
  notifications.

The repository's longer-form protocol explanation lives in
[`../`](../README.md). The runnable demos live in
[`../../examples/`](../../examples/). The contract you can rely on
lives in [`../../test/`](../../test/).

When something behaves unexpectedly, the path is always: pick the
chapter for the affected layer, open the file it links, and read.
