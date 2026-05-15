// ============================================================
//  Typed domain mail material (DKIM, MTA-STS, TLS-RPT, DNS)
// ============================================================
//
//  Strict, type-safe API. No Map<String, dynamic> / Map<String, Object?> /
//  Object? entry points — every option and result is a real Dart class.

import 'dart:async';

import '../cipher/rsa.dart' as rsa;

// ------------------------------------------------------------
//  Options (input)
// ------------------------------------------------------------

class DkimOptions {
  final String? selector;
  final String algo;
  final String? privateKey;

  const DkimOptions({this.selector, this.algo = 'rsa-sha256', this.privateKey});
}

class TlsMaterial {
  final String? key;
  final String? cert;

  const TlsMaterial({this.key, this.cert});
}

/// Outbound relay smarthost configuration (used by both `Server` and
/// the standalone `sendMail` client).
class RelayOptions {
  final String host;
  final int port;
  final String? username;
  final String? password;
  final bool requireTls;

  const RelayOptions({
    required this.host,
    this.port = 587,
    this.username,
    this.password,
    this.requireTls = true,
  });
}

/// MTA-STS policy mode (RFC 8461).
enum MtaStsMode {
  enforce,
  testing,
  none;

  String get wire => name; // 'enforce' / 'testing' / 'none'
}

class MtaStsOptions {
  final String? id;
  final MtaStsMode mode;
  final List<String> mx;
  final int maxAgeSeconds;

  const MtaStsOptions({
    this.id,
    this.mode = MtaStsMode.enforce,
    this.mx = const [],
    this.maxAgeSeconds = 604800,
  });
}

class TlsRptOptions {
  final String? rua;
  final String? ruaEmail;

  const TlsRptOptions({this.rua, this.ruaEmail});

  bool get hasAddress => rua != null || ruaEmail != null;
}

class DomainPolicyOptions {
  final String? spfTxt;
  final String? dmarcTxt;

  const DomainPolicyOptions({this.spfTxt, this.dmarcTxt});
}

class BuildDomainOptions {
  final DkimOptions? dkim;
  final TlsMaterial? tls;
  final MtaStsOptions? mtaSts;
  final TlsRptOptions? tlsRpt;
  final DomainPolicyOptions? policy;

  const BuildDomainOptions({
    this.dkim,
    this.tls,
    this.mtaSts,
    this.tlsRpt,
    this.policy,
  });
}

// ------------------------------------------------------------
//  Results (output)
// ------------------------------------------------------------

class DkimMaterial {
  final String selector;
  final String algo;
  final String? privateKey;
  final String? publicKey;
  final String dnsName;
  final String? dnsValue;

  const DkimMaterial({
    required this.selector,
    required this.algo,
    required this.privateKey,
    required this.publicKey,
    required this.dnsName,
    required this.dnsValue,
  });
}

class MtaStsMaterial {
  final String id;
  final MtaStsMode mode;
  final List<String> mx;
  final int maxAge;
  final String policy;
  final String policyUrl;
  final String policyHost;

  const MtaStsMaterial({
    required this.id,
    required this.mode,
    required this.mx,
    required this.maxAge,
    required this.policy,
    required this.policyUrl,
    required this.policyHost,
  });
}

class TlsRptMaterial {
  final String rua;
  final String value;

  const TlsRptMaterial({required this.rua, required this.value});
}

class DnsRecord {
  final String type; // TXT | MX | A_OR_CNAME ...
  final String name;
  final String value;
  final String? note;

  const DnsRecord({
    required this.type,
    required this.name,
    required this.value,
    this.note,
  });
}

class DnsWarning {
  final String domain;
  final String message;
  const DnsWarning({required this.domain, required this.message});
}

class VerifyDnsResult {
  final bool dkim;
  final bool spf;
  final bool dmarc;
  final bool mx;
  final bool? mtaSts;
  final bool? tlsRpt;

  const VerifyDnsResult({
    required this.dkim,
    required this.spf,
    required this.dmarc,
    required this.mx,
    this.mtaSts,
    this.tlsRpt,
  });
}

