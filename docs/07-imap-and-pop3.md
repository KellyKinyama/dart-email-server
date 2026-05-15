# 07 — IMAP & POP3 (Retrieval)

Once a message is sitting in a user's mailbox, SMTP is done. The user's
client pulls it out with one of two protocols.

| | POP3 | IMAP |
|---|---|---|
| Designed for | One device that downloads then deletes | Many devices sharing the same server-side mailbox |
| Folders | Inbox only | Arbitrary nested folders |
| State | Tiny (UIDL list) | Rich (flags, MODSEQ, UIDVALIDITY) |
| Search | Client-side | Server-side (`SEARCH`, `ESEARCH`) |
| Push | None (must reconnect/poll) | `IDLE`, `NOTIFY` |
| Body parts | All-or-nothing | Fetch single MIME parts (e.g. headers only, body without attachments) |
| Concurrency | One client at a time | Many clients, server reconciles |
| Best for | Tiny embedded clients, archiving daemons | Everything else |

POP3 is implemented in [`lib/src/pop3_session.dart`](../lib/src/pop3_session.dart);
IMAP across `lib/src/imap_*.dart`.

## POP3 — short and sweet

```
< +OK POP3 server ready
> USER alice
< +OK
> PASS s3cret
< +OK 3 messages (4521 octets)
> STAT
< +OK 3 4521
> LIST
< +OK 3 messages
< 1 1234
< 2 2000
< 3 1287
< .
> RETR 1
< +OK 1234 octets
< From: bob@…
< …entire message…
< .
> DELE 1
< +OK
> QUIT
< +OK bye
```

Replies are `+OK` or `-ERR` followed by free text. Multi-line responses
end with a `.` line (dot-stuffed exactly like SMTP DATA). Messages are
numbered 1..N within a session; `UIDL` returns a stable per-message ID
so a client can recognize what it's already downloaded across sessions.

POP3 has essentially **two states**: AUTHORIZATION (before login) and
TRANSACTION (after). `DELE` only marks for deletion; the actual remove
happens on `QUIT`. `RSET` un-marks everything — the safety net.

## IMAP — stateful, asynchronous, command-tagged

Every IMAP command is prefixed with a client-chosen tag so responses
can be correlated:

```
< * OK IMAP4rev1 ready
> A001 LOGIN alice s3cret
< A001 OK Logged in
> A002 LIST "" "*"
< * LIST (\HasNoChildren) "/" INBOX
< * LIST (\HasChildren) "/" Archive
< * LIST (\HasNoChildren) "/" Archive/2025
< A002 OK
> A003 SELECT INBOX
< * 42 EXISTS
< * 0 RECENT
< * OK [UIDVALIDITY 1234567890]
< * OK [UIDNEXT 1043]
< * FLAGS (\Answered \Flagged \Deleted \Seen \Draft)
< A003 OK [READ-WRITE]
> A004 FETCH 42 (UID FLAGS BODY[HEADER.FIELDS (FROM SUBJECT)])
< * 42 FETCH (UID 1042 FLAGS (\Seen)
<      BODY[HEADER.FIELDS (FROM SUBJECT)] {54}
< From: bob@example.org
< Subject: hi
< )
< A004 OK
> A005 STORE 42 +FLAGS (\Deleted)
< * 42 FETCH (FLAGS (\Seen \Deleted))
< A005 OK
> A006 EXPUNGE
< * 42 EXPUNGE
< A006 OK
> A007 LOGOUT
< * BYE
< A007 OK
```

### Untagged responses

Lines starting with `*` are **untagged** — the server can send them at
any time, even unsolicited (e.g. `* 43 EXISTS` while the client is idle
to announce a new message). Tagged lines (`A001 OK …`) signal the
completion of a specific command.

### The four key concepts

1. **Mailbox = folder.** `INBOX` is special-cased (case-insensitive).
2. **Sequence number** vs. **UID.** Sequence numbers are *positional*
   (1..EXISTS) and shift as you EXPUNGE. UIDs are *stable* within a
   `UIDVALIDITY`. Real clients use UIDs.
