# 09 — End-to-End Walk-Through

One message, all the way from Alice's phone to Bob's laptop, with
every byte that crosses every wire. This ties together everything in
chapters 01–08.

## Setup

* Alice — `alice@a.example`, on her phone, network IP 203.0.113.42.
* Bob — `bob@b.example`, on a laptop with IMAP open to his mailbox.
* `a.example` publishes:
  * `MX  10 mx.a.example`
  * `TXT "v=spf1 ip4:198.51.100.0/24 -all"` (her submission server)
  * `TXT 2026q2._domainkey.a.example  "v=DKIM1; k=rsa; p=…"`
  * `TXT _dmarc.a.example  "v=DMARC1; p=reject; rua=mailto:dmarc@a.example"`
* `b.example` publishes:
  * `MX  10 mx1.b.example`
  * `TXT _mta-sts.b.example  "v=STSv1; id=20260101"`
  * MTA-STS policy at `https://mta-sts.b.example/.well-known/mta-sts.txt`
    listing `mx1.b.example` in `mode: enforce`.

## Step 1 — Alice's phone composes the message

Tapping Send results in a `multipart/alternative` blob in memory:

```dart
final composed = composeMessageTyped(ComposeMessageOptions(
  from: 'Alice <alice@a.example>',
  to:   'Bob <bob@b.example>',
  subject: 'lunch?',
  text: 'Free at 12:30?',
  html: '<p>Free at <b>12:30</b>?</p>',
));
```

`composed.raw` is what we'll send after `DATA`.

## Step 2 — Submission to the MSA (port 587)

The phone opens TCP to `smtp.a.example:587` (resolved from DNS A) and:

```
< 220 smtp.a.example ESMTP ready
> EHLO phone-12ab
< 250-smtp.a.example Hello phone-12ab [203.0.113.42]
< 250-PIPELINING
< 250-SIZE 52428800
< 250-STARTTLS
< 250-AUTH PLAIN LOGIN
< 250-8BITMIME
< 250 SMTPUTF8
> STARTTLS
< 220 Ready to start TLS
… TLS 1.3 handshake …
> EHLO phone-12ab
< 250-smtp.a.example Hello (encrypted)
< 250-AUTH PLAIN LOGIN
< 250-PIPELINING
< 250 SMTPUTF8
> AUTH PLAIN AGFsaWNlAHNlY3JldA==
< 235 2.7.0 Authentication successful
> MAIL FROM:<alice@a.example> SIZE=487
< 250 2.1.0 OK
> RCPT TO:<bob@b.example>
< 250 2.1.5 OK
> DATA
< 354 End data with <CRLF>.<CRLF>
> Message-ID: <c5f4@a.example>
> Date: Tue, 05 May 2026 09:00:00 +0000
> From: Alice <alice@a.example>
> To: Bob <bob@b.example>
> Subject: lunch?
> MIME-Version: 1.0
> Content-Type: multipart/alternative; boundary="b1"
> 
> --b1
> Content-Type: text/plain; charset=UTF-8
> 
> Free at 12:30?
> --b1
> Content-Type: text/html; charset=UTF-8
> 
> <p>Free at <b>12:30</b>?</p>
> --b1--
> .
< 250 2.6.0 Accepted as msa-1042
> QUIT
< 221 2.0.0 Bye
```

The MSA has the message in its outbound queue.

## Step 3 — MSA prepares the message for relay

Before handing off, the MSA:

1. **Adds a `Received:` header** so the path is traceable:
   ```
   Received: from phone-12ab ([203.0.113.42]) by smtp.a.example
     with ESMTPSA id msa-1042
     for <bob@b.example>; Tue, 05 May 2026 09:00:00 +0000
   ```
2. **DKIM-signs the message.** Computes the body hash, the header
   hash over `From`, `To`, `Subject`, `Date`, `Message-ID`, prepends:
   ```
   DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=a.example;
     s=2026q2; t=1714896000; h=from:to:subject:date:message-id;
     bh=…; b=…
   ```
3. **Bounce path = the envelope sender.** For a personal account this
   stays as `alice@a.example`; for mailing lists it would be a VERP
   address.

## Step 4 — DNS lookup for the destination

```
$ dig MX b.example
b.example.   3600  IN  MX  10  mx1.b.example.

$ dig A mx1.b.example
mx1.b.example.   3600  IN  A  192.0.2.25
```

Plus, because the MSA is MTA-STS-aware:

```
$ dig TXT _mta-sts.b.example
_mta-sts.b.example.  3600  IN  TXT  "v=STSv1; id=20260101"

$ curl -s https://mta-sts.b.example/.well-known/mta-sts.txt
version: STSv1
mode: enforce
mx: mx1.b.example
max_age: 604800
```

The MSA caches the policy. It now *must* use STARTTLS and validate
that `mx1.b.example`'s certificate covers that name.

## Step 5 — Relay to mx1.b.example (port 25)

