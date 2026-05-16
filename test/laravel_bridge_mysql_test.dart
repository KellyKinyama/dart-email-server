// Integration tests for `examples/laravel_bridge_mysql.dart`.
//
// These tests boot the bridge as a subprocess against a real MySQL server,
// deliver a message over SMTP, verify it lands in the `mailbox_messages`
// table, restart the bridge, and confirm the message survives by reading
// it back over IMAP.
//
// They are SKIPPED automatically when MySQL is not reachable. Set
// `DART_TEST_MYSQL=1` and provide credentials via the same env vars the
// example reads (DART_MAIL_DB_HOST, DART_MAIL_DB_PORT, DART_MAIL_DB_NAME,
// DART_MAIL_DB_USER, DART_MAIL_DB_PASS, DART_MAIL_DB_SSL) to run them.
// Defaults: host=127.0.0.1, port=3306, db=dart_email_server, user=dart,
// pass=dart, sslmode=require.
//
// The tests are intentionally `Timeout(Duration(minutes: 2))` because
// `dart run` on a cold cache + waiting for the listen line can be slow.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eloquent/eloquent.dart';
import 'package:test/test.dart';

const _bridgeScript = 'examples/laravel_bridge_mysql.dart';

String _env(String key, String fallback) =>
    Platform.environment[key]?.trim().isNotEmpty == true
        ? Platform.environment[key]!.trim()
        : fallback;

final String _dbHost = _env('DART_MAIL_DB_HOST', '127.0.0.1');
final String _dbPort = _env('DART_MAIL_DB_PORT', '3306');
final String _dbName = _env('DART_MAIL_DB_NAME', 'dart_email_server');
final String _dbUser = _env('DART_MAIL_DB_USER', 'dart');
final String _dbPass = _env('DART_MAIL_DB_PASS', 'dart');
final String _dbSsl  = _env('DART_MAIL_DB_SSL',  'require');

/// Try to open a MySQL connection with the configured creds. Returns the
/// live `Connection` on success, `null` on any failure (used to skip).
Future<dynamic> _tryConnect() async {
  try {
    final m = Manager()
      ..addConnection({
        'driver': 'mysql',
        'host': _dbHost,
        'port': _dbPort,
        'database': _dbName,
        'username': _dbUser,
        'password': _dbPass,
        'prefix': '',
        'sslmode': _dbSsl,
      })
      ..setAsGlobal();
    final db = await m.connection();
    // Minimal smoke query.
    await db.select('SELECT 1');
    return db;
  } catch (_) {
    return null;
  }
}

Future<void> _wipeTables(dynamic db) async {
  // Order matters: messages -> folders -> users (FK chain).
  await db.execute('SET FOREIGN_KEY_CHECKS=0');
  for (final t in const ['mailbox_messages', 'mailbox_folders', 'mailbox_users']) {
    await db.execute('DROP TABLE IF EXISTS $t');
  }
  await db.execute('SET FOREIGN_KEY_CHECKS=1');
}

/// Pick a free TCP port by binding and immediately releasing it.
Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

class _BridgeProcess {
  _BridgeProcess(this.proc, this.smtpPort, this.submissionPort,
      this.imapPort, this.pop3Port, this.stdoutBuf, this.stderrBuf);

  final Process proc;
  final int smtpPort;
  final int submissionPort;
  final int imapPort;
  final int pop3Port;
  final StringBuffer stdoutBuf;
  final StringBuffer stderrBuf;

