// End-to-end integration tests for IMAP and POP3 sessions.
//
// One Server is started per test on a random local port. Tests drive the
// protocol over a raw `Socket` so we exercise the on-the-wire bytes the
// session emits.
//
// Hermetic: no DNS, no external network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:dart_email_server/dart_email_server.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Generic helpers
// ---------------------------------------------------------------------------

/// Pick a free TCP port by binding to 0 and immediately releasing it.
Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

/// Best-effort `close()` with a short grace period.
Future<void> _stopServer(Server s) async {
  final done = Completer<void>();
  s.close(() {
    if (!done.isCompleted) done.complete();
  });
  await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
}

void _send(Socket s, String line) {
  s.add(utf8.encode('$line\r\n'));
}

/// A sample RFC-822 message used by both protocols.
final Uint8List _sampleMessage = Uint8List.fromList(
  ('From: postmaster@test.local\r\n'
          'To: demo@test.local\r\n'
          'Subject: hello-world\r\n'
          'Message-ID: <welcome-1@test.local>\r\n'
          'Date: Mon, 04 May 2026 12:00:00 +0000\r\n'
          '\r\n'
          'Body line one.\r\n'
          'Body line two.\r\n')
      .codeUnits,
);

const String _user = 'demo@test.local';
const String _pass = 'demo-pass';

// ---------------------------------------------------------------------------
// POP3 helpers
// ---------------------------------------------------------------------------

/// Read one POP3 status line (terminated by CRLF) from [lines].
Future<String> _readPopLine(StreamQueue<String> lines) =>
    lines.next.timeout(const Duration(seconds: 5));

/// Read a POP3 multi-line response: lines until a sole "." line.
/// Returns the gathered body lines (excluding the terminating dot).
Future<List<String>> _readPopMulti(StreamQueue<String> lines) async {
  final out = <String>[];
  while (true) {
    final l = await lines.next.timeout(const Duration(seconds: 5));
    if (l == '.') return out;
    // RFC 1939 dot-stuffing: leading "." is doubled by the sender.
    out.add(l.startsWith('..') ? l.substring(1) : l);
  }
}

/// Bring up a Server with a POP3 listener that exposes a single in-memory
/// inbox containing [_sampleMessage]. The [deletedLog] is appended to with
/// every UID the client deletes (after QUIT/expunge).
Future<Server> _startPopServer(int port, {List<int>? deletedLog}) async {
  final server = Server(
    ServerOptions(
      hostname: 'pop.test.local',
      ports: ServerPorts(pop3: port),
    ),
  );

  final ready = Completer<void>();
  server.on('ready', () {
    if (!ready.isCompleted) ready.complete();
  });

  server.on('auth', (AuthInfo a) {
    if (a.protocol != 'pop3') return;
    if (a.username == _user && a.password == _pass) {
      a.accept();
    } else {
      a.reject('Bad credentials');
    }
  });

  server.on('mailboxSession', (MailboxFacade mb) {
    if (mb.protocol != 'pop3') return;

    // openFolder → tell session how many messages exist.
    mb.on('openFolder', (String name, Function cb) {
      cb(null, {'total': 1, 'uidvalidity': 1});
    });

    // resolveMessages → return seq/uid pairs for the requested ranges.
    mb.on('resolveMessages', (
      String name,
      Map<String, dynamic> query,
      Function cb,
    ) {
      cb(null, [
        {'seq': 1, 'uid': 1001},
      ]);
    });

    // messageMeta → size/flags per UID.
    mb.on('messageMeta', (String name, List<dynamic> uids, Function cb) {
      final out = <Map<String, dynamic>>[];
      for (final u in uids) {
        if (u == 1001) {
          out.add({
            'uid': 1001,
            'size': _sampleMessage.length,
            'flags': <String>[],
          });
        }
      }
      cb(null, out);
    });

    // messageBody → respond with raw RFC-822 bytes via the responder map.
    mb.on('messageBody', (
      String name,
      int uid,
      Map<String, dynamic> responder,
    ) {
      if (uid == 1001) {
        (responder['respond'] as Function)(_sampleMessage);
      } else {
        (responder['error'] as Function)('No such message');
      }
    });

    // setFlags + expunge are issued at QUIT for any DELE'd messages.
    mb.on('setFlags', (String name, Map<String, dynamic> query, Function cb) {
      cb(null);
    });
    mb.on('expunge', (String name, Map<String, dynamic> options, Function cb) {
      if (deletedLog != null) {
        final uids = options['uids'];
        if (uids is List) {
          for (final u in uids) {
            if (u is int) deletedLog.add(u);
          }
        }
      }
      cb(null);
    });
  });

  unawaited(server.listen());
  await ready.future.timeout(const Duration(seconds: 5));
  return server;
}

