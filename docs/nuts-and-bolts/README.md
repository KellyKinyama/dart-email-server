# **dart_email_server — Nuts and Bolts**

A full architectural walkthrough of the pure-Dart email stack in this
repository. Companion to the protocol tutorial in [`../`](../README.md)
(which explains *email itself*); this folder explains *how this codebase
implements it* — file by file, class by class, hot path and cold path.

> An email server does one job: take an RFC 5322 message from one
> network endpoint and hand it to another. Everything else in this
> codebase — sessions, SPF/DKIM/DMARC, IMAP folders, the outbound pool,
> rate limiting, DSN — exists to do that one job at scale, with trust,
> and without losing mail.

---

## Chapters

| # | File | What it covers |
|---|---|---|
| 0 | [00-OVERVIEW.md](./00-OVERVIEW.md) | Big-picture data flow, actors, hot/cold paths, state-ownership map, glossary |
| 1 | [01-PROCESS-AND-LISTENERS.md](./01-PROCESS-AND-LISTENERS.md) | `bin/dart_email_server.dart`, `Server.listen()`, per-protocol sockets, TLS contexts, SNI |
| 2 | [02-SERVER-CONTEXT-CONNECTION.md](./02-SERVER-CONTEXT-CONNECTION.md) | `Server`, `ServerContext`, `ConnectionRecord`, the event bus |
| 3 | [03-SMTP-SESSION-INBOUND.md](./03-SMTP-SESSION-INBOUND.md) | `smtp_wire.dart`, `smtp_session.dart` state machine, EHLO → DATA → ACK |
| 4 | [04-AUTH-SPF-DKIM-DMARC.md](./04-AUTH-SPF-DKIM-DMARC.md) | The verification pipeline that runs after `DATA` |
| 5 | [05-MESSAGE-PARSE-AND-COMPOSE.md](./05-MESSAGE-PARSE-AND-COMPOSE.md) | `message.dart`: parsing inbound bytes, composing outbound bytes |
| 6 | [06-OUTBOUND-CLIENT-AND-POOL.md](./06-OUTBOUND-CLIENT-AND-POOL.md) | `sendMail`, MX lookup, `OutboundPool`, retry curve |
| 7 | [07-IMAP-SESSION.md](./07-IMAP-SESSION.md) | `imap_session.dart` + helpers, FETCH/SEARCH/IDLE, mailbox facade |
| 8 | [08-POP3-SESSION.md](./08-POP3-SESSION.md) | `pop3_session.dart`, the simplest of the three protocols |
| 9 | [09-RATE-LIMIT-AND-DNS-CACHE.md](./09-RATE-LIMIT-AND-DNS-CACHE.md) | Cross-cutting infrastructure: `RateLimiter`, `dns_cache`, rDNS |
| 10 | [10-DSN-AND-OBSERVABILITY.md](./10-DSN-AND-OBSERVABILITY.md) | Bounces, the `Server` event surface, hooks for metrics and tests |

## How to read it

Read in order if this is your first email server. Each chapter ends
with a "connect to next stage" pointer so the data-flow picture builds
incrementally.

If you already know SMTP/IMAP and just want to find a specific
subsystem, jump straight to the chapter — every section names the
**exact files and class/method names** so you can read source side by
side.

## Top-level map

```
                bin/dart_email_server.dart       ← chapter 1
                          │
                          ▼
                       Server                    ← chapter 2
                       │ (one ServerSocket per enabled port)
        ┌──────────────┼─────────────┬─────────────┐
        ▼              ▼             ▼             ▼
   inbound:25    submission:587   imap:143     pop3:110
   secure:465                     imaps:993    pop3s:995
        │              │             │             │
        ▼              ▼             ▼             ▼
   SMTPSession   SMTPSession    IMAPSession   POP3Session   ← chs 3, 7, 8
        │ (relay)     │ (auth)        │             │
        ▼              ▼             ▼             ▼
   parseMessage  parseMessage    folder ops    mailbox ops
        │              │
        ▼              ▼
   SPF / DKIM /   composeMessage
   DMARC / rDNS                                              ← chapters 4, 5
        │              │
        ▼              ▼
   MailObject     OutboundPool ─► SmtpClient ─► remote MX   ← chapter 6
        │              ▲
        ▼              │
   'mail' event   sendMail()
        │
        ▼
   Application (mail store, queue, webhook…)
```

## Prerequisites

* You've at least skimmed [`../README.md`](../README.md) and the
  protocol-overview chapter [`../01-overview.md`](../01-overview.md).
* Comfortable with Dart's `dart:io` socket API and `Future`/`Stream`.
* Comfortable with the email vocabulary used throughout: envelope vs
  header, MTA vs MSA, RFC 5322, MIME, STARTTLS, SPF/DKIM/DMARC.
* Helpful, not required: a passing familiarity with the Node.js
  `EventEmitter` pattern (this codebase uses one — see
  [utils.dart](../../lib/src/utils.dart)).

## Conventions

* File links go to actual source. Click them.
* "**Hot path**" = code that runs per packet / per command (high
  frequency). "**Cold path**" = once per connection / per session.
* "**Inbound**" = bytes arriving from the network into this process.
  "**Outbound**" = bytes this process sends to the network.
* `>` lines in protocol traces are sent **by the client** to the
  server; `<` lines are sent **by the server** to the client.
* Constants in `SHOUTING_SNAKE_CASE` (e.g. `DEFAULT_MAX_SIZE`) are
  internal-only and not exported from
  [`lib/index.dart`](../../lib/index.dart).
