# 01 — Overview & Actors

Email looks like one system but is actually a chain of independent
programs that hand a message off, each adding a layer of trust or
control. Understanding *who* does *what* is the single most useful
mental model — once the actors are clear, the protocols just describe
how they talk.

```
┌─────────┐ submission ┌─────────┐ relay ┌─────────┐ delivery ┌─────────┐ retrieval ┌─────────┐
│  MUA    │ ─────────► │  MSA    │ ────► │  MTA    │ ───────► │  MDA    │ ────────► │  MUA    │
│ (Alice) │   :587     │ (smtp)  │ :25   │ (smtp)  │ local    │ (lmtp)  │  :143/993 │  (Bob)  │
└─────────┘  AUTH+TLS  └─────────┘ MX    └─────────┘  spool   └─────────┘  IMAP     └─────────┘
                                                                          :110/995
                                                                          POP3
```

## The five actors

| Actor | Full name | Role | Typical port | Implemented in |
|---|---|---|---|---|
| **MUA** | Mail User Agent | The thing the human uses (Thunderbird, Mail.app, mobile clients, webmail). | n/a | n/a |
| **MSA** | Mail Submission Agent | Accepts new mail from authenticated users, sanity-checks it, queues for relay. | **587** (or 465 implicit-TLS) | [`SmtpSession`](../lib/src/smtp_session.dart) when `state.isSubmission == true` |
| **MTA** | Mail Transfer Agent | Server-to-server hop. Looks up the recipient domain's MX, opens an SMTP connection, transfers the message. | **25** | [`smtp_client.dart`](../lib/src/smtp_client.dart) (outbound) + [`smtp_session.dart`](../lib/src/smtp_session.dart) (inbound) |
| **MDA** | Mail Delivery Agent | Final hop into the user's mailbox storage (mbox, Maildir, database). | local / LMTP | upstream of [`Server.emit('newmail', …)`](../lib/src/server.dart) |
| **MUA** (again) | Same client as before | Pulls new mail back out via IMAP or POP3. | 143/993 (IMAP), 110/995 (POP3) | [`imap_session.dart`](../lib/src/imap_session.dart), [`pop3_session.dart`](../lib/src/pop3_session.dart) |

> **Key insight:** SMTP is *only* used for **pushing** mail to the next
> hop. Reading mail uses entirely different protocols (IMAP/POP3). Many
> bugs come from confusing the two halves.

## The two ports that matter most

* **Port 25 — relay (MTA↔MTA).** No authentication. Anti-abuse comes from
  IP reputation, SPF, DKIM, DMARC, and — increasingly — TLS policy
  (MTA-STS). Most consumer ISPs block outbound 25 to fight botnets.
* **Port 587 — submission (MUA→MSA).** Authentication is **mandatory**
  (`AUTH PLAIN` / `AUTH LOGIN` over STARTTLS, or `XOAUTH2`).
  This is the port your phone uses to send mail through Gmail.

Port 465 is "Submission over implicit TLS" — same intent as 587, but the
TLS handshake happens immediately on connect instead of after `STARTTLS`.

In this codebase the distinction is one line in
[`ServerPorts`](../lib/src/server.dart):

```dart
final server = Server(ServerOptions(
  hostname: 'mx.example.com',
  ports: ServerPorts(
    inbound: 25,        // MTA-to-MTA relay
    submission: 587,    // authenticated MUA submission
    submissions: 465,   // implicit-TLS variant
    imap: 143,
    imaps: 993,
    pop3: 110,
    pop3s: 995,
  ),
));
```

## Envelope vs. message — the most important distinction

Two different "addresses" travel with every email and they are routinely
*not* the same:

| | Envelope | Message header |
|---|---|---|
| Who sets it | The submitting MUA / MSA | The author |
| Used by | The MTA, for routing | Humans, when reading |
| Wire form | `MAIL FROM:<bounces+abc@list.example>` <br> `RCPT TO:<bob@corp.example>` | `From: "Alice" <alice@list.example>` <br> `To: "Bob" <bob@corp.example>` |
| Survives forwarding? | **No** — replaced at every hop | **Yes** — preserved verbatim |

A mailing list is the canonical example: the visible `From:` is the
original author, but the envelope sender is the list's bounce address so
that delivery failures go to the list software, not back to the author.

In this server the envelope addresses arrive on
[`MailObject.from`](../lib/src/server.dart) and `MailObject.to`, and the
header addresses are inside `MailObject.raw` (the bytes after `DATA`).

## A first end-to-end picture

For `alice@a.example` sending to `bob@b.example`:

1. Alice's phone (**MUA**) opens TCP to `smtp.a.example:587`.
2. STARTTLS upgrades the connection; Alice does `AUTH PLAIN`.
3. The submission server (**MSA**) accepts the message into a queue.
4. A queue runner (**MTA**) does `dig MX b.example`, picks the lowest
   priority host (say `mx1.b.example`), opens TCP to it on port 25.
5. The receiving MTA validates SPF (does Alice's IP appear in
   `a.example`'s SPF record?), DKIM (does the signature in the headers
   verify?), and DMARC (do those results align with `From:`?).
6. If accepted, an internal **MDA** writes the message into Bob's
   mailbox.
7. Bob's laptop opens IMAP to `imap.b.example:993`, sees a new
   `EXISTS 42` notification, fetches the message.

Chapter [09 — End-to-end walk-through](09-end-to-end-flow.md) replays
this same scenario with every byte on the wire shown.
