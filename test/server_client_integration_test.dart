// End-to-end integration tests:
//   * One email server  : Server (inbound SMTP on a random local port)
//   * Two email clients :
//       1) raw TCP client driving HELO/MAIL/RCPT/DATA over the wire
//       2) typed sendMail() via RelayOptions against the same server
//
// All tests are hermetic — no DNS, no external network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dart_email_server/dart_email_server.dart';
import 'package:test/test.dart';

/// Pick a free TCP port by binding to 0 and immediately releasing it.
Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

/// Start a Server bound to [port] and wait until `ready` fires.
Future<Server> _startServer(
  int port, {
  void Function(MailObject)? onMail,
}) async {
  final server = Server(
    ServerOptions(
      hostname: 'test.local',
      ports: ServerPorts(inbound: port),
      maxSize: 1024 * 1024,
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

/// Drain a Server: best-effort `close()` with a short grace period.
Future<void> _stopServer(Server s) async {
  final done = Completer<void>();
  s.close(() {
    if (!done.isCompleted) done.complete();
  });
  await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
}

/// Read SMTP reply lines from a socket until we see a non-continuation
/// line (i.e. "NNN " instead of "NNN-").
Future<String> _readReply(StreamQueue<String> lines) async {
  final buf = StringBuffer();
  while (true) {
    final l = await lines.next.timeout(const Duration(seconds: 5));
    buf.writeln(l);
    if (l.length >= 4 && l[3] == ' ') return buf.toString();
  }
}

void _send(Socket s, String line) {
  s.add(utf8.encode('$line\r\n'));
}

void main() {
  group('Server (inbound SMTP) <-> raw TCP client', () {
    late int port;
    late Server server;
    final received = <MailObject>[];

    setUp(() async {
      received.clear();
      port = await _freePort();
      server = await _startServer(port, onMail: received.add);
    });

    tearDown(() async {
      await _stopServer(server);
    });

    test('HELO/MAIL/RCPT/DATA round-trip delivers a message', () async {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
      ).timeout(const Duration(seconds: 5));
      addTearDown(() => socket.destroy());

      final lines = StreamQueue<String>(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );

      // Greeting
      final greet = await _readReply(lines);
      expect(greet, startsWith('220'));

      _send(socket, 'HELO client.test');
      expect(await _readReply(lines), startsWith('250'));

      _send(socket, 'MAIL FROM:<alice@example.com>');
      expect(await _readReply(lines), startsWith('250'));

      _send(socket, 'RCPT TO:<bob@example.org>');
      expect(await _readReply(lines), startsWith('250'));

      _send(socket, 'DATA');
      expect(await _readReply(lines), startsWith('354'));

      socket.add(
        utf8.encode(
          'From: Alice <alice@example.com>\r\n'
          'To: Bob <bob@example.org>\r\n'
          'Subject: raw client hello\r\n'
          'Message-ID: <raw-1@test.local>\r\n'
          'Date: Sat, 09 May 2026 09:00:00 +0000\r\n'
          '\r\n'
          'Body sent by the raw TCP client.\r\n'
          '.\r\n',
        ),
      );
      expect(await _readReply(lines), startsWith('250'));

      _send(socket, 'QUIT');
      // Server may close right after 221 — tolerate either.
      try {
        expect(await _readReply(lines), startsWith('221'));
      } on StateError {
        // socket closed cleanly
      }

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, hasLength(1));
      expect(received.first.from, 'alice@example.com');
      expect(received.first.to, contains('bob@example.org'));
      expect(received.first.subject, 'raw client hello');
    });

    test('EHLO advertises pipelining and 8bitmime capabilities', () async {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      addTearDown(() => socket.destroy());

      final lines = StreamQueue<String>(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );

      expect((await _readReply(lines)), startsWith('220'));

      _send(socket, 'EHLO client.test');
      final ehlo = await _readReply(lines);
      expect(ehlo, startsWith('250'));
      expect(ehlo.toUpperCase(), contains('PIPELINING'));
      expect(ehlo.toUpperCase(), contains('8BITMIME'));

      _send(socket, 'QUIT');
    });

    test('RCPT before MAIL is rejected', () async {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      addTearDown(() => socket.destroy());

      final lines = StreamQueue<String>(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );
      expect(await _readReply(lines), startsWith('220'));

      _send(socket, 'EHLO client.test');
      expect(await _readReply(lines), startsWith('250'));

      _send(socket, 'RCPT TO:<bob@example.org>');
      final reply = await _readReply(lines);
      expect(reply, startsWith('503'));

      _send(socket, 'QUIT');
    });
  });

  group('Server (inbound SMTP) <-> typed sendMail() relay client', () {
    late int port;
    late Server server;
    final received = <MailObject>[];

    setUp(() async {
      received.clear();
      port = await _freePort();
      server = await _startServer(port, onMail: received.add);
    });

    tearDown(() async {
      await _stopServer(server);
    });

    test(
      'sendMail via RelayOptions delivers and round-trips Subject',
      () async {
        final result = await sendMail(
          SendMailOptions(
            from: AddressObj(name: 'Alice', address: 'alice@example.com'),
            to: [AddressObj(name: 'Bob', address: 'bob@example.org')],
            subject: 'integration via relay',
            text: 'Hello from sendMail via relay.\r\n',
            relay: RelayOptions(
              host: '127.0.0.1',
              port: port,
              requireTls: false,
            ),
            localHostname: 'client.test',
            ignoreTLS: true,
            timeout: 10000,
          ),
        ).timeout(const Duration(seconds: 15));

        expect(result.messageId, isNotNull);
        expect(result.rejected, isEmpty);

        // Server should have observed exactly one mail.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(received, hasLength(1));
        expect(received.first.subject, 'integration via relay');
        expect(received.first.to, contains('bob@example.org'));
      },
    );

    test(
      'sendMail to multiple recipients delivers once with two RCPTs',
      () async {
        final result = await sendMail(
          SendMailOptions(
            from: AddressObj(name: '', address: 'sender@example.com'),
            to: [
              AddressObj(name: '', address: 'r1@example.org'),
              AddressObj(name: '', address: 'r2@example.org'),
            ],
            subject: 'fan-out',
            text: 'multi-recipient body\r\n',
            relay: RelayOptions(
              host: '127.0.0.1',
              port: port,
              requireTls: false,
            ),
            localHostname: 'client.test',
            ignoreTLS: true,
            timeout: 10000,
          ),
        ).timeout(const Duration(seconds: 15));

        expect(result.rejected, isEmpty);

        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(received, hasLength(1));
        expect(
          received.first.to,
          containsAll(<String>['r1@example.org', 'r2@example.org']),
        );
      },
    );
  });
}
