# 04 — DNS & MX Routing

When `alice@a.example` sends to `bob@b.example`, the sending MTA needs
exactly one piece of information: *which IP address should I open a TCP
connection to?* The answer comes from DNS.

## The lookup, in one picture

```
   recipient address: bob@b.example
                          │
                          ▼
   1. ask DNS for MX records of "b.example"
                          │
       ┌──────────────────┴──────────────────┐
       │ MX records returned                 │ no MX records
       ▼                                     ▼
   sort by priority (low = preferred)   2. fall back to A/AAAA of "b.example"
   pick lowest priority host                 │
       │                                     │
       ▼                                     ▼
   3. resolve that hostname to A/AAAA     connect to that IP
       │
       ▼
   open TCP to <ip>:25
```

## MX records — the routing table

An MX (Mail eXchanger) record looks like this in zone-file form:

```
b.example.   3600  IN  MX  10  mx1.b.example.
b.example.   3600  IN  MX  10  mx2.b.example.
b.example.   3600  IN  MX  20  mx-backup.b.example.
```

Three things to understand:

1. **Priority is "lower wins."** `10` is preferred over `20`.
2. **Equal priorities are load-balanced** — pick one at random; if it
   fails, try the next equal-priority host.
3. **The target must be a hostname, not an IP, and not a CNAME** (the
   RFC forbids CNAME-targeted MX, though many servers tolerate it).

A single MX of "." (`b.example. IN MX 0 .`) is a **null MX** — it
explicitly says "this domain accepts no mail; bounce immediately."

## The implicit-MX fallback

If `b.example` has no MX records at all, the sender must look up an A
or AAAA record on the bare domain and use that. This is why so many
small domains "just work" without ever publishing an MX. This codebase
implements the fallback explicitly:

```dart
// lib/src/smtp_client.dart
Future<List<MxRecord>> resolveMX(String domain) async {
  final records = await dnsCache.mxRecords(domain);
  if (records.isEmpty) {
    // Implicit MX: use the domain itself with priority 10.
    return [MxRecord(exchange: domain, priority: 10)];
  }
  final out = records
      .map((r) => MxRecord(exchange: r.exchange, priority: r.priority))
      .toList();
  out.sort((a, b) => a.priority.compareTo(b.priority));
  return out;
}
```

You can call it directly:

```dart
import 'package:dart_email_server/dart_email_server.dart';

final mxs = await resolveMX('gmail.com');
for (final r in mxs) {
  print('priority ${r.priority}  →  ${r.exchange}');
}
// priority 5   →  gmail-smtp-in.l.google.com
// priority 10  →  alt1.gmail-smtp-in.l.google.com
// …
```

See [`examples/client_send_direct_mx.dart`](../examples/client_send_direct_mx.dart).

## Fail-over algorithm

A correct sender:

1. Lists all MX records, sorted by priority ascending.
2. Within a single priority group, randomizes order (so two equal MXes
   share the load).
3. Tries them in order; on a *connection-level* failure (TCP refused,
   timeout, TLS handshake failure when policy permits) it moves to the
   next host.
4. On a `4xx` SMTP reply, it gives up *for now* and re-queues the
   message for retry later — typically with exponential backoff
   (15 min, 30 min, 1 h, 2 h, 4 h, …) for up to ~3 days.
5. On a `5xx` reply it generates a bounce (chapter 08).

A sender **never** retries on `5xx` and **never** stops retrying on
`4xx` (until a configured deadline).

## DNS records used elsewhere in mail

Mail relies on a *lot* more than just MX:

| Record | Name | Purpose | Chapter |
|---|---|---|---|
| `MX` | `b.example` | Routing | this chapter |
| `A` / `AAAA` | `mx1.b.example` | Resolve MX hostname to IP | this chapter |
| `PTR` | `1.2.3.4.in-addr.arpa` | Reverse DNS — receivers check it on connect | 05 |
| `TXT` (SPF) | `a.example` | Which IPs may send for this domain | 05 |
| `TXT` (DKIM) | `selector._domainkey.a.example` | DKIM public key | 05 |
| `TXT` (DMARC) | `_dmarc.a.example` | Policy + report addresses | 05 |
| `TXT` (MTA-STS) | `_mta-sts.b.example` | "There is an MTA-STS policy, version v=…" | 06 |
| `TXT` (TLS-RPT) | `_smtp._tls.b.example` | Where to send TLS failure reports | 06 |
| `TLSA` | `_25._tcp.mx1.b.example` | DANE — pinned cert for SMTP | 06 |
| `CNAME` | various | Used heavily for selector delegation in DKIM and MTA-STS hosting | 06 |

## Caching and TTLs

DNS answers come with a TTL (seconds). A caching resolver will hand you
the same answer for that long. This matters because:

* MX changes don't take effect everywhere immediately — old SMTP
  servers may keep delivering to the previous host until the TTL
  expires.
* DKIM key rotation must keep both the old and the new selector
  TXT-records published until at least the previous TTL has passed,
  otherwise in-flight messages fail signature verification.

This codebase caches DNS lookups in memory:

```dart
// lib/src/dns_cache.dart  — used by resolveMX, checkSPF, DMARC, etc.
Future<List<dns.MxRecord>> mxRecords(String name) async {
  final cached = _mxCache[name];
  if (cached != null && DateTime.now().isBefore(cached.expires)) {
    return cached.records;
  }
  final records = await InternetAddress.lookupMxRecords(name);
  _mxCache[name] = _MxEntry(records, DateTime.now().add(_ttl));
  return records;
}
```

A TTL too long delays config rollouts; too short hurts throughput. The
common default is 5 minutes for cache, honoring the upstream TTL when
shorter.

## What goes wrong in real life

| Symptom | Likely DNS cause |
|---|---|
| "Relay access denied" from random hosts | Receiver sees no MX → thinks you're trying to use it as an open relay. Publish an MX. |
| Mail to a brand-new domain disappears | Resolver still has the old NXDOMAIN cached. Wait the negative-cache TTL (often 1 hour). |
| One ISP delivers, another bounces | Some recursive resolvers see a stale MX or refuse responses > 512 bytes. Enable EDNS0 on your auth servers. |
| Intermittent "TLS verification failed" | Receiver's `mta-sts.b.example` policy lists names that don't match the MX cert. See chapter 06. |

DNS is the most common single source of mail outages — even more than
SMTP itself. When something is broken, run `dig +short MX b.example`
**before** anything else.