// ---------------------------------------------------------------------------
// IMAP helpers
// ---------------------------------------------------------------------------

/// Read IMAP lines until a tagged response with [tag] is seen.
/// Returns the full transcript (joined with \r\n) since the previous read.
Future<String> _readImapUntilTag(StreamQueue<String> lines, String tag) async {
  final buf = StringBuffer();
  while (true) {
    final l = await lines.next.timeout(const Duration(seconds: 5));
    buf.writeln(l);
    if (l.startsWith('$tag ')) return buf.toString();
  }
}

Future<Server> _startImapServer(int port) async {
  final server = Server(
    ServerOptions(
      hostname: 'imap.test.local',
      ports: ServerPorts(imap: port),
    ),
  );

  final ready = Completer<void>();
  server.on('ready', () {
    if (!ready.isCompleted) ready.complete();
  });

  server.on('auth', (AuthInfo a) {
    if (a.protocol != 'imap') return;
    if (a.username == _user && a.password == _pass) {
      a.accept();
    } else {
      a.reject('Bad credentials');
    }
  });

  server.on('mailboxSession', (MailboxFacade mb) {
    if (mb.protocol != 'imap') return;

    mb.on('folders', (Function cb) {
      cb(null, [
        {'name': 'INBOX', 'subscribed': true, 'specialUse': null},
      ]);
    });

    mb.on('openFolder', (String name, Function cb) {
      cb(null, {
        'total': 1,
        'recent': 0,
        'uidValidity': 1,
        'uidNext': 1002,
        'flags': <String>['\\Seen'],
        'permanentFlags': <String>['\\Seen'],
      });
    });

    mb.on('resolveMessages', (
      String name,
      Map<String, dynamic> query,
      Function cb,
    ) {
      cb(null, [
        {'seq': 1, 'uid': 1001},
      ]);
    });

    mb.on('messageMeta', (String name, List<dynamic> uids, Function cb) {
      final out = <Map<String, dynamic>>[];
      for (final u in uids) {
        out.add({
          'uid': u,
          'seq': 1,
          'flags': <String>[],
          'internalDate': DateTime.utc(2026, 5, 4, 12, 0, 0),
          'size': _sampleMessage.length,
        });
      }
      cb(null, out);
    });

    mb.on('messageBody', (
      String name,
      int uid,
      Map<String, dynamic> responder,
    ) {
      // IMAP body responder exposes 'send' (data) / 'error' (msg).
      (responder['send'] as Function)(_sampleMessage);
    });

    mb.on('status', (String name, List<dynamic> items, Function cb) {
      cb(null, {
        'exists': 1,
        'recent': 0,
        'uidnext': 1002,
        'uidvalidity': 1,
        'unseen': 1,
      });
    });
  });

  unawaited(server.listen());
  await ready.future.timeout(const Duration(seconds: 5));
  return server;
}

// ---------------------------------------------------------------------------
// POP3 tests
// ---------------------------------------------------------------------------