  Future<void> stop() async {
    proc.kill(ProcessSignal.sigkill);
    try {
      await proc.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {/* ignore */}
  }
}

/// Start the bridge as a subprocess. Waits up to [bootTimeout] for the
/// `listening` line on stdout. Throws on failure (after surfacing the
/// captured logs to make CI failures debuggable).
Future<_BridgeProcess> _spawnBridge({
  required int smtpPort,
  required int submissionPort,
  required int imapPort,
  required int pop3Port,
  Duration bootTimeout = const Duration(seconds: 45),
}) async {
  final env = <String, String>{
    'DART_MAIL_DB_HOST': _dbHost,
    'DART_MAIL_DB_PORT': _dbPort,
    'DART_MAIL_DB_NAME': _dbName,
    'DART_MAIL_DB_USER': _dbUser,
    'DART_MAIL_DB_PASS': _dbPass,
    'DART_MAIL_DB_SSL':  _dbSsl,
    'DART_MAIL_SMTP_PORT':       '$smtpPort',
    'DART_MAIL_SUBMISSION_PORT': '$submissionPort',
    'DART_MAIL_IMAP_PORT':       '$imapPort',
    'DART_MAIL_POP3_PORT':       '$pop3Port',
  };
  final proc = await Process.start(
    Platform.resolvedExecutable, // current `dart` binary
    ['run', _bridgeScript],
    environment: env,
    workingDirectory: Directory.current.path,
  );

  final outBuf = StringBuffer();
  final errBuf = StringBuffer();
  final ready = Completer<void>();

  proc.stdout.transform(utf8.decoder).listen((chunk) {
    outBuf.write(chunk);
    if (!ready.isCompleted && chunk.contains('listening')) {
      ready.complete();
    }
  });
  proc.stderr.transform(utf8.decoder).listen((chunk) {
    errBuf.write(chunk);
  });

  // Surface an early exit before bootTimeout fires.
  unawaited(proc.exitCode.then((code) {
    if (!ready.isCompleted) {
      ready.completeError(StateError(
          'bridge exited early with code $code\n'
          'STDOUT:\n${outBuf.toString()}\n'
          'STDERR:\n${errBuf.toString()}'));
    }
  }));

  await ready.future.timeout(bootTimeout, onTimeout: () {
    throw TimeoutException(
        'bridge did not log "listening" within $bootTimeout\n'
        'STDOUT:\n${outBuf.toString()}\n'
        'STDERR:\n${errBuf.toString()}');
  });

  return _BridgeProcess(
      proc, smtpPort, submissionPort, imapPort, pop3Port, outBuf, errBuf);
}

// ---------------------------------------------------------------------------
// SMTP helpers (raw socket; no auth on port 2525-equivalent).
// ---------------------------------------------------------------------------

Future<List<String>> _smtpDeliver({
  required int port,
  required String from,
  required String to,
  required String subject,
  required String body,
}) async {
  final socket = await Socket.connect(
      InternetAddress.loopbackIPv4, port,
      timeout: const Duration(seconds: 10));
  final lines = <String>[];
  final pendingLine = StringBuffer();

  final sub = socket.cast<List<int>>().transform(utf8.decoder).listen((chunk) {
    for (final ch in chunk.split('')) {
      if (ch == '\n') {
        lines.add(pendingLine.toString().replaceAll('\r', ''));
        pendingLine.clear();
      } else {
        pendingLine.write(ch);
      }
    }
  });

  Future<void> wait(int millis) =>
      Future<void>.delayed(Duration(milliseconds: millis));

  /// Wait until [predicate] is satisfied, or [timeoutMs] elapses.
  Future<bool> waitFor(bool Function() predicate,
      {int timeoutMs = 8000, int pollMs = 100}) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (predicate()) return true;
      await wait(pollMs);
    }
    return predicate();
  }

  Future<void> writeLine(String s) async {
    socket.add(utf8.encode('$s\r\n'));
    await socket.flush();
  }

  // Greeting (single 220 line).
  await waitFor(() => lines.any((l) => l.startsWith('220 ')));
  final ehloMark = lines.length;
  await writeLine('EHLO test.local');
  // Wait for a final EHLO reply line: "250 " (single space, not dash).
  await waitFor(() => lines.skip(ehloMark)
      .any((l) => l.startsWith('250 ')));

  final mailMark = lines.length;
  await writeLine('MAIL FROM:<$from>');
  await waitFor(() => lines.length > mailMark);

  final rcptMark = lines.length;
  await writeLine('RCPT TO:<$to>');
  await waitFor(() => lines.length > rcptMark);

  final dataMark = lines.length;
  await writeLine('DATA');
  await waitFor(() => lines.skip(dataMark).any((l) => l.startsWith('354')));

  final bodyMark = lines.length;
  final dataBuf = StringBuffer()
    ..write('From: $from\r\n')
    ..write('To: $to\r\n')
    ..write('Subject: $subject\r\n')
    ..write('\r\n');
  for (final ln in body.split('\n')) {
    dataBuf.write(ln.startsWith('.') ? '.$ln\r\n' : '$ln\r\n');
  }
  dataBuf.write('.\r\n');
  socket.add(utf8.encode(dataBuf.toString()));
  await socket.flush();
  // Wait for a 250 ack of the message.
  await waitFor(
      () => lines.skip(bodyMark).any((l) => l.startsWith('250 ')),
      timeoutMs: 30000);

  await writeLine('QUIT');
  await wait(300);
  await sub.cancel();
  await socket.close();
  return lines;
}