3. **`UIDVALIDITY`.** A 32-bit number sent on SELECT. If it changes
   (server side mailbox rebuild), the client must throw away its UID
   cache and re-sync.
4. **Flags.** `\Seen \Answered \Flagged \Deleted \Draft \Recent` are
   system flags; `$Forwarded`, `$Junk`, etc. are user keywords.

### Fetching only what you need

The clever part of IMAP is partial fetches:

```
A FETCH 42 (BODYSTRUCTURE)              ← MIME tree, no bytes
A FETCH 42 (BODY.PEEK[HEADER])          ← headers only, don't mark Seen
A FETCH 42 (BODY[1])                    ← the first MIME part (often text/plain)
A FETCH 42 (BODY[2.MIME])               ← part 2's MIME headers
A FETCH 1:* (UID FLAGS INTERNALDATE)    ← summary for the entire mailbox
```

A mobile client typically does:

1. `FETCH 1:* (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)` →
   complete summary view.
2. On tap, `FETCH <uid> (BODYSTRUCTURE BODY.PEEK[HEADER])` then
   `BODY[1]` for the text — only downloading attachments on explicit
   user request.

### IDLE — server push

```
> A010 IDLE
< + idling
…server holds the connection open…
< * 43 EXISTS                   ← new message arrived
< * 1 RECENT
> DONE                          ← client must literally send "DONE"
< A010 OK IDLE terminated
> A011 FETCH 43 (UID FLAGS ENVELOPE)
< …
```

The server pushes status changes through the open socket. The client
must drop out of IDLE every ~29 minutes to keep NAT mappings alive
(this is why mobile mail apps drain a tiny bit of battery even when
idle).

### Server emit hooks in this codebase

[`lib/src/imap_session.dart`](../lib/src/imap_session.dart) hides the
wire protocol behind callbacks per command. From
[`examples/imap_server.dart`](../examples/imap_server.dart):

```dart
sess.on('mailboxSession', (MailboxFacade mb, _) {
  // List folders
  mb.on('folders', (req) {
    req.respond([
      ImapFolder(name: 'INBOX', delimiter: '/', flags: ['\\HasNoChildren']),
      ImapFolder(name: 'Archive', delimiter: '/', flags: ['\\HasNoChildren']),
    ]);
  });

  // SELECT INBOX
  mb.on('select', (req) {
    req.respond(ImapSelectResult(
      exists: 1,
      recent: 0,
      uidValidity: 1714915200,
      uidNext: 2,
      flags: ['\\Seen', '\\Flagged', '\\Deleted'],
    ));
  });

  // FETCH
  mb.on('fetch', (req) {
    req.respond([
      ImapMessage(seq: 1, uid: 1, flags: [], rawBytes: storedRawBytes),
    ]);
  });
});
```

When a new message arrives, push it to connected clients with one call:

```dart
mb.notifyExists(2);   // emits "* 2 EXISTS\r\n"
```

## When to choose which

* **POP3** — backup mirror that ingests mail, archives to a database,
  and removes from the server. Two commands later you're done.
* **IMAP** — anything a human reads on more than one device. Pretty
  much the universal default in 2026.

## Common pitfalls

* **POP3 leaving messages on the server.** With `RETR` then no `DELE`,
  the same message is downloaded forever. The "leave on server"
  setting in old clients depends on `UIDL`-based de-duplication;
  mailbox bloats forever if the server doesn't enforce a cap.
* **IMAP UIDVALIDITY churn.** Migrating mailboxes between servers
  without preserving UIDVALIDITY makes every client re-download every
  message.
* **Concurrent EXPUNGE.** A client looking at sequence number 42 may
  find that the server has expunged 40 in the meantime — 42 is now a
  different message. UIDs are immune.
* **Folder name encoding.** IMAP uses *modified UTF-7* in folder names
  on the wire (`Caf&Pck-` = "Café"). Clients must convert.
