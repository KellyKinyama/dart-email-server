// Direct-to-MX delivery: look up the recipient's domain MX records and
// deliver without any smart-host. Requires outbound TCP/25 — many ISPs
// block that, so test from a server with port 25 open.
//
//   dart run examples/client_send_direct_mx.dart

import 'package:dart_email_server/dart_email_server.dart';

Future<void> main() async {
  // Inspect the MX records first (handy for debugging).
  final mx = await resolveMX('example.org');
  print('MX records for example.org:');
  for (final r in mx) {
    print('  priority=${r.priority}  exchange=${r.exchange}');
  }

  final result = await sendMail(
    SendMailOptions(
      from: AddressObj(name: 'Alice', address: 'alice@example.com'),
      to: [AddressObj(name: '', address: 'bob@example.org')],
      subject: 'Direct-MX test',
      text: 'This message was delivered straight to the recipient MX.\r\n',

      // No `relay:` => direct-MX path
      localHostname: 'mail.example.com',
      timeout: 30000,
    ),
  );

  print('\nmessageId : ${result.messageId}');
  print('accepted  :');
  for (final r in result.accepted) {
    print('  host=${r.host} accepted=${r.accepted}');
  }
  print('rejected  :');
  for (final r in result.rejected) {
    print('  domain=${r.domain} error=${r.error}');
  }
}
