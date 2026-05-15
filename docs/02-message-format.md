# 02 — Message Format (RFC 5322 + MIME)

A "message" on the wire is just a blob of US-ASCII text split into a
**header section**, a single blank line, and a **body**. Everything
fancy — Unicode subjects, attachments, HTML — is layered on top of this
plain structure using **MIME** (RFC 2045–2049).

## The minimal valid message

```
From: alice@example.com
To: bob@example.org
Subject: hi
Date: Tue, 05 May 2026 09:00:00 +0000
Message-ID: <abc@example.com>

Hello, Bob.
```

Five rules govern that text:

1. Every line ends with **`\r\n`** (CRLF). Bare `\n` is a bug.
2. The header section ends at the first **empty line** (`\r\n\r\n`).
3. A header is `Name: value`. Names are case-insensitive, ASCII only.
4. A long header may be **folded** onto the next line by starting the
   continuation with a space or tab.
5. A line in the body that begins with a single `.` is **dot-stuffed**
   to `..` on the wire so that SMTP's end-of-data marker (`\r\n.\r\n`)
   is unambiguous (chapter 03).

This codebase produces such a blob from a typed
[`ComposeMessageOptions`](../lib/src/message.dart) via
`composeMessageTyped()`:

```dart
import 'package:dart_email_server/dart_email_server.dart';

final r = composeMessageTyped(ComposeMessageOptions(
  from: 'alice@example.com',
  to: 'bob@example.org',
  subject: 'hi',
  text: 'Hello, Bob.',
));
print(r.raw);  // the bytes you'd hand to DATA
```

See [`examples/compose_message.dart`](../examples/compose_message.dart).

## Required vs. recommended headers

| Header | Required? | Purpose |
|---|---|---|
| `From:` | yes (RFC 5322) | Author. Used by DMARC for alignment. |
| `Date:` | yes | Author's local time when composed. |
| `Message-ID:` | strongly recommended | Globally unique reference; threading uses this. |
| `To:` / `Cc:` / `Bcc:` | one recipient header should exist | Display only — actual recipients are in the envelope. |
| `Subject:` | optional | Free text. |
| `Reply-To:` | optional | Where replies should go if not `From:`. |
| `In-Reply-To:` / `References:` | reply only | Thread linkage. |
| `MIME-Version: 1.0` | required if MIME used | Switches body interpretation rules on. |
| `Content-Type:` | with MIME | What the body is. |
| `Content-Transfer-Encoding:` | with MIME | How the body is encoded for 7-bit transport. |

Any `X-…` header is application-private — you can invent your own (the
classic `X-Mailer:` is one such convention).

## Folding long headers

A `Subject:` that exceeds ~78 characters gets folded:

```
Subject: This is a slightly longer subject that we want
 to keep readable in old terminals
```

The continuation line **must** start with at least one space or tab.
The receiver "unfolds" by removing the CRLF, keeping the whitespace.

## Non-ASCII headers — encoded-words (RFC 2047)

Header fields are ASCII-only. To put `"Café"` in a `Subject:` you wrap
the bytes in an encoded-word:

```
Subject: =?UTF-8?B?Q2Fmw6k=?=         (B = Base64)
Subject: =?UTF-8?Q?Caf=C3=A9?=        (Q = Quoted-Printable)
```

Format: `=?charset?encoding?text?=`. The library decides automatically:

```dart
// from lib/src/message.dart
bool needsEncodedWord(String s) {
  for (int i = 0; i < s.length; i++) {
    int c = s.codeUnitAt(i);
    if (c < 32 || c > 126) return true;
  }
  return false;
}
```

For *true* Unicode in addresses (`josé@example.com`), the modern answer
is **SMTPUTF8** (chapter 03), not encoded-words.

## MIME — multipart messages

The minute you need an HTML body, an attachment, or both, you switch on
MIME by adding `MIME-Version: 1.0` and a `Content-Type:` of one of the
`multipart/*` flavors. Each flavor uses a `boundary=` parameter; the
boundary string appears between parts as `--boundary` and at the end as
`--boundary--`.

### `multipart/alternative` — same content, two formats

The receiver picks whichever it can render best (almost always HTML).

```
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="b1"

--b1
Content-Type: text/plain; charset=UTF-8

Hello, Bob.
--b1
Content-Type: text/html; charset=UTF-8

<p>Hello, <b>Bob</b>.</p>
--b1--
```

### `multipart/mixed` — body + attachments

```
Content-Type: multipart/mixed; boundary="b2"

--b2
Content-Type: text/plain; charset=UTF-8

See attached invoice.

--b2
Content-Type: application/pdf; name="invoice.pdf"
Content-Disposition: attachment; filename="invoice.pdf"
Content-Transfer-Encoding: base64

JVBERi0xLjQKJcfsj6IKMyAwIG9iago8PC9MZW5n…
--b2--
```

### `multipart/related` — HTML body that references inline images

The HTML uses `<img src="cid:logo">` and one of the parts has
`Content-ID: <logo>`. Used heavily by marketing email so that images
display without "load remote content?" warnings.

### Nesting

Real-world messages combine all three:

```
multipart/mixed                       (body + attachments)
├── multipart/alternative             (text vs. html version)
│   ├── text/plain
│   └── multipart/related             (html + inline images)
│       ├── text/html
│       └── image/png  (Content-ID: logo)
└── application/pdf  (attachment)
```

## Body encodings (`Content-Transfer-Encoding`)

SMTP guarantees only 7-bit ASCII with line lengths ≤ 998 octets. To
ship anything else safely:

| CTE | When to use | Round-trip cost |
|---|---|---|
| `7bit` | Pure ASCII, short lines. The default. | none |
| `8bit` | UTF-8 bodies when both sides advertise `8BITMIME`. | none |
| `binary` | Truly binary; only with `BINARYMIME` + `CHUNKING`. | none |
| `quoted-printable` | Mostly-ASCII text with a few non-ASCII bytes. | ~3× per non-ASCII byte. |
| `base64` | Anything binary (images, PDFs, ZIPs). | exactly 4/3 size. |

The library implements all of these — see `qpEncode`, `qpDecode`,
`base64Encode`, `base64Wrap76` in
[`lib/src/message.dart`](../lib/src/message.dart). Quoted-printable is
the trickiest because it must keep lines ≤ 76 chars and emit *soft line
breaks* `=\r\n`:

```dart
// excerpt — see message.dart for the full routine
if (lineLen + token.length > 73) {
  out.write('=\r\n');
  lineLen = 0;
}
```

## Trace headers — how forwarding history is recorded

Every MTA that handles the message **prepends** a `Received:` header.
You read these bottom-up to follow the path:

```
Received: from mx1.b.example by mda.b.example with LMTP id …
Received: from a.example (1.2.3.4) by mx1.b.example with ESMTPS id …
Received: from alice-laptop by smtp.a.example with ESMTPSA id …      ← submission
```

`ESMTPSA` = ESMTP + STARTTLS + Authenticated. Reading `Received:`
chains is the single most useful debugging skill in mail operations.
