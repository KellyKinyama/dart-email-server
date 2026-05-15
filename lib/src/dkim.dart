import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../cipher/rsa.dart' as rsa;
import 'dns_cache.dart' as dns_cache;
import 'utils.dart';

// ============================================================
//  Canonicalization (RFC 6376 §3.4)
// ============================================================

final _reUnfold = RegExp(r'\r\n[ \t]+');
final _reWspCompress = RegExp(r'[ \t]+');
final _reWspTrailing = RegExp(r'[ \t]+$');
final _reWspLeading = RegExp(r'^[ \t]+');
final _reNormalizeNl = RegExp(r'\r?\n');

String canonicalizeHeaderRelaxed(String name, String value) {
  String n = name.toLowerCase().trim();
  String v = value
      .replaceAll(_reUnfold, ' ')
      .replaceAll(_reWspCompress, ' ')
      .replaceAll(_reWspTrailing, '')
      .replaceAll(_reWspLeading, '');
  return '$n:$v';
}

String canonicalizeBodyRelaxed(Object body) {
  String str;
  if (body is Uint8List) {
    str = u8ToStr(body);
  } else {
    str = body.toString();
  }

  List<String> lines = str.replaceAll(_reNormalizeNl, '\n').split('\n');
  List<String> out = [];

  for (String line in lines) {
    String processed = line
        .replaceAll(_reWspCompress, ' ')
        .replaceAll(_reWspTrailing, '');
    out.add(processed);
  }

  while (out.isNotEmpty && out.last == '') {
    out.removeLast();
  }

  if (out.isEmpty) return '\r\n';
  return '${out.join('\r\n')}\r\n';
}

MailHeader? _findHeader(List<MailHeader> headers, String name) {
  String low = name.toLowerCase();
  for (int i = headers.length - 1; i >= 0; i--) {
    if (headers[i].name.toLowerCase() == low) return headers[i];
  }
  return null;
}

// ============================================================
//  DKIM Result Types
// ============================================================

class DkimSignOptions {
  final String domain;
  final String selector;
  final String privateKey;
  final String algo;
  final List<String>? signHeaders;

  DkimSignOptions({
    required this.domain,
    required this.selector,
    required this.privateKey,
    this.algo = 'rsa-sha256',
    this.signHeaders,
  });
}

class DkimResult {
  final String result;
  final String? reason;
  final String? domain;
  final String? selector;
  final String? algo;
  final String? header;
  final String? signature;
  final String? bodyHash;
  final List<String>? signedHeaders;
  final Uint8List? message;

  DkimResult({
    required this.result,
    this.reason,
    this.domain,
    this.selector,
    this.algo,
    this.header,
    this.signature,
    this.bodyHash,
    this.signedHeaders,
    this.message,
  });

  Map<String, dynamic> toMap() => {
    'result': result,
    'reason': reason,
    'domain': domain,
    'selector': selector,
    'algo': algo,
    'header': header,
    'signature': signature,
    'bodyHash': bodyHash,
    'signedHeaders': signedHeaders,
    'message': message,
  };
}

// ============================================================
//  DKIM Sign (RFC 6376)
// ============================================================

const List<String> defaultSignedHeaders = [
  'from',
  'to',
  'cc',
  'subject',
  'date',
  'message-id',
  'mime-version',
  'content-type',
  'content-transfer-encoding',
  'reply-to',
  'in-reply-to',
  'references',
];

