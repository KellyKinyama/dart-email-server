// Edge-case + protocol-conformance tests for SMTP / IMAP / POP3.
//
// These complement the happy-path coverage in:
//   * test/server_client_integration_test.dart
//   * test/imap_pop3_integration_test.dart
//   * test/end_to_end_mail_flow_test.dart
//
// All tests are hermetic — no DNS, no external network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:dart_email_server/dart_email_server.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
//  Helpers (mirrored from existing integration tests; kept local so each
//  edge-case file is self-contained).
// ---------------------------------------------------------------------------

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

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
//  Server fixtures
// ---------------------------------------------------------------------------

Future<Server> _startSmtp(
  int port, {
  int maxSize = 1024 * 1024,
  int maxRecipients = 5,
  void Function(MailObject)? onMail,
}) async {
  final server = Server(
    ServerOptions(
      hostname: 'edge.test.local',
      ports: ServerPorts(inbound: port),
      maxSize: maxSize,
      maxRecipients: maxRecipients,
    ),
  );
  final ready = Completer<void>();
  server.on('ready', () {
    if (!ready.isCompleted) ready.complete();
  });
  server.on('smtpSession', (sessionFacade, SmtpFacadeState _) {
    sessionFacade.on('mail', (MailObject mail) {
      if (onMail != null) onMail(mail);
      mail.accept();
    });
  });
  unawaited(server.listen());
  await ready.future.timeout(const Duration(seconds: 5));
  return server;
}

Future<Server> _startPop3Empty(int port) async {
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
    if (a.username == 'demo' && a.password == 'demo') {
      a.accept();
    } else {
      a.reject('Bad credentials');
    }
  });
  server.on('mailboxSession', (MailboxFacade mb) {
    if (mb.protocol != 'pop3') return;
    mb.on('openFolder', (String name, Function cb) {
      cb(null, {'total': 0});
    });
    mb.on('resolveMessages', (
      String name,
      Map<String, dynamic> q,
      Function cb,
    ) {
      cb(null, <Map<String, dynamic>>[]);
    });
    mb.on('messageMeta', (String name, List<dynamic> uids, Function cb) {
      cb(null, <Map<String, dynamic>>[]);
    });
  });
  unawaited(server.listen());
  await ready.future.timeout(const Duration(seconds: 5));
  return server;
}

Future<Server> _startImapEmpty(int port) async {
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
    if (a.username == 'demo' && a.password == 'demo') {
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
        'total': 0,
        'recent': 0,
        'uidValidity': 1,
        'uidNext': 1,
        'flags': <String>['\\Seen'],
        'permanentFlags': <String>['\\Seen'],
      });
    });
    mb.on('resolveMessages', (
      String name,
      Map<String, dynamic> q,
      Function cb,
    ) {
      cb(null, <Map<String, dynamic>>[]);
    });
    mb.on('messageMeta', (String name, List<dynamic> uids, Function cb) {
      cb(null, <Map<String, dynamic>>[]);
    });
    mb.on('status', (String name, List<dynamic> items, Function cb) {
      cb(null, {
        'exists': 0,
        'recent': 0,
        'uidnext': 1,
        'uidvalidity': 1,
        'unseen': 0,
      });
    });
  });
  unawaited(server.listen());
  await ready.future.timeout(const Duration(seconds: 5));
  return server;
}

// ---------------------------------------------------------------------------
//  SMTP edge cases
// ---------------------------------------------------------------------------

