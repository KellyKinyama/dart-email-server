import 'package:dart_email_server/index.dart';

void main() async {
  // Generate DKIM keys + every DNS record you need
  final mat = buildDomainMailMaterial(
    'example.com',
    const BuildDomainOptions(
      // Optional: opt in to MTA-STS enforcement
      mtaSts: MtaStsOptions(mode: MtaStsMode.enforce, mx: ['mx.example.com']),
      tlsRpt: TlsRptOptions(ruaEmail: 'tls-reports@example.com'),
    ),
  );

  print('DNS Records:');
  for (final record in mat.requiredDNS) {
    print('  ${record.type} ${record.name} → ${record.value}');
  }

  // Create server instance
  final server = createServer(
    const ServerOptions(
      hostname: 'mx.example.com',
      ports: ServerPorts(inbound: 25),
    ),
  );

  server.addDomain(mat);

  // Handle incoming SMTP sessions
  server.on('smtpSession', (session) {
    // Cast appropriately if needed, or use dynamic
    session.on('mail', (mail) {
      // Envelope + auth results available immediately
      print('New mail: ${mail.from} → ${mail.to}');
      print(
        '  Auth Status: DKIM: ${mail.auth.dkim}, SPF: ${mail.auth.spf}, DMARC: ${mail.auth.dmarc}',
      );

      // Reject based on DMARC policy
      if (mail.auth.dmarc == 'fail' && mail.auth.dmarcPolicy == 'reject') {
        mail.reject(550, 'DMARC policy rejection');
        return;
      }

      // Stream body data (Uint8List)
      mail.on('data', (chunk) {
        // chunk is Uint8List
      });

      // Handle message completion
      mail.on('end', () {
        print('Message received:');
        print('  Subject: ${mail.subject}');
        print('  Attachments: ${mail.attachments.length}');

        // Storage logic would go here
        // saveMessage(mail.to, mail.raw);

        mail.accept(); // → Send 250 OK
      });
    });
  });

  // Start the server
  await server.listen();
  print('\nSMTP MX server listening on port 25...');
}
