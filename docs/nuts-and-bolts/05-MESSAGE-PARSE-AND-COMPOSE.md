# 5. Message parse and compose

How raw bytes become a `MailObject`, and how a `ComposeMessageOptions`
becomes raw bytes. Both directions live in
[`lib/src/message.dart`](../../lib/src/message.dart) — a single,
unusually large file because the encoders, decoders, MIME tree walker,
and canonicalisation helpers are all interrelated.

---

## 5.1. Two directions, one file

```
incoming bytes ──► parseMessage(raw)         ──► ParsedMessage / MailObject
outgoing intent ──► composeMessageTyped(opts) ──► ComposeResult.raw
```

Both directions share:

* Address parsing (`AddressObj.parse(...)`)
* Encoded-word handling (RFC 2047, `=?UTF-8?Q?…?=`)
* Quoted-printable + base64 codecs
* Header folding/unfolding
* `Content-Type`/`Content-Transfer-Encoding` interpretation

Keeping them together avoids the classic asymmetry where a message
your composer produces fails to round-trip through your parser.

---

## 5.2. `composeMessageTyped(opts)`

```dart
ComposeResult composeMessageTyped(
  ComposeMessageOptions options,
  [ComposeCapabilities caps = const ComposeCapabilities()]
);
```

Inputs (every field is optional except whichever pair you actually
want — typically `from`, `to`, `subject`, and `text` or `html`):

```dart
ComposeMessageOptions(
  from: 'Alice <alice@example.com>',          // String | AddressObj | List
  to:   ['bob@example.org', 'carol@example.org'],
  cc:   …, bcc: …,
  subject: 'Hi',
  text: 'plain body\r\n',
  html: '<p>html body</p>',
  attachments: [
    {'filename': 'report.pdf', 'content': pdfBytes, 'contentType': 'application/pdf'},
  ],
  headers: {'X-Mailer': 'dart_email_server'},
  messageId: '<unique@example.com>',           // auto-generated if null
  date: 'Mon, 04 May 2026 12:00:00 +0000',     // auto if null
  priority: 'normal',                          // 'high' | 'normal' | 'low'
);
```

Output:

```dart
class ComposeResult {
  final Uint8List raw;          // the bytes you'd hand to DATA
  final String   messageId;     // value chosen / generated
  final Map<String, dynamic> profile; // {'has8bit': true, 'needsSmtputf8': false, ...}
}
```

The `profile` lets the *outbound* code decide which ESMTP extensions
to advertise/require: `8BITMIME` if any header or body byte is ≥ 128;
`SMTPUTF8` if any address contains non-ASCII per
[`utils.dart#addressNeedsSmtputf8`](../../lib/src/utils.dart).

### MIME structure produced

| Inputs | Top-level Content-Type |
|---|---|
| Only `text` | `text/plain; charset=utf-8` |
| Only `html` | `text/html; charset=utf-8` |
| Both `text` and `html` | `multipart/alternative` |
| Either + `attachments` | `multipart/mixed` wrapping the body part(s) |
| HTML with embedded inline images (`cid:` parts) | `multipart/related` inside `multipart/mixed` |

Boundary strings come from `_randomHex(...)` — never reused, so the
same composer can be called concurrently.

### Address coercion

`AddressObj.parse(input)` accepts:

* `'alice@example.com'`
* `'Alice <alice@example.com>'`
* `AddressObj(name: 'Alice', address: 'alice@example.com')`
* `{'name': 'Alice', 'address': 'alice@example.com'}`
* A `List` of any of the above

…and produces a normalised `AddressObj` with optional name encoded as
RFC 2047 if it contains non-ASCII.

---

## 5.3. `parseMessage(raw)`

```dart
ParsedMessage parseMessage(dynamic rawInput);
```

Accepts a `Uint8List` or `String`. Returns:

```dart
class ParsedMessage {
  List<MailHeader> headers;
  Uint8List bodyRaw;       // bytes after the header/body CRLF CRLF
  String? text;            // decoded text/plain part if present
  String? html;            // decoded text/html part if present
  String? subject;         // decoded RFC 2047
  String? from;            // header From, decoded
  List<String> to;         // header To, decoded, split
  List<MimeNode> parts;    // flat list of leaf parts
  String? messageId;
  // …
}
```

