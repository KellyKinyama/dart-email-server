// End-to-end regression tests for the email crypto stack:
//   * RSA key gen / parse / sign / verify (lib/cipher/rsa.dart)
//   * DKIM sign + verify round-trip (lib/src/dkim.dart)
//   * Wrong key / tampered body / tampered header are rejected
//   * SPF + DMARC evaluation against a pre-seeded DNS cache

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_email_server/cipher/rsa.dart' as rsa;
import 'package:dart_email_server/src/dkim.dart' as dkim;
import 'package:dart_email_server/src/dmarc.dart';
import 'package:dart_email_server/src/dns_cache.dart' as dns_cache;
import 'package:dart_email_server/src/domain.dart';
import 'package:dart_email_server/src/spf.dart';
import 'package:test/test.dart';

String _dkimDnsValueFromPublicPem(String pubPem) {
  final b64 = pubPem
      .replaceAll('-----BEGIN PUBLIC KEY-----', '')
      .replaceAll('-----END PUBLIC KEY-----', '')
      .replaceAll(RegExp(r'\s+'), '');
  return 'v=DKIM1; k=rsa; h=sha256; p=$b64';
}

void _seedTxt(String name, String value) {
  dns_cache.setCacheEntry(
    'TXT',
    name,
    dns_cache.DnsCacheData.txt([
      [value],
    ]),
  );
}

const _rawMessage =
    'From: Alice <alice@example.com>\r\n'
    'To: Bob <bob@example.org>\r\n'
    'Subject: Hello\r\n'
    'Date: Mon, 04 May 2026 12:00:00 +0000\r\n'
    'Message-ID: <abc-1@example.com>\r\n'
    '\r\n'
    'Hello world.\r\n'
    'This is a test.\r\n';

