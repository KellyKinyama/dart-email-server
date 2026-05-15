import 'dart:typed_data';

import 'package:dart_email_server/src/utils.dart';
import 'package:test/test.dart';

void main() {
  group('isAscii', () {
    test('returns true for plain ASCII', () {
      expect(isAscii('hello@example.com'), isTrue);
      expect(isAscii(''), isTrue);
    });

    test('returns false when any char > 0x7F', () {
      expect(isAscii('héllo'), isFalse);
      expect(isAscii('日本語'), isFalse);
    });
  });

  group('splitAddress', () {
    test('splits a simple address', () {
      final p = splitAddress('alice@example.com');
      expect(p, isNotNull);
      expect(p!.local, 'alice');
      expect(p.domain, 'example.com');
    });

    test('handles quoted local-part with embedded @', () {
      final p = splitAddress('"weird@local"@example.com');
      expect(p, isNotNull);
      expect(p!.local, '"weird@local"');
      expect(p.domain, 'example.com');
    });

    test('splits at last unquoted @', () {
      final p = splitAddress('a@b@c');
      expect(p, isNotNull);
      expect(p!.local, 'a@b');
      expect(p.domain, 'c');
    });

    test('returns null for missing @', () {
      expect(splitAddress('no-at-here'), isNull);
    });

    test('returns null for null/empty', () {
      expect(splitAddress(null), isNull);
      expect(splitAddress(''), isNull);
    });
  });

  group('addressNeedsSmtputf8', () {
    test('false for ASCII addresses', () {
      expect(addressNeedsSmtputf8('user@example.com'), isFalse);
    });

    test('true when local-part has non-ASCII', () {
      expect(addressNeedsSmtputf8('üser@example.com'), isTrue);
    });

    test('false when only domain has non-ASCII', () {
      // domain IDN is handled separately; local-part is ASCII here
      expect(addressNeedsSmtputf8('user@münchen.de'), isFalse);
    });
  });

  group('addressForAsciiOnlyPeer', () {
    test('passes through ASCII addresses', () {
      expect(addressForAsciiOnlyPeer('a@b.com'), 'a@b.com');
    });

    test('punycode-encodes the domain when local-part is ASCII', () {
      final v = addressForAsciiOnlyPeer('user@münchen.de');
      expect(v, isNotNull);
      expect(v, startsWith('user@'));
      expect(isAscii(v!), isTrue);
    });

    test('returns null when local-part has non-ASCII', () {
      expect(addressForAsciiOnlyPeer('üser@example.com'), isNull);
    });
  });

  group('domainToAscii', () {
    test('ASCII passthrough', () {
      expect(domainToAscii('example.com'), 'example.com');
    });

    test('IDN domains are encoded to ASCII', () {
      final v = domainToAscii('münchen.de');
      expect(isAscii(v), isTrue);
      expect(v, isNot(equals('münchen.de')));
    });

    test('null/empty', () {
      expect(domainToAscii(null), '');
      expect(domainToAscii(''), '');
    });
  });

  group('parseTags', () {
    test('parses semicolon-separated tags', () {
      final t = parseTags('v=DKIM1; k=rsa; p=ABC');
      expect(t['v'], 'DKIM1');
      expect(t['k'], 'rsa');
      expect(t['p'], 'ABC');
    });

    test('lowercases keys when requested', () {
      final t = parseTags('V=DKIM1; K=rsa', true);
      expect(t['v'], 'DKIM1');
      expect(t['k'], 'rsa');
    });
  });

  group('extractAddress', () {
    test('plain string with @', () {
      expect(extractAddress('alice@example.com'), 'alice@example.com');
    });

    test('extracts <addr> from display form', () {
      expect(extractAddress('Alice <alice@example.com>'), 'alice@example.com');
    });

    test('returns null for non-address strings', () {
      expect(extractAddress(null), isNull);
      expect(extractAddress('not an address'), isNull);
    });
  });

  group('indexOfCRLF', () {
    test('finds CRLF', () {
      final buf = Uint8List.fromList('hello\r\nworld'.codeUnits);
      expect(indexOfCRLF(buf), 5);
    });

    test('returns -1 when absent', () {
      final buf = Uint8List.fromList('no-newlines'.codeUnits);
      expect(indexOfCRLF(buf), -1);
    });
  });

  group('u8Equal', () {
    test('equal buffers', () {
      expect(
        u8Equal(Uint8List.fromList([1, 2, 3]), Uint8List.fromList([1, 2, 3])),
        isTrue,
      );
    });

    test('different lengths', () {
      expect(
        u8Equal(Uint8List.fromList([1, 2]), Uint8List.fromList([1, 2, 3])),
        isFalse,
      );
    });

    test('null pair handling', () {
      expect(u8Equal(null, null), isTrue);
      expect(u8Equal(Uint8List(0), null), isFalse);
    });
  });
}
