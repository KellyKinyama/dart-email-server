# 0. Overview — the data-flow picture

Before diving into individual files, install the mental model. The
rest of the tutorial just adds precision to the picture you'll build
here.

---

## 0.1. What this server is, in 30 seconds

`dart_email_server` is **three protocol servers in one process** plus a
small **outbound SMTP client** and a stack of helpers that decide
whether to trust a message:

1. **Inbound SMTP** (port 25) — accepts mail from other servers on
   the public Internet. No auth. SPF/DKIM/DMARC decide trust.
2. **Submission SMTP** (port 587 / 465) — accepts mail from your own
   users. Auth required. The server may then DKIM-sign and relay.
3. **Mailbox protocols** — IMAP (143/993) and POP3 (110/995) — let
   users *read* the mail that landed in step 1.
4. **Outbound SMTP client** — `sendMail()` and the `OutboundPool` look
   up MX records and deliver to the next hop.

It does **not** decode HTML for rendering, run a spam classifier, or
ship a persistent mailbox store — those are explicitly application
responsibilities and live above the `'mail'` and `'mailboxSession'`
events emitted by [`Server`](../../lib/src/server.dart).

Compare to:

* **Postfix / Exim** — full MTA with on-disk queue, alias system,
  pluggable LDA. This is much smaller; it gives you the protocol and
  hands you the bytes.
* **Mailhog / MailCatcher** — dev-only "sink" servers. This can do
  that, but can also relay, sign, and serve mailboxes.
* **Nodemailer** — outbound only. This includes outbound delivery, but
  also accepts and serves.

---

## 0.2. The two sides — inbound and outbound

For each participating *domain*, an email server actually plays two
unrelated roles:

```
                   ┌─────────────────┐
   peer MTA   ────►│ inbound SMTP :25│  (relay accepted, trust judged)
                   └─────────────────┘
                   ┌─────────────────┐
   your users ────►│ submission :587 │  (auth required, DKIM-signed)
                   └─────────────────┘   ──► OutboundPool ──► peer MX
                   ┌─────────────────┐
   your users ◄────│  IMAP :143/993  │  (read what inbound dropped)
                   └─────────────────┘
```

Files:

* Inbound + submission — [`lib/src/smtp_session.dart`](../../lib/src/smtp_session.dart).
* Outbound — [`lib/src/smtp_client.dart`](../../lib/src/smtp_client.dart) + [`lib/src/pool.dart`](../../lib/src/pool.dart).
* Mailbox — [`lib/src/imap_session.dart`](../../lib/src/imap_session.dart), [`lib/src/pop3_session.dart`](../../lib/src/pop3_session.dart).

Why split inbound vs submission when both speak SMTP? Because the rules
are different: submission requires `AUTH`, can rewrite headers, and
should DKIM-sign. Inbound forbids `AUTH`, must run SPF/DKIM/DMARC, and
must accept whatever shows up. The same `SMTPSession` class handles
both — `isSubmission: true` flips the rule set.

---

## 0.3. The hot path — one inbound message's journey

Follow a single message arriving at port 25 from a peer MTA:

```
1. Remote MTA opens TCP connection. Kernel hands the socket to our
   ServerSocket listener.
        ↓
2. Server.handleConnection (lib/src/server.dart) wraps the Socket,
   records a ConnectionRecord, optionally STARTTLS-upgrades, and
   constructs an SMTPSession.
        ↓
3. Bytes from the socket → SMTPSession.feed() → smtp_wire.dart
   tokenises lines / handles literals.
        ↓
4. SMTPSession state machine walks GREETING → READY → MAIL → RCPT
   → DATA, validating each verb against context.state.
        ↓
5. After DATA's terminating ".\r\n", SMTPSession assembles raw bytes,
   calls parseMessage() (chapter 5) → MailObject.
        ↓
6. Server emits 'message'. The default handler runs:
        a. SPF check on MAIL FROM domain (spf.dart)
        b. DKIM verify against DNS-published public key (dkim.dart)
        c. DMARC alignment + policy lookup (dmarc.dart)
        d. forward-confirmed reverse-DNS (rdns.dart)
   Each writes its verdict to MailObject.authResults.
        ↓
7. Once all four return, the session emits 'mail'. The application
   listener decides:
        - mail.accept()   → 250 OK back to sender
        - mail.reject(msg) → 5xx back to sender
        ↓
8. Application persists to a mailbox store, which IMAP/POP3 sessions
   later read.
```

