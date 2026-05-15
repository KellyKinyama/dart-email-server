import 'dns_cache.dart' as dns_cache;
import 'utils.dart';

// ============================================================
//  DMARC check (RFC 7489)
// ============================================================

class DmarcOptions {
  final String? fromDomain;
  final String? dkimResult;
  final String? dkimDomain;
  final String? spfResult;
  final String? spfDomain;

  DmarcOptions({
    this.fromDomain,
    this.dkimResult,
    this.dkimDomain,
    this.spfResult,
    this.spfDomain,
  });
}

class DmarcResult {
  final String result;
  final String? domain;
  final String? reason;
  final String? policy;
  final bool? dkimAligned;
  final bool? spfAligned;
  final String? adkim;
  final String? aspf;

  DmarcResult({
    required this.result,
    this.domain,
    this.reason,
    this.policy,
    this.dkimAligned,
    this.spfAligned,
    this.adkim,
    this.aspf,
  });
}

Future<DmarcResult> checkDMARC(DmarcOptions options) async {
  String? fromDomain = options.fromDomain;

  if (fromDomain == null || fromDomain.isEmpty) {
    return DmarcResult(result: 'none', reason: 'No From domain');
  }

  String dmarcName = '_dmarc.$fromDomain';

  try {
    var records = await dns_cache.txt(dmarcName);
    if (records.isEmpty) {
      String orgDomain = getOrgDomain(fromDomain);
      if (orgDomain.isNotEmpty && orgDomain != fromDomain) {
        String orgDmarcName = '_dmarc.$orgDomain';
        try {
          var records2 = await dns_cache.txt(orgDmarcName);
          if (records2.isEmpty) {
            return DmarcResult(result: 'none', domain: fromDomain, reason: 'No DMARC record');
          }
          return _evaluateDMARC(fromDomain, orgDomain, records2, options);
        } catch (_) {
          return DmarcResult(result: 'none', domain: fromDomain, reason: 'No DMARC record');
        }
      }
      return DmarcResult(result: 'none', domain: fromDomain, reason: 'No DMARC record');
    }
    
    return _evaluateDMARC(fromDomain, fromDomain, records, options);

  } catch (_) {
    return DmarcResult(result: 'none', domain: fromDomain, reason: 'No DMARC record');
  }
}

DmarcResult _evaluateDMARC(String fromDomain, String dmarcDomain, List<List<String>> records, DmarcOptions options) {
  var flat = records.map((r) => r.join('')).toList();
  String? dmarcRecord;
  for (var r in flat) {
    if (RegExp(r'^v=DMARC1', caseSensitive: false).hasMatch(r)) {
      dmarcRecord = r;
      break;
    }
  }

  if (dmarcRecord == null) {
    return DmarcResult(result: 'none', domain: fromDomain, reason: 'No DMARC record');
  }

  var tags = parseTags(dmarcRecord, true);
  String policy = tags['p'] ?? 'none';
  String adkim = tags['adkim'] ?? 'r';
  String aspf = tags['aspf'] ?? 'r';

  bool dkimAligned = false;
  if (options.dkimResult == 'pass' && options.dkimDomain != null) {
    if (adkim == 's') {
      dkimAligned = (options.dkimDomain!.toLowerCase() == fromDomain.toLowerCase());
    } else {
      dkimAligned = sameOrgDomain(options.dkimDomain!, fromDomain);
    }
  }

  bool spfAligned = false;
  if (options.spfResult == 'pass' && options.spfDomain != null) {
    if (aspf == 's') {
      spfAligned = (options.spfDomain!.toLowerCase() == fromDomain.toLowerCase());
    } else {
      spfAligned = sameOrgDomain(options.spfDomain!, fromDomain);
    }
  }

  String dmarcResult = (dkimAligned || spfAligned) ? 'pass' : 'fail';

  return DmarcResult(
    result: dmarcResult,
    domain: fromDomain,
    policy: policy,
    dkimAligned: dkimAligned,
    spfAligned: spfAligned,
    adkim: adkim,
    aspf: aspf,
  );
}

// ============================================================
//  Domain helpers
// ============================================================

String getOrgDomain(String domain) {
  var parts = domain.split('.');
  if (parts.length <= 2) return domain;
  return parts.sublist(parts.length - 2).join('.');
}

bool sameOrgDomain(String domain1, String domain2) {
  return getOrgDomain(domain1).toLowerCase() == getOrgDomain(domain2).toLowerCase();
}
