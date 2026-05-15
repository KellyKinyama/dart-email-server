import 'package:dart_email_server/src/dkim.dart';
import 'package:test/test.dart';

void main() {
  group('canonicalizeHeaderRelaxed', () {
    test('lowercases name and collapses internal whitespace', () {
      final v = canonicalizeHeaderRelaxed('Subject', '  Hello   World  ');
      expect(v, 'subject:Hello World');
    });

    test('strips trailing whitespace before end of value', () {
      final v = canonicalizeHeaderRelaxed('From', 'a@b.com   ');
      expect(v, 'from:a@b.com');
    });
  });

  group('canonicalizeBodyRelaxed', () {
    test('trims trailing empty lines and ends with one CRLF', () {
      final v = canonicalizeBodyRelaxed('Hi\r\n\r\n\r\n');
      expect(v, 'Hi\r\n');
    });

    test('returns "\r\n" for an empty body', () {
      expect(canonicalizeBodyRelaxed(''), '\r\n');
    });

    test('collapses multiple internal spaces in each line', () {
      final v = canonicalizeBodyRelaxed('a    b\r\n');
      expect(v, 'a b\r\n');
    });
  });
}