void main() {
  group('Server (POP3) <-> raw POP3 client', () {
    late int port;
    late Server server;
    final deleted = <int>[];

    setUp(() async {
      deleted.clear();
      port = await _freePort();
      server = await _startPopServer(port, deletedLog: deleted);
    });

    tearDown(() async {
      await _stopServer(server);
    });

    Future<({Socket socket, StreamQueue<String> lines})> openClient() async {
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
      addTearDown(() async {
        socket.destroy();
      });
      return (socket: socket, lines: lines);
    }

    test('greeting is +OK and CAPA lists USER', () async {
      final c = await openClient();
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'CAPA');
      // First status line then multi-line list terminated by '.'.
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      final caps = await _readPopMulti(c.lines);
      expect(caps.map((s) => s.toUpperCase()), contains('USER'));
    });

    test('USER/PASS happy path enables STAT, LIST, UIDL, RETR, QUIT', () async {
      final c = await openClient();
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'USER $_user');
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'PASS $_pass');
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'STAT');
      // "+OK <count> <octets>"
      final stat = await _readPopLine(c.lines);
      expect(stat, startsWith('+OK'));
      final parts = stat.trim().split(RegExp(r'\s+'));
      expect(parts[1], '1');
      expect(int.parse(parts[2]), _sampleMessage.length);

      _send(c.socket, 'LIST');
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      final list = await _readPopMulti(c.lines);
      expect(list, hasLength(1));
      expect(list.first, '1 ${_sampleMessage.length}');

      _send(c.socket, 'UIDL');
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      final uidl = await _readPopMulti(c.lines);
      expect(uidl, hasLength(1));
      expect(uidl.first.split(' ').first, '1');

      _send(c.socket, 'RETR 1');
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      final body = await _readPopMulti(c.lines);
      expect(body.join('\r\n'), contains('Subject: hello-world'));
      expect(body.join('\r\n'), contains('Body line one.'));

      _send(c.socket, 'QUIT');
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      expect(deleted, isEmpty); // nothing was DELE'd
    });

    test('DELE before QUIT triggers expunge of that UID', () async {
      final c = await openClient();
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'USER $_user');
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      _send(c.socket, 'PASS $_pass');
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'DELE 1');
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'QUIT');
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      // Server callback should have fired with our UID.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(deleted, [1001]);
    });

    test('PASS with bad credentials is rejected', () async {
      final c = await openClient();
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'USER $_user');
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'PASS wrong-pass');
      expect(await _readPopLine(c.lines), startsWith('-ERR'));
    });

    test('commands before AUTH are rejected', () async {
      final c = await openClient();
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'STAT');
      expect(await _readPopLine(c.lines), startsWith('-ERR'));
    });
  });

  // -------------------------------------------------------------------------
  // IMAP tests
  // -------------------------------------------------------------------------
  group('Server (IMAP) <-> raw IMAP client', () {
    late int port;
    late Server server;

    setUp(() async {
      port = await _freePort();
      server = await _startImapServer(port);
    });

    tearDown(() async {
      await _stopServer(server);
    });

    Future<({Socket socket, StreamQueue<String> lines})> openClient() async {
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
      addTearDown(() async {
        socket.destroy();
      });
      // Untagged greeting.
      final greet = await lines.next.timeout(const Duration(seconds: 5));
      expect(greet, startsWith('* OK'));
      return (socket: socket, lines: lines);
    }

    test('CAPABILITY advertises IMAP4rev1', () async {
      final c = await openClient();
      _send(c.socket, 'A001 CAPABILITY');
      final reply = await _readImapUntilTag(c.lines, 'A001');
      expect(reply, contains('* CAPABILITY'));
      expect(reply.toUpperCase(), contains('IMAP4REV1'));
      expect(reply, contains('A001 OK'));
    });

    test('LOGIN with wrong credentials returns NO', () async {
      final c = await openClient();
      _send(c.socket, 'A001 LOGIN $_user wrong-pass');
      final reply = await _readImapUntilTag(c.lines, 'A001');
      expect(reply, contains('A001 NO'));
    });

    test('LOGIN + LIST + SELECT + LOGOUT flow works', () async {
      final c = await openClient();

      _send(c.socket, 'A001 LOGIN $_user $_pass');
      expect(await _readImapUntilTag(c.lines, 'A001'), contains('A001 OK'));

      _send(c.socket, 'A002 LIST "" "*"');
      final listReply = await _readImapUntilTag(c.lines, 'A002');
      expect(listReply.toUpperCase(), contains('INBOX'));
      expect(listReply, contains('A002 OK'));

      _send(c.socket, 'A003 SELECT INBOX');
      final selReply = await _readImapUntilTag(c.lines, 'A003');
      expect(selReply, contains('1 EXISTS'));
      expect(selReply, contains('A003 OK'));

      _send(c.socket, 'A004 LOGOUT');
      // RFC 3501 §6.1.3: server MUST emit untagged "* BYE" then a tagged
      // OK before closing. Now that the server uses graceful socket.close()
      // these bytes reliably reach the client.
      final byeReply = await _readImapUntilTag(c.lines, 'A004');
      expect(byeReply, contains('* BYE'));
      expect(byeReply, contains('A004 OK'));
    });

    test('FETCH 1 (UID FLAGS RFC822.SIZE) returns metadata', () async {
      final c = await openClient();

      _send(c.socket, 'A001 LOGIN $_user $_pass');
      expect(await _readImapUntilTag(c.lines, 'A001'), contains('A001 OK'));

      _send(c.socket, 'A002 SELECT INBOX');
      expect(await _readImapUntilTag(c.lines, 'A002'), contains('A002 OK'));

      _send(c.socket, 'A003 FETCH 1 (UID FLAGS RFC822.SIZE)');
      final reply = await _readImapUntilTag(c.lines, 'A003');
      expect(reply, contains('* 1 FETCH'));
      expect(reply, contains('UID 1001'));
      expect(reply, contains('RFC822.SIZE ${_sampleMessage.length}'));
      expect(reply, contains('A003 OK'));
    });

    test('NOOP without auth is allowed', () async {
      final c = await openClient();
      _send(c.socket, 'A001 NOOP');
      final reply = await _readImapUntilTag(c.lines, 'A001');
      expect(reply, contains('A001 OK'));
    });
  });
}