DkimResult sign(Object rawMessage, [DkimSignOptions? options]) {
  String str = rawMessage is Uint8List
      ? u8ToStr(rawMessage)
      : rawMessage.toString();

  if (options == null) {
    throw Exception(
      'DKIM sign requires options (domain, selector, privateKey)',
    );
  }

  String domain = options.domain;
  String selector = options.selector;
  String privateKey = options.privateKey;
  String algo = options.algo;

  var parsed = parseMailHeaders(str);
  var headers = parsed.headers;
  var body = parsed.body;

  if (algo != 'rsa-sha256') {
    throw UnimplementedError(
      'DKIM algorithm "$algo" is not supported (only rsa-sha256).',
    );
  }

  // Body hash = base64(SHA-256(canonicalized body))
  final canonBody = canonicalizeBodyRelaxed(body);
  final bodyHash = base64.encode(
    crypto.sha256.convert(utf8.encode(canonBody)).bytes,
  );

  List<String> signedHeaderNames = options.signHeaders ?? defaultSignedHeaders;
  List<String> actualSigned = [];
  for (String hName in signedHeaderNames) {
    var h = _findHeader(headers, hName);
    if (h != null) actualSigned.add(hName);
  }

  if (!actualSigned.contains('from')) actualSigned.insert(0, 'from');

  int timestamp = (DateTime.now().millisecondsSinceEpoch / 1000).floor();
  String sigAlgoTag = 'rsa-sha256';

  // Build the DKIM-Signature header value with empty b= for signing.
  String dkimHeaderValue =
      'v=1; a=$sigAlgoTag; c=relaxed/relaxed; d=$domain; '
      's=$selector; t=$timestamp; '
      'h=${actualSigned.join(':')}; bh=$bodyHash; b=';

  // Build sign-data per RFC 6376 §3.7
  final signBuf = StringBuffer();
  for (final hName in actualSigned) {
    final h = _findHeader(headers, hName);
    if (h == null) continue;
    final value = h.raw.replaceFirst(RegExp(r'^[^:]+:\s*'), '');
    signBuf.write(canonicalizeHeaderRelaxed(h.name, value));
    signBuf.write('\r\n');
  }
  signBuf.write(canonicalizeHeaderRelaxed('dkim-signature', dkimHeaderValue));

  final signData = Uint8List.fromList(utf8.encode(signBuf.toString()));
  final priv = rsa.parseRsaPrivateKeyPem(privateKey);
  final sigBytes = rsa.rsaSignSha256(priv, signData);
  final b64Sig = base64.encode(sigBytes);

  final fullDkimValue = dkimHeaderValue + _foldB64(b64Sig);
  final dkimHeaderLine = 'DKIM-Signature: $fullDkimValue';

  final signedMessageStr = '$dkimHeaderLine\r\n$str';

  return DkimResult(
    result: 'signed',
    domain: domain,
    selector: selector,
    algo: sigAlgoTag,
    header: dkimHeaderLine,
    signature: b64Sig,
    bodyHash: bodyHash,
    signedHeaders: actualSigned,
    message: toU8(signedMessageStr),
  );
}

String _foldB64(String b64) {
  String out = '';
  int lineLen = 0;
  for (int i = 0; i < b64.length; i++) {
    if (lineLen >= 72) {
      out += '\r\n        ';
      lineLen = 8;
    }
    out += b64[i];
    lineLen++;
  }
  return out;
}

// ============================================================
//  DKIM Verify (RFC 6376)
// ============================================================