class DomainMaterial {
  final String domain;
  final DkimMaterial dkim;
  final TlsMaterial? tls;
  final MtaStsMaterial? mtaSts;
  final TlsRptMaterial? tlsRpt;
  final List<DnsRecord> requiredDNS;
  final Future<VerifyDnsResult> Function() verifyDNS;

  const DomainMaterial({
    required this.domain,
    required this.dkim,
    required this.tls,
    required this.mtaSts,
    required this.tlsRpt,
    required this.requiredDNS,
    required this.verifyDNS,
  });
}

// ============================================================
//  buildDomainMailMaterial
// ============================================================

DomainMaterial buildDomainMailMaterial(
  String domain, [
  BuildDomainOptions opts = const BuildDomainOptions(),
]) {
  if (domain.isEmpty) {
    throw ArgumentError('domain is required');
  }

  final dkim = buildDkimMaterial(domain, opts.dkim);
  final mtaSts = opts.mtaSts != null
      ? buildMtaStsMaterial(domain, opts.mtaSts!)
      : null;
  final tlsRpt = (opts.tlsRpt != null && opts.tlsRpt!.hasAddress)
      ? buildTlsRptMaterial(domain, opts.tlsRpt!)
      : null;

  final required = buildRequiredDNS(domain, dkim, opts.policy, mtaSts, tlsRpt);

  return DomainMaterial(
    domain: domain,
    dkim: dkim,
    tls: opts.tls,
    mtaSts: mtaSts,
    tlsRpt: tlsRpt,
    requiredDNS: required,
    verifyDNS: () => verifyDNS(domain, dkim, mtaSts, tlsRpt),
  );
}

// ============================================================
//  MTA-STS (RFC 8461)
// ============================================================

MtaStsMaterial buildMtaStsMaterial(String domain, MtaStsOptions opts) {
  final mx = opts.mx.isNotEmpty
      ? List<String>.unmodifiable(opts.mx)
      : <String>['mx.$domain'];
  final id = opts.id ?? buildStsId();

  final policyBuf = StringBuffer()
    ..write('version: STSv1\r\n')
    ..write('mode: ${opts.mode.wire}\r\n');
  for (final m in mx) {
    policyBuf.write('mx: $m\r\n');
  }
  policyBuf.write('max_age: ${opts.maxAgeSeconds}\r\n');

  return MtaStsMaterial(
    id: id,
    mode: opts.mode,
    mx: mx,
    maxAge: opts.maxAgeSeconds,
    policy: policyBuf.toString(),
    policyUrl: 'https://mta-sts.$domain/.well-known/mta-sts.txt',
    policyHost: 'mta-sts.$domain',
  );
}

String buildStsId() {
  final d = DateTime.now().toUtc();
  String pad2(int n) => n.toString().padLeft(2, '0');
  return '${d.year}${pad2(d.month)}${pad2(d.day)}'
      'T${pad2(d.hour)}${pad2(d.minute)}${pad2(d.second)}Z';
}

// ============================================================
//  TLS-RPT (RFC 8460)
// ============================================================

TlsRptMaterial buildTlsRptMaterial(String domain, TlsRptOptions opts) {
  final rua =
      opts.rua ??
      (opts.ruaEmail != null
          ? 'mailto:${opts.ruaEmail}'
          : 'mailto:tls-reports@$domain');
  return TlsRptMaterial(rua: rua, value: 'v=TLSRPTv1; rua=$rua');
}

// ============================================================
//  DKIM key generation / normalization
// ============================================================

DkimMaterial buildDkimMaterial(String domain, DkimOptions? dkimOpts) {
  final opts = dkimOpts ?? const DkimOptions();
  final algo = opts.algo;
  final selector = opts.selector ?? buildSelector();

  String? privateKey = opts.privateKey;
  String? publicKey;

  if (privateKey == null) {
    final pair = generateKeyPair(algo);
    privateKey = pair.privateKey;
    publicKey = pair.publicKey;
  } else {
    publicKey = extractPublicKey(privateKey, algo);
  }

  return DkimMaterial(
    selector: selector,
    algo: algo,
    privateKey: privateKey,
    publicKey: publicKey,
    dnsName: '$selector._domainkey.$domain',
    dnsValue: buildDkimDnsValue(algo, publicKey),
  );
}

