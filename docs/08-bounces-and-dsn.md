# 08 — Bounces & DSNs

When a message can't be delivered, the receiving MTA generates a
**Delivery Status Notification** (DSN, RFC 3464) and sends it back to
the envelope sender (`MAIL FROM`). Done well, DSNs let the sender
distinguish "user is on vacation" from "user does not exist" from "your
domain is on a blocklist."

## When does a bounce happen?

| Scenario | Reply class | Outcome |
|---|---|---|
| Unknown user (`5.1.1`) | `5xx` at `RCPT TO` | Bounce immediately. |
| Mailbox full (`4.2.2`) | `4xx` at `RCPT TO` or `DATA` | Re-queue, retry hourly for ~3 days, then bounce. |
| Spam scoring rejection (`5.7.1`) | `5xx` after `DATA` | Bounce. |
| TLS policy mismatch (`5.7.10`) | `5xx` before `MAIL FROM` | Bounce; sender may surface as "TLS error." |
| Connection refused / timeout | n/a — TCP failure | Re-queue; bounce after deadline. |

The sender's queue runner produces the bounce; receivers never bounce
on the *original* connection (you can't push back into a TCP socket
that has already been closed).

## The "null sender" — who bounces a bounce?

Every DSN must use an **empty envelope sender**:

```
> MAIL FROM:<>
> RCPT TO:<alice@a.example>
> DATA
…the bounce…
.
```

`MAIL FROM:<>` exists for exactly this reason — it prevents bounce
loops. If a DSN itself fails to deliver, the receiver simply *drops*
it; there is no further bounce.

The visible `From:` of a DSN is conventionally
`MAILER-DAEMON@<receiving-host>`.

## DSN structure — three MIME parts

A DSN is a `multipart/report; report-type=delivery-status` with three
parts:

```
Content-Type: multipart/report; report-type=delivery-status;
              boundary="b1"

--b1
Content-Type: text/plain

Your message could not be delivered to bob@b.example because the
mailbox does not exist.

--b1
Content-Type: message/delivery-status

Reporting-MTA: dns; mx1.b.example
Arrival-Date: Tue, 05 May 2026 09:00:01 +0000

Final-Recipient: rfc822; bob@b.example
Action: failed
Status: 5.1.1
Diagnostic-Code: smtp; 550 5.1.1 No such user
Last-Attempt-Date: Tue, 05 May 2026 09:00:02 +0000
Remote-MTA: dns; mx1.b.example

--b1
Content-Type: message/rfc822

From: alice@a.example
To: bob@b.example
Subject: hi
…original headers (or full message)…

--b1--
```

### Part 1 — `text/plain` summary

Human-readable. The only part most users ever see.

### Part 2 — `message/delivery-status`

Machine-readable. Two header *blocks* separated by a blank line:

* **Per-message** fields (`Reporting-MTA:`, `Arrival-Date:`).
* **Per-recipient** fields, repeated once per recipient
  (`Final-Recipient:`, `Action:`, `Status:`, …).

| Field | Values |
|---|---|
| `Action` | `failed`, `delayed`, `delivered`, `relayed`, `expanded` |
| `Status` | Enhanced status code `X.Y.Z` from RFC 3463 |
| `Diagnostic-Code` | `smtp; <reply line>` — the actual SMTP refusal |

### Part 3 — `message/rfc822` (or `text/rfc822-headers`)

The original message — full body, or just the headers, depending on
what the sender requested via `RET=`.

## Building a DSN with this codebase

```dart
import 'package:dart_email_server/dart_email_server.dart';

final dsn = buildDsn(DsnOptions(
  reportingMta: 'mx1.b.example',
  from: 'MAILER-DAEMON@mx1.b.example',
  to: 'alice@a.example',
  arrivalDate: DateTime.utc(2026, 5, 5, 9, 0, 1),
  originalMessage: originalRawBytes,
  returnContent: 'headers',           // or 'full'
  recipients: [
    DsnRecipient(
      finalRecipient: 'bob@b.example',
      action: 'failed',
      status: '5.1.1',
      diagnostic: 'smtp; 550 5.1.1 No such user',
      remoteMta: 'mx1.b.example',
      lastAttempt: DateTime.utc(2026, 5, 5, 9, 0, 2),
    ),
  ],
));

print(dsn.raw);   // ready to hand to your relay queue
```

See [`examples/build_dsn.dart`](../examples/build_dsn.dart).

## Sender-side: requesting DSNs (RFC 3461)

A submitting client can ask for explicit notifications:

```
> MAIL FROM:<alice@a.example> RET=HDRS ENVID=msg-12345
> RCPT TO:<bob@b.example> NOTIFY=SUCCESS,FAILURE,DELAY ORCPT=rfc822;bob@b.example
> RCPT TO:<carol@b.example> NOTIFY=NEVER
```

| `MAIL FROM` parameter | Meaning |
|---|---|
| `RET=FULL` | Include the entire original message in the DSN. |
| `RET=HDRS` | Headers only (default). |
| `ENVID=…` | Envelope ID — echoed back in the DSN's `Original-Envelope-Id:`. |

| `RCPT TO` parameter | Meaning |
|---|---|
| `NOTIFY=SUCCESS,FAILURE,DELAY` | Tell me when each happens. |
| `NOTIFY=NEVER` | No DSN at all. |
| `ORCPT=rfc822;…` | The "original recipient" before any forwarding. Echoed in `Original-Recipient:`. |

`NOTIFY=NEVER` is critical when *forwarding*: when your mail server
re-injects an incoming message to the user's actual ISP, you don't want
the ISP's bounces flying back at the original sender — you want them to
land at you. Mailing list software does this for every message.

## Out-of-band bounces (the bad case)

Some receivers accept the message at `DATA`, then *later* discover it's
spam or the user no longer exists, and bounce asynchronously. These
**out-of-band bounces** are common from large providers and they are a
major spam vector — anyone can forge a `MAIL FROM` and trigger a
"bounce" to the victim.

Two defenses:

* **BATV (Bounce Address Tag Validation)** — sign the local-part of
  every `MAIL FROM` with a private key; reject `<>` bounces whose
  recipient doesn't carry a valid signature.
* **DMARC alignment** — out-of-band bounces have `From: MAILER-DAEMON@…`
  and a forged `<>` envelope; DMARC catches the forgery if the spoofed
  domain has `p=reject`.

## Reading bounces in operations

When triaging "why didn't my mail go through?", the file you want is
the DSN's `message/delivery-status` part. The two fields that *always*
matter:

```
Status: 5.7.1
Diagnostic-Code: smtp; 550 5.7.1 SPF check failed for a.example
```

`5.7.x` = security/policy. `5.1.1` = no such user. `4.x.x` = transient.
The `Diagnostic-Code` is verbatim what the receiver said, often with
links to their support docs.