Future<DkimResult> verify(Object rawMessage) async {
  String str = rawMessage is Uint8List
      ? u8ToStr(rawMessage)
      : rawMessage.toString();

  var parsed = parseMailHeaders(str);
  var headers = parsed.headers;
  var body = parsed.body;

  var dkimHeader = _findHeader(headers, 'DKIM-Signature');
  if (dkimHeader == null) {
    return DkimResult(result: 'none', reason: 'No DKIM-Signature header');
  }

  var tags = parseTags(dkimHeader.value);
  if (!tags.containsKey('v') ||
      !tags.containsKey('a') ||
      !tags.containsKey('d') ||
      !tags.containsKey('s') ||
      !tags.containsKey('h') ||
      !tags.containsKey('bh') ||
      !tags.containsKey('b')) {
    return DkimResult(
      result: 'permerror',
      reason: 'Missing required DKIM tags',
    );
  }

  String domain = tags['d']!;
  String selector = tags['s']!;
  String algo = tags['a']!;
  List<String> signedHeaderList = tags['h']!
      .split(':')
      .map((s) => s.trim().toLowerCase())
      .toList();
  String claimedBodyHash = tags['bh']!;
  String signatureB64 = tags['b']!.replaceAll(RegExp(r'\s+'), '');

  if (algo != 'rsa-sha256') {
    return DkimResult(
      result: 'permerror',
      reason: 'Unsupported DKIM algorithm: $algo',
      domain: domain,
    );
  }

  // Body hash check
  final canonBody = canonicalizeBodyRelaxed(body);
  final computedBodyHash = base64.encode(
    crypto.sha256.convert(utf8.encode(canonBody)).bytes,
  );

  if (computedBodyHash != claimedBodyHash) {
    return DkimResult(
      result: 'fail',
      reason: 'Body hash mismatch',
      domain: domain,
      selector: selector,
      algo: algo,
    );
  }

  String dnsName = '$selector._domainkey.$domain';
  try {
    var records = await dns_cache.txt(dnsName);
    if (records.isEmpty) {
      return DkimResult(
        result: 'temperror',
        reason: 'DNS lookup failed for $dnsName',
        domain: domain,
      );
    }

    List<String> flat = records.map((r) => r.join('')).toList();

    String? dkimRecord;
    for (var r in flat) {
      if (r.contains('v=DKIM1')) {
        dkimRecord = r;
        break;
      }
    }

    if (dkimRecord == null) {
      return DkimResult(
        result: 'permerror',
        reason: 'No DKIM record at $dnsName',
        domain: domain,
      );
    }

    String? pubKeyB64 = _extractDkimPublicKey(dkimRecord, algo);
    if (pubKeyB64 == null) {
      return DkimResult(
        result: 'permerror',
        reason: 'Could not extract public key',
        domain: domain,
      );
    }

    // Reconstruct sign-data with the b= field zeroed.
    final signBuf = StringBuffer();
    for (final hName in signedHeaderList) {
      final h = _findHeader(headers, hName);
      if (h == null) continue;
      final value = h.raw.replaceFirst(RegExp(r'^[^:]+:\s*'), '');
      signBuf.write(canonicalizeHeaderRelaxed(h.name, value));
      signBuf.write('\r\n');
    }

    final dkimRaw = dkimHeader.raw.replaceFirst(RegExp(r'^[^:]+:\s*'), '');
    // Unfold and zero out the b= tag value (preserve trailing tags).
    final unfolded = dkimRaw.replaceAll(RegExp(r'\r\n[ \t]+'), ' ');
    final zeroedB = unfolded.replaceFirst(RegExp(r'(b=)([^;]*)'), r'b=');
    signBuf.write(canonicalizeHeaderRelaxed('dkim-signature', zeroedB));

    final signData = Uint8List.fromList(utf8.encode(signBuf.toString()));
    final sigBytes = base64.decode(signatureB64);

    // Public key from DNS may be either bare RSA SPKI (most common) or just
    // the SPKI b64. Wrap it as DER and parse.
    final pubKeyDer = base64.decode(pubKeyB64);
    final pubKey = rsa.parseRsaPublicKeySpki(pubKeyDer);

    final valid = rsa.rsaVerifySha256(pubKey, signData, sigBytes);

    if (valid) {
      return DkimResult(
        result: 'pass',
        domain: domain,
        selector: selector,
        algo: algo,
        bodyHash: computedBodyHash,
        signedHeaders: signedHeaderList,
      );
    }
    return DkimResult(
      result: 'fail',
      reason: 'Signature verification failed',
      domain: domain,
      selector: selector,
      algo: algo,
    );
  } catch (e) {
    return DkimResult(result: 'permerror', reason: 'Error: $e', domain: domain);
  }
}

String? _extractDkimPublicKey(String record, String algo) {
  var tags = parseTags(record);
  return tags['p'];
}
