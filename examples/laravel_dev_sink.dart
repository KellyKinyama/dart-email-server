// examples/laravel_dev_sink.dart
import 'dart:convert';
import 'package:dart_email_server/dart_email_server.dart';

Future<void> main() async {
  final server = Server(ServerOptions(
    hostname: 'localhost',
    ports: ServerPorts(inbound: 2525),
    maxSize: 10 * 1024 * 1024,
    maxRecipients: 50,
  ));

  server.on('ready', () => print('SMTP listening on 127.0.0.1:2525'));
  server.on('smtpSession', (session, _) {
    session.on('mail', (MailObject mail) {
      print('--- ${mail.from} -> ${mail.to.join(", ")} '
            '(${mail.size} bytes) ---');
      print('Subject: ${mail.subject}');
      print(utf8.decode(mail.raw, allowMalformed: true));
      mail.accept();
    });
  });

  await server.listen();
}