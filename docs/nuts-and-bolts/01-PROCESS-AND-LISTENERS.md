# 1. Process and listeners

Where the program starts, how the sockets get bound, and what each
listening port turns into.

---

## 1.1. The CLI entrypoint

File: [`bin/dart_email_server.dart`](../../bin/dart_email_server.dart).

The bundled entrypoint is intentionally trivial — it exists to satisfy
`dart run dart_email_server` and to give you a place to wire up your
own production configuration:

```dart
import 'package:dart_email_server/dart_email_server.dart' as dart_email_server;

void main(List<String> arguments) {
  print('IMAP Server starter...');
}
```

In real deployments you replace this with a `main()` that:

1. Loads config (env vars, YAML, whatever).
2. Constructs `Server(ServerOptions(...))`.
3. `addDomain(...)` for every domain you serve.
4. Wires `server.on('connection' | 'auth' | 'smtpSession' | 'mailboxSession' | 'mail' | 'bounce' | 'sent' | 'rateLimit' | 'dnsWarning' | 'error', ...)`.
5. `await server.listen()`.
6. `await ProcessSignal.sigint.watch().first; await Future.value(server.close());`.

The runnable demos in [`examples/`](../../examples/) are full
copy-pasteable templates of this shape.

---

## 1.2. `Server.listen()`

File: [`lib/src/server.dart`](../../lib/src/server.dart) — search for
`Future<void> listen()`.

`listen()` is the *only* place sockets are bound. It walks
`context.ports` (a `ServerPorts` you provided) and builds two job
maps:

* **Cleartext sockets** (`tcpJobs: Map<int, void Function(Socket)>`) —
  one entry per non-null `inbound` / `submission` / `imap` / `pop3`.
* **TLS sockets** (`tlsJobs: Map<int, void Function(SecureSocket)>`) —
  one entry per non-null `secure` (465) / `imaps` (993) / `pop3s` (995).

Then for each entry it does, in order:

```dart
final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
context.servers.add(server);
server.listen(handlerForThatPort);
```

For TLS jobs it first calls `await resolveTlsContext(null)` to get a
default `SecurityContext` and binds a `SecureServerSocket` instead.
**If no default certificate is configured, the entire TLS-jobs block
is silently skipped** — your 465/993/995 sockets simply never come up.
(See chapter 6 of [`docs/06-tls-and-mta-sts.md`](../06-tls-and-mta-sts.md)
for what to put in `addDomain` to make this work.)

After every bind succeeds, it sets `context.listening = true` and emits
`'ready'`. Bind failures emit `'error'` but do **not** abort — partial
startup is intentional.

```
ServerPorts(inbound: 25, submission: 587, secure: 465,
            imap: 143, imaps: 993, pop3: 110, pop3s: 995)

         ┌──────── tcpJobs ────────┐         ┌──── tlsJobs ────┐
         │  25 → handleConnection  │         │ 465 → handleConn │
         │ 587 → handleConnection  │         │ 993 → handleImap │
         │ 143 → handleImapConn    │         │ 995 → handlePop3 │
         │ 110 → handlePop3Conn    │         └─────────────────┘
         └─────────────────────────┘                   │
                       │                               │
                  ServerSocket.bind            SecureServerSocket.bind
                  (defaults to anyIPv4)                │
                       │                               │
                       └────► context.servers ◄────────┘
```

---

## 1.3. The four connection handlers

Each handler runs **once per accepted socket** and is the cold-path
gateway into a per-connection state machine.

### 1.3.1. `handleConnection(socket, isSubmission)`

Used for cleartext SMTP (25/587) and implicit-TLS SMTP (465 — because
once the TLS handshake is done, a `SecureSocket` *is* a `Socket`).

Steps:

1. Allocate `connId` from a base-36 monotonic counter.
2. Optionally consult `RateLimiter.canConnect(remoteAddress)`. If
   refused → `421 4.7.0 Too many connections or banned\r\n`, destroy,
   emit `'rateLimit'`. Otherwise `recordConnection(remoteAddress)`.
3. Insert a `ConnectionRecord` into `context.connections` keyed on the
   socket.
