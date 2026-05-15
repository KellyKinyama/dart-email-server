import 'dart:typed_data';

import 'package:dart_email_server/src/imap_wire.dart';
import 'package:test/test.dart';

Uint8List _u8(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('enums', () {
    test('ImapStatus values cover RFC 9051 statuses', () {
      expect(ImapStatus.values.map((e) => e.name).toList(), [
        'OK',
        'NO',
        'BAD',
        'PREAUTH',
        'BYE',
      ]);
    });

    test('legacy STATUS_* aliases point at the enum', () {
      expect(STATUS_OK, ImapStatus.OK);
      expect(STATUS_NO, ImapStatus.NO);
      expect(STATUS_BAD, ImapStatus.BAD);
      expect(STATUS_PREAUTH, ImapStatus.PREAUTH);
      expect(STATUS_BYE, ImapStatus.BYE);
    });

    test('ResponseKind / ParseStatus enums populated', () {
      expect(ResponseKind.values, hasLength(3));
      expect(ParseStatus.values, hasLength(4));
      expect(RESP_TAGGED, ResponseKind.tagged);
      expect(PARSE_OK, ParseStatus.ok);
    });
  });

  group('builders', () {
    test('buildTagged accepts ImapStatus and serializes wire form', () {
      expect(
        buildTagged('A001', ImapStatus.OK, 'NOOP completed'),
        'A001 OK NOOP completed\r\n',
      );
    });

    test('buildTagged accepts a literal String for back-compat', () {
      expect(buildTagged('A002', 'NO', 'denied'), 'A002 NO denied\r\n');
    });

    test('buildTagged inserts a response code', () {
      expect(
        buildTagged('T1', ImapStatus.OK, 'done', 'READ-ONLY'),
        'T1 OK [READ-ONLY] done\r\n',
      );
    });

    test('buildUntagged / buildContinuation', () {
      expect(
        buildUntagged('CAPABILITY IMAP4rev2'),
        '* CAPABILITY IMAP4rev2\r\n',
      );
      expect(buildContinuation('Ready'), '+ Ready\r\n');
    });

    test('buildExists / buildRecent / buildExpunge', () {
      expect(buildExists(42), '* 42 EXISTS\r\n');
      expect(buildRecent(2), '* 2 RECENT\r\n');
      expect(buildExpunge(7), '* 7 EXPUNGE\r\n');
    });
  });

  group('parseResponse', () {
    test('parses an OK tagged response into typed ImapResponse', () {
      final r = parseResponse(_u8('A001 OK NOOP completed\r\n'));
      expect(r['status'], PARSE_OK);
      final resp = r['response'] as ImapResponse;
      expect(resp.kind, ResponseKind.tagged);
      expect(resp.tag, 'A001');
      expect(resp.status, ImapStatus.OK);
      expect(resp.text, contains('NOOP completed'));
    });

    test('parses a continuation line', () {
      final r = parseResponse(_u8('+ Ready for literal\r\n'));
      expect(r['status'], PARSE_OK);
      final resp = r['response'] as ImapResponse;
      expect(resp.kind, ResponseKind.continuation);
      expect(resp.text, 'Ready for literal');
    });

    test('parses an untagged BYE', () {
      final r = parseResponse(_u8('* BYE Server going down\r\n'));
      expect(r['status'], PARSE_OK);
      final resp = r['response'] as ImapResponse;
      expect(resp.kind, ResponseKind.untagged);
    });

    test('returns incomplete on a partial buffer', () {
      final r = parseResponse(_u8('A00'));
      expect(r['status'], PARSE_INCOMPLETE);
    });
  });

  group('parseCommand', () {
    test('parses a simple LOGIN command', () {
      final r = parseCommand(_u8('A001 LOGIN user pass\r\n'));
      expect(r['status'], PARSE_OK);
      final cmd = r['command'] as ImapCommand;
      expect(cmd.tag, 'A001');
      expect(cmd.name, 'LOGIN');
      expect(cmd.args.length, greaterThanOrEqualTo(2));
    });

    test('returns incomplete when CRLF missing', () {
      final r = parseCommand(_u8('A001 NOOP'));
      expect(r['status'], PARSE_INCOMPLETE);
    });
  });
}