Algorithm:

1. **Split** at the first `\r\n\r\n` (or `\n\n` after CRLF
   normalisation) → headers vs body.
2. **Unfold + parse headers** (`name`, `value`, RFC 2047 decoded
   versions). See `parseMailHeaders` in
   [`utils.dart`](../../lib/src/utils.dart).
3. **Look at top-level Content-Type:**
   * `text/*` → decode body via the `Content-Transfer-Encoding`
     (`7bit`, `8bit`, `quoted-printable`, `base64`) and stash as
     `text`/`html`.
   * `multipart/*` → recurse into `parseMessageTree`, walk each part,
     decode each leaf, attach to `parts`.
4. **Lift convenience fields** — first text/plain becomes `text`, first
   text/html becomes `html`, attachments (any non-text leaf with
   `Content-Disposition: attachment`) get filename + bytes.

The walker is iterative-with-stack to avoid blowing the Dart frame
limit on deeply nested or pathological MIME (some spam goes 50 levels
deep).

---

## 5.4. The bridge to `MailObject`

Inside [`smtp_session.dart`](../../lib/src/smtp_session.dart) the
session calls `parseMessage(rawBytes)` and copies the relevant fields
onto a `MailObject`:

| `MailObject` field | Source |
|---|---|
| `from` | envelope `MAIL FROM` (set by SMTP, **not** parsed from headers) |
| `to` | envelope `RCPT TO` accumulated during the session |
| `headerFrom` | parsed `From:` header value |
| `subject` | parsed `Subject:` header (decoded encoded-words) |
| `text` / `html` | first matching MIME leaf |
| `size` | `rawBytes.length` |
| `raw` | original `rawBytes` (verbatim) |
| `authResults` | populated later by chapter 4 |
| `accept` / `reject` | closures the session installs to settle the DATA reply |
| `emitBody` | for streaming consumers; a no-op when bodies were buffered |

Notice the duplicate paths for "from" — `mail.from` (envelope) and
`mail.headerFrom` (header). DMARC alignment cares about the latter;
SPF cares about the former. Don't conflate them.

---

## 5.5. Encoders / decoders cheat sheet

| Function | Use |
|---|---|
| `base64Encode(u8)` / `base64Wrap76(s)` | Body parts and binary attachments |
| `base64DecodeRaw(s)` | Inbound base64 leaves; tolerates whitespace and missing padding |
| `qpEncode(u8)` | Bodies with mostly-ASCII + a few high bytes |
| `qpDecode(s)` | Inbound `Content-Transfer-Encoding: quoted-printable` |
| `headerQEncode(s)` | RFC 2047 `=?UTF-8?Q?…?=` for header values |
| `decodeEncodedWords(s)` | Header parsing |
| `foldHeader(name, value)` | 78-char folding for outbound headers |
| `ensureCRLF(s)` | Normalise `\n` → `\r\n` everywhere |

These are the same primitives used by the DKIM canonicaliser
(chapter 4) — the relaxed body algorithm hashes the *output* of an
internal canonicaliser, not raw bytes.

---

## 5.6. Edge cases the parser handles

* **Bare LF** (`\n` without `\r`) — normalised to CRLF before parsing.
* **Headers with no `\r\n\r\n` body delimiter** — treated as zero-byte
  body.
* **Unknown `Content-Transfer-Encoding`** — body returned as raw
  bytes.
* **Content-Type with quoted parameters** containing `;` — proper
  parameter parser, not a naive split.
* **Boundary not found** in a `multipart/*` — the part is treated as a
  single leaf (a permissive interpretation that avoids losing mail).
* **8BITMIME bodies on a non-`8BITMIME` peer** — the composer's
  `profile` flags this; outbound code (chapter 6) will refuse to
  pipeline without the extension.

See [`test/message_test.dart`](../../test/message_test.dart) and
[`test/edge_cases_test.dart`](../../test/edge_cases_test.dart) for the
exact contract.

---

Next: [Chapter 6 — Outbound client and pool](./06-OUTBOUND-CLIENT-AND-POOL.md).
