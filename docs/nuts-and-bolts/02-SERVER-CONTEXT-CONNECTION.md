# 2. Server, ServerContext, Connection

The orchestrator that owns everything else. Three small classes form
the entire control surface; everything past this chapter has a parent
here.

---

## 2.1. The hierarchy

```
Server                      ← one per process (usually)
  ├── ServerContext         ← all mutable runtime state
  │     ├── domains         ← DKIM keys, TLS certs, MTA-STS material
  │     ├── secureContexts  ← cached dart:io SecurityContext per SNI
  │     ├── servers         ← bound ServerSocket / SecureServerSocket
  │     ├── connections     ← Socket → ConnectionRecord
  │     ├── pool            ← OutboundPool for relay
  │     └── limiter         ← RateLimiter per remote IP
  └── EventEmitter          ← the one and only event bus
```

Ownership = "I close it when I'm closed". `Server.close()` shuts down
the pool, every server socket, and every live connection — which
cascades into per-session cleanup.

---

## 2.2. `Server`

File: [`lib/src/server.dart`](../../lib/src/server.dart).

```dart
class Server {
  Server([ServerOptions opts = const ServerOptions()]);

  // event bus
  void on(String name, Function fn);
  void off(String name, Function fn);

  // lifecycle
  Future<void> listen();
  void close([Function? cb]);

  // domain registration
  void addDomain(DomainMaterial mat);
  bool removeDomain(String domain);
  DomainMaterial? getDomainMaterial(String domain);

  // helpers exposed for the session layer
  Future<SecurityContext?> resolveTlsContext(String? servername);
  Future<DkimSignOptions?> resolveDkim(String domain);
}
```

The constructor doesn't bind any sockets — it only:

1. Copies `ServerOptions` fields into `context`.
2. Constructs a `RateLimiter` if `rateLimit != null`.
3. Constructs the `OutboundPool` (always — relay is opt-in per message,
   but the pool is cheap to keep around).
4. Re-emits the pool's `'sent' / 'bounce' / 'retry'` events on the
   server's own event bus, so callers only need one `EventEmitter` to
   subscribe to.

Everything else is deferred until `listen()` (chapter 1).

---

## 2.3. `ServerContext`

File: [`lib/src/server.dart`](../../lib/src/server.dart) — search for
`class ServerContext`.

A plain mutable struct. No methods, just fields. It exists so that the
session-creation methods (`createSession`, `handleImapConnection`,
etc.) can read configuration and stash per-process state without
plumbing constructor parameters everywhere.

Key fields:

| Field | Type | Purpose |
|---|---|---|
| `hostname` | `String` | Used in 220 greetings, EHLO replies, Received headers |
| `ports` | `ServerPorts` | Which TCP ports to bind in `listen()` |
| `maxSize` | `int` | Largest accepted DATA payload. Advertised in `EHLO` as `SIZE n` |
| `maxRecipients` | `int` | Hard cap on `RCPT TO` per transaction |
| `acceptTimeout` | `int` | Per-command idle timeout in ms |
| `rateLimit` | `RateLimiterConfig?` | If set, a `RateLimiter` is constructed |
| `closeTimeout` | `int` | Grace period during `Server.close()` |
| `useProxy` | `bool` | Honour PROXY-protocol v1 header on inbound TCP |
| `relay` | `RelayOptions?` | Default smarthost for submission sessions that don't override |
| `sniCallback` | `SniCallback?` | Async per-SNI cert lookup |
| `dkimCallback` | `DkimCallback?` | Async per-domain DKIM key lookup |
| `domains` | `Map<String, DomainMaterial>` | Authoritative per-domain material added via `addDomain` |
| `secureContexts` | `Map<String, SecurityContext>` | Cached parse of cert + key bytes |
| `servers` | `List<Object>` | The bound `ServerSocket` / `SecureServerSocket` instances |
| `connections` | `Map<Socket, ConnectionRecord>` | All currently open sessions |
| `connectionCounter` | `int` | Monotonic source for `connId` |
| `pool` | `OutboundPool?` | Outbound relay pool |
| `limiter` | `RateLimiter?` | Per-IP limiter, if `rateLimit` was set |

> **Note:** these fields are mutable on purpose — `addDomain` /
> `removeDomain` after `listen()` is supported. The state machine
> classes never mutate `context` themselves; they read from it.

---

## 2.4. `ConnectionRecord` and `ConnectionInfo`

```dart
class ConnectionRecord {
  final String id;          // 'a-conn', 'b-conn', …
  final String protocol;    // 'smtp' | 'imap' | 'pop3'
  final String? remoteAddress;
}
```

`ConnectionRecord` is what lives inside `context.connections`.
It is **per active socket** and removed in the socket's `onDone`.

