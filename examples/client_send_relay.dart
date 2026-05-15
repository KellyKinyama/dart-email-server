// Send a message through an authenticated SMTP relay (e.g. Gmail / Postfix
// submission on port 587).
//
// Edit the `RelayOptions` below and run:
//
//   dart run examples/client_send_relay.dart

import 'package:dart_email_server/dart_email_server.dart';

Future<void> main() async {
  final result = await sendMail(
    SendMailOptions(
      // Compose
      from: AddressObj(name: 'Alice', address: 'alice@example.com'),
      to: [AddressObj(name: 'Bob', address: 'bob@example.org')],
      subject: 'Test from dart_email_server',
      text:
          'Hello Bob,\r\n\r\nThis was sent via an SMTP relay.\r\n\r\n— Alice\r\n',
      html:
          '<p>Hello <b>Bob</b>,<br><br>'
          'This was sent via an SMTP relay.<br><br>'
          '— Alice</p>',

      // Smart-host (relay) — fill in your real submission server
      relay: const RelayOptions(
        host: 'smtp.example.com',
        port: 587,
        username: 'alice@example.com',
        password: 'app-password-here',
        requireTls: true,
      ),

      localHostname: 'client.example.com',
    ),
  );

  print('messageId : ${result.messageId}');
  print('accepted  :');
  for (final r in result.accepted) {
    print('  host=${r.host} accepted=${r.accepted} rejected=${r.rejected}');
  }
  print('rejected  :');
  for (final r in result.rejected) {
    print('  domain=${r.domain} error=${r.error}');
  }
}
