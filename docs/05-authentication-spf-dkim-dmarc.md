# 05 — SPF, DKIM, DMARC

The trio that decides whether your mail looks legitimate. Each tackles
a different question:

| | Question it answers | What it checks | DNS lookup |
|---|---|---|---|
| **SPF** (RFC 7208) | Is this *IP* allowed to send for this *envelope* domain? | `MAIL FROM` domain vs. connecting IP | `TXT a.example` |
| **DKIM** (RFC 6376) | Was this *message* authored by someone with the *private key* matching this DNS public key, and is it unmodified? | `DKIM-Signature:` header vs. message body | `TXT selector._domainkey.a.example` |
| **DMARC** (RFC 7489) | Does the *visible* `From:` align with whichever of SPF/DKIM passed, and what should I do if not? | `From:` domain vs. SPF/DKIM domains | `TXT _dmarc.a.example` |

Receivers run all three and combine the verdict. Senders publish all
three records and hope receivers respect them.

## SPF — IP authorization

### The DNS record

```
a.example.   3600  IN  TXT  "v=spf1 ip4:198.51.100.0/24 include:_spf.google.com -all"
```

Read left to right; the first matching mechanism decides:

| Mechanism | Match if… |
|---|---|
| `ip4:1.2.3.0/24` | Connecting IP is in this CIDR. |
| `ip6:2001:db8::/32` | Same, IPv6. |
| `a` / `a:host` | Connecting IP is an A/AAAA of the domain. |
| `mx` / `mx:host` | Connecting IP is an MX of the domain. |
| `include:_spf.x` | Recursively evaluate that record (counts toward 10-lookup limit). |
| `exists:%{i}.dnsbl.x` | Synthesize a DNS name; if it resolves, match. |
| `all` | Match everything (catch-all at the end). |

Each mechanism has a *qualifier*:

| Prefix | Result if matched |
|---|---|
| `+` (default) | **pass** |
| `-` | **fail** (reject) |
| `~` | **softfail** (accept but mark) |
| `?` | **neutral** (no opinion) |

`-all` at the end means "anyone not explicitly allowed → fail."
`~all` is the more common, more forgiving variant.

### The 10-lookup limit

Every `include:`, `a:`, `mx:`, `exists:`, and `redirect=` costs one DNS
lookup; you get **10 total**. Past that the result is **`permerror`**.
This is why SaaS providers ask you to use a single `include:` instead of
flattening their record into yours.

### Running an SPF check

This codebase implements a full evaluator:

```dart
// from lib/src/spf.dart
Future<SpfResult> checkSPF(String? ip, String? domain) async { … }
```

Use it like this:

```dart
import 'package:dart_email_server/dart_email_server.dart';

final r = await checkSPF('198.51.100.5', 'a.example');
print('${r.result}  (${r.reason ?? r.mechanism})');
// pass  (ip4:198.51.100.0/24)
```

A `MailObject` arriving via the SMTP listener already carries the
result on its `spf` field — the server runs it during `RCPT` so you can
reject early.

## DKIM — cryptographic message signing

### What's signed

The sender computes:

* A SHA-256 hash of the canonicalized **body** → goes in the `bh=` tag.
* A SHA-256 hash over a chosen list of **headers plus the
  DKIM-Signature header itself** (with `b=` empty during hashing) →
  signed with the private key → goes in the `b=` tag.

The signature is one header on the message:

```
DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=a.example;
 s=2026q2; h=from:to:subject:date:message-id;
 bh=47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=;
 b=hP1Jy3HJh… (base64 signature) …Ag==
```

| Tag | Meaning |
|---|---|
| `v=1` | DKIM version. |
| `a=rsa-sha256` | Signing algorithm (RSA-SHA256 most common; Ed25519 emerging). |
| `c=relaxed/relaxed` | Canonicalization for headers/body. |
| `d=a.example` | Signing domain (the **DKIM identity**). |
| `s=2026q2` | Selector — distinguishes multiple keys for the domain. |
| `h=…` | Which headers were signed, in order. |
| `bh=…` | Base64 SHA-256 of the canonicalized body. |
| `b=…` | The actual signature. |

### The DNS public key

Published at `<selector>._domainkey.<domain>` as TXT:

```
2026q2._domainkey.a.example.  3600  IN  TXT
  "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA…IDAQAB"
```

