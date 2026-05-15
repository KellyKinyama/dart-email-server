import 'dart:typed_data';

import 'package:dart_email_server/src/smtp_wire.dart';
import 'package:test/test.dart';

Uint8List _u8(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('buildReply', () {
    test('builds a single-line reply with CRLF', () {
      expect(buildReply(250, 'OK'), '250 OK\r\n');
    });

    test('appends enhanced status code when provided', () {
      expect(
        buildReply(550, 'Mailbox unavailable', enhanced: '5.1.1'),
        '550 5.1.1 Mailbox unavailable\r\n',
      );
    });

    test('multiline message uses dash continuations', () {
      final out = buildReply(250, ['hello', 'PIPELINING', 'SIZE 10240000']);
      final lines = out.split('\r\n').where((s) => s.isNotEmpty).toList();
      expect(lines, hasLength(3));
      expect(lines[0], '250-hello');
      expect(lines[1], '250-PIPELINING');
      expect(lines[2], '250 SIZE 10240000');
    });
  });

  group('buildEhloReply', () {
    test('emits multiline 250 with hostname banner first', () {
      final out = buildEhloReply('mail.example.com', [
        'PIPELINING',
        '8BITMIME',
      ]);
      final lines = out.split('\r\n').where((s) => s.isNotEmpty).toList();
      expect(lines.first, startsWith('250-'));
      expect(lines.first, contains('mail.example.com'));
      expect(lines.last, '250 8BITMIME');
    });

    test('hostname-only reply uses single-line form', () {
      final out = buildEhloReply('mail.example.com');
      expect(out.endsWith('\r\n'), isTrue);
      expect(out, startsWith('250 '));
    });
  });

  group('parseReplyBlockTyped', () {
    test('parses a single-line 250 OK', () {
      final r = parseReplyBlockTyped(_u8('250 OK\r\n'));
      expect(r.code, 250);
      expect(r.isSuccess, isTrue);
      expect(r.replyLines, ['OK']);
      expect(r.isEhloCaps, isFalse);
    });

    test('parses an EHLO multi-line reply and extracts caps', () {
      final block = _u8(
        '250-mail.example.com Hello there\r\n'
        '250-PIPELINING\r\n'
        '250-SIZE 10240000\r\n'
        '250 8BITMIME\r\n',
      );
      final r = parseReplyBlockTyped(block);
      expect(r.code, 250);
      expect(r.isEhloCaps, isTrue);
      expect(r.capabilities, isNotNull);
      expect(r.capabilities!['size'], 10240000);
      expect(r.capabilities!['pipelining'], isTrue);
      expect(r.capabilities!['eightBitMime'], isTrue);
      expect(r.capabilities!['serverName'], 'mail.example.com');
    });

    test('exposes a 220 banner domain', () {
      final r = parseReplyBlockTyped(
        _u8('220 mail.example.com ESMTP ready\r\n'),
      );
      expect(r.code, 220);
      expect(r.bannerDomain, 'mail.example.com');
    });

    test('exposes 334 auth challenge text', () {
      final r = parseReplyBlockTyped(_u8('334 VXNlcm5hbWU6\r\n'));
      expect(r.code, 334);
      expect(r.authChallenge, 'VXNlcm5hbWU6');
      expect(r.isIntermediate, isTrue);
    });

    test('5xx classified as permFail', () {
      final r = parseReplyBlockTyped(_u8('550 5.1.1 No such user\r\n'));
      expect(r.isPermFail, isTrue);
      expect(r.enhanced, isNotNull);
      expect(r.enhanced!.code, '5.1.1');
    });

    test('4xx classified as tempFail', () {
      final r = parseReplyBlockTyped(_u8('421 4.7.0 Try again later\r\n'));
      expect(r.isTempFail, isTrue);
    });
  });
}