Steps 3–5 happen **per command, per connection**. Step 6 fires at most
once per accepted message and may stall the response while DNS lookups
finish — the session re-arms a timeout to avoid hanging the peer.

---

## 0.4. The hot path — one outbound message's journey

Follow a message handed to `sendMail()` (or to a submission session
that needs to relay):

```
1. Caller builds SendMailOptions (or the inbound submission session
   produced a MailObject). composeMessageTyped() if no raw bytes yet.
        ↓
2. sendMail() (smtp_client.dart) groups recipients by RCPT domain.
        ↓
3. For each domain:
        a. RelayOptions present?     → host = relay.host, single hop
        b. otherwise resolveMX(d)    → list of (priority, exchange)
        ↓
4. OutboundPool.sendOnce() picks an idle SMTPConnectionWrapper for
   that exchange (or opens one); rate-limits per minute.
        ↓
5. SMTPConnectionWrapper drives the wire:
        EHLO → STARTTLS → EHLO → AUTH (if creds) → MAIL FROM → RCPT
        TO* → DATA → bytes → "."
        ↓
6. Reply codes parsed (smtp_wire.parseReplyBlockTyped):
        2xx → SendResult.accepted
        4xx → schedule retry from PoolOptions.retryDelays
        5xx → SendResult.rejected (caller may build a DSN, chapter 10)
        ↓
7. Connection returned to pool (or closed if maxMessagesPerConn hit).
```

The pool keeps **at most `maxPerDomain`** open connections to any one
exchange and reuses them until `idleTimeout` or `maxMessagesPerConn`.

---

## 0.5. The cold path — control-plane events

Less frequent but more interesting:

| Event | Trigger | What happens |
|---|---|---|
| `Server.listen()` | App startup | One `ServerSocket` per non-null port in `ServerPorts` |
| `addDomain(material)` | App startup | DKIM/MTA-STS/TLS material registered; async `verifyDNS()` emits warnings |
| Connection accepted | Kernel `accept()` | `ConnectionInfo` event — listener may `reject()` |
| STARTTLS / implicit TLS | Client requests, or 465/993/995 | `SecureSocket.secure(server: ctx)` upgrades the socket |
| `auth` event | SMTP AUTH / IMAP LOGIN / POP3 USER+PASS | App listener calls `accept()` or `reject(msg)` |
| `dnsWarning` | After `verifyDNS()` | Missing SPF/DKIM/DMARC/MX record for a registered domain |
| `bounce` | Outbound 5xx exhaust retries | Pool emits payload; app builds DSN via `buildDsn()` |
| Connection close | Socket FIN/RST or QUIT | Session state → `CLOSED`, `ConnectionRecord` removed |

---

## 0.6. State ownership map

If you remember nothing else from this chapter, remember which object
owns which state:

