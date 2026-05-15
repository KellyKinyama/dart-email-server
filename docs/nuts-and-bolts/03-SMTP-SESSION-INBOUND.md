# 3. Inbound SMTP session

How a TCP socket on port 25 (or 587 / 465) becomes an accepted message.
This is the longest chapter because SMTP is the most stateful of the
three protocols.

Files in this chapter:

* [`lib/src/smtp_wire.dart`](../../lib/src/smtp_wire.dart) — pure
  parsers and serializers for SMTP lines and reply blocks.
* [`lib/src/smtp_session.dart`](../../lib/src/smtp_session.dart) — the
  state machine.

---

## 3.1. Two-layer split

The session deliberately separates **wire** from **logic**:

```
        bytes from socket
              │
              ▼
   SMTPSession.feed(chunk)
              │  appends to inputBuf
              ▼
   smtp_wire.parseCommandLine(line)   ← purely functional
              │
              ▼
   SMTPSession._handleCommand(parsed)
              │  inspects context.state, mutates it
              ▼
   smtp_wire.<format reply>           ← purely functional
              │
              ▼
   session.emit('send', "250 OK\r\n")
              │
              ▼
   socket.add(...)  (wired in createSession)
```

This means:

* `smtp_wire.dart` has **no I/O** and is fully unit-testable. See
  [`test/smtp_wire_test.dart`](../../test/smtp_wire_test.dart).
* `SMTPSession` has **no parser logic** and **no socket calls** — it
  just emits `'send'` events. The same class therefore drives
  cleartext, STARTTLS-upgraded, and implicit-TLS sockets without
  changes.

---

## 3.2. `smtp_wire.dart` — what it provides

```dart
// reply (server → client)
class SmtpReply {
  int code;            // 220, 250, 354, 451, 550, …
  String type;         // 'success' | 'intermediate' | 'tempfail' | 'permfail'
  EnhancedCode? enhanced; // 2.0.0 etc.
  List<String> lines;
}
SmtpReply parseReplyBlockTyped(Uint8List bytes);

// command (client → server)
Map<String, dynamic> parseCommandLine(Uint8List line);
// returns { 'verb': 'MAIL', 'rest': 'FROM:<a@b>', 'params': {...} }

// EHLO capability advertisement
String formatEhloReply(String hostname, List<String> caps);
```

`parseCommandLine` recognises every verb in RFC 5321 plus the common
extensions (`STARTTLS`, `AUTH`, `SIZE`, `8BITMIME`, `SMTPUTF8`,
`PIPELINING`, `CHUNKING`, `BDAT`). Unknown verbs are returned as-is
for the session to reply with `502 5.5.2 unknown command`.

The reply parser handles RFC 5321 multi-line replies:

```
250-mx.example.com Hello
250-SIZE 26214400
250-PIPELINING
250 SMTPUTF8
```

→ `SmtpReply(code: 250, lines: ['mx.example.com Hello', 'SIZE …', …])`.

---

## 3.3. `SMTPSession` — the state machine

File: [`lib/src/smtp_session.dart`](../../lib/src/smtp_session.dart).

State is held in `SmtpContext` (a struct nested in the session). The
canonical `SessionState` enum:

```dart
enum SessionState {
  NEW, GREETING, READY, MAIL, RCPT, DATA, BDAT, MESSAGE, CLOSING, CLOSED
}
```

Allowed transitions (server side):

```
            ┌──────────────────────────────────────────┐
            ▼                                          │
NEW → GREETING ── EHLO/HELO ──► READY ── MAIL FROM ──► MAIL
                                  │                     │
                                  │                     ▼
                                  │                    RCPT ◄─┐ RCPT TO
                                  │                     │     │ (loop)
                                  │                     ▼     │
                                  │                    DATA / BDAT
                                  │                     │
                                  │                     ▼
                                  └──── RSET / 250 ─── MESSAGE
                                                        │
                                              QUIT / FIN
                                                        ▼
                                                     CLOSING → CLOSED
```

Any out-of-order verb gets `503 5.5.1 Bad sequence of commands`. The
state guards live at the top of each `case` in `_handleCommand`.

---

## 3.4. The verb table

Search [`smtp_session.dart`](../../lib/src/smtp_session.dart) for
`case '<VERB>':`.

