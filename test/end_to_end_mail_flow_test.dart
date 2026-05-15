// Real-world end-to-end scenario test on localhost.
//
// Topology — one Server, three ports, two clients per scenario:
//
//   ┌─────────────────────────────────────────────────────┐
//   │           Server('mail.test.local')                  │
//   │   ┌──────────┐  ┌──────────┐  ┌──────────┐           │
//   │   │  SMTP    │  │   IMAP   │  │   POP3   │           │
//   │   │ inbound  │  │  store   │  │  store   │           │
//   │   └─────┬────┘  └────┬─────┘  └────┬─────┘           │
//   │         │            │             │                  │
//   │         ▼            ▼             ▼                  │
//   │   ┌──────────────────────────────────────────────┐   │
//   │   │ in-memory MailStore (per-recipient mailbox)  │   │
//   │   └──────────────────────────────────────────────┘   │
//   └─────────────────────────────────────────────────────┘
//
// Scenario A: Alice's SMTP client delivers to Bob → Bob's IMAP client reads it.
// Scenario B: Same flow but Bob retrieves via POP3 and DELE'es the message.
// Scenario C: Two messages, two readers.
//
// Hermetic: no DNS, no external network. All on 127.0.0.1.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:dart_email_server/dart_email_server.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
//  In-memory mail store
// ---------------------------------------------------------------------------

/// One stored message in the test mail store.
class StoredMessage {
  final int uid;
  final Uint8List raw;
  final DateTime internalDate;
  bool deleted;

  StoredMessage({
    required this.uid,
    required this.raw,
    required this.internalDate,
    this.deleted = false,
  });

  int get size => raw.length;
}

/// Tiny per-user mailbox store. Keyed by lowercase address.
class MailStore {
  final Map<String, List<StoredMessage>> _byUser = {};
  int _nextUid = 1000;

  void deliver(String to, Uint8List raw) {
    final key = to.toLowerCase();
    final list = _byUser.putIfAbsent(key, () => <StoredMessage>[]);
    list.add(
      StoredMessage(
        uid: ++_nextUid,
        raw: raw,
        internalDate: DateTime.now().toUtc(),
      ),
    );
  }

  /// Returns the live list of non-deleted messages for [user] (sorted by UID).
  List<StoredMessage> live(String user) {
    final all = _byUser[user.toLowerCase()] ?? const <StoredMessage>[];
    return all.where((m) => !m.deleted).toList()
      ..sort((a, b) => a.uid.compareTo(b.uid));
  }

  /// Total raw byte count for [user]'s live messages.
  int totalBytes(String user) =>
      live(user).fold<int>(0, (sum, m) => sum + m.size);

  /// Mark [uids] deleted for [user] (non-existent UIDs are silently ignored).
  void markDeleted(String user, List<int> uids) {
    for (final m in _byUser[user.toLowerCase()] ?? const <StoredMessage>[]) {
      if (uids.contains(m.uid)) m.deleted = true;
    }
  }
}

// ---------------------------------------------------------------------------
//  Test fixture: a single Server wiring SMTP-in + IMAP + POP3 to the store
// ---------------------------------------------------------------------------

class MailFixture {
  final Server server;
  final MailStore store;
  final int smtpPort;
  final int imapPort;
  final int pop3Port;

  MailFixture._({
    required this.server,
    required this.store,
    required this.smtpPort,
    required this.imapPort,
    required this.pop3Port,
  });

