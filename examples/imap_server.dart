// Minimal IMAP server (port 2143). Authenticates a single hard-coded user,
// exposes a single in-memory INBOX with one message.
//
//   dart run examples/imap_server.dart
//
// Test with any IMAP client (port 2143, no TLS, user/pass below).

import 'dart:typed_data';

import 'package:dart_email_server/dart_email_server.dart';

const _user = 'demo@example.com';
const _pass = 'demo';

final _message = Uint8List.fromList(
  ('From: postmaster@example.com\r\n'
          'To: $_user\r\n'
          'Subject: Welcome\r\n'
          'Message-ID: <welcome-1@example.com>\r\n'
          'Date: Mon, 04 May 2026 12:00:00 +0000\r\n'
          '\r\n'
          'Welcome to the demo IMAP server.\r\n')
      .codeUnits,
);

Future<void> main() async {
  final server = Server(
    const ServerOptions(
      hostname: 'imap.example.com',
      ports: ServerPorts(imap: 2143),
    ),
  );

  // Auth gate
  server.on('auth', (AuthInfo a) {
    if (a.protocol != 'imap') return;
    if (a.username == _user && a.password == _pass) {
      a.accept();
    } else {
      a.reject('Bad credentials');
    }
  });

  // Wire up an in-memory mailbox once a session authenticates.
  server.on('mailboxSession', (MailboxFacade mb) {
    if (mb.protocol != 'imap') return;
    print('[imap] session opened for ${mb.username}');

    mb.on('folders', (Function cb) {
      cb(null, [
        {'name': 'INBOX', 'subscribed': true, 'specialUse': null},
      ]);
    });

    mb.on('select', (String name, Function cb) {
      cb(null, {
        'exists': 1,
        'recent': 0,
        'uidvalidity': 1,
        'uidnext': 2,
        'flags': ['\\Seen'],
        'permanentFlags': ['\\Seen'],
      });
    });

    mb.on('fetch', (Map<String, dynamic> req, Function cb) {
      // Return our single message for any sequence/UID request.
      cb(null, [
        {
          'seq': 1,
          'uid': 1,
          'flags': <String>[],
          'internalDate': DateTime.now(),
          'size': _message.length,
          'raw': _message,
        },
      ]);
    });
  });

  await server.listen();
  print('IMAP server listening on 2143 — login $_user / $_pass');
}