// ---------------------------------------------------------------------------
// IMAP helpers (raw socket; demo creds).
// ---------------------------------------------------------------------------

Future<List<String>> _imapSearchInbox({
  required int port,
  required String user,
  required String pass,
}) async {
  final socket = await Socket.connect(
      InternetAddress.loopbackIPv4, port,
      timeout: const Duration(seconds: 10));
  final lines = <String>[];
  final pendingLine = StringBuffer();
  final sub = socket.cast<List<int>>().transform(utf8.decoder).listen((chunk) {
    for (final ch in chunk.split('')) {
      if (ch == '\n') {
        lines.add(pendingLine.toString().replaceAll('\r', ''));
        pendingLine.clear();
      } else {
        pendingLine.write(ch);
      }
    }
  });

  Future<void> wait(int millis) =>
      Future<void>.delayed(Duration(milliseconds: millis));

  Future<bool> waitFor(bool Function() predicate,
      {int timeoutMs = 8000, int pollMs = 100}) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (predicate()) return true;
      await wait(pollMs);
    }
    return predicate();
  }

  Future<void> writeLine(String s) async {
    socket.add(utf8.encode('$s\r\n'));
    await socket.flush();
  }

  // Greeting.
  await waitFor(() => lines.isNotEmpty);

  Future<void> issue(String tag, String cmd) async {
    final mark = lines.length;
    await writeLine('$tag $cmd');
    await waitFor(
        () => lines.skip(mark).any((l) => l.startsWith('$tag ')),
        timeoutMs: 8000);
  }

  await issue('a', 'login $user $pass');
  await issue('b', 'select INBOX');
  await issue('c', 'uid search all');
  await issue('d', 'uid fetch 1 (BODY.PEEK[HEADER.FIELDS (SUBJECT)])');
  await writeLine('z logout');
  await wait(300);
  await sub.cancel();
  await socket.close();
  return lines;
}

