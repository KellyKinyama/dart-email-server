import 'dart:convert';

import 'package:dart_email_server/src/message.dart';
import 'package:test/test.dart';

void main() {
  group('header encoders', () {
    test('encodeHeaderValue passes ASCII through unchanged', () {
      expect(encodeHeaderValue('Hello there'), 'Hello there');
    });

    test('encodeHeaderValue applies RFC 2047 to non-ASCII', () {
      final v = encodeHeaderValue('héllo');
      expect(v, contains('=?UTF-8?'));
      expect(v.endsWith('?='), isTrue);
    });

    test('decodeEncodedWords reverses Q-encoded value', () {
      final src = '=?UTF-8?Q?h=C3=A9llo?=';
      expect(decodeEncodedWords(src), 'héllo');
    });

    test('decodeEncodedWords handles B-encoded value', () {
      final b64 = base64.encode(utf8.encode('héllo'));
      final src = '=?UTF-8?B?$b64?=';
      expect(decodeEncodedWords(src), 'héllo');
    });
  });

  group('foldHeader', () {
    test('short headers are not folded', () {
      final h = foldHeader('Subject', 'Hi');
      expect(h, 'Subject: Hi');
    });

    test('long headers wrap with CRLF + WSP', () {
      final long = 'A' * 200;
      final h = foldHeader('X-Long', long);
      // every continuation line must begin with whitespace
      final lines = h.split('\r\n').where((l) => l.isNotEmpty).toList();
      expect(lines.length, greaterThan(1));
      for (var i = 1; i < lines.length; i++) {
        expect(lines[i].startsWith(' ') || lines[i].startsWith('\t'), isTrue);
      }
    });
  });

  group('mime helpers', () {
    test('detectMimeType uses extension', () {
      expect(detectMimeType('photo.jpg'), 'image/jpeg');
      expect(detectMimeType('doc.pdf'), 'application/pdf');
      expect(detectMimeType('readme.txt'), 'text/plain');
      expect(detectMimeType(null), 'application/octet-stream');
    });

    test('boundary returns a safe RFC 2046 token', () {
      final b = boundary();
      expect(b, isNotEmpty);
      expect(b, matches(RegExp(r'^[A-Za-z0-9_=+\-]+$')));
    });

    test('genMessageId uses provided domain hint', () {
      final id = genMessageId('example.com');
      expect(id, startsWith('<'));
      expect(id, endsWith('@example.com>'));
    });

    test('nowRfc2822Date returns an RFC-2822 date', () {
      final d = nowRfc2822Date();
      expect(
        d,
        matches(
          RegExp(
            r'^[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} [+-]\d{4}$',
          ),
        ),
      );
    });
  });

  group('composeMessageTyped', () {
    test('builds a minimal text/plain message with required headers', () {
      final res = composeMessageTyped(
        ComposeMessageOptions(
          from: 'alice@example.com',
          to: 'bob@example.org',
          subject: 'Hello',
          text: 'Hello world\r\n',
        ),
      );

      expect(res.messageId, startsWith('<'));
      final msg = String.fromCharCodes(res.raw);
      expect(msg, contains('From: <alice@example.com>'));
      expect(msg, contains('To: <bob@example.org>'));
      expect(msg, contains('Subject: Hello'));
      expect(msg, contains('MIME-Version: 1.0'));
      expect(msg, contains('Message-ID: '));
      expect(msg, contains('Hello world'));
    });

    test('Q-encodes non-ASCII Subject', () {
      final res = composeMessageTyped(
        ComposeMessageOptions(
          from: 'alice@example.com',
          to: 'bob@example.org',
          subject: 'Héllo',
          text: 'body',
        ),
      );
      final msg = String.fromCharCodes(res.raw);
      expect(msg, contains('Subject: =?UTF-8?'));
    });

    test('multipart/alternative when both text and html supplied', () {
      final res = composeMessageTyped(
        ComposeMessageOptions(
          from: 'a@x.test',
          to: 'b@x.test',
          subject: 's',
          text: 't',
          html: '<p>h</p>',
        ),
      );
      final msg = String.fromCharCodes(res.raw);
      expect(msg, contains('multipart/alternative'));
      expect(msg, contains('text/plain'));
      expect(msg, contains('text/html'));
    });
  });
}
