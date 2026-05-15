import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart' as asn1;
import 'package:pointycastle/export.dart' as pc;

// ============================================================
//  PEM <-> DER helpers
// ============================================================

String wrapPem(String label, Uint8List der) {
  final b64 = base64.encode(der);
  final buf = StringBuffer('-----BEGIN $label-----\n');
  for (var i = 0; i < b64.length; i += 64) {
    buf.writeln(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
  }
  buf.write('-----END $label-----');
  return buf.toString();
}

Uint8List stripPemToDer(String pem) {
  final b64 = pem
      .replaceAll(RegExp(r'-----BEGIN [^-]+-----'), '')
      .replaceAll(RegExp(r'-----END [^-]+-----'), '')
      .replaceAll(RegExp(r'\s+'), '');
  return base64.decode(b64);
}

// ============================================================
//  RSA key generation / encoding (PKCS#8 + SPKI)
// ============================================================

class RsaKeyPairPem {
  final String privateKeyPem; // PKCS#8
  final String publicKeyPem; // SPKI (X.509 SubjectPublicKeyInfo)
  const RsaKeyPairPem(this.privateKeyPem, this.publicKeyPem);
}

RsaKeyPairPem rsaGenerateKeyPairPem({int bits = 2048}) {
  final secureRandom = pc.SecureRandom('Fortuna')
    ..seed(
      pc.KeyParameter(
        Uint8List.fromList(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)),
        ),
      ),
    );

  final keyGen = pc.RSAKeyGenerator()
    ..init(
      pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
        secureRandom,
      ),
    );

  final pair = keyGen.generateKeyPair();
  final priv = pair.privateKey as pc.RSAPrivateKey;
  final pub = pair.publicKey as pc.RSAPublicKey;

  return RsaKeyPairPem(
    encodeRsaPrivateKeyPem(priv),
    encodeRsaPublicKeyPem(pub),
  );
}

String rsaPublicKeyPemFromPrivatePem(String privatePem) {
  final priv = parseRsaPrivateKeyPem(privatePem);
  final pub = pc.RSAPublicKey(priv.modulus!, priv.publicExponent!);
  return encodeRsaPublicKeyPem(pub);
}

// SubjectPublicKeyInfo for rsaEncryption (1.2.840.113549.1.1.1)
String encodeRsaPublicKeyPem(pc.RSAPublicKey pub) {
  final der = encodeRsaPublicKeyDer(pub);
  return wrapPem('PUBLIC KEY', der);
}

Uint8List encodeRsaPublicKeyDer(pc.RSAPublicKey pub) {
  final rsaPubKey = asn1.ASN1Sequence()
    ..add(asn1.ASN1Integer(pub.modulus!))
    ..add(asn1.ASN1Integer(pub.exponent!));

  final algId = asn1.ASN1Sequence()
    ..add(
      asn1.ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'),
    )
    ..add(asn1.ASN1Null());

  final bitString = asn1.ASN1BitString(stringValues: rsaPubKey.encode());

  final spki = asn1.ASN1Sequence()
    ..add(algId)
    ..add(bitString);

  return spki.encode();
}

String encodeRsaPrivateKeyPem(pc.RSAPrivateKey priv) {
  final n = priv.modulus!;
  final e = priv.publicExponent!;
  final d = priv.privateExponent!;
  final p = priv.p!;
  final q = priv.q!;
  final dP = d % (p - BigInt.one);
  final dQ = d % (q - BigInt.one);
  final qInv = q.modInverse(p);

  final rsaPriv = asn1.ASN1Sequence()
    ..add(asn1.ASN1Integer(BigInt.zero))
    ..add(asn1.ASN1Integer(n))
    ..add(asn1.ASN1Integer(e))
    ..add(asn1.ASN1Integer(d))
    ..add(asn1.ASN1Integer(p))
    ..add(asn1.ASN1Integer(q))
    ..add(asn1.ASN1Integer(dP))
    ..add(asn1.ASN1Integer(dQ))
    ..add(asn1.ASN1Integer(qInv));

  final algId = asn1.ASN1Sequence()
    ..add(
      asn1.ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'),
    )
    ..add(asn1.ASN1Null());

  final pkcs8 = asn1.ASN1Sequence()
    ..add(asn1.ASN1Integer(BigInt.zero))
    ..add(algId)
    ..add(asn1.ASN1OctetString(octets: rsaPriv.encode()));

  return wrapPem('PRIVATE KEY', pkcs8.encode());
}

pc.RSAPrivateKey parseRsaPrivateKeyPem(String pem) {
  final der = stripPemToDer(pem);
  final outer = asn1.ASN1Parser(der).nextObject() as asn1.ASN1Sequence;

  asn1.ASN1Sequence rsaSeq;

  final first = outer.elements!.first;
  if (first is asn1.ASN1Integer &&
      outer.elements!.length == 3 &&
      outer.elements![1] is asn1.ASN1Sequence &&
      outer.elements![2] is asn1.ASN1OctetString) {
    final inner = (outer.elements![2] as asn1.ASN1OctetString).octets!;
    rsaSeq = asn1.ASN1Parser(inner).nextObject() as asn1.ASN1Sequence;
  } else {
    rsaSeq = outer;
  }

  final n = (rsaSeq.elements![1] as asn1.ASN1Integer).integer!;
  final e = (rsaSeq.elements![2] as asn1.ASN1Integer).integer!;
  final d = (rsaSeq.elements![3] as asn1.ASN1Integer).integer!;
  final p = (rsaSeq.elements![4] as asn1.ASN1Integer).integer!;
  final q = (rsaSeq.elements![5] as asn1.ASN1Integer).integer!;

  return pc.RSAPrivateKey(n, d, p, q, e);
}

/// Parse a public RSA key from either:
///   - SPKI PEM ("BEGIN PUBLIC KEY")
///   - SPKI DER bytes
pc.RSAPublicKey parseRsaPublicKeySpki(Uint8List der) {
  final outer = asn1.ASN1Parser(der).nextObject() as asn1.ASN1Sequence;
  final bitString = outer.elements![1] as asn1.ASN1BitString;
  final inner = Uint8List.fromList(bitString.stringValues!);
  final rsaSeq = asn1.ASN1Parser(inner).nextObject() as asn1.ASN1Sequence;
  final n = (rsaSeq.elements![0] as asn1.ASN1Integer).integer!;
  final e = (rsaSeq.elements![1] as asn1.ASN1Integer).integer!;
  return pc.RSAPublicKey(n, e);
}

pc.RSAPublicKey parseRsaPublicKeyPem(String pem) =>
    parseRsaPublicKeySpki(stripPemToDer(pem));

// ============================================================
//  RSA-SHA256 sign / verify (RSASSA-PKCS1-v1_5)
// ============================================================

Uint8List rsaSignSha256(pc.RSAPrivateKey privateKey, Uint8List data) {
  final signer = pc.RSASigner(pc.SHA256Digest(), '0609608648016503040201')
    ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(privateKey));
  final sig = signer.generateSignature(data);
  return sig.bytes;
}

bool rsaVerifySha256(
  pc.RSAPublicKey publicKey,
  Uint8List data,
  Uint8List signature,
) {
  final verifier = pc.RSASigner(pc.SHA256Digest(), '0609608648016503040201')
    ..init(false, pc.PublicKeyParameter<pc.RSAPublicKey>(publicKey));
  try {
    return verifier.verifySignature(data, pc.RSASignature(signature));
  } catch (_) {
    return false;
  }
}
