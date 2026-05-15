# 7. IMAP session

How an authenticated IMAP client browses, fetches, and watches
mailboxes. IMAP is by far the most complex protocol in this codebase
because it has *state* (the currently selected mailbox), *push*
notifications (`IDLE`, unsolicited `* EXISTS`), and a large verb
surface (FETCH, SEARCH, STORE, COPY, MOVE, METADATA, QUOTA, …).

Files:

* [`lib/src/imap_wire.dart`](../../lib/src/imap_wire.dart) — pure
  tokeniser. IMAP is *not* line-oriented (it has byte literals), so
  this is more involved than the SMTP wire layer.
* [`lib/src/imap_session.dart`](../../lib/src/imap_session.dart) —
  the engine: state machine, dispatch, capability negotiation.
* [`lib/src/imap_folders.dart`](../../lib/src/imap_folders.dart) —
  `LIST`, `LSUB`, `SELECT`, `EXAMINE`, `CREATE`, `DELETE`, `RENAME`,
  `SUBSCRIBE`, `STATUS`.
* [`lib/src/imap_messages.dart`](../../lib/src/imap_messages.dart) —
  `FETCH`, `STORE`, `COPY`, `MOVE`, `APPEND`, `EXPUNGE`, `UID …`.
* [`lib/src/imap_search.dart`](../../lib/src/imap_search.dart) —
  `SEARCH`, `UID SEARCH` with the full criteria grammar.
* [`lib/src/imap_metadata.dart`](../../lib/src/imap_metadata.dart) —
  `METADATA`, `QUOTA`, `ENABLE`, `NAMESPACE`.
* [`lib/src/imap_helpers.dart`](../../lib/src/imap_helpers.dart) —
  shared utilities (UID range parsing, flag hygiene, sequence sets).

---

## 7.1. Three-layer split

```
        bytes from socket
              │
              ▼
   IMAPSession.feed(chunk)
              │  appends to inputBuf, awaits literals
              ▼
   imap_wire.tokenise → ImapCommand{tag, name, args[]}
              │
              ▼
   IMAPSession dispatches name → handler
              │
              ├── registerFolderHandlers   (imap_folders.dart)
              ├── registerMessageHandlers  (imap_messages.dart)
              ├── registerSearchHandlers   (imap_search.dart)
              └── registerMetadataHandlers (imap_metadata.dart)
              │
              ▼
   handler emits 'send' events with formatted ImapResponse lines
```

This split exists because IMAP has roughly **30 verbs** and putting
them all in one switch would be unmanageable. Each `register*Handlers`
function attaches a verb → callback map onto the session it's given.

---

## 7.2. `imap_wire.dart` — tokens, not lines

A single IMAP command may span multiple TCP reads because of
**literals**:

```
A001 APPEND INBOX (\Seen) {1024}
<...exactly 1024 bytes...>
)
```

The wire layer therefore uses a `_LiteralWaiting` marker — when the
parser sees `{n}` it tells the session "I need n more bytes before I
can continue". The session buffers, and resumes parsing when enough
bytes arrive.

Token classes (sealed sub-types of `ImapToken`):

| Class | Wire form | Use |
|---|---|---|
| `AtomToken` | `INBOX`, `BODY[HEADER]` | identifiers |
| `NumberToken` | `42` | sequence numbers, octet counts |
| `QuotedToken` | `"Re: hi"` | strings with possible spaces |
| `LiteralToken` | `{N}\r\n…` | binary-safe blobs |
| `ListToken` | `(\Seen \Flagged)` | parenthesised groups |
| `BracketedToken` | `[…]` inside fetch attribute names |
| `ResponseCodeToken` | `[CAPABILITY IMAP4rev1 …]` | machine-readable status hints |
| `NilToken` | `NIL` | absence sentinel |

`ImapCommand`:

```dart
class ImapCommand {
  String tag;            // 'A001'
  String name;           // 'FETCH'
  List<ImapToken> args;  // [ NumberToken(1), ListToken([...]) ]
}
```

`ImapResponse` is the symmetric server-to-client form, formatted
through `formatResponse(...)`. The session holds **one
`PendingImapCommand`** at a time (no command pipelining beyond what
`SASL-IR`/`LITERAL+` allows).

---

## 7.3. `IMAPSession` — engine and state

Constructor:

