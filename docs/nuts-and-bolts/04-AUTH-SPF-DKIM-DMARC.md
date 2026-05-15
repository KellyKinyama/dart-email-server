# 4. Auth — SPF, DKIM, DMARC, rDNS

The four checks that decide whether the inbound message you just
received is *trustworthy*. None of them prevent delivery on their own
— they produce verdicts that your `'mail'` listener (or DMARC policy)
combines into a decision.

Files:

* [`lib/src/spf.dart`](../../lib/src/spf.dart) — `checkSPF(ip, domain)`
* [`lib/src/dkim.dart`](../../lib/src/dkim.dart) — `sign(...)` and `verify(...)`
* [`lib/src/dmarc.dart`](../../lib/src/dmarc.dart) — `checkDMARC(opts)`
* [`lib/src/rdns.dart`](../../lib/src/rdns.dart) — `checkFCrDNS(ip)`
* [`lib/src/dns_cache.dart`](../../lib/src/dns_cache.dart) — caches every
  TXT/MX/A/PTR lookup the four modules issue

---

## 4.1. Where in the lifecycle this runs

Inside `Server.createSession(...)` (chapter 2), the inbound branch of
the `'message'` handler kicks off **all four checks in parallel** the
moment the session has assembled the raw bytes. From
[`server.dart`](../../lib/src/server.dart):

```dart
session.on('message', (MailObject mail) {
  if (isSubmission) { /* shortcut to facade 'mail' */ return; }

  bool dkimDone = false, spfDone = false, rdnsDone = false;
  // … kick off three parallel futures that each set their flag and
  //   call afterAllAuth(); afterAllAuth then runs DMARC (which depends
  //   on SPF + DKIM verdicts) and finally emits the user's 'mail'.
});
```

So the actual ordering is:

```
DATA terminator
      │
      ├── SPF.check(ip, MAIL FROM domain)         ──┐
      ├── DKIM.verify(rawBytes)                    ──┤  parallel
      └── FCrDNS.check(ip)                          ──┘
                                                     │
                                       all three settle
                                                     ▼
                              DMARC.check({fromDomain, dkimResult, spfResult, …})
                                                     │
                                                     ▼
                                          mail.authResults populated
                                                     ▼
                                         emit('mail', mailObject)
```

DMARC depends on the SPF and DKIM *domains* (for alignment), so it
must wait. The other three are independent.

---

## 4.2. SPF — `checkSPF(ip, domain)`

File: [`lib/src/spf.dart`](../../lib/src/spf.dart).

Walks the `v=spf1 …` TXT record for `domain`, evaluates each mechanism
against `ip`, returns:

```dart
class SpfResult {
  String result;     // 'pass' | 'fail' | 'softfail' | 'neutral' | 'none' | 'temperror' | 'permerror'
  String domain;
  String? reason;
  String? mechanism; // 'all' | 'a' | 'mx' | 'ip4' | 'ip6' | 'include' | 'exists'
}
```

Implementation notes:

* Mechanisms supported: `all`, `a`, `mx`, `ip4`, `ip6`, `include`,
  `exists`, plus `redirect=` and `exp=` modifiers.
* DNS lookup budget: **10** per RFC 7208 §4.6.4. Tracked in
  `_LookupCount`; exceeding it → `permerror`.
* Macros (`%{i}`, `%{s}`, `%{l}`, `%{d}`, `%{h}`) are expanded inside
  `exists:` and `redirect:` targets.
* All DNS goes through [`dns_cache`](../../lib/src/dns_cache.dart)
  (chapter 9), so repeated lookups in a session are free.

What `domain` to pass: the **MAIL FROM domain** (envelope), *not* the
header `From:`. The dispatcher in `server.dart` does this — splits on
`@` of `mail.from`.

---

## 4.3. DKIM — `sign(opts, raw)` and `verify(raw)`

File: [`lib/src/dkim.dart`](../../lib/src/dkim.dart).

### Verification (inbound)

`verify(rawBytes)`:

1. Pulls every `DKIM-Signature:` header (a message can carry multiple).
2. For each, parses tags: `v=`, `a=`, `c=`, `d=`, `s=`, `h=`, `bh=`,
   `b=`, `t=`, `x=`, `i=`, `l=`.
3. Fetches the public key TXT record at `<s>._domainkey.<d>`. Cached.
4. **Canonicalises** the body (`relaxed` or `simple`) — see
   `canonicalizeBodyRelaxed` at the top of the file — hashes with SHA-256,
   compares to `bh=`. Mismatch → `fail`.
5. Canonicalises the signed headers in `h=` order, hashes, RSA-verifies
   against the public key. Mismatch → `fail`.
6. Returns the verdict and the verified `d=` domain (used by DMARC).

Verdicts: `pass`, `fail`, `none` (no signature), `policy` (signature
violates a published policy), `neutral`, `temperror`, `permerror`.

### Signing (outbound)

`sign(opts, raw)` does the reverse, producing the raw bytes of a
`DKIM-Signature:` header to prepend. Algorithms: `rsa-sha256` (the
default; `ed25519-sha256` is parsable but key-loading uses
PointyCastle's RSA primitives — see
[`lib/cipher/rsa.dart`](../../lib/cipher/rsa.dart)).

