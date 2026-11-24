import 'dart:typed_data';
import 'package:dart_email_server/dart_email_server.dart';

const _user = 'demo@example.com';
const _pass = 'demo';

// Mock email messages for the INBOX
final _mockEmails = [
  {
    'uid': 1,
    'from': 'alice@example.com',
    'subject': 'Welcome to Flutter Email Client',
    'date': 'Mon, 24 Nov 2026 18:19:00 +0000',
    'preview': 'This is a test welcome message. Thanks for trying out our new email client!',
    'body': 'This is a test welcome message. Thanks for trying out our new email client!',
  },
  {
    'uid': 2,
    'from': 'bob@example.com',
    'subject': 'Project Update - Q4 Review',
    'date': 'Mon, 24 Nov 2026 16:19:00 +0000',
    'preview': 'Please find the Q4 review attached. The results look great for this quarter.',
    'body': 'Please find the Q4 review attached. The results look great for this quarter.',
  },
  {
    'uid': 3,
    'from': 'charlie@example.com',
    'subject': 'Meeting Scheduled for Tomorrow',
    'date': 'Mon, 24 Nov 2026 13:19:00 +0000',
    'preview': 'The meeting is scheduled for 2 PM at the conference room. Please bring your laptop.',
    'body': 'The meeting is scheduled for 2 PM at the conference room. Please bring your laptop.',
  },
  {
    'uid': 4,
    'from': 'diana@example.com',
    'subject': 'Your Invoice #INV-2024-001',
    'date': 'Sun, 23 Nov 2026 12:00:00 +0000',
    'preview': 'Your invoice for services rendered is attached. Please review and let us know if you have any questions.',
    'body': 'Your invoice for services rendered is attached. Please review and let us know if you have any questions.',
  },
  {
    'uid': 5,
    'from': 'eve@example.com',
    'subject': 'Happy Birthday! 🎉',
    'date': 'Sat, 22 Nov 2026 10:00:00 +0000',
    'preview': 'Hope you have an amazing day! Let\'s grab coffee soon to celebrate.',
    'body': 'Hope you have an amazing day! Let\'s grab coffee soon to celebrate.',
  },
  {
    'uid': 6,
    'from': 'frank@example.com',
    'subject': 'Weekly Team Standup - Agenda',
    'date': 'Fri, 21 Nov 2026 09:00:00 +0000',
    'preview': 'Please review the agenda for this week\'s standup. We\'ll be discussing Q4 goals.',
    'body': 'Please review the agenda for this week\'s standup. We\'ll be discussing Q4 goals.',
  },
  {
    'uid': 7,
    'from': 'grace@example.com',
    'subject': 'Vacation Photos Shared',
    'date': 'Thu, 20 Nov 2026 15:00:00 +0000',
    'preview': 'Check out the photos from our trip to Hawaii! Click here to view the album.',
    'body': 'Check out the photos from our trip to Hawaii! Click here to view the album.',
  },
  {
    'uid': 8,
    'from': 'henry@example.com',
    'subject': 'System Maintenance Notice',
    'date': 'Wed, 19 Nov 2026 11:00:00 +0000',
    'preview': 'We will be performing system maintenance on Saturday from 2-6 AM EST. Please plan accordingly.',
    'body': 'We will be performing system maintenance on Saturday from 2-6 AM EST. Please plan accordingly.',
  },
];

Future<void> main(List<String> arguments) async {
  print('═══════════════════════════════════════════════════════════');
  print('  Dart Email Server (IMAP + SMTP)');
  print('═══════════════════════════════════════════════════════════');
  print('');
  print('Credentials: $_user / $_pass');
  print('');

  final server = Server(
    const ServerOptions(
      hostname: 'localhost',
      ports: ServerPorts(
        imap: 2143,
        submission: 2587,
      ),
    ),
  );

  // Handle authentication for both IMAP and SMTP
  server.on('auth', (AuthInfo a) {
    if (a.username == _user && a.password == _pass) {
      print('[${a.protocol.toUpperCase()}] ✓ Auth OK: ${'$_user'} from ${a.remoteAddress}');
      a.accept();
    } else {
      print('[${a.protocol.toUpperCase()}] ✗ Auth FAIL: ${a.username} from ${a.remoteAddress}');
      a.reject('Invalid credentials');
    }
  });

  // Handle SMTP submission (sending emails)
  server.on('smtpSession', (sessionFacade, SmtpFacadeState st) {
    sessionFacade.on('mail', (MailObject mail) {
      print('[SMTP] 📨 Received email:');
      print('       From: ${mail.from}');
      print('       To: ${mail.to.join(', ')}');
      print('       Subject: ${mail.subject}');
      print('       Size: ${mail.size} bytes');
      mail.accept();
    });
  });

  // Handle IMAP mailbox sessions
  server.on('mailboxSession', (MailboxFacade mb) {
    if (mb.protocol != 'imap') return;
    print('[IMAP] 📭 Session opened for ${mb.username}');

    mb.on('folders', (Function cb) {
      cb(null, [
        {'name': 'INBOX', 'subscribed': true, 'specialUse': null},
        {'name': 'Sent', 'subscribed': true, 'specialUse': '\\Sent'},
        {'name': 'Drafts', 'subscribed': true, 'specialUse': '\\Drafts'},
        {'name': 'Trash', 'subscribed': true, 'specialUse': '\\Trash'},
        {'name': 'Starred', 'subscribed': false, 'specialUse': null},
      ]);
    });

    mb.on('select', (String name, Function cb) {
      if (name == 'INBOX') {
        cb(null, {
          'exists': _mockEmails.length,
          'recent': 0,
          'uidvalidity': 1,
          'uidnext': _mockEmails.length + 1,
          'flags': ['\\Seen', '\\Flagged', '\\Answered', '\\Deleted', '\\Draft'],
          'permanentFlags': ['\\Seen', '\\Flagged', '\\Answered', '\\Deleted', '\\Draft', '\\*'],
        });
      } else {
        cb(null, {
          'exists': 0,
          'recent': 0,
          'uidvalidity': 1,
          'uidnext': 1,
          'flags': ['\\Seen'],
          'permanentFlags': ['\\Seen'],
        });
      }
    });

    mb.on('fetch', (Map<String, dynamic> req, Function cb) {
      final results = <Map<String, dynamic>>[];
      
      for (final email in _mockEmails) {
        final raw = Uint8List.fromList(
          'From: ${email['from']}\r\n'
          'To: $_user\r\n'
          'Subject: ${email['subject']}\r\n'
          'Date: ${email['date']}\r\n'
          'Message-ID: <${email['uid']}@example.com>\r\n'
          '\r\n'
          '${email['body']}\r\n'
          .codeUnits,
        );

        results.add({
          'seq': email['uid'],
          'uid': email['uid'],
          'flags': <String>[],
          'internalDate': DateTime.now(),
          'size': raw.length,
          'raw': raw,
        });
      }

      cb(null, results);
    });

    mb.on('search', (Map<String, dynamic> req, Function cb) {
      // Return all UIDs
      cb(null, List.generate(_mockEmails.length, (i) => i + 1));
    });
  });

  await server.listen();
  print('');
  print('✓ IMAP Server listening on 127.0.0.1:2143');
  print('✓ SMTP Server listening on 127.0.0.1:2587');
  print('');
  print('Press Ctrl+C to stop the server.');
}