void main() {
  late dynamic db;
  late int smtpPort, submissionPort, imapPort, pop3Port;

  setUpAll(() async {
    db = await _tryConnect();
  });

  group('laravel_bridge_mysql.dart', () {
    test('connect-or-skip', () async {
      if (db == null) {
        markTestSkipped(
            'MySQL not reachable at $_dbUser@$_dbHost:$_dbPort/$_dbName '
            '(set DART_MAIL_DB_* env vars to enable)');
        return;
      }
      // Sanity: SELECT 1 already passed in _tryConnect.
      expect(db, isNotNull);
    });

    test('bridge boots, persists an SMTP delivery, survives a restart',
        () async {
      if (db == null) {
        markTestSkipped('MySQL unreachable; see "connect-or-skip"');
        return;
      }

      // Fresh schema for each run of this test.
      await _wipeTables(db);

      smtpPort = await _freePort();
      submissionPort = await _freePort();
      imapPort = await _freePort();
      pop3Port = await _freePort();

      final first = await _spawnBridge(
        smtpPort: smtpPort,
        submissionPort: submissionPort,
        imapPort: imapPort,
        pop3Port: pop3Port,
      );

      try {
        // Deliver a single message via SMTP.
        final smtpLines = await _smtpDeliver(
          port: smtpPort,
          from: 'sender@example.com',
          to: 'demo@example.com',
          subject: 'persistence integration',
          body: 'hello from the integration test',
        );
        expect(
          smtpLines.any((l) => l.startsWith('250') && l.contains('queued')),
          isTrue,
          reason:
              'expected a 250 ... queued response after DATA terminator. '
              'Lines: $smtpLines\n'
              'Bridge stdout:\n${first.stdoutBuf}\n'
              'Bridge stderr:\n${first.stderrBuf}',
        );

        // Give the fire-and-forget INSERT a moment to flush.
        await Future<void>.delayed(const Duration(seconds: 1));

        // Confirm the row landed in MySQL.
        final rows = await db.select(
          'SELECT u.username AS u, f.name AS f, COUNT(m.id) AS n '
          'FROM mailbox_users u '
          'JOIN mailbox_folders f ON f.user_id = u.id '
          'LEFT JOIN mailbox_messages m ON m.folder_id = f.id '
          'WHERE u.username = ? AND f.name = ? '
          'GROUP BY u.id, f.id',
          ['demo@example.com', 'INBOX'],
        );
        expect(rows, isNotEmpty);
        expect((rows.first['n'] as num).toInt(), equals(1),
            reason: 'INBOX should have exactly one persisted message');
      } finally {
        await first.stop();
      }

      // Restart against the existing data.
      final second = await _spawnBridge(
        smtpPort: smtpPort,
        submissionPort: submissionPort,
        imapPort: imapPort,
        pop3Port: pop3Port,
      );

      try {
        final imapLines = await _imapSearchInbox(
          port: imapPort,
          user: 'demo@example.com',
          pass: 'demo',
        );
        expect(
          imapLines.any((l) => l.startsWith('* SEARCH 1')),
          isTrue,
          reason:
              'IMAP should report UID 1 surviving the restart. '
              'Lines: $imapLines',
        );
        expect(
          imapLines.any((l) => l.contains('Subject: persistence integration')),
          isTrue,
          reason:
              'restored message should still carry its subject header. '
              'Lines: $imapLines',
        );
      } finally {
        await second.stop();
      }
    },
        timeout: const Timeout(Duration(minutes: 2)));

    test('mailbox_users gets a row for every distinct address SMTP touches',
        () async {
      if (db == null) {
        markTestSkipped('MySQL unreachable; see "connect-or-skip"');
        return;
      }

      await _wipeTables(db);

      final ports = await Future.wait([
        _freePort(), _freePort(), _freePort(), _freePort(),
      ]);
      final bridge = await _spawnBridge(
        smtpPort: ports[0],
        submissionPort: ports[1],
        imapPort: ports[2],
        pop3Port: ports[3],
      );

      try {
        await _smtpDeliver(
          port: ports[0],
          from: 'sender@example.com',
          to: 'demo@example.com',
          subject: 'first',
          body: 'one',
        );
        await Future<void>.delayed(const Duration(milliseconds: 800));

        final rows = await db.select(
            'SELECT username FROM mailbox_users ORDER BY username');
        final names =
            rows.map<String>((r) => (r['username'] as String).toLowerCase()).toList();
        expect(names, contains('demo@example.com'),
            reason: 'recipient should be persisted into mailbox_users');

        // Each user should have exactly five default folders.
        final folderRows = await db.select(
          'SELECT COUNT(*) AS n FROM mailbox_folders f '
          'JOIN mailbox_users u ON u.id = f.user_id '
          'WHERE u.username = ?',
          ['demo@example.com'],
        );
        expect((folderRows.first['n'] as num).toInt(), equals(5),
            reason:
                'default tree should be INBOX, Sent, Drafts, Trash, Junk');
      } finally {
        await bridge.stop();
      }
    },
        timeout: const Timeout(Duration(minutes: 2)));
  });
}