| State | Owner | File |
|---|---|---|
| Registered domains (DKIM keys, TLS certs, MTA-STS) | `ServerContext.domains` | [server.dart](../../lib/src/server.dart) |
| Listening sockets | `ServerContext.servers` | [server.dart](../../lib/src/server.dart) |
| Active connections (id → record) | `ServerContext.connections` | [server.dart](../../lib/src/server.dart) |
| SMTP per-connection state machine | `SmtpContext` inside `SMTPSession` | [smtp_session.dart](../../lib/src/smtp_session.dart) |
| Buffered DATA chunks pre-parse | `SmtpContext.dataChunks` | [smtp_session.dart](../../lib/src/smtp_session.dart) |
| MAIL FROM, RCPT TO, ext params | `SmtpContext.mailFrom / rcptTo / mailParams` | [smtp_session.dart](../../lib/src/smtp_session.dart) |
| Per-message auth verdicts | `MailObject.authResults` | [smtp_session.dart](../../lib/src/smtp_session.dart) |
| IMAP folder tree + flags | `ImapFolders` (per session) | [imap_folders.dart](../../lib/src/imap_folders.dart) |
| IMAP message store handle | injected via `IMAPSession` callbacks | [imap_session.dart](../../lib/src/imap_session.dart) |
| Outbound conn pool (per MX exchange) | `OutboundPool._pools` | [pool.dart](../../lib/src/pool.dart) |
| MX cache | `dns_cache.dart` module-level | [dns_cache.dart](../../lib/src/dns_cache.dart) |
| Per-IP failure counters + bans | `RateLimiter._states` | [rate_limit.dart](../../lib/src/rate_limit.dart) |
| TLS contexts (per servername) | `ServerContext.secureContexts` | [server.dart](../../lib/src/server.dart) |

---

## 0.7. Glossary

* **MUA** — Mail User Agent. The thing the human uses (Thunderbird,
  Apple Mail, mobile clients).
* **MSA** — Mail Submission Agent. The server side of port 587. Auth
  required; this is the role our submission session plays.
* **MTA** — Mail Transfer Agent. The server-to-server hop on port 25.
  Both inbound `SMTPSession` and outbound `SmtpClient` are MTAs.
* **MDA** — Mail Delivery Agent. The thing that finally writes the
  message to a mailbox. Lives **above** this library — you implement
  it in the `'mail'` event handler.
* **Envelope** — `MAIL FROM` / `RCPT TO` from the SMTP wire. Used for
  routing. Replaced at every hop.
* **Header** — `From:` / `To:` *inside* the message. Used by humans.
  Preserved verbatim.
* **STARTTLS** — Cleartext connection that upgrades to TLS mid-stream.
  Used on 25/587/143/110.
* **Implicit TLS** — TLS from byte zero. Used on 465/993/995.
* **SPF** — Sender Policy Framework. DNS TXT record listing which IPs
  are allowed to send for a domain.
* **DKIM** — DomainKeys Identified Mail. Cryptographic signature over
  selected headers + body, key published in DNS.
* **DMARC** — Policy that says "if SPF and DKIM both fail, do X" and
  "send me reports". Requires *alignment* between the visible `From:`
  domain and the SPF/DKIM domain.
* **MTA-STS** — Policy file at `https://mta-sts.<domain>/.well-known/`
  saying "always use TLS to reach my MX".
* **DSN** — Delivery Status Notification (RFC 3464). Structured bounce.
* **MX** — DNS record listing the mail exchanger(s) for a domain, with
  priority. Lower priority = preferred.
* **8BITMIME / SMTPUTF8 / CHUNKING / PIPELINING / SIZE** — SMTP
  extensions advertised after `EHLO`.
* **rDNS / FCrDNS** — Reverse DNS, optionally forward-confirmed (the
  PTR resolves back to the same IP). Reputation signal.

---

## 0.8. What this server explicitly is and isn't

**Is:**

* A reference Dart implementation of inbound + outbound + mailbox
  protocols, with all three SMTP modes (relay/submission/implicit-TLS).
* Production-shaped: rate limits, DNS cache, connection pool, retry
  curve, structured event surface.
* A great local development sink (run [`smtp_server.dart`](../../examples/smtp_server.dart)).

**Is not:**

* A full MTA replacement for Postfix / Exim — there's no on-disk queue,
  no alias map, no LDA chaining, no per-recipient routing rules.
* A persistent mailbox store — the bundled IMAP backend is in-memory.
* A spam filter — there's no Bayesian classifier, RBL lookup, or URL
  reputation. Add your own from the `'mail'` event.
* SMTP-over-TLS-only — cleartext fallback is supported (and required
  for port 25 interop).

---

Next: [Chapter 1 — Process and listeners](./01-PROCESS-AND-LISTENERS.md).
