# 03 — SMTP Wire Protocol

SMTP is a line-based, request/response, ASCII protocol. Every command
is one line ending in CRLF; every reply is one or more lines, each
starting with a 3-digit code. That's it — the rest is conventions and
extensions.

## The shape of a session

```
< 220 mx.example.com ESMTP ready                       (banner)
> EHLO sender.example.org                              (capability negotiation)
< 250-mx.example.com Hello sender.example.org
< 250-PIPELINING
< 250-SIZE 52428800
< 250-8BITMIME
< 250-STARTTLS
< 250-AUTH PLAIN LOGIN
< 250 SMTPUTF8
> STARTTLS
< 220 Ready to start TLS
… TLS handshake …
> EHLO sender.example.org                              (must redo after TLS)
< 250-mx.example.com Hello (encrypted)
< 250 SMTPUTF8
> MAIL FROM:<alice@a.example> SIZE=1234                (envelope sender)
< 250 OK
> RCPT TO:<bob@b.example>                              (envelope recipient)
< 250 OK
> RCPT TO:<carol@b.example>
< 250 OK
> DATA
< 354 End data with <CRLF>.<CRLF>
> From: alice@a.example
> To: bob@b.example, carol@b.example
> Subject: hi
> 
> Hello.
> .
< 250 2.6.0 Message accepted as a8b9c0
> QUIT
< 221 2.0.0 Bye
```

The **envelope** is `MAIL FROM` + `RCPT TO` (one or many). The **message**
is everything between `DATA` and the lone `.` line.

## Reply codes — the 3-digit grammar

A reply code is `XYZ` where each digit is meaningful:

* **X** — outcome class:
  * `2xx` success
  * `3xx` intermediate (server is waiting for more data)
  * `4xx` *temporary* failure (sender should retry later)
  * `5xx` *permanent* failure (sender should bounce)
* **Y** — category: `0` syntax, `1` info, `2` connections, `3` mail
  system, `4` mail/system, `5` mail-server status.
* **Z** — specific reply.

This codebase exposes the table directly:

```dart
// lib/src/smtp_wire.dart
const Map<int, String> smtpReplyClass = {
  2: 'success', 3: 'intermediate', 4: 'tempfail', 5: 'permfail',
};

const Map<int, String> smtpReplyMeaning = {
  220: 'ServiceReady',
  221: 'ServiceClosing',
  235: 'AuthSuccessful',
  250: 'Ok',
  354: 'StartMailInput',
  421: 'ServiceNotAvailable',
  450: 'MailboxUnavailable',
  535: 'AuthInvalid',
  550: 'MailboxUnavailable',
  554: 'TransactionFailed',
  // …
};
```

The most important rule: **`4xx` means retry, `5xx` means give up**.
Confusing the two creates either dropped mail or infinite retry storms.

## Multi-line replies

Continuation lines use `-`; the final line uses a space. So:

```
250-mx.example.com Hello
250-PIPELINING
250 SIZE 52428800
```

is one logical reply (the EHLO banner). The library decodes a multi-line
reply into a [`SmtpReply`](../lib/src/smtp_wire.dart):

```dart
import 'dart:typed_data';
import 'package:dart_email_server/dart_email_server.dart';

final bytes = Uint8List.fromList(
  '250-mx.example.com Hello\r\n'
  '250-PIPELINING\r\n'
  '250 SIZE 52428800\r\n'.codeUnits,
);

final reply = parseReplyBlockTyped(bytes);
print(reply.code);          // 250
print(reply.cls);           // success
print(reply.replyLines);    // [mx.example.com Hello, PIPELINING, SIZE 52428800]
print(reply.capabilities);  // {pipelining: true, size: 52428800, ...}
```

See [`examples/parse_smtp_reply.dart`](../examples/parse_smtp_reply.dart).

## Enhanced status codes (RFC 3463)

Modern servers prefix the human text with `X.Y.Z`:

```
550 5.1.1 The email account that you tried to reach does not exist.
```

| Class | Subject | Meaning |
|---|---|---|
| `2.x.x` | success | as it sounds |
| `4.x.x` | persistent transient | retry later |
| `5.x.x` | permanent | bounce |

The library decodes these into `enhancedStatus` keyed by the full
`X.Y.Z` string.

## Required commands

| Command | Form | Reply on success | Notes |
|---|---|---|---|
| `EHLO` / `HELO` | `EHLO client.example.org` | `250` multi-line | `EHLO` advertises ESMTP capabilities; `HELO` is the legacy fallback. |
| `MAIL FROM` | `MAIL FROM:<a@b> [SIZE=… BODY=8BITMIME …]` | `250` | Starts a transaction; resets any prior. |
| `RCPT TO` | `RCPT TO:<x@y> [NOTIFY=…]` | `250` / `251` | Repeat for each recipient. |
| `DATA` | `DATA` | `354` then `250` after `.\r\n` | The message itself. |
| `RSET` | `RSET` | `250` | Abandon current transaction; keep connection. |
| `NOOP` | `NOOP` | `250` | Keep-alive. |
| `QUIT` | `QUIT` | `221` | Polite close. |

## Optional commands & the EHLO menu

After `EHLO`, the server prints which extensions it supports. Common ones:

