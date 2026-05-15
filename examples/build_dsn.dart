// Generate an RFC 3464 Delivery Status Notification (bounce report).
//
//   dart run examples/build_dsn.dart

import 'dart:typed_data';

import 'package:dart_email_server/dart_email_server.dart';

void main() {
  final original = Uint8List.fromList(
    ('From: sender@example.org\r\n'
            'To: missing@dest.example\r\n'
            'Subject: Greetings\r\n'
            'Message-ID: <orig-1@example.org>\r\n'
            '\r\n'
            'Body of the original message.\r\n')
        .codeUnits,
  );

  final dsn = buildDsn(
    DsnOptions(
      reportingMta: 'mx.example.com',
      from: 'postmaster@example.com',
      to: 'sender@example.org',
      arrivalDate: DateTime.now().toUtc(),
      originalMessage: original,
      returnContent: 'headers', // 'headers' | 'full'
      recipients: [
        DsnRecipient(
          finalRecipient: 'missing@dest.example',
          action: 'failed',
          status: '5.1.1',
          diagnostic: 'smtp; 550 5.1.1 No such user here',
          remoteMta: 'dns; mx.dest.example',
          lastAttempt: DateTime.now().toUtc(),
        ),
      ],
    ),
  );

  print(String.fromCharCodes(dsn));
}
