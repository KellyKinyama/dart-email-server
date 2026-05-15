# 8. POP3 session

POP3 is the *simplest* of the three protocols and the easiest chapter
in this book. There are 11 verbs total and almost no state — a client
either downloads everything and disconnects, or leaves messages on the
server with `RETR` + no `DELE`.

File: [`lib/src/pop3_session.dart`](../../lib/src/pop3_session.dart).

---

## 8.1. The whole protocol on one page

```
                connect
                   │
                   ▼
              GREETING ──► +OK dart_email_server POP3
                   │
                   ▼
               AUTHORIZATION ── USER name ───► +OK
                   │           PASS pass  ───► +OK (locks the mailbox)
                   ▼
              TRANSACTION
                   │
                   ├── STAT     → +OK n total_octets
                   ├── LIST     → +OK n msgs / multi-line list
                   ├── UIDL     → +OK n msgs / multi-line uids
                   ├── RETR n   → +OK octets / message bytes / "."
                   ├── TOP n L  → +OK / headers + L lines / "."
                   ├── DELE n   → +OK marked deleted
                   ├── NOOP     → +OK
                   ├── RSET     → +OK (unmarks all DELE)
                   ├── CAPA     → +OK / capability list / "."
                   ├── STLS     → +OK Begin TLS  (cleartext only)
                   ▼
                QUIT  → +OK / commit deletes / FIN
                   │
                   ▼
                 CLOSED
```

That's it. There's no concept of folders, no flags, no search, no
push. A client opens, drains the inbox, optionally tells the server
to delete what it took, and disconnects.

---

## 8.2. State

`POP3Session` carries:

| Field | Use |
|---|---|
| `state` | `NEW` → `AUTHORIZATION` → `TRANSACTION` → `UPDATE` → `CLOSED` |
| `username` / `passwordPending` | Filled by `USER` then consumed by `PASS` |
| `messages: List<POP3Message>` | The mailbox snapshot taken at `PASS` time |
| `deleted: Set<int>` | Indices marked by `DELE`, committed at `QUIT` |

A `POP3Message` is just `{ uid, sizeOctets, raw }` — POP3 has no
metadata richer than that.

---

## 8.3. The handler switch

From [`pop3_session.dart`](../../lib/src/pop3_session.dart) (line ~200):

```dart
switch (verb) {
  case 'CAPA':  return _handleCapa();
  case 'NOOP':  return _send('+OK');
  case 'STLS':  return _handleStls();
  case 'USER':  return _handleUser(arg);
  case 'PASS':  return _handlePass(arg);
  case 'STAT':  return _handleStat();
  case 'LIST':  return _handleList(arg);
  case 'UIDL':  return _handleUidl(arg);
  case 'RETR':  return _handleRetr(arg);
  case 'TOP':   return _handleTop(arg);
  case 'DELE':  return _handleDele(arg);
  case 'RSET':  return _handleRset();
  case 'QUIT':  return _handleQuit();
  default:      return _send('-ERR Unknown command');
}
```

State guards live inside each `_handle*`: `STAT` rejects with `-ERR
Not authenticated` outside `TRANSACTION`, `STLS` rejects when already
TLS, etc.

---

## 8.4. Authentication

Two modes:

1. **`USER` + `PASS`** — the only mode supported here. Cleartext on
   the wire (use `STLS` first or implicit TLS on 995).
2. **`APOP`** (legacy MD5 challenge) — *not* implemented. Most modern
   clients don't use it.

`PASS` builds a `Pop3AuthRequest` and emits `'auth'`. The
`Server.handlePop3Connection` listener (chapter 1) bridges this to the
top-level `'auth'` event with `protocol: 'pop3'`. Your handler calls
`accept()` (success → state becomes `TRANSACTION`, `messages` is
loaded from your store via the `MailboxFacade`) or `reject(msg)`
(`-ERR <msg>` and the session stays in `AUTHORIZATION`).

After three failed `PASS` attempts the session disconnects (configured
in `_handlePass`).

---

## 8.5. RETR vs TOP

* `RETR n` → entire message, octet-stuffed (`.` at line start →
  `..`), terminated by `.\r\n`.
* `TOP n L` → headers + first `L` lines of body, same termination.
  Useful for clients that show a preview before downloading.

The byte-stuffing rule is the same as SMTP DATA in reverse. It's
implemented in `_octetStuff(raw)` inside the session.

---

## 8.6. The two-phase delete

`DELE n` does **not** delete immediately. It just sets `deleted.add(n)`.
The actual commit happens in `QUIT`:

```
QUIT
 │
 ▼
state = UPDATE
 │
 ├── for each i in deleted: store.delete(messages[i].uid)
 ├── send '+OK Bye'
 ▼
close socket
```

If the client *aborts* without `QUIT` (RST, FIN, timeout), all `DELE`
marks are discarded — the messages survive. This is RFC 1939 §6.

---

## 8.7. Why POP3 is in this codebase

POP3 is a 1996 protocol that pretty much nobody implements clients for
any more — IMAP won. It's included because:

1. Some old corporate setups still use POP3 for archival.
2. Mobile carriers occasionally have it as the only "fetch" protocol
   on cheap email plans.
3. It's a 200-line implementation that exercises the same `Server`
   plumbing as IMAP, validating the abstractions for free.

For new projects, prefer IMAP (chapter 7).

---

## 8.8. End-to-end packet trace

```
< +OK dart_email_server POP3 ready
> CAPA
< +OK Capability list follows
< USER
< UIDL
< TOP
< STLS
< .
> STLS
< +OK Begin TLS negotiation
*** TLS handshake ***
> USER demo@example.com
< +OK
> PASS demo
< +OK Mailbox locked and ready
> STAT
< +OK 1 142
> LIST
< +OK 1 messages
< 1 142
< .
> RETR 1
< +OK 142 octets
< From: postmaster@example.com
< To: demo@example.com
< Subject: Welcome
<
< Welcome to the demo POP3 server.
< .
> DELE 1
< +OK Marked
> QUIT
< +OK Bye
*** message 1 deleted in store; FIN ***
```

---

Next: [Chapter 9 — Rate limit and DNS cache](./09-RATE-LIMIT-AND-DNS-CACHE.md).