4. Emit `'connection'` with a `ConnectionInfo`. The listener may call
   `info.reject()` — checked synchronously after `emit`.
5. Build the per-connection `SMTPSession` via `createSession(...)`.
6. Pipe the socket into the session: `socket.listen(session.feed, …)`.
7. Send `220 hostname ESMTP …` greeting.

The `onDone` callback removes the record and releases the connection
slot in the limiter. No queue, no fan-out — the socket *is* the
session.

### 1.3.2. `handleImapConnection(socket, remoteAddress, connId)`

Same shape, but constructs an `IMAPSession` and emits the rate-limit
denial in IMAP's wire format (`* BYE …`). After `greet()` the socket
becomes part of the IMAP state machine described in chapter 7.

### 1.3.3. `handlePop3Connection(socket, remoteAddress, connId)`

Same shape; POP3-flavoured. Chapter 8.

### 1.3.4. The TLS variants

For 465/993/995, the handler signature uses `SecureSocket` and skips
the `STARTTLS` branch in the protocol state machines (the session is
constructed with `isTLS: true`). All other logic is identical.

---

## 1.4. STARTTLS upgrade (cleartext → TLS mid-stream)

For cleartext ports, when the client issues `STARTTLS`,
`SMTPSession`/`IMAPSession`/`POP3Session` doesn't perform the upgrade
itself — it emits a **send** of `220 Ready to start TLS\r\n` and
expects the *outer* code to call `SecureSocket.secure(server: ctx)` on
the underlying socket.

In this codebase that wiring lives in `createSession` (and the IMAP /
POP3 equivalents). Look for `socket.secure(` / `SecureSocket.secure(`.

The TLS context comes from `Server.resolveTlsContext(servername)`,
which:

1. Checks `context.secureContexts[servername]` for a cached `SecurityContext`.
2. Falls back to the `DomainMaterial.tls` you registered via `addDomain`
   (key + cert as PEM strings).
3. Falls back to the user-supplied `sniCallback` if any.
4. Returns `null` → STARTTLS fails with `454 TLS unavailable`.

SNI matters here: the client sends the `servername` in the
`ClientHello`, the server picks the right cert. For implicit-TLS ports
(465/993/995) the SNI lookup happens *before* the application sees a
single byte, inside `SecureServerSocket.bind`'s default context — there
isn't a per-connection `sniCallback` hook there yet.

---

## 1.5. Connection lifecycle in one diagram

```
client TCP SYN
      │
      ▼
ServerSocket accept()
      │
      ▼
handle(Imap|Pop3|)Connection(socket, …)
      │
      ├── RateLimiter.canConnect()? ──▼ no  421 / * BYE / -ERR; destroy
      │                               │
      │                            yes
      ▼
context.connections[socket] = ConnectionRecord
      │
      ▼
emit('connection', ConnectionInfo)  ── listener may .reject()
      │
      ▼
new (SMTP|IMAP|POP3)Session(...)
      │
      ▼
socket.listen(session.feed, onError: close, onDone: cleanup)
session.greet()
      │
      ▼
... protocol state machine runs (chapters 3, 7, 8) ...
      │
      ▼
QUIT / FIN / RST / timeout
      │
      ▼
session.close() → context.connections.remove(socket)
                  → RateLimiter.releaseConnection()
```

---

## 1.6. Shutdown

`Server.close([cb])`:

1. `context.pool!.closeAll()` — drain the **outbound** pool first so
   in-flight relays settle.
2. Close every entry in `context.servers` (`ServerSocket` and
   `SecureServerSocket`).
3. For every still-open connection, write `421 hostname Server
   shutting down\r\n` (SMTP-flavoured — IMAP/POP3 clients tolerate it).
4. After `closeTimeout` ms (default 30 000), forcibly destroy any
   remaining sockets and invoke the callback.

There's no draining of the inbound message queue because there isn't
one — accepted messages have already been emitted to your `'mail'`
listener and become *your* problem.

---

Next: [Chapter 2 — Server, ServerContext, Connection](./02-SERVER-CONTEXT-CONNECTION.md).
