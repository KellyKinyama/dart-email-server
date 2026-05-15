# dart_email_server

A pure-Dart, batteries-included **email stack** — SMTP (relay + submission),
IMAP, POP3, message composition, DKIM signing/verification, SPF, DMARC,
DSN bounces, MTA-STS / TLS-RPT helpers, and an outbound SMTP client with
direct-MX delivery.

It can be used three ways:

1. As a **library** — embed an SMTP/IMAP/POP3 server inside your own Dart
   process, or compose and send messages from a CLI tool.
2. As a **reference implementation** — a single, readable codebase that
   shows how each piece of the email ecosystem fits together. The
   [docs/](docs/README.md) folder is a long-form, code-linked tour of how
   email actually works.
3. As a **drop-in dev mailserver** — run [examples/smtp_server.dart](examples/smtp_server.dart)
   to capture mail locally during development, the same way Mailhog or
   the Laravel `log` mailer does.

> Status: 1.0.0 — public API is stable and all protocols are functional,
> but this is not yet a hardened production MTA. See
> [Production notes](#production-notes).

---

## Features

| Area | What's included |
|------|-----------------|
| **SMTP server** | Inbound (port 25) relay, authenticated submission (587), implicit-TLS (465), STARTTLS, `SIZE`, `PIPELINING`, `CHUNKING`, `SMTPUTF8`, `8BITMIME`, `AUTH PLAIN`/`LOGIN`, per-IP rate limiting, PROXY-protocol, SNI, connection pooling. |
| **SMTP client** | `sendMail()` with relay (smarthost) **or** direct MX delivery, MX lookup with priority + randomization, STARTTLS upgrade, multi-recipient fan-out per domain. |
| **IMAP server** | LOGIN/AUTHENTICATE, LIST/LSUB, SELECT/EXAMINE, UID FETCH/STORE/COPY/SEARCH, IDLE, flags, multiple folders, in-memory or pluggable backend. |
| **POP3 server** | USER/PASS, STAT, LIST, UIDL, RETR, DELE, QUIT, TOP. |
| **Message composition** | RFC 5322 + MIME (multipart/alternative, attachments, inline parts), address parsing, IDN (Punycode/Unicode), Message-ID generation, header folding, quoted-printable + base64 encoders. |
| **Authentication** | DKIM **sign** and **verify**, SPF check (`include`, `a`, `mx`, `ip4`, `ip6`, `redirect`, `exists`, macros), DMARC policy lookup + alignment. |
| **Bounces** | RFC 3464 multipart/report DSN builder, status code helpers. |
| **TLS policy** | MTA-STS policy file generator, TLS-RPT DNS record generator, reverse-DNS helper. |
| **Operational** | DNS cache, outbound connection pool, configurable rate limits, structured event API. |

The library has no transport-level dependencies beyond Dart's `dart:io`
and a handful of well-known crypto packages (see [pubspec.yaml](pubspec.yaml)).

---

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  dart_email_server:
    git:
      url: https://github.com/your-org/dart-email-server.git
```

Or, locally:

```yaml
dependencies:
  dart_email_server:
    path: ../dart-email-server
```

Requires the **Dart SDK ≥ 3.11.5**.

---

## Quick start

### 1. Compose a message (no networking)

```dart
import 'package:dart_email_server/dart_email_server.dart';

void main() {
  final result = composeMessageTyped(ComposeMessageOptions(
    from: 'Alice <alice@example.com>',
    to:   'Bob <bob@example.org>',
    subject: 'Hello',
    text: 'Plain body\r\n',
    html: '<p>HTML body</p>',
  ));

  print(result.messageId);
  print(String.fromCharCodes(result.raw)); // RFC 5322 bytes
}
```

### 2. Send through an authenticated relay

```dart
final r = await sendMail(SendMailOptions(
  from: AddressObj(name: 'Alice', address: 'alice@example.com'),
  to:   [AddressObj(address: 'bob@example.org')],
  subject: 'Hi',
  text: 'sent via relay\r\n',
  relay: const RelayOptions(
    host: 'smtp.example.com',
    port: 587,
    username: 'alice@example.com',
    password: 'app-password',
    requireTls: true,
  ),
));
```

### 3. Run an inbound SMTP server

```dart
final server = Server(const ServerOptions(
  hostname: 'mail.example.com',
  ports: ServerPorts(inbound: 2525),
));

server.on('smtpSession', (session, SmtpFacadeState st) {
  session.on('mail', (MailObject mail) {
    print('from=${mail.from} to=${mail.to} subj=${mail.subject}');
    mail.accept();
  });
});

await server.listen();
```

Test it from another terminal:

```sh
swaks --to bob@example.com --from alice@example.org \
      --server 127.0.0.1:2525 --body "hello"
```

### 4. Run an IMAP server

```dart
final server = Server(const ServerOptions(
  hostname: 'imap.example.com',
  ports: ServerPorts(imap: 2143),
));

server.on('auth', (AuthInfo a) {
  if (a.protocol == 'imap' && a.username == 'demo' && a.password == 'demo') {
    a.accept();
  } else {
    a.reject('bad credentials');
  }
});

await server.listen();
```

More end-to-end recipes (direct-MX delivery, submission server, DSN
bounces, MTA-STS material, IMAP with a backing store) live in
[examples/README.md](examples/README.md).

---

## Project layout

```
bin/      Tiny CLI entrypoint
lib/
  dart_email_server.dart  Public re-exports
  cipher/                 RSA, ECDSA, X25519, AES-GCM, HKDF, hashing
  src/
    smtp_wire.dart        SMTP line/reply parser + writer
    smtp_session.dart     Inbound SMTP state machine (relay + submission)
    smtp_client.dart      Outbound sendMail() + MX delivery
    imap_*.dart           IMAP server (wire, session, folders, search, …)
    pop3_session.dart     POP3 server
    message.dart          RFC 5322 / MIME composer + parser
    dkim.dart             DKIM sign / verify
    spf.dart              SPF evaluator
    dmarc.dart            DMARC policy lookup + alignment
    dsn.dart              RFC 3464 DSN builder
    domain.dart           MTA-STS, TLS-RPT, RelayOptions
    server.dart           Top-level Server orchestrator
    pool.dart             Outbound connection pool
    rate_limit.dart       Per-IP rate limiter
    dns_cache.dart        DNS lookup cache
    rdns.dart             Reverse-DNS helper
    utils.dart            IDN, address parsing, etc.
docs/     Long-form "how email works" tour, linked to source
examples/ Runnable demo scripts (one per concept)
test/     Unit + integration tests
```

---

## Documentation

The `docs/` folder is a structured walkthrough of the entire email
ecosystem with links into this codebase:

| # | Chapter |
|---|---------|
| 01 | [Overview & actors (MUA/MSA/MTA/MDA)](docs/01-overview.md) |
| 02 | [Message format (RFC 5322 + MIME)](docs/02-message-format.md) |
| 03 | [SMTP wire protocol](docs/03-smtp-protocol.md) |
| 04 | [DNS & MX routing](docs/04-dns-and-mx.md) |
| 05 | [SPF / DKIM / DMARC](docs/05-authentication-spf-dkim-dmarc.md) |
| 06 | [TLS, MTA-STS, TLS-RPT](docs/06-tls-and-mta-sts.md) |
| 07 | [IMAP & POP3 retrieval](docs/07-imap-and-pop3.md) |
| 08 | [Bounces & DSN](docs/08-bounces-and-dsn.md) |
| 09 | [End-to-end packet walk-through](docs/09-end-to-end-flow.md) |

Start at [docs/README.md](docs/README.md).

For an implementation-focused tour — *how this codebase implements*
each protocol, file by file and class by class — see
[**docs/nuts-and-bolts/**](docs/nuts-and-bolts/README.md).

---

## Public API at a glance

The single import `package:dart_email_server/dart_email_server.dart`
re-exports everything you need:

* **Servers** — `Server`, `ServerOptions`, `ServerPorts`, `ConnectionInfo`,
  `AuthInfo`, `MailObject`.
* **SMTP wire** — `parseReplyBlockTyped`, command/reply types.
* **Sessions** — `SmtpFacadeState`, IMAP/POP3 session facades.
* **Outbound** — `sendMail`, `SendMailOptions`, `RelayOptions`, `SendResult`.
* **Composition** — `composeMessageTyped`, `ComposeMessageOptions`, `AddressObj`.
* **DSN** — `buildDsn(...)`.
* **Auth** — `dkim.sign`, `dkim.verify`, `checkSPF`, `checkDMARC`.
* **Domain material** — MTA-STS policy + TLS-RPT record builders.
* **Utilities** — `domainToAscii`, `domainToUnicode`, `splitAddress`,
  `addressNeedsSmtputf8`, `addressForAsciiOnlyPeer`.

See [lib/index.dart](lib/index.dart) for the exact export surface.

---

## Running the tests

```sh
dart pub get
dart test
```

The test suite covers wire parsers, the message composer, DKIM
round-trips, DSN generation, edge cases, and end-to-end SMTP↔IMAP/POP3
flows over loopback sockets.

---

## Production notes

This package implements the protocols correctly, but running a public
MTA on the open Internet involves more than just protocol code. Before
using it in production you still need:

* A real **TLS certificate** (Let's Encrypt) wired into `SecurityContext`.
* A persistent **mail store** — the bundled IMAP store is in-memory.
* Forward and **reverse DNS** that match, plus published SPF/DKIM/DMARC
  records for your sending domain.
* An **MTA-STS** policy hosted at
  `https://mta-sts.<domain>/.well-known/mta-sts.txt`
  (use the `buildDomainMaterial` helper).
* A **queue** with retries and exponential backoff for transient (4xx)
  failures.
* Outbound IP **reputation** and FCrDNS — most large receivers will
  defer mail from a brand-new IP.
* OS-level **rate limiting** / fail2ban in addition to the in-process
  limiter.

For a *local development sink* — capturing mail your app sends so you
can inspect it — none of the above matters and you can use this today.

---

## License

[Apache License 2.0](lib/LICENSE).
