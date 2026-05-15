// Minimal inbound SMTP server. Listens on localhost:2525, accepts any mail,
// prints a summary of every received message.
//
//   dart run examples/smtp_server.dart
//
// Test it from another terminal:
//   swaks --to bob@example.com --from alice@example.org \
//         --server 127.0.0.1:2525 --body "hello"

import 'dart:async';

import 'package:dart_email_server/dart_email_server.dart';

Future<void> main() async {
  final server = Server(
    const ServerOptions(
      hostname: 'mail.example.com',
      ports: ServerPorts(inbound: 2525), // SMTP, no TLS, no auth
      maxSize: 10 * 1024 * 1024,
      maxRecipients: 50,
    ),
  );

  // Hook every connection (optional — call `info.reject()` to refuse).
  server.on('connection', (ConnectionInfo info) {
    print('[conn] ${info.protocol} from ${info.remoteAddress} (${info.id})');
  });

  // The 'smtpSession' event hands us a per-session EventEmitter and a
  // typed state object. The session emits 'mail' for each accepted DATA.
  server.on('smtpSession', (sessionFacade, SmtpFacadeState st) {
    sessionFacade.on('mail', (MailObject mail) {
      print('--- new mail ---');
      print('  from    : ${mail.from}');
      print('  to      : ${mail.to}');
      print('  subject : ${mail.subject}');
      print('  size    : ${mail.size} bytes');
      print('  text    : ${(mail.text ?? '').split('\n').first}');
      mail.accept();
    });
  });

  await server.listen();
  print('SMTP server listening on port 2525. Ctrl-C to stop.');
}
