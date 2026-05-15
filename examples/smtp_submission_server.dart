// Submission server (port 2587) that authenticates with hard-coded
// credentials and prints every submitted message. Suitable as a starting
// point for an outbound MTA frontend.
//
//   dart run examples/smtp_submission_server.dart
//
// Test:
//   swaks --to bob@example.org --from alice@example.com \
//         --server 127.0.0.1:2587 \
//         --auth-user alice@example.com --auth-password secret \
//         --body "hello"

import 'package:dart_email_server/dart_email_server.dart';

const _users = <String, String>{
  'alice@example.com': 'secret',
  'bob@example.com': 'hunter2',
};

Future<void> main() async {
  final server = Server(
    const ServerOptions(
      hostname: 'submission.example.com',
      ports: ServerPorts(submission: 2587),
    ),
  );

  // 'auth' is fired on every AUTH attempt — call .accept() or .reject().
  server.on('auth', (AuthInfo a) {
    final ok = a.username != null && _users[a.username!] == a.password;
    if (ok) {
      print('[auth] OK   ${a.username} from ${a.remoteAddress}');
      a.accept();
    } else {
      print('[auth] FAIL ${a.username} from ${a.remoteAddress}');
      a.reject('Invalid credentials');
    }
  });

  server.on('smtpSession', (sessionFacade, SmtpFacadeState st) {
    sessionFacade.on('mail', (MailObject mail) {
      print('--- submission from ${st.username} ---');
      print('  envelope from : ${mail.from}');
      print('  envelope to   : ${mail.to}');
      print('  subject       : ${mail.subject}');
      print('  ${mail.size} bytes');
      mail.accept();
    });
  });

  await server.listen();
  print('SMTP submission server listening on 2587. Ctrl-C to stop.');
}