| Verb | Allowed from | Reply on success | Side effects |
|---|---|---|---|
| `EHLO` / `HELO` | `GREETING`, `READY` (resets) | `250-` capability list | `clientHostname`, `ehloReceived = true`, `state = READY` |
| `STARTTLS` | `READY` (cleartext only) | `220 Ready to start TLS` | Outer code upgrades the socket; session resets `ehloReceived = false` so client must re-EHLO |
| `AUTH PLAIN` / `LOGIN` / `XOAUTH2` | `READY`, only on submission ports | `334` challenges → `235 Authentication successful` | Emits `'auth'` event; on accept sets `authenticated = true` |
| `MAIL FROM:<…>` | `READY` | `250 2.1.0 Sender OK` | Parses ESMTP params (`SIZE=`, `BODY=`, `SMTPUTF8`, `REQUIRETLS`). `state = MAIL` |
| `RCPT TO:<…>` | `MAIL`, `RCPT` | `250 2.1.5 Recipient OK` | Appends to `rcptTo`. Hits `maxRecipients` → `452 4.5.3` |
| `DATA` | `RCPT` (>= 1 recipient) | `354 End data with <CR><LF>.<CR><LF>` | `state = DATA`; subsequent bytes go into `dataChunks` |
| dot-stuffed body + `\r\n.\r\n` | `DATA` | `250 2.0.0 OK: queued as <id>` | Triggers `parseMessage` → `_completeMessage` (see §3.6) |
| `BDAT n [LAST]` | `READY` (after MAIL/RCPT setup), `BDAT` | `250 2.0.0 chunk accepted` | RFC 3030 CHUNKING. Bytes are taken from `inputBuf` for exactly `n` octets |
| `RSET` | any | `250 2.0.0 Flushed` | Wipes `mailFrom / rcptTo / dataChunks`, `state = READY` |
| `NOOP` | any | `250 2.0.0 OK` | nothing |
| `QUIT` | any | `221 2.0.0 Bye` | `state = CLOSING`, socket closes after flush |
| `HELP` | any | `214` lines | static help text |
| `VRFY` / `EXPN` | any | `252 2.5.2` (cannot verify) | refused for privacy |

---

## 3.5. `feed(chunk)` — the byte-level driver

```dart
void feed(Uint8List chunk) {
  inputBuf = concatU8(inputBuf, chunk);
  if (state == DATA)      _consumeDataPayload();
  else if (state == BDAT) _consumeBdatPayload();
  else                    _consumeCommandLines();
}
```

`_consumeCommandLines()` repeatedly looks for `\r\n` (via
`indexOfCRLF` in [`utils.dart`](../../lib/src/utils.dart)). For each
complete line:

1. `parseCommandLine(line)` → `{ verb, rest, params }`.
2. `_handleCommand(parsed)` switches on `verb`.
3. The handler emits one or more `'send'` events.

`_consumeDataPayload()` is more delicate — it needs to:

* Detect the dot-CRLF terminator, even when split across chunks.
* **Un-stuff** lines that begin with `..` (RFC 5321 §4.5.2).
* Enforce `maxSize` and reply `552 5.3.4 Message too big` if exceeded.

Each accepted chunk is appended to `dataChunks: List<Uint8List>` to
avoid an O(n²) copy on every `feed` call. They are concatenated once
when DATA terminates.

---

## 3.6. `_completeMessage` — the handoff

When the dot terminator arrives:

1. Concatenate `dataChunks` → one `Uint8List rawBytes`.
2. Call the injected `parseMessage` callback (set by `Server.createSession`,
   chapter 5).
3. Build a `MailObject`:
   ```dart
   class MailObject {
     String? from;            // envelope MAIL FROM
     List<String> to;         // envelope RCPT TO
     String? subject;         // header
     String? text, html;      // decoded bodies
     String? headerFrom;      // header From
     int size;                // raw byte count
     Uint8List raw;           // exact bytes received
     MailAuthResult authResults;
     void Function() accept;
     void Function([String? msg]) reject;
     void Function() emitBody;
   }
   ```
4. Emit `'message'` on the session.
   * For **inbound** sessions, the `Server`'s default handler runs
     SPF/DKIM/DMARC/rDNS in parallel (chapter 4) and only then forwards
     to the user's `'mail'` listener.
   * For **submission** sessions, the message is forwarded to the
     `'smtpSession'` facade's `'mail'` event immediately — your code
     is expected to DKIM-sign and hand it to the outbound pool.