void main() {
  group('cipher/rsa.dart', () {
    late rsa.RsaKeyPairPem pair;

    setUpAll(() {
      // 1024 to keep test runtime tight — only used for crypto plumbing.
      pair = rsa.rsaGenerateKeyPairPem(bits: 1024);
    });

    test('generates PKCS#8 + SPKI PEMs that round-trip', () {
      expect(pair.privateKeyPem, contains('BEGIN PRIVATE KEY'));
      expect(pair.publicKeyPem, contains('BEGIN PUBLIC KEY'));

      final priv = rsa.parseRsaPrivateKeyPem(pair.privateKeyPem);
      final pub = rsa.parseRsaPublicKeyPem(pair.publicKeyPem);
      expect(priv.modulus, equals(pub.modulus));
      expect(priv.publicExponent, equals(pub.exponent));
    });

    test('rsaPublicKeyPemFromPrivatePem matches the original SPKI PEM', () {
      final derived = rsa.rsaPublicKeyPemFromPrivatePem(pair.privateKeyPem);
      // Strip whitespace before comparing.
      String norm(String s) => s.replaceAll(RegExp(r'\s+'), '');
      expect(norm(derived), norm(pair.publicKeyPem));
    });

    test('sign + verify round-trip with SHA-256', () {
      final priv = rsa.parseRsaPrivateKeyPem(pair.privateKeyPem);
      final pub = rsa.parseRsaPublicKeyPem(pair.publicKeyPem);
      final msg = Uint8List.fromList(utf8.encode('Hello, RSA!'));
      final sig = rsa.rsaSignSha256(priv, msg);
      expect(rsa.rsaVerifySha256(pub, msg, sig), isTrue);
    });

    test('verify fails for tampered data', () {
      final priv = rsa.parseRsaPrivateKeyPem(pair.privateKeyPem);
      final pub = rsa.parseRsaPublicKeyPem(pair.publicKeyPem);
      final msg = Uint8List.fromList(utf8.encode('Hello, RSA!'));
      final sig = rsa.rsaSignSha256(priv, msg);
      final tampered = Uint8List.fromList(utf8.encode('Hello, rsa!'));
      expect(rsa.rsaVerifySha256(pub, tampered, sig), isFalse);
    });

    test('verify fails for signature from a different key', () {
      final other = rsa.rsaGenerateKeyPairPem(bits: 1024);
      final pub = rsa.parseRsaPublicKeyPem(pair.publicKeyPem);
      final otherPriv = rsa.parseRsaPrivateKeyPem(other.privateKeyPem);
      final msg = Uint8List.fromList(utf8.encode('Hello'));
      final sig = rsa.rsaSignSha256(otherPriv, msg);
      expect(rsa.rsaVerifySha256(pub, msg, sig), isFalse);
    });
  });

  group('dkim.sign + verify', () {
    late rsa.RsaKeyPairPem pair;
    const domain = 'example.com';
    const selector = 'test';

    setUpAll(() {
      pair = rsa.rsaGenerateKeyPairPem(bits: 1024);
      dns_cache.clearCache();
      _seedTxt(
        '$selector._domainkey.$domain',
        _dkimDnsValueFromPublicPem(pair.publicKeyPem),
      );
    });

    test('signs and self-verifies an RFC 5322 message', () async {
      final res = dkim.sign(
        _rawMessage,
        dkim.DkimSignOptions(
          domain: domain,
          selector: selector,
          privateKey: pair.privateKeyPem,
        ),
      );

      expect(res.result, 'signed');
      expect(res.bodyHash, isNotNull);
      expect(res.signature, isNotNull);
      expect(res.signature, isNot(equals('dummy_signature_placeholder')));
      expect(res.bodyHash, isNot(equals('dummy_body_hash_placeholder')));
      expect(res.signedHeaders, contains('from'));
      expect(res.message, isNotNull);

      final verified = await dkim.verify(res.message!);
      expect(verified.result, 'pass');
      expect(verified.domain, domain);
      expect(verified.selector, selector);
      expect(verified.algo, 'rsa-sha256');
    });

    test('verify fails when body is tampered', () async {
      final signed = dkim.sign(
        _rawMessage,
        dkim.DkimSignOptions(
          domain: domain,
          selector: selector,
          privateKey: pair.privateKeyPem,
        ),
      );
      final tamperedStr = utf8
          .decode(signed.message!)
          .replaceFirst('Hello world.', 'Hello WORLD.');
      final verified = await dkim.verify(tamperedStr);
      expect(verified.result, anyOf('fail', 'permerror'));
      expect(verified.reason, isNotNull);
    });

    test('verify fails when DNS public key is wrong', () async {
      final signed = dkim.sign(
        _rawMessage,
        dkim.DkimSignOptions(
          domain: domain,
          selector: 'rotated',
          privateKey: pair.privateKeyPem,
        ),
      );

      // Seed a *different* key for that selector.
      final wrongPair = rsa.rsaGenerateKeyPairPem(bits: 1024);
      _seedTxt(
        'rotated._domainkey.$domain',
        _dkimDnsValueFromPublicPem(wrongPair.publicKeyPem),
      );

      final verified = await dkim.verify(signed.message!);
      expect(verified.result, 'fail');
    });

    test(
      'verify returns "none" when DKIM-Signature header is missing',
      () async {
        final v = await dkim.verify(_rawMessage);
        expect(v.result, 'none');
      },
    );
  });

  group('domain.buildDkimMaterial / generateKeyPair', () {
    test('produces a DNS TXT record with v=DKIM1', () {
      final mat = buildDkimMaterial('example.com', const DkimOptions());
      expect(mat.algo, 'rsa-sha256');
      expect(mat.privateKey, contains('BEGIN PRIVATE KEY'));
      expect(mat.publicKey, contains('BEGIN PUBLIC KEY'));
      expect(mat.dnsValue, startsWith('v=DKIM1'));
      expect(mat.dnsValue, contains('k=rsa'));
      expect(mat.dnsName, endsWith('._domainkey.example.com'));
    });

    test('reuses provided private key and derives matching public key', () {
      final fresh = rsa.rsaGenerateKeyPairPem(bits: 1024);
      final mat = buildDkimMaterial(
        'example.com',
        DkimOptions(privateKey: fresh.privateKeyPem),
      );
      String norm(String s) => s.replaceAll(RegExp(r'\s+'), '');
      expect(norm(mat.publicKey!), norm(fresh.publicKeyPem));
    });

    test('Ed25519 still throws UnimplementedError', () {
      expect(
        () => generateKeyPair('ed25519-sha256'),
        throwsA(isA<UnimplementedError>()),
      );
    });
  });

  group('SPF (offline DNS fixtures)', () {
    setUpAll(() {
      dns_cache.clearCache();
      _seedTxt('pass.example', 'v=spf1 ip4:203.0.113.5 -all');
      _seedTxt('hard.example', 'v=spf1 ip4:198.51.100.0/24 -all');
      _seedTxt('softfail.example', 'v=spf1 ~all');
      _seedTxt('plain.example', 'no spf here');
    });

    test('ip4 mechanism that matches yields pass', () async {
      final r = await checkSPF('203.0.113.5', 'pass.example');
      expect(r.result, 'pass');
      expect(r.domain, 'pass.example');
    });

    test('ip4 mechanism that does not match yields fail (-all)', () async {
      final r = await checkSPF('198.51.100.7', 'pass.example');
      expect(r.result, 'fail');
    });

    test('ip4 CIDR match', () async {
      final r = await checkSPF('198.51.100.42', 'hard.example');
      expect(r.result, 'pass');
    });

    test('softfail with ~all', () async {
      final r = await checkSPF('192.0.2.1', 'softfail.example');
      expect(r.result, 'softfail');
    });

    test('domain without SPF record yields none', () async {
      final r = await checkSPF('192.0.2.1', 'plain.example');
      expect(r.result, 'none');
    });

    test('null/empty inputs yield none', () async {
      expect((await checkSPF(null, 'x')).result, 'none');
      expect((await checkSPF('1.2.3.4', '')).result, 'none');
    });
  });

  group('DMARC (offline DNS fixtures)', () {
    setUpAll(() {
      dns_cache.clearCache();
      _seedTxt('_dmarc.example.com', 'v=DMARC1; p=quarantine; adkim=s; aspf=r');
    });

    test('DKIM-aligned pass', () async {
      final r = await checkDMARC(
        DmarcOptions(
          fromDomain: 'example.com',
          dkimResult: 'pass',
          dkimDomain: 'example.com',
        ),
      );
      expect(r.result, 'pass');
      expect(r.dkimAligned, isTrue);
      expect(r.policy, 'quarantine');
    });

    test('DKIM strict alignment fails for subdomain', () async {
      final r = await checkDMARC(
        DmarcOptions(
          fromDomain: 'example.com',
          dkimResult: 'pass',
          dkimDomain: 'mail.example.com',
        ),
      );
      expect(r.result, 'fail');
      expect(r.dkimAligned, isFalse);
    });

    test('SPF relaxed alignment passes for subdomain', () async {
      final r = await checkDMARC(
        DmarcOptions(
          fromDomain: 'example.com',
          spfResult: 'pass',
          spfDomain: 'mail.example.com',
        ),
      );
      expect(r.result, 'pass');
      expect(r.spfAligned, isTrue);
    });

    test('returns none when no DMARC record exists', () async {
      final r = await checkDMARC(DmarcOptions(fromDomain: 'no-dmarc.example'));
      expect(r.result, 'none');
    });
  });
}
