# 9. Rate limit and DNS cache

Two cross-cutting modules used by everything else in the codebase:

* [`lib/src/rate_limit.dart`](../../lib/src/rate_limit.dart) — bounds
  what a single remote IP can do, and bans bad actors temporarily.
* [`lib/src/dns_cache.dart`](../../lib/src/dns_cache.dart) — keeps
  TXT/MX/A/PTR lookups O(1) after the first hit, with TTL eviction.

Neither has its own protocol; both are plain in-memory state with
clear methods. They're worth their own chapter because they sit on
the **hot path** of every connection accept and every SPF/DKIM/DMARC
verdict.

---

## 9.1. `RateLimiter`

Configured via `RateLimiterConfig` on `ServerOptions`:

```dart
RateLimiterConfig(
  maxConnectionsPerIp:    20,         // 0 = unlimited
  maxAuthFailuresPerIp:   10,
  authFailureWindow:      300_000,    // ms
  banDuration:           3_600_000,   // ms — 1 hour
  maxMessagesPerHourPerIp: 100,
  exemptIps:             ['10.0.0.0/8', '127.0.0.1'],
);
```

`Server` constructs one `RateLimiter` if `rateLimit != null`.

### State per IP

```dart
class _RateState {
  int connections = 0;        // currently open
  List<int> failures = [];    // ms timestamps of recent auth failures
  List<int> messages = [];    // ms timestamps of recent accepted messages
  int bannedUntil = 0;        // ms timestamp; 0 = not banned
}
```

The lists are pruned lazily on read — entries older than the relevant
window are discarded.

### Hooks

| Method | Where it's called | What it does |
|---|---|---|
| `canConnect(ip)` | Each `handle*Connection` in `Server` | Checks `connections < max` and `now > bannedUntil`. Returns `ConnectResult(ok, reason, retryAfter)`. |
| `recordConnection(ip)` | After `canConnect` accepts | Bumps `connections`. |
| `releaseConnection(ip)` | Socket `onDone` | Decrements `connections`. |
| `recordAuthSuccess(ip)` | `'auth'` accept | Clears recent failures (a successful login forgives prior typos). |
| `recordAuthFailure(ip)` | `'auth'` reject | Appends timestamp; if `failures` in window ≥ `max`, sets `bannedUntil = now + banDuration` and returns `AuthFailureResult(banned: true, …)`. |
| `recordMessage(ip)` | (optional, your code) | Appends ms; you check `MessageResult.ok` before deciding to accept the DATA. |
| `snapshot(ip)` | observability | Returns counts for metrics. |

Refused connections trigger:

```dart
_ev.emit('rateLimit', RateLimitNotice(
  protocol: 'smtp' | 'imap' | 'pop3',
  remoteAddress: ip,
  reason: 'connection_limit' | 'banned' | …,
  bannedUntil: int?,
));
```

…so external metrics / logs pick this up without a special path.

### Exempt IPs

`exemptIps` short-circuits **all** checks. CIDR matching is naïve
substring at the moment — if you need real CIDR, wrap the limiter.

---

## 9.2. Where the limiter applies

| Site | Check | Failure response |
|---|---|---|
| `handleConnection` (SMTP 25 / 587 / 465) | `canConnect` | `421 4.7.0 Too many connections or banned\r\n`, destroy |
| `handleImapConnection` | `canConnect` | `* BYE Too many connections or banned\r\n`, destroy |
| `handlePop3Connection` | `canConnect` | `-ERR Too many connections or banned\r\n`, destroy |
| `'auth'` reject path (all three) | `recordAuthFailure` | If just-banned, emit `'rateLimit'` reason `'banned'` |

Notice the limiter is **per remote address**, not per username. A
single user behind NAT shares the budget with anyone else on the same
public IP. For per-account quotas, layer your own counter on top of
`'auth'`.

---

## 9.3. `dns_cache.dart`

A bare-bones in-memory cache around `dart:io`'s DNS APIs. Module-level
state — there is one cache per process (no instances).

```dart
Future<List<List<String>>> txt(String name);
Future<List<MxRow>>        mxRecords(String name);
Future<List<String>>       a(String name);
Future<List<String>>       aaaa(String name);
Future<List<String>>       ptr(String ip);

class MxRow { String exchange; int priority; }
```

Each function:

1. Looks up the name in the per-record-type map.
2. If the entry exists and `expires > now`, returns the cached value.
3. Otherwise issues the underlying lookup, computes `expires = now +
   defaultTtlMs` (configurable per record type), stores, returns.
4. On error caches a *negative* result (with a shorter TTL) so a
   missing SPF record doesn't slam the DNS server.

The cache is unbounded by item count. For a busy MX, this is fine —
the working set of TXT/MX domains is small. If you operate at scale,
swap in an LRU.

`OutboundPool.PoolOptions.mxCacheTTL` controls the **MX-specific**
TTL the pool installs on initialization.

---

## 9.4. Who uses the DNS cache

Every other module that talks to DNS goes through `dns_cache`:

| Caller | Records | Why |
|---|---|---|
| `spf.dart` | `txt`, `a`, `mx` | SPF mechanism resolution + macro expansion |
| `dkim.dart` | `txt` | Public key at `<selector>._domainkey.<domain>` |
| `dmarc.dart` | `txt` | `_dmarc.<domain>` |
| `rdns.dart` | `ptr`, `a` | Forward-confirmed reverse DNS |
| `smtp_client.dart` (`resolveMX`) | `mx` | Outbound delivery |
| `domain.dart` (`verifyDNS`) | `txt`, `mx` | Sanity-check after `addDomain` |

The benefit shows up *across* checks: SPF and DMARC both fetch the
same `_dmarc.example.com` TXT during the auth pipeline (chapter 4),
and the second call is free.

---

## 9.5. Cache invalidation

Two mechanisms:

* **TTL expiry** — happens on read. Cheap, but means a record stays
  cached for a *full* TTL even if the operator updated DNS.
* **Manual** — `dns_cache.evict(name)` (if your app needs it). Useful
  during DNS propagation tests.

There is no negative-cache TTL knob currently — the negative TTL is
hardcoded to a small value (~1 minute). If you publish an SPF record
and the cache has a `none` for it, wait at most that long before it
re-fetches.

---

## 9.6. Putting it together — a connection's view

```
peer SYN / accept
    │
    ▼
RateLimiter.canConnect(ip)?
    ├── banned? 421 / * BYE / -ERR, destroy
    ├── over connection cap? same
    └── ok → recordConnection(ip)
    ▼
greet → state machine
    │
    ▼
AUTH → 'auth' event
    ├── reject → RateLimiter.recordAuthFailure(ip)
    │             └── newly banned? emit('rateLimit', reason='banned')
    └── accept → RateLimiter.recordAuthSuccess(ip)  (clears failures)
    ▼
… messages flow …
    │
    ▼
DKIM verify needs <s>._domainkey.<d> TXT
    │  → dns_cache.txt(...)
    │       └── miss? underlying lookup; cache; return
    │       └── hit? return immediately
    ▼
… session ends, FIN ...
    │
    ▼
RateLimiter.releaseConnection(ip)
```

Everything is synchronous-looking from the caller's perspective; the
`Future`s settle from cache or DNS, but the *limiter* is purely
in-memory and never blocks.

---

Next: [Chapter 10 — DSN and observability](./10-DSN-AND-OBSERVABILITY.md).
