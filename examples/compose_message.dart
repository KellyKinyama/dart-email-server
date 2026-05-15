// Build an RFC 5322 message in memory. No sockets, no networking.
//
//   dart run examples/compose_message.dart
//
// Prints the resulting message bytes to stdout.

import 'package:dart_email_server/dart_email_server.dart';

void main() {
  final result = composeMessageTyped(
    ComposeMessageOptions(
      from: 'Alice <alice@example.com>',
      to: 'Bob <bob@example.org>',
      cc: ['carol@example.org'],
      subject: 'Hello from dart_email_server',
      text: 'Plain-text body.\r\n\r\nGreetings from Dart!\r\n',
      html: '<p>HTML body — <strong>greetings</strong> from Dart!</p>',
      headers: {'X-Mailer': 'dart_email_server example'},
    ),
  );

  print('Message-ID: ${result.messageId}');
  print('--- raw message (${result.raw.length} bytes) ---');
  print(String.fromCharCodes(result.raw));
}