```
< 220 mx1.b.example ESMTP Postfix
> EHLO mx.a.example
< 250-mx1.b.example
< 250-PIPELINING
< 250-SIZE 104857600
< 250-STARTTLS
< 250-8BITMIME
< 250 SMTPUTF8
> STARTTLS
< 220 2.0.0 Ready to start TLS
… TLS handshake; sender verifies cert against MTA-STS policy …
> EHLO mx.a.example
< 250-mx1.b.example
< 250-SIZE 104857600
< 250 SMTPUTF8
> MAIL FROM:<alice@a.example> SIZE=702
< 250 2.1.0 Ok
> RCPT TO:<bob@b.example>
< 250 2.1.5 Ok
> DATA
< 354 End data with <CRLF>.<CRLF>
> Received: from phone-12ab ([203.0.113.42]) by smtp.a.example …
> DKIM-Signature: v=1; a=rsa-sha256; … b=…
> Message-ID: <c5f4@a.example>
> …(rest as before)…
> .
< 250 2.6.0 Accepted as ABCD1234
> QUIT
< 221 2.0.0 Bye
```

## Step 6 — Receiver authenticates the message

`mx1.b.example` runs the chapter-05 trio in parallel with reading the
body:

```dart
// Pseudo, but each function exists in this codebase.
final spf  = await checkSPF('198.51.100.7' /* sending IP */, 'a.example');
final dkim = await verifyDkim(receivedRawBytes);   // looks up 2026q2._domainkey.a.example
final dm   = await checkDMARC(
  fromDomain: 'a.example',
  spfResult: spf,
  dkimResults: dkim,
);
```

Verdict for our happy-path scenario:

| Check | Result | Aligned with `From:`? |
|---|---|---|
| SPF | `pass` (mx.a.example IP in `198.51.100.0/24`) | yes (relaxed) |
| DKIM | `pass` (signature verifies, `d=a.example`) | yes (strict) |
| DMARC | `pass` | — |

The MTA prepends its own `Received:` and an
`Authentication-Results:` summary so downstream filters can see what
happened:

```
Authentication-Results: mx1.b.example;
  spf=pass smtp.mailfrom=alice@a.example;
  dkim=pass header.d=a.example header.s=2026q2;
  dmarc=pass header.from=a.example
Received: from mx.a.example ([198.51.100.7]) by mx1.b.example
  with ESMTPS id ABCD1234 (using TLSv1.3) for <bob@b.example>;
  Tue, 05 May 2026 09:00:01 +0000
```

## Step 7 — Local delivery (MDA)

The MTA hands the message to the MDA — in this codebase, by emitting a
`newmail` event with the final raw bytes plus the verified envelope:

```dart
server.on('newmail', (NewMailEvent ev) async {
  await mailbox.append(
    user: ev.recipient,
    folder: 'INBOX',
    rawBytes: ev.rawBytes,
    flags: const ['\\Recent'],
    internalDate: DateTime.now().toUtc(),
  );
  // notify any IMAP sessions Bob has open:
  for (final mb in openMailboxes(ev.recipient, folder: 'INBOX')) {
    mb.notifyExists(mb.exists + 1);
    mb.notifyRecent(mb.recent + 1);
  }
});
```

## Step 8 — Bob's laptop sees it via IMAP IDLE

Bob's IMAP client has been idling against `imap.b.example:993`:

```
> A042 IDLE
< + idling
… (some time later) …
< * 43 EXISTS                ← server pushed this
< * 1 RECENT
> DONE
< A042 OK IDLE terminated
> A043 FETCH 43 (UID FLAGS BODYSTRUCTURE BODY.PEEK[HEADER])
< * 43 FETCH (UID 1042 FLAGS (\Recent)
<      BODYSTRUCTURE ("multipart" "alternative" …)
<      BODY[HEADER] {…}
< From: Alice <alice@a.example>
< Subject: lunch?
< …)
< A043 OK
```

Bob taps "Free at 12:30?" — the client requests the actual body part:

```
> A044 FETCH 43 (BODY[1])
< * 43 FETCH (BODY[1] {15}
< Free at 12:30?
< )
< A044 OK
```

The display lights up. End-to-end latency in a healthy network is
typically 1–4 seconds.

## What had to go right

In delivery order:

1. ✅ The phone trusted the submission server's certificate.
2. ✅ The submission server accepted Alice's password.
3. ✅ DNS for `b.example` returned a usable MX.
4. ✅ MTA-STS policy was retrievable and listed the actual MX name.
5. ✅ TLS handshake succeeded with a cert covering `mx1.b.example`.
6. ✅ SPF authorized `mx.a.example`'s IP for `a.example`.
7. ✅ DKIM key was published at `2026q2._domainkey.a.example` and
   matched the signature.
8. ✅ DMARC policy permitted the result.
9. ✅ Bob's mailbox had room.
10. ✅ The IMAP IDLE socket survived intermediate NATs.

A failure at any of these steps falls into one of the boxes from the
earlier chapters:

| Failed step | Where to look |
|---|---|
| 1, 2, 5 | TLS / cert chain — chapter 06 |
| 3, 4 | DNS — chapter 04 |
| 6, 7, 8 | SPF / DKIM / DMARC — chapter 05 |
| 9 | DSN — chapter 08 |
| 10 | IMAP — chapter 07 |
| Any SMTP reply | Reply codes — chapter 03 |

The point of every chapter is that you can answer "*which* of those did
I just break?" with code, not guesswork. The same Dart APIs that built
this scenario are what you ship to production:

* `composeMessageTyped` — chapter 02
* `parseReplyBlockTyped` — chapter 03
* `resolveMX` — chapter 04
* `checkSPF`, `verifyDkim`, `checkDMARC` — chapter 05
* `buildMtaStsMaterial`, `buildTlsRptMaterial` — chapter 06
* `Server` + `MailboxFacade` — chapter 07
* `buildDsn` — chapter 08

That's email. Everything else is a knob on top.
