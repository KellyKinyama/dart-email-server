import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_email_server/cipher/cipher.dart';
import 'package:test/test.dart';

void main() {
  group('hash + hmac', () {
    test('sha-256 of empty string', () {
      final h = createHash(Uint8List(0));
      // Known: SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
      expect(
        h.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('hmac-sha256 RFC 4231 test case 1', () {
      // key = 0x0b * 20, data = "Hi There"
      final key = Uint8List.fromList(List.filled(20, 0x0b));
      final data = Uint8List.fromList(utf8.encode('Hi There'));
      final mac = hmacSha256(key: key, data: data);
      expect(
        mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
      );
    });
  });

  group('hkdf (RFC 5869 test case 1)', () {
    final ikm = Uint8List.fromList(List.filled(22, 0x0b));
    final salt = Uint8List.fromList(List<int>.generate(13, (i) => i));
    final info = Uint8List.fromList(List<int>.generate(10, (i) => 0xf0 + i));

    test('extract', () {
      final prk = hkdfExtract(ikm, salt: salt);
      expect(
        prk.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5',
      );
    });

    test('expand', () {
      final prk = hkdfExtract(ikm, salt: salt);
      final okm = hkdfExpand(prk: prk, info: info, outputLength: 42);
      expect(
        okm.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '3cb25f25faacd57a90434f64d0362f2a'
        '2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
        '34007208d5b887185865',
      );
    });

    test('expandLabel produces requested length', () {
      final prk = hkdfExtract(ikm, salt: salt);
      final out = hkdfExpandLabel(
        secret: prk,
        context: Uint8List(0),
        label: 'derived',
        length: 32,
      );
      expect(out.length, 32);
    });
  });

  group('aes-gcm round trip', () {
    test('encrypt -> decrypt yields original plaintext', () {
      final key = aesGenerateKey(bytes: 16);
      final nonce = aesGcmGenerateNonce();
      final aad = Uint8List.fromList(utf8.encode('header'));
      final pt = Uint8List.fromList(
        utf8.encode('the quick brown fox jumps over the lazy dog'),
      );

      final ct = encrypt(
        encryptionKey: key,
        message: pt,
        nonce: nonce,
        aead: aad,
      );
      expect(ct.length, pt.length + 16);

      final back = decrypt(
        encryptionKey: key,
        ciphertextWithAuthTag: ct,
        nonce: nonce,
        aead: aad,
      );
      expect(back, equals(pt));
    });

    test('tamper with ciphertext -> auth tag fails', () {
      final key = aesGenerateKey(bytes: 16);
      final nonce = aesGcmGenerateNonce();
      final pt = Uint8List.fromList(utf8.encode('secret'));
      final aad = Uint8List(0);

      final ct = encrypt(
        encryptionKey: key,
        message: pt,
        nonce: nonce,
        aead: aad,
      );
      ct[0] ^= 0x01;

      expect(
        () => decrypt(
          encryptionKey: key,
          ciphertextWithAuthTag: ct,
          nonce: nonce,
          aead: aad,
        ),
        throwsA(anything),
      );
    });
  });

  group('x25519 ECDH', () {
    test('alice/bob derive identical shared secret', () {
      final alice = x25519GenerateKeyPair();
      final bob = x25519GenerateKeyPair();

      final sa = x25519ShareSecret(
        privateKey: alice.privateKey,
        publicKey: bob.publicKey,
      );
      final sb = x25519ShareSecret(
        privateKey: bob.privateKey,
        publicKey: alice.publicKey,
      );

      expect(alice.privateKey.length, 32);
      expect(alice.publicKey.length, 32);
      expect(sa.length, 32);
      expect(sa, equals(sb));
    });
  });

  group('p256 ECDH', () {
    test('alice/bob derive identical shared secret', () {
      final alice = p256GenerateKeyPair();
      final bob = p256GenerateKeyPair();

      final sa = generateP256SharedSecret(bob.publicKey, alice.privateKey);
      final sb = generateP256SharedSecret(alice.publicKey, bob.privateKey);

      expect(alice.privateKey.length, 32);
      expect(alice.publicKey.length, 65);
      expect(alice.publicKey[0], 0x04);
      expect(sa, equals(sb));
    });
  });

  group('ecdsa P-256', () {
    test('sign/verify round trip with generated key', () {
      final kp = ecdsaGenerateKeyPair();
      final msg = Uint8List.fromList(utf8.encode('hello world'));
      final h = createHash(msg);

      final sig = ecdsaSign(kp.privateKey, h);
      expect(ecdsaVerify(kp.publicKey, h, sig), isTrue);

      // Tampered hash should fail.
      final bad = Uint8List.fromList(h);
      bad[0] ^= 0x01;
      expect(ecdsaVerify(kp.publicKey, bad, sig), isFalse);
    });
  });

  group('certificates', () {
    test('pinned cert loads and signs a verifiable signature', () {
      final cert = loadPinnedServerCertificate();

      expect(cert.privateKey.length, 32);
      expect(cert.publickKey.length, 65);
      expect(cert.publickKey[0], 0x04);
      expect(cert.fingerPrint.length, 32);

      final pubFromCert = extractEcdsaPublicKeyFromCertificateDer(cert.cert);
      expect(pubFromCert, equals(cert.publickKey));

      final h = createHash(Uint8List.fromList(utf8.encode('payload')));
      final sig = ecdsaSign(cert.privateKey, h);
      expect(ecdsaVerify(cert.publickKey, h, sig), isTrue);
    });

    test('fingerprint is colon-separated uppercase hex of correct length', () {
      final fp = fingerprint(Uint8List.fromList(List<int>.filled(32, 0xab)));
      // 32 bytes -> 32 pairs of hex separated by 31 colons = 95 chars.
      expect(fp.length, 95);
      expect(fp.split(':').length, 32);
      expect(fp, fp.toUpperCase());
    });
  });
}
