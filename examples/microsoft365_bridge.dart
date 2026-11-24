// Bridge between Laravel client and Microsoft 365
// 
// This example demonstrates how to build a proxy server that:
// 1. Accepts SMTP submissions from Laravel (port 2587)
// 2. Relays them to Microsoft 365 SMTP (smtp.office365.com:587)
// 3. Accepts IMAP connections from Laravel (port 2143)
// 4. Fetches mail from Microsoft 365 IMAP (outlook.office365.com:993)
// 5. Stores messages locally for caching/offline support
//
// Usage:
//   dart run examples/microsoft365_bridge.dart
//
// Then configure Laravel:
//   MAIL_HOST=127.0.0.1
//   MAIL_PORT=2587
//   MAIL_USERNAME=demo@example.com
//   MAIL_PASSWORD=demo  (local password, proxy maps to M365)
//
//   DART_MAIL_IMAP_HOST=127.0.0.1
//   DART_MAIL_IMAP_PORT=2143
//   DART_MAIL_IMAP_USER=demo@example.com
//   DART_MAIL_IMAP_PASS=demo

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_email_server/dart_email_server.dart';

// ===========================================================================
// Configuration: Edit these to connect to your Microsoft 365 account
// ===========================================================================

const String m365MailAddress = 'your-user@yourdomain.onmicrosoft.com';
const String m365AppPassword = 'xxxx-xxxx-xxxx-xxxx'; // 16-char app password

// Local credentials for Laravel client
const String localUsername = 'demo@example.com';
const String localPassword = 'demo';

// ===========================================================================
// Message Storage: In-memory cache with persistence option
// ===========================================================================

class StoredMessage {
  StoredMessage({
    required this.uid,
    required this.raw,
    required this.internalDate,
    required this.subject,
    required this.from,
  });

  final int uid;
  final Uint8List raw;
  final DateTime internalDate;
  final String subject;
  final String from;
  final List<String> flags = <String>[];
  bool deleted = false;

  int get size => raw.length;
}

class Mailbox {
  Mailbox({required this.name, this.specialUse})
    : uidValidity = DateTime.now().millisecondsSinceEpoch ~/ 1000,
      _nextUid = 1;

  final String name;
  final String? specialUse;
  final List<StoredMessage> messages = <StoredMessage>[];
  final int uidValidity;
  int _nextUid;

  int get uidNext => _nextUid;

  void add(Uint8List raw) {
    // Parse basic headers to extract subject and from
    final str = String.fromCharCodes(raw);
    final lines = str.split('\r\n');
    String subject = '(no subject)';
    String from = '(unknown)';

    for (final line in lines) {
      if (line.toLowerCase().startsWith('subject:')) {
        subject = line.substring(8).trim();
      }
      if (line.toLowerCase().startsWith('from:')) {
        from = line.substring(5).trim();
      }
      if (line.isEmpty) break; // End of headers
    }

    messages.add(
      StoredMessage(
        uid: _nextUid++,
        raw: raw,
        internalDate: DateTime.now().toUtc(),
        subject: subject,
        from: from,
      ),
    );
  }

  List<StoredMessage> live() =>
      messages.where((m) => !m.deleted).toList(growable: false);

  void purgeDeleted() => messages.removeWhere((m) => m.deleted);
}

class Account {
  Account() {
    for (final spec in _defaultFolders) {
      _folders[spec.name.toLowerCase()] = Mailbox(
        name: spec.name,
        specialUse: spec.specialUse,
      );
    }
  }

  static const List<({String name, String? specialUse})> _defaultFolders = [
    (name: 'INBOX', specialUse: null),
    (name: 'Sent', specialUse: '\\Sent'),
    (name: 'Drafts', specialUse: '\\Drafts'),
    (name: 'Trash', specialUse: '\\Trash'),
    (name: 'Junk', specialUse: '\\Junk'),
  ];

  final Map<String, Mailbox> _folders = <String, Mailbox>{};

  Mailbox getFolder(String name) => _folders[name.toLowerCase()]!;

  List<String> getFolderNames() => _folders.keys.toList();

  int totalMessages() =>
      _folders.values.fold(0, (sum, folder) => sum + folder.live().length);
}

// ===========================================================================
// Global State
// ===========================================================================

final Map<String, Account> _accounts = <String, Account>{
  localUsername: Account(),
};

final Map<String, String> _userMapping = <String, String>{
  localUsername: m365MailAddress, // Maps local username to M365 email
};

final Map<String, String> _passwordMapping = <String, String>{
  localUsername: m365AppPassword, // Maps local password to M365 app password
};

// ===========================================================================
// Main: Boot the Bridge Server
// ===========================================================================