The receiver pulls this record, decodes `p=` into a public key, and
verifies the signature. Mismatch → DKIM fails. The signature is also
invalidated if a body byte changes (so list servers that rewrite the
body break it — they're expected to **re-sign** with their own key).

### Canonicalization — the gotcha

Networks sometimes mangle whitespace, line endings, or header case.
Canonicalization normalizes both ends so signatures survive:

* `c=simple/simple` — exact bytes (very fragile).
* `c=relaxed/relaxed` — collapse whitespace, lowercase header names,
  strip trailing whitespace from lines, remove trailing empty lines
  from the body. **Use this**.

### Building a domain's material

```dart
// from examples/build_domain_material.dart  (when crypto is wired)
final mat = buildDomainMailMaterial(BuildDomainOptions(
  domain: 'a.example',
  dkim: DkimOptions(
    selector: '2026q2',
    privateKey: pemFromOpenssl,
    headers: ['from', 'to', 'subject', 'date', 'message-id'],
    canonicalization: 'relaxed/relaxed',
  ),
));
```

The published DNS records returned by that call are the only thing the
receiver ever sees.

## DMARC — alignment + policy + reporting

DMARC sits on top of SPF and DKIM and says:

> "I only trust an SPF/DKIM pass if the domain it authenticated for
> *aligns* with the visible `From:` domain. If neither aligns, here is
> what you should do, and please tell me about it."

### The DNS record

```
_dmarc.a.example.  3600  IN  TXT
  "v=DMARC1; p=reject; rua=mailto:dmarc-agg@a.example;
   ruf=mailto:dmarc-fr@a.example; sp=reject; aspf=s; adkim=s; pct=100;
   fo=1"
```

| Tag | Meaning |
|---|---|
| `p=` | Policy for the org domain: `none` (monitor only), `quarantine` (spam folder), `reject`. |
| `sp=` | Same, but for **subdomains**. |
| `rua=` | Where to send aggregate (XML, daily) reports. |
| `ruf=` | Where to send forensic (per-failure) reports. |
| `pct=` | Percentage of failing mail to apply the policy to (rolling deployment). |
| `aspf=` | Alignment mode for SPF: `r` (relaxed, organizational-domain match) or `s` (strict, exact match). |
| `adkim=` | Same for DKIM. |
| `fo=` | When to send forensic reports: `0` both fail, `1` either fails, `d` DKIM fail, `s` SPF fail. |

### Alignment — the whole point

Suppose `From: alice@a.example`. SPF passed for `bounces.a.example`
(envelope sender). DMARC asks: does `bounces.a.example` *align* with
`a.example`?

* **Relaxed** — share the same organizational domain → ✅ aligned.
* **Strict** — must be the exact same hostname → ❌ not aligned.

If neither SPF nor DKIM aligns, DMARC fails and `p=` decides what
happens.

### Reading a verdict in code

```dart
import 'package:dart_email_server/dart_email_server.dart';

final dmarc = await checkDMARC(
  fromDomain: 'a.example',
  spfResult: spfResult,        // from checkSPF
  dkimResults: dkimResults,    // list from DKIM verify
);

print('${dmarc.result}  policy=${dmarc.policy}  aligned=${dmarc.alignedBy}');
// pass  policy=reject  aligned=dkim
```

(See [`lib/src/dmarc.dart`](../lib/src/dmarc.dart).)

### Reports — the feedback loop

DMARC's quiet superpower is **aggregate reports**. Every receiver that
honors DMARC sends you a daily XML file listing every IP that sent mail
claiming to be your domain, with pass/fail counts. Without this you
have no idea who is impersonating you. Tooling like dmarcian or
Postmark ingests these XML reports and shows them as dashboards.

## A receiver's decision tree

```
                    ┌──────────────────────────────┐
                    │  message arrives (RCPT/DATA) │
                    └──────────────┬───────────────┘
                                   ▼
                  ┌──────────  run SPF on MAIL FROM IP  ───────────┐
                  ▼                                                 │
        ┌──── pass / fail ─────┐                                    │
        ▼                       ▼                                   ▼
   verify DKIM signatures  verify DKIM signatures  (always: verify DKIM)
   on the message          on the message
        │                       │                                   │
        └─────────┬─────────────┘                                   │
                  ▼                                                 │
         lookup _dmarc.<From-domain>                                │
                  │                                                 │
        ┌─────────┴─────────────┐                                   │
        ▼                       ▼                                   │
   no DMARC record         have DMARC record                        │
        │                       │                                   │
        ▼                       ▼                                   │
   accept (legacy)         check alignment                          │
                                │                                   │
                  ┌──── aligned (SPF or DKIM) ────┐                 │
                  ▼                                ▼                │
              accept                          apply p=              │
                                          (none/quarantine/reject)  │
                                                                    │
                                send aggregate report → rua= ───────┘
```

This codebase exposes each step as a separate function so you can write
filtering policy in pure Dart on top of them.