`Server.resolveDkim(domain)` is the bridge: it returns the
`DkimSignOptions` for a registered domain, which the application or
the submission session passes to `sign(...)`.

---

## 4.4. DMARC — `checkDMARC(opts)`

File: [`lib/src/dmarc.dart`](../../lib/src/dmarc.dart).

Inputs:

```dart
DmarcOptions(
  fromDomain: 'example.com',         // header From: domain
  dkimResult: 'pass',                // from chapter 4.3
  dkimDomain: 'example.com',         // d= tag of verified sig
  spfResult:  'pass',                // from chapter 4.2
  spfDomain:  'example.com',         // MAIL FROM domain
);
```

Steps:

1. Look up `_dmarc.<fromDomain>` TXT. If missing, fall back to the
   **organizational domain** (uses `getOrgDomain` which currently
   strips one label — for production wire in a Public Suffix List).
2. Parse `p=`, `sp=`, `adkim=`, `aspf=`, `pct=`, `rua=`, `ruf=`.
3. Check **alignment**:
   * DKIM aligned ⇔ `dkimResult == 'pass'` AND `dkimDomain`
     matches `fromDomain` under `adkim` (relaxed = same org domain;
     strict = exact match).
   * SPF aligned ⇔ same idea with `spfDomain`.
4. `result = 'pass'` if either is aligned, else `'fail'`.
5. Returns `DmarcResult` with `policy` (`none` / `quarantine` /
   `reject`) so your application can act on it.

The policy *enforcement* is your job. The library writes the verdict
into `MailObject.authResults` and emits `'mail'` regardless; you
decide whether to bounce, quarantine, or deliver.

---

## 4.5. FCrDNS — `checkFCrDNS(ip)`

File: [`lib/src/rdns.dart`](../../lib/src/rdns.dart).

Forward-Confirmed Reverse DNS:

1. PTR lookup on `ip` → list of hostnames.
2. For each hostname, A/AAAA lookup → must include the original `ip`.
3. If any hostname round-trips, `result: 'pass', hostname: <that>`.
4. No PTR → `'fail'` (`reason: 'No PTR record'`).
5. PTR exists but none round-trip → `'fail'` (`reason: 'No forward match'`).

The `hostname` from a `pass` is what shows up in the `Received:`
header your application later writes (so spam scanners can see it).

---

## 4.6. The combined verdict — `MailAuthResult`

After all four checks land, the session populates:

```dart
class MailAuthResult {
  String? dkim;          // 'pass' / 'fail' / 'none' / …
  String? dkimDomain;    // d= of verified sig
  String? spf;           // 'pass' / 'fail' / …
  String? dmarc;         // 'pass' / 'fail'
  String? dmarcPolicy;   // 'none' / 'quarantine' / 'reject'
  String? rdns;          // 'pass' / 'fail' / 'none'
  String? rdnsHostname;  // FCrDNS verified name
}
```

…and it lives at `mail.authResults`. The conventional rendering is an
`Authentication-Results:` header your application prepends before
storing the message:

```
Authentication-Results: mx.example.com;
  spf=pass smtp.mailfrom=alice@example.com;
  dkim=pass header.d=example.com;
  dmarc=pass header.from=example.com;
  iprev=pass policy.iprev=mail.example.com
```

Helpers for formatting this string aren't yet shipped — build it in
your `'mail'` listener.

---

## 4.7. Failure modes you'll see

| Symptom | Cause | Fix |
|---|---|---|
| `spf: temperror` for everything | `dns_cache` errors / no internet on the host | Verify outbound DNS works |
| `dkim: none` from a known signer | `DKIM-Signature` header was reordered or rewritten by an upstream proxy | Don't rewrite headers before reaching this server |
| `dkim: fail` only for some messages | Body was modified in transit (CRLF normalisation, footer added) | Sign with `c=relaxed/relaxed`, not `simple/simple` |
| `dmarc: none` even though sender publishes | Public Suffix List not consulted; org-domain heuristic is naïve | Plug a PSL into `getOrgDomain` |
| `rdns: fail` for big senders | Their PTR points at a generic name | Don't reject on rDNS alone — use as a reputation hint |
| Slow `'mail'` event | Sequential, not parallel checks | Confirm you didn't override the default handler — the parallel scheduling is in `server.dart` |

---

## 4.8. Submission side — DKIM **signing**

Outbound from a submission session:

1. The user authenticated; `'smtpSession'` fired.
2. The user issued `MAIL FROM:<alice@example.com>` etc., DATA arrived.
3. The session emits `'mail'` on the per-session facade.
4. Your handler calls `Server.resolveDkim('example.com')` to get the
   `DkimSignOptions`, then `dkim.sign(opts, mail.raw)` to produce a
   `DKIM-Signature:` header, prepends it, and hands the bytes to
   `OutboundPool.send(...)` (chapter 6).

There is no automatic submission-time signing yet — by design, the
library leaves it to you so you can sign with the *right* selector
based on tenant, IP pool, or A/B test.

---

Next: [Chapter 5 — Message parse and compose](./05-MESSAGE-PARSE-AND-COMPOSE.md).