```dart
IMAPSession(IMAPSessionOptions(
  isServer: true,
  hostname: 'imap.example.com',
  remoteAddress: …,
  isTLS: false,
  advertiseTLS: true,
  delimiter: '/',     // mailbox path separator: '/' or '.'
));
```

State enum:

```dart
enum SessionState {
  NEW, GREETING, NOT_AUTHENTICATED, AUTHENTICATED, SELECTED, LOGOUT, CLOSED
}
```

The transition rules:

```
NEW
 │  greet()
 ▼
NOT_AUTHENTICATED
 │  LOGIN | AUTHENTICATE
 ▼
AUTHENTICATED ◄────── CLOSE / UNSELECT
 │  SELECT mb | EXAMINE mb
 ▼
SELECTED  ◄── most verbs valid here ──┐
 │                                    │
 │  LOGOUT                            │
 ▼                                    │
LOGOUT → close socket → CLOSED  <─────┘
```

`SELECTED` is special: many fetch/store verbs are only valid when one
mailbox is currently selected. The session enforces this, returning
`BAD Command not valid in this state`.

---

## 7.4. Capabilities

After STARTTLS / LOGIN, the server advertises a `CAPABILITY` set —
configured by `BASE_CAPABILITIES` in
[`imap_session.dart`](../../lib/src/imap_session.dart):

```
IMAP4rev1 SASL-IR LITERAL+ IDLE NAMESPACE UIDPLUS ENABLE
CONDSTORE QRESYNC LIST-EXTENDED LIST-STATUS SPECIAL-USE
WITHIN MOVE METADATA QUOTA
```

What each enables:

| Cap | Behaviour |
|---|---|
| `IMAP4rev1` | Baseline RFC 3501 |
| `SASL-IR` | `AUTHENTICATE` may carry the initial response inline |
| `LITERAL+` | Client may use non-synchronising literals (`{N+}`) |
| `IDLE` | Long-running connection that pushes `* EXISTS` until DONE |
| `NAMESPACE` | `NAMESPACE` command returns personal/other/shared |
| `UIDPLUS` | `APPEND`/`COPY`/`MOVE` return the new UID |
| `ENABLE` | Client opts into extensions explicitly |
| `CONDSTORE` / `QRESYNC` | Mod-sequence tracking for incremental sync |
| `LIST-EXTENDED` / `LIST-STATUS` | `LIST` with selection/return options + STATUS |
| `SPECIAL-USE` | `\Drafts` / `\Sent` / `\Trash` / `\Junk` markers |
| `MOVE` | Atomic copy+expunge |
| `METADATA` / `QUOTA` | Per-folder annotations and size limits |

---

## 7.5. The handler registration pattern

`Server.handleImapConnection` (chapter 1) constructs an `IMAPSession`
and calls each `register*Handlers(session)` once. Each module
*attaches* its verbs onto the session via an internal map, e.g.:

```dart
void registerMessageHandlers(IMAPSession s) {
  s.handlers['FETCH']   = (cmd) async { … };
  s.handlers['STORE']   = (cmd) async { … };
  s.handlers['APPEND']  = (cmd) async { … };
  s.handlers['COPY']    = (cmd) async { … };
  s.handlers['MOVE']    = (cmd) async { … };
  s.handlers['UID']     = _uidPrefixDispatcher;
}
```

This way a handler module has private helpers but a public
registration entrypoint — the same shape as Express middleware.

---

## 7.6. The mailbox backend — *your* responsibility

The session never opens a file. All persistence is driven by callbacks
your application supplies on a `MailboxFacade` returned from
`'mailboxSession'`:

```dart
server.on('mailboxSession', (MailboxFacade mb) {
  // mb.notifyExists(int total)
  // mb.notifyRecent(int count)
  // mb.notifyExpunge(int seq, int? uid)
  // mb.notifyVanished(VanishedSet)
  // mb.notifyFlags(int seq, int? uid, List<String>? flags)

  myStore.subscribe(mb.username, (event) {
    switch (event.type) {
      case 'new':     mb.notifyExists(event.total);  break;
      case 'expunge': mb.notifyExpunge(event.seq, event.uid); break;
      // …
    }
  });
});
```

The notify methods are the *push* path — they format the right `*
EXISTS` / `* EXPUNGE` / `* VANISHED` / `* FETCH FLAGS` line and emit
it on the session. The wire layer takes care of multiplexing this with
in-flight tagged responses (notifications are untagged so they can
appear at any time).