`ConnectionInfo` is the same data plus a `reject()` method, emitted to
`'connection'` listeners *before* the session greets:

```dart
server.on('connection', (ConnectionInfo info) {
  if (isOnBlocklist(info.remoteAddress)) info.reject();
});
```

If `info._rejected` is true after the synchronous emit, the socket is
destroyed and no `*Session` is ever created.

---

## 2.5. The event surface

There is **one** `EventEmitter` per `Server`. Names emitted on it,
roughly in their lifecycle order:

| Event | Payload | When |
|---|---|---|
| `'ready'` | `null` | All sockets bound; `listening = true` |
| `'error'` | `Object` (usually `SocketException`) | A bind failed |
| `'domainAdded'` | `String domain` | After `addDomain(...)` |
| `'dnsWarning'` | `DnsWarning` | Async `verifyDNS()` found a missing record |
| `'connection'` | `ConnectionInfo` | New socket accepted, before greeting |
| `'rateLimit'` | `RateLimitNotice` | Connection or auth refused by limiter |
| `'auth'` | `AuthInfo` | SMTP `AUTH` / IMAP `LOGIN` / POP3 `USER+PASS` requesting verdict |
| `'smtpSession'` | `(EventEmitter, SmtpFacadeState)` | After a *submission* session authenticates — gives you a per-session sub-emitter to listen for `'mail'` |
| `'mailboxSession'` | `MailboxFacade` | After IMAP/POP3 authenticates — gives you `notifyExists` / `notifyExpunge` / etc. for push notifications |
| `'mail'` | `MailObject` | An inbound (port 25) message passed all checks (or failed and is being offered for policy) |
| `'sent'` | `Map<String, dynamic>` | OutboundPool relayed a message successfully |
| `'bounce'` | `Map<String, dynamic>` | OutboundPool gave up after retries |
| `'retry'` | `Map<String, dynamic>` | OutboundPool scheduled another attempt |

Every one of these is fan-out — multiple `on(...)` listeners receive
each event, in registration order. The emitter is synchronous (see
[utils.dart](../../lib/src/utils.dart)); a slow listener stalls the
hot path. Schedule heavy work with `Timer.run` or a bounded queue.

---

## 2.6. Domain material

File: [`lib/src/domain.dart`](../../lib/src/domain.dart).

`DomainMaterial` is the unit of "everything we need to operate one
domain":

```dart
class DomainMaterial {
  final String domain;
  final TlsMaterial? tls;          // PEM key + cert
  final DkimOptions? dkim;         // selector, algo, private key
  final MtaStsOptions? mtaSts;     // policy mode, MX list, max_age
  final TlsRptOptions? tlsRpt;     // rua URI for reports

  Future<DnsCheckResult> verifyDNS();
}
```

`Server.addDomain(mat)` does three things:

1. Stores `mat` in `context.domains`.
2. Emits `'domainAdded'`.
3. Asynchronously calls `mat.verifyDNS()` and emits a `dnsWarning` for
   each missing record.

The TLS, DKIM, and MTA-STS bits are then used lazily:

* `resolveTlsContext('mx.foo.example')` consults `domains['foo.example'].tls`
  (and caches the parsed `SecurityContext`).
* `resolveDkim('foo.example')` consults `domains['foo.example'].dkim`.
* MTA-STS material is published over HTTPS by *your* code — see
  [`examples/build_domain_material.dart`](../../examples/build_domain_material.dart).

---

## 2.7. Putting it together

A minimal but realistic boot sequence:

```dart
final server = Server(ServerOptions(
  hostname: 'mx.example.com',
  ports: ServerPorts(inbound: 25, submission: 587, imap: 143),
  rateLimit: RateLimiterConfig(maxConnectionsPerIp: 20),
));

server.addDomain(DomainMaterial(
  domain: 'example.com',
  tls: TlsMaterial(key: keyPem, cert: certPem),
  dkim: DkimOptions(selector: 'default', privateKey: dkimPem),
));

server.on('connection',     (ConnectionInfo i) { /* … */ });
server.on('auth',           (AuthInfo a)       { /* check creds, a.accept()/a.reject() */ });
server.on('smtpSession',    (sess, st)         { sess.on('mail', _onSubmittedMail); });
server.on('mail',           (MailObject m)     { _onInboundMail(m); });
server.on('mailboxSession', (MailboxFacade m)  { _attachMailbox(m); });
server.on('bounce',         (info)             { _writeDsn(info); });

await server.listen();
```

Notice the symmetry: every protocol enters through one of the four
handlers in chapter 1, every authentication hits `'auth'`, every
inbound message hits `'mail'`, every authenticated mailbox hits
`'mailboxSession'`. There are no other entry points.

---

Next: [Chapter 3 — Inbound SMTP session](./03-SMTP-SESSION-INBOUND.md).