  Future<void> stop() async {
    final done = Completer<void>();
    server.close(() {
      if (!done.isCompleted) done.complete();
    });
    await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
  }
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

const String _bobUser = 'bob@test.local';
const String _bobPass = 'bob-secret';

/// Wire one Server with inbound SMTP + IMAP + POP3 backed by [MailStore].
Future<MailFixture> _bringUp() async {
  final smtpPort = await _freePort();
  final imapPort = await _freePort();
  final pop3Port = await _freePort();

  final store = MailStore();
  final server = Server(
    ServerOptions(
      hostname: 'mail.test.local',
      ports: ServerPorts(inbound: smtpPort, imap: imapPort, pop3: pop3Port),
      maxSize: 2 * 1024 * 1024,
      maxRecipients: 10,
    ),
  );

  // ---- SMTP delivery ----------------------------------------------------
  server.on('smtpSession', (sessionFacade, SmtpFacadeState _) {
    sessionFacade.on('mail', (MailObject mail) {
      // mail.raw is the full RFC822 bytes captured during DATA — the SMTP
      // session normalizes the trailing CRLF for us, so we can just store
      // the bytes verbatim and IMAP/POP3 will hand them back unchanged.
      final raw = mail.raw;
      for (final rcpt in mail.to) {
        store.deliver(rcpt, raw);
      }
      mail.accept();
    });
  });

  // ---- Auth gate (single user 'bob') ------------------------------------
  server.on('auth', (AuthInfo a) {
    if (a.protocol == 'smtp') return; // not authenticating SMTP-in
    if (a.username == _bobUser && a.password == _bobPass) {
      a.accept();
    } else {
      a.reject('Bad credentials');
    }
  });

  // ---- IMAP + POP3 mailbox session wiring -------------------------------
  server.on('mailboxSession', (MailboxFacade mb) {
    final user = mb.username ?? '';
    if (user.isEmpty) return;

    if (mb.protocol == 'imap') {
      mb.on('folders', (Function cb) {
        cb(null, [
          {'name': 'INBOX', 'subscribed': true, 'specialUse': null},
        ]);
      });

      mb.on('openFolder', (String name, Function cb) {
        final live = store.live(user);
        cb(null, {
          'total': live.length,
          'recent': 0,
          'uidValidity': 1,
          'uidNext': (live.isEmpty ? 1001 : live.last.uid + 1),
          'flags': <String>['\\Seen'],
          'permanentFlags': <String>['\\Seen'],
        });
      });

      mb.on('resolveMessages', (
        String name,
        Map<String, dynamic> query,
        Function cb,
      ) {
        final live = store.live(user);
        final out = <Map<String, dynamic>>[];
        for (var i = 0; i < live.length; i++) {
          out.add({'seq': i + 1, 'uid': live[i].uid});
        }
        cb(null, out);
      });

      mb.on('messageMeta', (String name, List<dynamic> uids, Function cb) {
        final live = store.live(user);
        final byUid = {for (final m in live) m.uid: m};
        final out = <Map<String, dynamic>>[];
        for (final u in uids) {
          final m = byUid[u];
          if (m == null) continue;
          final seq = live.indexOf(m) + 1;
          out.add({
            'uid': m.uid,
            'seq': seq,
            'flags': <String>[],
            'internalDate': m.internalDate,
            'size': m.size,
          });
        }
        cb(null, out);
      });

      mb.on('messageBody', (
        String name,
        int uid,
        Map<String, dynamic> responder,
      ) {
        final m = store
            .live(user)
            .where((x) => x.uid == uid)
            .cast<StoredMessage?>()
            .firstWhere((x) => x != null, orElse: () => null);
        if (m == null) {
          (responder['error'] as Function)('No such message');
        } else {
          (responder['send'] as Function)(m.raw);
        }
      });

      mb.on('status', (String name, List<dynamic> items, Function cb) {
        final live = store.live(user);
        cb(null, {
          'exists': live.length,
          'recent': 0,
          'uidnext': (live.isEmpty ? 1001 : live.last.uid + 1),
          'uidvalidity': 1,
          'unseen': live.length,
        });
      });
    } else if (mb.protocol == 'pop3') {
      mb.on('openFolder', (String name, Function cb) {
        cb(null, {'total': store.live(user).length, 'uidvalidity': 1});
      });

      mb.on('resolveMessages', (
        String name,
        Map<String, dynamic> query,
        Function cb,
      ) {
        final live = store.live(user);
        cb(null, [
          for (var i = 0; i < live.length; i++)
            {'seq': i + 1, 'uid': live[i].uid},
        ]);
      });

      mb.on('messageMeta', (String name, List<dynamic> uids, Function cb) {
        final live = store.live(user);
        final byUid = {for (final m in live) m.uid: m};
        cb(null, [
          for (final u in uids)
            if (byUid[u] != null)
              {'uid': u, 'size': byUid[u]!.size, 'flags': <String>[]},
        ]);
      });

      mb.on('messageBody', (
        String name,
        int uid,
        Map<String, dynamic> responder,
      ) {
        final live = store.live(user);
        final m = live
            .where((x) => x.uid == uid)
            .cast<StoredMessage?>()
            .firstWhere((x) => x != null, orElse: () => null);
        if (m == null) {
          (responder['error'] as Function)('No such message');
        } else {
          (responder['respond'] as Function)(m.raw);
        }
      });

      mb.on('setFlags', (String name, Map<String, dynamic> query, Function cb) {
        cb(null);
      });

      mb.on('expunge', (
        String name,
        Map<String, dynamic> options,
        Function cb,
      ) {
        final uids = options['uids'];
        if (uids is List) {
          store.markDeleted(user, [
            for (final u in uids)
              if (u is int) u,
          ]);
        }
        cb(null);
      });
    }
  });

  final ready = Completer<void>();
  server.on('ready', () {
    if (!ready.isCompleted) ready.complete();
  });

  unawaited(server.listen());
  await ready.future.timeout(const Duration(seconds: 5));

  return MailFixture._(
    server: server,
    store: store,
    smtpPort: smtpPort,
    imapPort: imapPort,
    pop3Port: pop3Port,
  );
}

// ---------------------------------------------------------------------------
//  Wire helpers
// ---------------------------------------------------------------------------

void _send(Socket s, String line) {
  s.add(utf8.encode('$line\r\n'));
}

Future<String> _readSmtpReply(StreamQueue<String> lines) async {
  final buf = StringBuffer();
  while (true) {
    final l = await lines.next.timeout(const Duration(seconds: 5));
    buf.writeln(l);
    if (l.length >= 4 && l[3] == ' ') return buf.toString();
  }
}

Future<String> _readImapUntilTag(StreamQueue<String> lines, String tag) async {
  final buf = StringBuffer();
  while (true) {
    final l = await lines.next.timeout(const Duration(seconds: 5));
    buf.writeln(l);
    if (l.startsWith('$tag ')) return buf.toString();
  }
}

Future<String> _readPopLine(StreamQueue<String> lines) =>
    lines.next.timeout(const Duration(seconds: 5));

Future<List<String>> _readPopMulti(StreamQueue<String> lines) async {
  final out = <String>[];
  while (true) {
    final l = await lines.next.timeout(const Duration(seconds: 5));
    if (l == '.') return out;
    out.add(l.startsWith('..') ? l.substring(1) : l);
  }
}

/// A typed convenience wrapper around an open socket + a line queue.
class _Conn {
  final Socket socket;
  final StreamQueue<String> lines;
  _Conn(this.socket, this.lines);
}

Future<_Conn> _connect(int port) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    port,
  ).timeout(const Duration(seconds: 5));
  final lines = StreamQueue<String>(
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter()),
  );
  return _Conn(socket, lines);
}

