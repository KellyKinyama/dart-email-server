// Decode a multi-line SMTP reply (e.g. an EHLO response) into the typed
// `SmtpReply` view exposed by `parseReplyBlockTyped`.
//
//   dart run examples/parse_smtp_reply.dart

import 'dart:typed_data';

import 'package:dart_email_server/dart_email_server.dart';

void main() {
  final raw = Uint8List.fromList(
    ('250-mail.example.com Hello client.example.org\r\n'
            '250-PIPELINING\r\n'
            '250-SIZE 10485760\r\n'
            '250-STARTTLS\r\n'
            '250-AUTH PLAIN LOGIN\r\n'
            '250-8BITMIME\r\n'
            '250 SMTPUTF8\r\n')
        .codeUnits,
  );

  final reply = parseReplyBlockTyped(raw);

  print('code        : ${reply.code}  (${reply.cls} / ${reply.meaning})');
  print('isSuccess   : ${reply.isSuccess}');
  print('isEhloCaps  : ${reply.isEhloCaps}');
  print('lines       :');
  for (final line in reply.replyLines) {
    print('  - $line');
  }

  final caps = reply.capabilities;
  if (caps != null) {
    print('capabilities:');
    print('  serverName    = ${caps['serverName']}');
    print('  pipelining    = ${caps['pipelining']}');
    print('  size          = ${caps['size']}');
    print('  startTls      = ${caps['startTls']}');
    print('  eightBitMime  = ${caps['eightBitMime']}');
    print('  smtputf8      = ${caps['smtputf8']}');
    final auth = caps['auth'] as Map<String, dynamic>?;
    if (auth != null) {
      print('  auth.advertised = ${auth['advertised']}');
      print('  auth.mechanisms = ${auth['mechanisms']}');
    }
  }
}
