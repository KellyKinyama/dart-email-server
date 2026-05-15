import 'package:dart_email_server/src/domain.dart';
import 'package:test/test.dart';

void main() {
  group('MtaStsMode enum', () {
    test('has the three RFC 8461 modes with wire form == name', () {
      expect(MtaStsMode.values, hasLength(3));
      expect(MtaStsMode.enforce.wire, 'enforce');
      expect(MtaStsMode.testing.wire, 'testing');
      expect(MtaStsMode.none.wire, 'none');
    });

    test('default in MtaStsOptions is enforce', () {
      const opts = MtaStsOptions();
      expect(opts.mode, MtaStsMode.enforce);
      expect(opts.mx, isEmpty);
      expect(opts.maxAgeSeconds, 604800);
    });
  });

  group('buildMtaStsMaterial', () {
    test('produces a policy with mode/mx/max_age lines', () {
      final mat = buildMtaStsMaterial(
        'example.com',
        const MtaStsOptions(
          mode: MtaStsMode.testing,
          mx: ['mx1.example.com', 'mx2.example.com'],
          maxAgeSeconds: 86400,
        ),
      );

      expect(mat.mode, MtaStsMode.testing);
      expect(mat.mx, ['mx1.example.com', 'mx2.example.com']);
      expect(mat.maxAge, 86400);
      expect(mat.policy, contains('version: STSv1'));
      expect(mat.policy, contains('mode: testing'));
      expect(mat.policy, contains('mx: mx1.example.com'));
      expect(mat.policy, contains('mx: mx2.example.com'));
      expect(mat.policy, contains('max_age: 86400'));
      expect(
        mat.policyUrl,
        'https://mta-sts.example.com/.well-known/mta-sts.txt',
      );
      expect(mat.policyHost, 'mta-sts.example.com');
    });

    test('defaults to a single mx.<domain> when none supplied', () {
      final mat = buildMtaStsMaterial('example.com', const MtaStsOptions());
      expect(mat.mx, ['mx.example.com']);
      expect(mat.policy, contains('mode: enforce'));
    });
  });
}