String buildSelector() {
  final d = DateTime.now();
  String pad2(int n) => n.toString().padLeft(2, '0');
  return 's${d.year}${pad2(d.month)}';
}

class KeyPair {
  final String privateKey;
  final String publicKey;
  const KeyPair(this.privateKey, this.publicKey);
}

KeyPair generateKeyPair(String algo) {
  if (algo == 'ed25519-sha256') {
    throw UnimplementedError(
      'Ed25519 DKIM key generation is not yet supported. '
      'Provide a privateKey instead.',
    );
  }
  // Default: RSA-2048 (DKIM rsa-sha256).
  final pair = rsa.rsaGenerateKeyPairPem(bits: 2048);
  return KeyPair(pair.privateKeyPem, pair.publicKeyPem);
}

String? extractPublicKey(String privateKeyPem, String algo) {
  if (algo == 'ed25519-sha256') {
    throw UnimplementedError(
      'Ed25519 public-key extraction is not yet supported.',
    );
  }
  return rsa.rsaPublicKeyPemFromPrivatePem(privateKeyPem);
}

String? buildDkimDnsValue(String algo, String? publicKeyPem) {
  if (publicKeyPem == null) return null;

  final k = (algo == 'ed25519-sha256') ? 'ed25519' : 'rsa';
  final b64 = publicKeyPem
      .replaceAll('-----BEGIN PUBLIC KEY-----', '')
      .replaceAll('-----END PUBLIC KEY-----', '')
      .replaceAll(RegExp(r'\s+'), '');

  if (k == 'ed25519') return 'v=DKIM1; k=ed25519; p=$b64';
  return 'v=DKIM1; k=rsa; h=sha256; p=$b64';
}

// ============================================================
//  Build required DNS records
// ============================================================

List<DnsRecord> buildRequiredDNS(
  String domain,
  DkimMaterial? dkim,
  DomainPolicyOptions? policy,
  MtaStsMaterial? mtaSts,
  TlsRptMaterial? tlsRpt,
) {
  final records = <DnsRecord>[];

  if (dkim != null && dkim.dnsValue != null) {
    records.add(
      DnsRecord(type: 'TXT', name: dkim.dnsName, value: dkim.dnsValue!),
    );
  }

  records.add(
    DnsRecord(
      type: 'TXT',
      name: domain,
      value: policy?.spfTxt ?? 'v=spf1 mx a ~all',
    ),
  );

  records.add(
    DnsRecord(
      type: 'TXT',
      name: '_dmarc.$domain',
      value: policy?.dmarcTxt ?? 'v=DMARC1; p=quarantine; adkim=s; aspf=s',
    ),
  );

  records.add(DnsRecord(type: 'MX', name: domain, value: '10 mx.$domain'));

  if (mtaSts != null) {
    records.add(
      DnsRecord(
        type: 'TXT',
        name: '_mta-sts.$domain',
        value: 'v=STSv1; id=${mtaSts.id}',
      ),
    );
    records.add(
      DnsRecord(
        type: 'A_OR_CNAME',
        name: mtaSts.policyHost,
        value: '<point to the HTTPS server that will serve the policy file>',
        note:
            'Needs HTTPS with a valid TLS cert for this hostname. '
            'Policy file: ${mtaSts.policyUrl}',
      ),
    );
  }

  if (tlsRpt != null) {
    records.add(
      DnsRecord(type: 'TXT', name: '_smtp._tls.$domain', value: tlsRpt.value),
    );
  }

  return records;
}

// ============================================================
//  Verify DNS records (placeholder until DNS client is wired)
// ============================================================

Future<VerifyDnsResult> verifyDNS(
  String domain,
  DkimMaterial? dkim,
  MtaStsMaterial? mtaSts,
  TlsRptMaterial? tlsRpt,
) async {
  return VerifyDnsResult(
    dkim: false,
    spf: false,
    dmarc: false,
    mx: false,
    mtaSts: mtaSts != null ? false : null,
    tlsRpt: tlsRpt != null ? false : null,
  );
}