| Extension | EHLO line | What it adds |
|---|---|---|
| `SIZE` | `SIZE 52428800` | Maximum bytes; client sends `MAIL FROM:<…> SIZE=N`. Server can reject early. |
| `8BITMIME` | `8BITMIME` | Body may contain bytes 0x80–0xFF (UTF-8). |
| `PIPELINING` | `PIPELINING` | Client may send several commands before reading replies. |
| `STARTTLS` | `STARTTLS` | Upgrade plaintext to TLS. |
| `AUTH` | `AUTH PLAIN LOGIN XOAUTH2` | Submission credentials. |
| `SMTPUTF8` | `SMTPUTF8` | UTF-8 in mailbox local-parts (`josé@example.com`). |
| `CHUNKING` | `CHUNKING` | Replace `DATA` with `BDAT n [LAST]` — usable for binary. |
| `BINARYMIME` | `BINARYMIME` | With CHUNKING, accept truly binary bodies. |
| `DSN` | `DSN` | RFC 3461 delivery status requests (chapter 08). |
| `REQUIRETLS` | `REQUIRETLS` | RFC 8689 — refuse to relay over plaintext. |

This server's `MailFromParams` mirrors the wire flags 1:1:

```dart
// lib/src/smtp_client.dart
class MailFromParams {
  final int? size;        // → SIZE=
  final String? body;     // → BODY=8BITMIME / BINARYMIME
  final bool smtputf8;    // → SMTPUTF8
  final bool requiretls;  // → REQUIRETLS
}
```

## Pipelining

Without pipelining, every command is a round-trip. Over a 100 ms link a
20-recipient message wastes ~2 seconds. With `PIPELINING` the client
fires a batch:

```
> MAIL FROM:<a@b>
> RCPT TO:<r1@x>
> RCPT TO:<r2@x>
> DATA
< 250 OK
< 250 OK
< 250 OK
< 354 Go ahead
```

The client must still wait for the `DATA` reply before sending the body.
The server must read the entire batch even if an early one fails.

## STARTTLS — opportunistic encryption

```
> STARTTLS
< 220 Ready to start TLS
… both peers run a TLS handshake on the existing TCP connection …
> EHLO sender.example.org   (must repeat — capabilities can change)
```

After STARTTLS the previous EHLO results are discarded; this is why you
see EHLO twice in every modern transcript. The session state is reset
to "before EHLO" — the spec calls this a *clean slate*. Chapter 06
covers when STARTTLS is *required* vs. *optional*.

## SMTPUTF8 — UTF-8 in addresses

When both peers advertise `SMTPUTF8`, the client may use UTF-8 bytes
in the local-part of envelope addresses:

```
> MAIL FROM:<josé@correo.example> SMTPUTF8
> RCPT TO:<bob@example.com>
```

Without it, internationalized local-parts must be replaced with an ASCII
alias or rejected.

## DATA and dot-stuffing

`DATA` switches the connection into "message mode" until the server sees
a line containing exactly `.` (`\r\n.\r\n`). To prevent a body line that
naturally starts with `.` from being interpreted as end-of-data, the
sender doubles every leading dot:

```
Body line:        .htaccess rules
On the wire:      ..htaccess rules
Receiver stores:  .htaccess rules
```

This is **dot-stuffing**. Forgetting to undo it on receive is one of
the all-time-classic mail bugs.

## CHUNKING — `BDAT` instead of `DATA`

For binary bodies (or just to skip dot-stuffing), `BDAT n [LAST]` ships
exactly *n* octets following the `\r\n`:

```
> BDAT 4096
> ……4096 raw bytes……
< 250 OK
> BDAT 312 LAST
> ……312 bytes……
< 250 2.6.0 Accepted
```

No CRLF terminator, no dot-escaping — much friendlier to large or
binary content.

## Authentication on submission (port 587/465)

The two universally supported mechanisms are `PLAIN` and `LOGIN`. Both
send credentials in clear text Base64 — TLS underneath is what keeps
them private.

`AUTH PLAIN`:

```
> AUTH PLAIN AGFsaWNlAHM zZWNyZXQ=          ← base64("\0alice\0secret")
< 235 2.7.0 Authentication successful
```

`AUTH LOGIN`:

```
> AUTH LOGIN
< 334 VXNlcm5hbWU6                          ← base64("Username:")
> YWxpY2U=                                   ← base64("alice")
< 334 UGFzc3dvcmQ6                          ← base64("Password:")
> c2VjcmV0                                   ← base64("secret")
< 235 2.7.0 Authentication successful
```

A modern mail provider also offers `XOAUTH2` — the password is replaced
by an OAuth bearer token.

In this server, the submission listener fires an `auth` event with an
[`AuthInfo`](../lib/src/server.dart) the application either accepts or
rejects:

```dart
// from examples/smtp_submission_server.dart
sess.on('auth', (AuthInfo a) {
  final expected = _users[a.username];
  if (expected == null || expected != a.password) {
    a.reject('5.7.8 Authentication credentials invalid');
    return;
  }
  a.accept();
});
```

## A complete client transaction in code

The bare-bones algorithm any SMTP client implements:

```dart
// pseudo-code; the real implementation is lib/src/smtp_client.dart
Future<void> deliver(SocketIO io) async {
  await io.expect(220);
  await io.send('EHLO $localHost');
  final caps = await io.readReply();           // 250-multi-line
  if (caps.has('STARTTLS') && !ignoreTLS) {
    await io.send('STARTTLS'); await io.expect(220);
    await io.upgradeTLS();
    await io.send('EHLO $localHost'); await io.expect(250);
  }
  if (caps.has('AUTH') && auth != null) {
    await io.send('AUTH PLAIN ${authBlob(auth)}');
    await io.expect(235);
  }
  await io.send('MAIL FROM:<${env.from}>'); await io.expect(250);
  for (final r in env.to) {
    await io.send('RCPT TO:<$r>'); await io.expect(250);
  }
  await io.send('DATA');           await io.expect(354);
  await io.sendDotStuffed(message);
  await io.send('.');              await io.expect(250);
  await io.send('QUIT');           await io.expect(221);
}
```

The real version handles pipelining, partial replies, timeouts, MX
fail-over, and TLS errors — see
[`lib/src/smtp_client.dart`](../lib/src/smtp_client.dart).
