import 'dart:typed_data';

import 'package:dart_email_server/src/dsn.dart';
import 'package:test/test.dart';

void main() {
  group('formatDate', () {
    test('emits an RFC 2822-style date string', () {
      final s = formatDate(DateTime.utc(2026, 5, 4, 12, 30, 0));
      // e.g. "Mon, 04 May 2026 12:30:00 +0000"
      expect(
        s,
        matches(
          RegExp(
            r'^[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} [+-]\d{4}$',
          ),
        ),
      );
    });
  });

  group('buildDsn', () {
    test('produces a multipart/report MIME with delivery-status part', () {
      final raw = buildDsn(
        DsnOptions(
          reportingMta: 'mx.example.com',
          from: 'postmaster@example.com',
          to: 'sender@example.org',
          arrivalDate: DateTime.utc(2026, 5, 4, 12, 0, 0),
          recipients: [
            DsnRecipient(
              finalRecipient: 'rcpt@dest.example',
              action: 'failed',
              status: '5.1.1',
              diagnostic: 'smtp; 550 No such user',
            ),
          ],
        ),
      );

      final txt = String.fromCharCodes(raw);
      expect(txt, contains('From: postmaster@example.com'));
      expect(txt, contains('To: sender@example.org'));
      expect(txt, contains('Subject: Undelivered Mail Returned to Sender'));
      expect(txt, contains('Content-Type: multipart/report'));
      expect(txt, contains('report-type=delivery-status'));
      expect(txt, contains('message/delivery-status'));
      expect(txt, contains('Final-Recipient: rfc822; rcpt@dest.example'));
      expect(txt, contains('Action: failed'));
      expect(txt, contains('Status: 5.1.1'));
    });

    test('uses delayed subject when any recipient is delayed', () {
      final raw = buildDsn(
        DsnOptions(
          reportingMta: 'mx.example.com',
          to: 'sender@example.org',
          recipients: [
            DsnRecipient(finalRecipient: 'a@b.example', action: 'delayed'),
          ],
        ),
      );
      expect(
        String.fromCharCodes(raw),
        contains('Delivery Status Notification (Delay)'),
      );
    });

    test('embeds original message headers when provided', () {
      final original = Uint8List.fromList(
        ('Subject: Hi\r\nFrom: sender@example.org\r\n\r\nBody').codeUnits,
      );
      final raw = buildDsn(
        DsnOptions(
          reportingMta: 'mx.example.com',
          to: 'sender@example.org',
          originalMessage: original,
          returnContent: 'headers',
          recipients: [
            DsnRecipient(finalRecipient: 'rcpt@dest.example', action: 'failed'),
          ],
        ),
      );
      final txt = String.fromCharCodes(raw);
      expect(txt, contains('Subject: Hi'));
      expect(txt, contains('From: sender@example.org'));
      // body should NOT be included with returnContent=headers
      expect(txt, isNot(contains('\r\nBody')));
    });
  });
}
