# How Email Works — A Deep Dive

This folder is a long-form, code-driven tour of how Internet email actually
moves from a user's "Send" button to another user's inbox. Every protocol
mentioned here is implemented somewhere in this repository, so each chapter
links to the relevant Dart source and shows a working snippet you can run
or adapt.

The story is told bottom-up: we start with the *shape* of a message, then
look at how one server hands a message to the next, then layer on the trust
machinery (SPF, DKIM, DMARC, MTA-STS) that decides whether the receiver
believes you.

## Reading order

| # | Chapter | What you learn |
|---|---|---|
| 01 | [Overview & actors](01-overview.md) | MUA, MSA, MTA, MDA, MX — who is who, and which port they speak on. |
| 02 | [Message format (RFC 5322 + MIME)](02-message-format.md) | Headers, bodies, multipart, encodings, the difference between an *envelope* and a *message*. |
| 03 | [SMTP wire protocol](03-smtp-protocol.md) | EHLO, MAIL FROM, RCPT TO, DATA, reply codes, pipelining, CHUNKING, SMTPUTF8. |
| 04 | [DNS & MX routing](04-dns-and-mx.md) | How a sender finds the receiving server; MX, A/AAAA fallback, priority and randomization. |
| 05 | [SPF / DKIM / DMARC](05-authentication-spf-dkim-dmarc.md) | The three pillars of sender authentication and how reports flow back. |
| 06 | [TLS / MTA-STS / TLS-RPT](06-tls-and-mta-sts.md) | STARTTLS, opportunistic vs. enforced TLS, MTA-STS policy files, TLS reporting, DANE. |
| 07 | [IMAP & POP3 retrieval](07-imap-and-pop3.md) | How clients fetch messages: folders, flags, UIDs, IDLE, search. |
| 08 | [Bounces & DSN](08-bounces-and-dsn.md) | Delivery Status Notifications: structure, status codes, return-path. |
| 09 | [End-to-end walk-through](09-end-to-end-flow.md) | A single message followed packet-by-packet from sender to inbox. |

## How the snippets relate to this codebase

The repository implements all three legs of the mail triangle in pure Dart:

* **Sending side** — [lib/src/smtp_client.dart](../lib/src/smtp_client.dart),
  [lib/src/message.dart](../lib/src/message.dart),
  [lib/src/dkim.dart](../lib/src/dkim.dart).
* **Receiving SMTP side** — [lib/src/smtp_session.dart](../lib/src/smtp_session.dart),
  [lib/src/smtp_wire.dart](../lib/src/smtp_wire.dart),
  [lib/src/spf.dart](../lib/src/spf.dart),
  [lib/src/dmarc.dart](../lib/src/dmarc.dart).
* **Mailbox access** — [lib/src/imap_session.dart](../lib/src/imap_session.dart),
  [lib/src/pop3_session.dart](../lib/src/pop3_session.dart).
* **Server orchestration** — [lib/src/server.dart](../lib/src/server.dart).

Runnable demos live in [examples/README.md](../examples/README.md).

## Conventions used in these docs

* `>` lines are sent **by the client** to the server.
* `<` lines are sent **by the server** to the client.
* `CRLF` (`\r\n`) terminates every protocol line — there are no exceptions
  in SMTP/IMAP/POP3.
* "Octet" means *byte* — the RFCs use the older term and so do most error
  messages you'll see in real logs.