For the *pull* path (FETCH / SEARCH / STORE), the session still needs
to ask your store for messages. That wiring is currently done via
extra hook fields on `IMAPSession` set up inside
`createImapSession(...)` in
[`server.dart`](../../lib/src/server.dart) — the bundled examples
show an in-memory implementation in
[`examples/imap_server.dart`](../../examples/imap_server.dart).

---

## 7.7. FETCH — the most-used verb

Anatomy of `A005 UID FETCH 1:* (FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])`:

1. `UID` prefix → resolve sequence-set in UID space, not message-seq.
2. `1:*` → range from UID 1 to the highest UID in the mailbox.
3. `(…)` → list of *attribute specs*:
   * `FLAGS` → `\Seen \Answered …`
   * `BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)]` → the named headers
     only, *without* setting `\Seen`. (`BODY[…]` would set it.)

The handler walks the requested attributes, builds one `* <seq> FETCH
(…)` line per matching message, then ends with the tagged response
`A005 OK FETCH completed`.

For large bodies, `BODY[]<offset.octet-count>` lets the client stream
attachments without fetching the whole message. The handler responds
with a literal: `BODY[]<0> {N}\r\n…N bytes…`.

---

## 7.8. SEARCH — the criteria mini-language

[`imap_search.dart`](../../lib/src/imap_search.dart) implements the
full RFC 3501 SEARCH grammar plus `WITHIN` (`OLDER` / `YOUNGER`) and
`MODSEQ` (CONDSTORE):

```
SEARCH OR (FROM "alice" SINCE 1-Jan-2026) HEADER X-Spam-Flag YES
       UNDELETED LARGER 100000
```

The handler parses the criteria into a tree, hands the tree to your
store's search hook, and formats the matching message numbers (or
UIDs, with `UID SEARCH`) on a single `* SEARCH …` line.

If your store can't natively answer a criterion (e.g. `BODY "needle"`
on a database with no full-text index), it can fall back to streaming
each candidate message through the session's helper —
`bodyTextMatches(rawBytes, needle)` — at the cost of latency.

---

## 7.9. IDLE — push notifications

```
> A006 IDLE
< + idling
…server may emit untagged responses freely…
< * 17 EXISTS
< * 18 EXISTS
> DONE
< A006 OK IDLE terminated
```

Implementation:

* On `IDLE` the session enters a state where untagged responses (queued
  by `MailboxFacade.notifyExists`/`notifyExpunge`/etc.) are flushed
  immediately.
* The session arms an inactivity timer — RFC 2177 mandates ≤ 29 min
  before the client must re-IDLE; the server typically just lets the
  client manage this.
* Any input that isn't `DONE` aborts the IDLE with `BAD …`.

---

## 7.10. End-to-end packet trace

```
< * OK [CAPABILITY IMAP4rev1 STARTTLS] dart_email_server ready
> A001 STARTTLS
< A001 OK Begin TLS negotiation now
*** TLS handshake ***
> A002 LOGIN demo@example.com demo
< A002 OK [CAPABILITY IMAP4rev1 SASL-IR LITERAL+ IDLE …] LOGIN completed
> A003 LIST "" "*"
< * LIST (\HasNoChildren) "/" "INBOX"
< A003 OK LIST completed
> A004 SELECT INBOX
< * 1 EXISTS
< * 0 RECENT
< * OK [UIDVALIDITY 1714000000]
< * OK [UIDNEXT 2]
< * FLAGS (\Answered \Flagged \Deleted \Seen \Draft)
< * OK [PERMANENTFLAGS (\Answered \Flagged \Deleted \Seen \Draft \*)]
< A004 OK [READ-WRITE] SELECT completed
> A005 UID FETCH 1 (FLAGS BODY.PEEK[HEADER])
< * 1 FETCH (UID 1 FLAGS () BODY[HEADER] {142}
< From: postmaster@example.com
< To: demo@example.com
< Subject: Welcome
< …
< )
< A005 OK FETCH completed
> A006 LOGOUT
< * BYE Logging out
< A006 OK LOGOUT completed
*** FIN ***
```

---

Next: [Chapter 8 — POP3 session](./08-POP3-SESSION.md).