// ---------------------------------------------------------------------------
//  Scenario A: SMTP send → IMAP read
// ---------------------------------------------------------------------------

void main() {
  group('end-to-end mail flow on localhost', () {
    late MailFixture fx;

    setUp(() async {
      fx = await _bringUp();
    });

    tearDown(() async {
      await fx.stop();
    });

    test('Alice → SMTP → Server → IMAP → Bob (read)', () async {
      // ---- (1) Alice sends via raw SMTP --------------------------------
      final smtp = await _connect(fx.smtpPort);
      addTearDown(() => smtp.socket.destroy());

      expect(await _readSmtpReply(smtp.lines), startsWith('220'));

      _send(smtp.socket, 'EHLO alice.test');
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));

      _send(smtp.socket, 'MAIL FROM:<alice@test.local>');
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));

      _send(smtp.socket, 'RCPT TO:<$_bobUser>');
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));

      _send(smtp.socket, 'DATA');
      expect(await _readSmtpReply(smtp.lines), startsWith('354'));

      const body =
          'From: alice@test.local\r\n'
          'To: $_bobUser\r\n'
          'Subject: dinner tonight?\r\n'
          'Message-ID: <a-1@alice.test>\r\n'
          '\r\n'
          'Hi Bob,\r\n'
          'Want to grab pasta at 7?\r\n'
          '— Alice\r\n'
          '.\r\n';
      smtp.socket.add(utf8.encode(body));
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));

      _send(smtp.socket, 'QUIT');
      // QUIT may or may not get a clean reply before close; tolerate both.
      try {
        await _readSmtpReply(
          smtp.lines,
        ).timeout(const Duration(milliseconds: 500));
      } catch (_) {}

      // Store now has exactly one message for Bob.
      expect(fx.store.live(_bobUser), hasLength(1));
      final stored = fx.store.live(_bobUser).single;

      // ---- (2) Bob reads via IMAP --------------------------------------
      final imap = await _connect(fx.imapPort);
      addTearDown(() => imap.socket.destroy());

      // Untagged greeting
      expect(await imap.lines.next, startsWith('* OK'));

      _send(imap.socket, 'B001 LOGIN $_bobUser $_bobPass');
      expect(await _readImapUntilTag(imap.lines, 'B001'), contains('B001 OK'));

      _send(imap.socket, 'B002 SELECT INBOX');
      final selReply = await _readImapUntilTag(imap.lines, 'B002');
      expect(selReply, contains('1 EXISTS'));
      expect(selReply, contains('B002 OK'));

      _send(imap.socket, 'B003 FETCH 1 (UID FLAGS RFC822.SIZE)');
      final fetchMeta = await _readImapUntilTag(imap.lines, 'B003');
      expect(fetchMeta, contains('UID ${stored.uid}'));
      expect(fetchMeta, contains('RFC822.SIZE ${stored.size}'));
      expect(fetchMeta, contains('B003 OK'));

      _send(imap.socket, 'B004 FETCH 1 BODY[]');
      final fetchBody = await _readImapUntilTag(imap.lines, 'B004');
      expect(fetchBody, contains('Subject: dinner tonight?'));
      expect(fetchBody, contains('Want to grab pasta at 7?'));
      expect(fetchBody, contains('B004 OK'));
    });

    test('Alice → SMTP → Server → POP3 → Bob (read + DELE)', () async {
      // (1) deliver via SMTP
      final smtp = await _connect(fx.smtpPort);
      addTearDown(() => smtp.socket.destroy());

      expect(await _readSmtpReply(smtp.lines), startsWith('220'));
      _send(smtp.socket, 'HELO alice.test');
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));
      _send(smtp.socket, 'MAIL FROM:<alice@test.local>');
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));
      _send(smtp.socket, 'RCPT TO:<$_bobUser>');
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));
      _send(smtp.socket, 'DATA');
      expect(await _readSmtpReply(smtp.lines), startsWith('354'));
      smtp.socket.add(
        utf8.encode(
          'From: alice@test.local\r\n'
          'To: $_bobUser\r\n'
          'Subject: pop please\r\n'
          '\r\n'
          'Pull me down via POP.\r\n'
          '.\r\n',
        ),
      );
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));

      expect(fx.store.live(_bobUser), hasLength(1));
      final stored = fx.store.live(_bobUser).single;

      // (2) Bob retrieves via POP3
      final pop = await _connect(fx.pop3Port);
      addTearDown(() => pop.socket.destroy());

      expect(await _readPopLine(pop.lines), startsWith('+OK'));

      _send(pop.socket, 'USER $_bobUser');
      expect(await _readPopLine(pop.lines), startsWith('+OK'));
      _send(pop.socket, 'PASS $_bobPass');
      expect(await _readPopLine(pop.lines), startsWith('+OK'));

      _send(pop.socket, 'STAT');
      final stat = await _readPopLine(pop.lines);
      expect(stat, startsWith('+OK'));
      final parts = stat.trim().split(RegExp(r'\s+'));
      expect(parts[1], '1');
      expect(int.parse(parts[2]), stored.size);

      _send(pop.socket, 'RETR 1');
      expect(await _readPopLine(pop.lines), startsWith('+OK'));
      final body = await _readPopMulti(pop.lines);
      expect(body.join('\r\n'), contains('Subject: pop please'));
      expect(body.join('\r\n'), contains('Pull me down via POP.'));

      _send(pop.socket, 'DELE 1');
      expect(await _readPopLine(pop.lines), startsWith('+OK'));

      _send(pop.socket, 'QUIT');
      expect(await _readPopLine(pop.lines), startsWith('+OK'));

      // Wait briefly for the server-side expunge callback to fire.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        fx.store.live(_bobUser),
        isEmpty,
        reason: 'POP3 DELE + QUIT must expunge the message from the store',
      );
    });

    test('two SMTP deliveries, IMAP sees both and reads each body', () async {
      // Send msg #1
      var smtp = await _connect(fx.smtpPort);
      addTearDown(() => smtp.socket.destroy());
      expect(await _readSmtpReply(smtp.lines), startsWith('220'));
      _send(smtp.socket, 'EHLO alice.test');
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));
      _send(smtp.socket, 'MAIL FROM:<alice@test.local>');
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));
      _send(smtp.socket, 'RCPT TO:<$_bobUser>');
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));
      _send(smtp.socket, 'DATA');
      expect(await _readSmtpReply(smtp.lines), startsWith('354'));
      smtp.socket.add(
        utf8.encode(
          'From: alice@test.local\r\n'
          'To: $_bobUser\r\n'
          'Subject: msg one\r\n'
          '\r\n'
          'first message body\r\n'
          '.\r\n',
        ),
      );
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));
      smtp.socket.destroy();

      // Send msg #2 over a fresh connection
      smtp = await _connect(fx.smtpPort);
      addTearDown(() => smtp.socket.destroy());
      expect(await _readSmtpReply(smtp.lines), startsWith('220'));
      _send(smtp.socket, 'EHLO carol.test');
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));
      _send(smtp.socket, 'MAIL FROM:<carol@test.local>');
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));
      _send(smtp.socket, 'RCPT TO:<$_bobUser>');
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));
      _send(smtp.socket, 'DATA');
      expect(await _readSmtpReply(smtp.lines), startsWith('354'));
      smtp.socket.add(
        utf8.encode(
          'From: carol@test.local\r\n'
          'To: $_bobUser\r\n'
          'Subject: msg two\r\n'
          '\r\n'
          'second message body\r\n'
          '.\r\n',
        ),
      );
      expect(await _readSmtpReply(smtp.lines), startsWith('250'));

      expect(fx.store.live(_bobUser), hasLength(2));

      // Bob reads both via IMAP
      final imap = await _connect(fx.imapPort);
      addTearDown(() => imap.socket.destroy());
      expect(await imap.lines.next, startsWith('* OK'));

      _send(imap.socket, 'C001 LOGIN $_bobUser $_bobPass');
      expect(await _readImapUntilTag(imap.lines, 'C001'), contains('C001 OK'));

      _send(imap.socket, 'C002 SELECT INBOX');
      final sel = await _readImapUntilTag(imap.lines, 'C002');
      expect(sel, contains('2 EXISTS'));

      _send(imap.socket, 'C003 FETCH 1:2 BODY[]');
      final fetched = await _readImapUntilTag(imap.lines, 'C003');
      expect(fetched, contains('first message body'));
      expect(fetched, contains('second message body'));
      expect(fetched, contains('C003 OK'));
    });
  });
}