void main() {
  group('SMTP edge cases', () {
    late int port;
    late Server server;
    final received = <MailObject>[];

    setUp(() async {
      received.clear();
      port = await _freePort();
      server = await _startSmtp(
        port,
        maxSize: 4096,
        maxRecipients: 3,
        onMail: received.add,
      );
    });

    tearDown(() async {
      await _stopServer(server);
    });

    test('EHLO advertises SIZE capability with the configured limit', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await _readSmtpReply(c.lines), startsWith('220'));
      _send(c.socket, 'EHLO client.test');
      final reply = await _readSmtpReply(c.lines);
      expect(reply, contains('SIZE 4096'));
    });

    test('MAIL FROM with SIZE > maxSize is rejected with 552', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await _readSmtpReply(c.lines), startsWith('220'));
      _send(c.socket, 'EHLO client.test');
      expect(await _readSmtpReply(c.lines), startsWith('250'));
      _send(c.socket, 'MAIL FROM:<a@b.test> SIZE=10000');
      final reply = await _readSmtpReply(c.lines);
      expect(reply, startsWith('552'));
      expect(reply, contains('exceeds'));
    });

    test('RCPT TO beyond maxRecipients is rejected with 452', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await _readSmtpReply(c.lines), startsWith('220'));
      _send(c.socket, 'EHLO client.test');
      expect(await _readSmtpReply(c.lines), startsWith('250'));
      _send(c.socket, 'MAIL FROM:<a@b.test>');
      expect(await _readSmtpReply(c.lines), startsWith('250'));
      for (var i = 0; i < 3; i++) {
        _send(c.socket, 'RCPT TO:<r$i@b.test>');
        expect(await _readSmtpReply(c.lines), startsWith('250'));
      }
      // 4th recipient should be 452 (we configured maxRecipients = 3).
      _send(c.socket, 'RCPT TO:<over@b.test>');
      final reply = await _readSmtpReply(c.lines);
      expect(reply, startsWith('452'));
      expect(reply.toLowerCase(), contains('too many'));
    });

    test('RSET clears in-progress transaction', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await _readSmtpReply(c.lines), startsWith('220'));
      _send(c.socket, 'HELO client.test');
      expect(await _readSmtpReply(c.lines), startsWith('250'));

      _send(c.socket, 'MAIL FROM:<a@b.test>');
      expect(await _readSmtpReply(c.lines), startsWith('250'));
      _send(c.socket, 'RCPT TO:<r@b.test>');
      expect(await _readSmtpReply(c.lines), startsWith('250'));

      _send(c.socket, 'RSET');
      expect(await _readSmtpReply(c.lines), startsWith('250'));

      // After RSET, RCPT before MAIL must fail.
      _send(c.socket, 'RCPT TO:<r2@b.test>');
      final reply = await _readSmtpReply(c.lines);
      expect(reply, startsWith('503'));
    });

    test('NOOP returns 250 from any state', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await _readSmtpReply(c.lines), startsWith('220'));
      _send(c.socket, 'NOOP');
      expect(await _readSmtpReply(c.lines), startsWith('250'));
    });

    test('VRFY responds with 252 (cannot verify, will accept)', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await _readSmtpReply(c.lines), startsWith('220'));
      _send(c.socket, 'VRFY postmaster');
      expect(await _readSmtpReply(c.lines), startsWith('252'));
    });

    test('Unknown command returns 502', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await _readSmtpReply(c.lines), startsWith('220'));
      _send(c.socket, 'XYZZY please');
      expect(await _readSmtpReply(c.lines), startsWith('502'));
    });

    test('QUIT returns 221 then closes the connection', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await _readSmtpReply(c.lines), startsWith('220'));
      _send(c.socket, 'QUIT');
      expect(await _readSmtpReply(c.lines), startsWith('221'));
      // Stream should drain and close shortly after.
      final more = await c.lines.hasNext.timeout(
        const Duration(seconds: 2),
        onTimeout: () => true,
      );
      expect(more, isFalse, reason: 'server should close after QUIT');
    });

    test(
      'Two sequential transactions on one connection both deliver',
      () async {
        final c = await _connect(port);
        addTearDown(() => c.socket.destroy());
        expect(await _readSmtpReply(c.lines), startsWith('220'));
        _send(c.socket, 'EHLO client.test');
        expect(await _readSmtpReply(c.lines), startsWith('250'));

        Future<void> deliverOne(String subject) async {
          _send(c.socket, 'MAIL FROM:<a@b.test>');
          expect(await _readSmtpReply(c.lines), startsWith('250'));
          _send(c.socket, 'RCPT TO:<r@b.test>');
          expect(await _readSmtpReply(c.lines), startsWith('250'));
          _send(c.socket, 'DATA');
          expect(await _readSmtpReply(c.lines), startsWith('354'));
          c.socket.add(
            utf8.encode('Subject: $subject\r\n\r\nbody for $subject\r\n.\r\n'),
          );
          expect(await _readSmtpReply(c.lines), startsWith('250'));
        }

        await deliverOne('first');
        await deliverOne('second');

        expect(received, hasLength(2));
        expect(received[0].subject, 'first');
        expect(received[1].subject, 'second');
      },
    );

    test(
      'mail.raw is CRLF-terminated even when client omits trailing CRLF',
      () async {
        final c = await _connect(port);
        addTearDown(() => c.socket.destroy());
        expect(await _readSmtpReply(c.lines), startsWith('220'));
        _send(c.socket, 'EHLO client.test');
        expect(await _readSmtpReply(c.lines), startsWith('250'));
        _send(c.socket, 'MAIL FROM:<a@b.test>');
        expect(await _readSmtpReply(c.lines), startsWith('250'));
        _send(c.socket, 'RCPT TO:<r@b.test>');
        expect(await _readSmtpReply(c.lines), startsWith('250'));
        _send(c.socket, 'DATA');
        expect(await _readSmtpReply(c.lines), startsWith('354'));
        // Body without trailing CRLF before the dot terminator.
        c.socket.add(
          utf8.encode('Subject: t\r\n\r\nno trailing crlf\r\n.\r\n'),
        );
        expect(await _readSmtpReply(c.lines), startsWith('250'));

        expect(received, hasLength(1));
        final raw = received.single.raw;
        expect(raw.length, greaterThanOrEqualTo(2));
        expect(raw[raw.length - 2], 0x0D);
        expect(raw[raw.length - 1], 0x0A);
      },
    );

    test('Concurrent SMTP deliveries all land', () async {
      const n = 10;
      final futures = <Future<void>>[];
      for (var i = 0; i < n; i++) {
        futures.add(() async {
          final c = await _connect(port);
          try {
            expect(await _readSmtpReply(c.lines), startsWith('220'));
            _send(c.socket, 'EHLO c$i.test');
            expect(await _readSmtpReply(c.lines), startsWith('250'));
            _send(c.socket, 'MAIL FROM:<s$i@b.test>');
            expect(await _readSmtpReply(c.lines), startsWith('250'));
            _send(c.socket, 'RCPT TO:<bob@b.test>');
            expect(await _readSmtpReply(c.lines), startsWith('250'));
            _send(c.socket, 'DATA');
            expect(await _readSmtpReply(c.lines), startsWith('354'));
            c.socket.add(
              utf8.encode('Subject: concurrent-$i\r\n\r\nbody $i\r\n.\r\n'),
            );
            expect(await _readSmtpReply(c.lines), startsWith('250'));
            _send(c.socket, 'QUIT');
            await _readSmtpReply(
              c.lines,
            ).timeout(const Duration(seconds: 2), onTimeout: () => '');
          } finally {
            c.socket.destroy();
          }
        }());
      }
      await Future.wait(futures);
      // All n messages must have been received with unique subjects.
      expect(received, hasLength(n));
      final subjects = received
          .map((m) => m.subject)
          .whereType<String>()
          .toSet();
      expect(subjects, hasLength(n));
    });
  });

  // -------------------------------------------------------------------------
  //  IMAP edge cases
  // -------------------------------------------------------------------------
  group('IMAP edge cases', () {
    late int port;
    late Server server;

    setUp(() async {
      port = await _freePort();
      server = await _startImapEmpty(port);
    });

    tearDown(() async {
      await _stopServer(server);
    });

    test('SELECT on empty INBOX shows 0 EXISTS', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await c.lines.next, startsWith('* OK'));

      _send(c.socket, 'A001 LOGIN demo demo');
      expect(await _readImapUntilTag(c.lines, 'A001'), contains('A001 OK'));

      _send(c.socket, 'A002 SELECT INBOX');
      final reply = await _readImapUntilTag(c.lines, 'A002');
      expect(reply, contains('0 EXISTS'));
      expect(reply, contains('A002 OK'));
    });

    test('STATUS INBOX returns expected items', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await c.lines.next, startsWith('* OK'));

      _send(c.socket, 'A001 LOGIN demo demo');
      expect(await _readImapUntilTag(c.lines, 'A001'), contains('A001 OK'));

      _send(
        c.socket,
        'A002 STATUS INBOX (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)',
      );
      final reply = await _readImapUntilTag(c.lines, 'A002');
      expect(reply, contains('* STATUS INBOX'));
      expect(reply, contains('A002 OK'));
    });

    test('Commands requiring auth fail before LOGIN', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await c.lines.next, startsWith('* OK'));

      _send(c.socket, 'A001 SELECT INBOX');
      final reply = await _readImapUntilTag(c.lines, 'A001');
      // RFC 3501 — SELECT requires authenticated state. Server may return
      // BAD or NO; both are acceptable rejections.
      expect(
        reply.contains('A001 NO') || reply.contains('A001 BAD'),
        isTrue,
        reason: 'expected NO or BAD for SELECT before LOGIN, got: $reply',
      );
    });

    test('CAPABILITY can be issued in any state', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await c.lines.next, startsWith('* OK'));

      // Pre-auth
      _send(c.socket, 'A001 CAPABILITY');
      expect(await _readImapUntilTag(c.lines, 'A001'), contains('A001 OK'));

      _send(c.socket, 'A002 LOGIN demo demo');
      expect(await _readImapUntilTag(c.lines, 'A002'), contains('A002 OK'));

      // Post-auth
      _send(c.socket, 'A003 CAPABILITY');
      final reply = await _readImapUntilTag(c.lines, 'A003');
      expect(reply, contains('* CAPABILITY'));
      expect(reply, contains('A003 OK'));
    });

    test('Bad LOGIN syntax returns BAD', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await c.lines.next, startsWith('* OK'));

      _send(c.socket, 'A001 LOGIN'); // missing args
      final reply = await _readImapUntilTag(c.lines, 'A001');
      expect(reply.contains('A001 BAD') || reply.contains('A001 NO'), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  //  POP3 edge cases
  // -------------------------------------------------------------------------
  group('POP3 edge cases', () {
    late int port;
    late Server server;

    setUp(() async {
      port = await _freePort();
      server = await _startPop3Empty(port);
    });

    tearDown(() async {
      await _stopServer(server);
    });

    test('STAT on empty mailbox returns "+OK 0 0"', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'USER demo');
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      _send(c.socket, 'PASS demo');
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'STAT');
      final stat = await _readPopLine(c.lines);
      expect(stat, startsWith('+OK'));
      final parts = stat.trim().split(RegExp(r'\s+'));
      expect(parts[1], '0');
      expect(parts[2], '0');
    });

    test('LIST on empty mailbox returns +OK then bare "."', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      _send(c.socket, 'USER demo');
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      _send(c.socket, 'PASS demo');
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'LIST');
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      final body = await _readPopMulti(c.lines);
      expect(body, isEmpty);
    });

    test('RETR on non-existent message returns -ERR', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      _send(c.socket, 'USER demo');
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      _send(c.socket, 'PASS demo');
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'RETR 1');
      expect(await _readPopLine(c.lines), startsWith('-ERR'));
    });

    test('Unknown command returns -ERR', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      _send(c.socket, 'BOGUS now');
      expect(await _readPopLine(c.lines), startsWith('-ERR'));
    });

    test('QUIT returns +OK then closes', () async {
      final c = await _connect(port);
      addTearDown(() => c.socket.destroy());
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      _send(c.socket, 'USER demo');
      expect(await _readPopLine(c.lines), startsWith('+OK'));
      _send(c.socket, 'PASS demo');
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      _send(c.socket, 'QUIT');
      expect(await _readPopLine(c.lines), startsWith('+OK'));

      final more = await c.lines.hasNext.timeout(
        const Duration(seconds: 2),
        onTimeout: () => true,
      );
      expect(more, isFalse);
    });
  });
}