5. Wait for `mail.accept()` or `mail.reject(msg)`.
6. Send `250 2.0.0 OK: queued as <id>` or `5xx <reason>`.
7. Reset to `state = READY`, clear `mailFrom / rcptTo / dataChunks`.

The session doesn't time out waiting for the listener — the listener
*must* eventually call accept or reject. If it doesn't, the connection
hangs until the client gives up. (A future improvement: enforce
`acceptTimeout` here.)

---

## 3.7. Capability advertisement

After a successful `EHLO`, the session builds the multiline reply
based on what the server supports *right now* on this socket:

| Cap | Condition |
|---|---|
| `SIZE 26214400` | Always; value from `context.maxSize` |
| `8BITMIME` | Always |
| `SMTPUTF8` | Always |
| `PIPELINING` | Always |
| `CHUNKING` | Always |
| `STARTTLS` | `!isTLS && tlsOptions != null` |
| `AUTH PLAIN LOGIN XOAUTH2` | `isSubmission && (isTLS || advertiseAuthCleartext)` — auth on cleartext is refused unless explicitly enabled, to discourage password leakage |
| `ENHANCEDSTATUSCODES` | Always |

Every reply line in the session also carries an enhanced status code
(`2.1.0`, `5.7.1`, …). See `EnhancedCode` in
[`smtp_wire.dart`](../../lib/src/smtp_wire.dart).

---

## 3.8. The PROXY-protocol prelude

If `ServerOptions.useProxy == true`, the *very first* bytes on the
socket are expected to be a PROXY-protocol v1 line:

```
PROXY TCP4 198.51.100.7 198.51.100.1 54321 25\r\n
```

The session parses this *before* sending the 220 greeting and uses the
parsed source IP as `remoteAddress` instead of the kernel's view. This
is what lets you put an L4 load balancer (HAProxy, AWS NLB) in front of
the server without losing the real client IP for SPF and rate-limiting.

If the prelude is missing or malformed when expected, the session
closes the socket with no greeting.

---

## 3.9. Submission vs inbound — the two-rule-set switch

`isSubmission` is set once at session construction and never changes.
It changes:

* `AUTH` is **required** before `MAIL FROM` (else `530 5.7.0 Auth required`).
* `MAIL FROM` is checked against the authenticated user (you can do
  this in your `'mail'` listener — the session itself does not bind
  identity to address).
* The `'message'` event bypasses SPF/DKIM/DMARC and goes straight to
  the per-session `'mail'` event for application processing.
* DKIM signing is the *application's* job — `Server.resolveDkim(domain)`
  exposes the key, and [`dkim.sign`](../../lib/src/dkim.dart) does the
  work; see chapter 4.

---

## 3.10. End-to-end packet trace

A real submission session, end to end:

```
< 220 mx.example.com ESMTP dart_email_server
> EHLO laptop.local
< 250-mx.example.com Hello laptop.local [203.0.113.5]
< 250-SIZE 26214400
< 250-8BITMIME
< 250-SMTPUTF8
< 250-PIPELINING
< 250-CHUNKING
< 250-STARTTLS
< 250 ENHANCEDSTATUSCODES
> STARTTLS
< 220 2.0.0 Ready to start TLS
*** TLS handshake; SecureSocket.secure(server: ctx) ***
> EHLO laptop.local
< 250-mx.example.com Hello laptop.local [203.0.113.5]
< 250-AUTH PLAIN LOGIN XOAUTH2
< 250 ENHANCEDSTATUSCODES
> AUTH PLAIN AGFsaWNlAHN1cGVyc2VjcmV0
< 235 2.7.0 Authentication successful
> MAIL FROM:<alice@example.com> SIZE=2345 SMTPUTF8
< 250 2.1.0 Sender OK
> RCPT TO:<bob@example.org>
< 250 2.1.5 Recipient OK
> DATA
< 354 End data with <CR><LF>.<CR><LF>
> From: Alice <alice@example.com>
> To: Bob <bob@example.org>
> Subject: hi
>
> body
> .
< 250 2.0.0 OK: queued as 9c84e1
> QUIT
< 221 2.0.0 Bye
*** FIN ***
```

---

Next: [Chapter 4 — Auth: SPF, DKIM, DMARC, rDNS](./04-AUTH-SPF-DKIM-DMARC.md).