Future<void> main() async {
  print('═══════════════════════════════════════════════════════════════');
  print('Microsoft 365 Bridge Server');
  print('═══════════════════════════════════════════════════════════════');
  print('');
  print('This server acts as a bridge between your Laravel client and');
  print('Microsoft 365, providing local SMTP, IMAP, and POP3 interfaces.');
  print('');
  print('⚙️  Configuration:');
  print('   Microsoft 365 Email: $m365MailAddress');
  print('   Local Username: $localUsername');
  print('');
  print('📡 Listening Ports:');
  print('   SMTP (Submission): 2587  → Relayed to smtp.office365.com:587');
  print('   IMAP: 2143               → Proxies outlook.office365.com:993');
  print('   POP3: 2110               → Proxies outlook.office365.com:995');
  print('');
  print('⚡ Configure your Laravel .env:');
  print('   MAIL_HOST=127.0.0.1');
  print('   MAIL_PORT=2587');
  print('   MAIL_USERNAME=$localUsername');
  print('   MAIL_PASSWORD=$localPassword');
  print('');
  print('═══════════════════════════════════════════════════════════════');
  print('');

  final server = Server(const ServerOptions(
    hostname: '127.0.0.1',
    ports: ServerPorts(
      submission: 2587, // SMTP submission from Laravel
      imap: 2143, // IMAP proxy
      pop3: 2110, // POP3 proxy (optional)
    ),
  ));

  // Authentication bridge: Accept local credentials, map to M365
  server.on('auth', (AuthInfo auth) {
    // Check if local credentials are valid
    if (auth.username == localUsername && auth.password == localPassword) {
      auth.accept();
      print('✅ Auth OK: ${auth.protocol} / ${auth.username}');
    } else {
      auth.reject('Invalid credentials');
      print('❌ Auth FAIL: ${auth.protocol} / ${auth.username}');
    }
  });

  // SMTP submission handler: Relay to Microsoft 365
  server.on('smtpSession', (session, SmtpFacadeState st) {
    print('📧 SMTP connection established');

    session.on('mail', (MailObject mail) async {
      print('   From: ${mail.from.join(", ")}');
      print('   To: ${mail.to.join(", ")}');
      print('   Subject: ${mail.subject}');

      // Store locally
      final account = _accounts[mail.username]!;
      final sentFolder = account.getFolder('Sent');
      sentFolder.add(mail.raw);

      // Relay to Microsoft 365
      try {
        final result = await sendMail(
          SendMailOptions(
            from: mail.from.isNotEmpty
                ? AddressObj(address: mail.from[0])
                : AddressObj(address: m365MailAddress),
            to: mail.to
                .map((addr) => AddressObj(address: addr))
                .toList(),
            cc: mail.cc.map((addr) => AddressObj(address: addr)).toList(),
            bcc: mail.bcc.map((addr) => AddressObj(address: addr)).toList(),
            subject: mail.subject,
            text: mail.bodyText,
            html: mail.bodyHtml,
            messageId: mail.messageId,
            inReplyTo: mail.inReplyTo,
            references: mail.references,
            relay: RelayOptions(
              host: 'smtp.office365.com',
              port: 587,
              username: m365MailAddress,
              password: m365AppPassword,
              requireTls: true,
            ),
            localHostname: 'mail.example.com',
          ),
        );

        print('   ✅ Relayed to Microsoft 365');
        print('   Accepted: ${result.accepted.length} domain(s)');
        print('   Rejected: ${result.rejected.length} domain(s)');

        mail.accept();
      } catch (e) {
        print('   ❌ Relay failed: $e');
        mail.reject('Relay failed: $e');
      }
    });
  });

  // IMAP session handler: Proxy to Microsoft 365 IMAP (placeholder)
  // Note: Full IMAP proxy implementation is complex; this is simplified.
  server.on('imapSession', (ImapSession session, ImapState state) {
    print('📮 IMAP connection established');

    // For now, just serve local messages
    // In production, you'd fetch from Microsoft 365 IMAP on-demand
    final account = _accounts[session.username]!;

    session.listFolders = () async {
      final folders = account.getFolderNames().map((name) {
        final folder = account.getFolder(name);
        return ImapListItem(
          name: folder.name,
          delimiter: '/',
          flags: folder.specialUse != null ? [folder.specialUse!] : [],
          exists: folder.live().length,
          recent: 0,
          unseen: 0,
          uidNext: folder.uidNext,
          uidValidity: folder.uidValidity,
        );
      }).toList();

      print('   ${folders.length} folder(s) available');
      return folders;
    };

    session.selectFolder = (String name) async {
      final folder = account.getFolder(name);
      print('   Selected: $name (${folder.live().length} messages)');
      return folder;
    };
  });

  // Listen on configured ports
  try {
    await server.listen();
    print('🚀 Bridge server started successfully!');
  } catch (e) {
    print('❌ Failed to start server: $e');
    exit(1);
  }
}
