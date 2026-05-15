// Build the publishable material for a sending domain.
//
// `buildDomainMailMaterial` wraps DKIM key handling, MTA-STS, and TLS-RPT
// in one call. This example exercises every piece:
//
//   * DKIM key generation + DNS record (`buildDkimMaterial`)
//   * MTA-STS policy + DNS record       (`buildMtaStsMaterial`)
//   * TLS-RPT DNS record                (`buildTlsRptMaterial`)
//   * Aggregate DNS plan                (`buildDomainMailMaterial`)
//
// To use a pre-generated key instead of generating a fresh one, set
// `DkimOptions(privateKey: pemString)`.
//
//   dart run examples/build_domain_material.dart

import 'package:dart_email_server/dart_email_server.dart';

void main() {
  const domain = 'example.com';

  // ---- DKIM (fresh RSA-2048 key) ---------------------------------------
  final dkim = buildDkimMaterial(domain, const DkimOptions());

  print('--- DKIM ---');
  print('selector    : ${dkim.selector}');
  print('algo        : ${dkim.algo}');
  print('dnsName     : ${dkim.dnsName}');
  print('dnsValue    : ${dkim.dnsValue}');
  print('--- DKIM private key (PEM) ---');
  print(dkim.privateKey);
  print('--- DKIM public key (PEM) ---');
  print(dkim.publicKey);

  // ---- MTA-STS ---------------------------------------------------------
  final sts = buildMtaStsMaterial(
    domain,
    const MtaStsOptions(
      mode: MtaStsMode.enforce,
      mx: ['mx1.example.com', 'mx2.example.com'],
      maxAgeSeconds: 604800,
    ),
  );

  print('--- MTA-STS ---');
  print('id          : ${sts.id}');
  print('mode        : ${sts.mode.wire}');
  print('policyHost  : ${sts.policyHost}');
  print('policyUrl   : ${sts.policyUrl}');
  print('--- policy file -----');
  print(sts.policy);

  // ---- TLS-RPT ---------------------------------------------------------
  final tlsRpt = buildTlsRptMaterial(
    domain,
    const TlsRptOptions(ruaEmail: 'tls-reports@example.com'),
  );

  print('--- TLS-RPT ---');
  print('TXT _smtp._tls.$domain  →  ${tlsRpt.value}');

  // ---- Full domain plan (single call) ----------------------------------
  final material = buildDomainMailMaterial(
    domain,
    BuildDomainOptions(
      dkim: DkimOptions(privateKey: dkim.privateKey),
      mtaSts: const MtaStsOptions(mx: ['mx1.example.com']),
      tlsRpt: const TlsRptOptions(ruaEmail: 'tls-reports@example.com'),
    ),
  );

  print('\n--- Required DNS records ---');
  for (final r in material.requiredDNS) {
    print('  ${r.type.padRight(4)} ${r.name}  →  ${r.value}');
  }
}
