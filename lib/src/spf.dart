import 'dart:io';
import 'dns_cache.dart' as dns_cache;

// ============================================================
//  SPF check (RFC 7208)
// ============================================================

class SpfResult {
  final String result;
  final String domain;
  final String? reason;
  final String? mechanism;

  SpfResult({required this.result, required this.domain, this.reason, this.mechanism});
}

class _LookupCount {
  int count;
  int max;
  _LookupCount(this.count, this.max);
}

Future<SpfResult> checkSPF(String? ip, String? domain) async {
  if (ip == null || ip.isEmpty || domain == null || domain.isEmpty) {
    return SpfResult(result: 'none', domain: domain ?? '');
  }

  try {
    var records = await dns_cache.txt(domain);
    if (records.isEmpty) {
      return SpfResult(result: 'none', domain: domain, reason: 'No TXT records');
    }

    var flat = records.map((r) => r.join('')).toList();
    
    String? spfRecord;
    for (var r in flat) {
      if (RegExp(r'^v=spf1\b', caseSensitive: false).hasMatch(r)) {
        spfRecord = r;
        break;
      }
    }

    if (spfRecord == null) {
      return SpfResult(result: 'none', domain: domain, reason: 'No SPF record');
    }

    var lookupCount = _LookupCount(0, 10);
    return await _evaluateSPF(ip, domain, spfRecord, lookupCount);
  } catch (err) {
    return SpfResult(result: 'none', domain: domain, reason: 'No TXT records');
  }
}

// ============================================================
//  SPF evaluation
// ============================================================

Future<SpfResult> _evaluateSPF(String ip, String domain, String spfRecord, _LookupCount lookups) async {
  if (lookups.count > lookups.max) {
    return SpfResult(result: 'permerror', domain: domain, reason: 'Too many DNS lookups');
  }

  var terms = spfRecord.replaceFirst(RegExp(r'^v=spf1\s*', caseSensitive: false), '').trim().split(RegExp(r'\s+'));

  for (int idx = 0; idx < terms.length; idx++) {
    String term = terms[idx];
    if (term.isEmpty) continue;

    String qualifier = '+';
    if (term[0] == '+' || term[0] == '-' || term[0] == '~' || term[0] == '?') {
      qualifier = term[0];
      term = term.substring(1);
    }

    String resultForQualifier = _qualifierToResult(qualifier);

    if (term.toLowerCase() == 'all') {
      return SpfResult(result: resultForQualifier, domain: domain, mechanism: 'all');
    }

    if (term.toLowerCase().startsWith('ip4:')) {
      String cidr = term.substring(4);
      if (_matchIPv4(ip, cidr)) {
        return SpfResult(result: resultForQualifier, domain: domain, mechanism: term);
      }
      continue;
    }

    if (term.toLowerCase().startsWith('ip6:')) {
      String cidr = term.substring(4);
      if (_matchIPv6(ip, cidr)) {
        return SpfResult(result: resultForQualifier, domain: domain, mechanism: term);
      }
      continue;
    }

    if (RegExp(r'^a(?:$|:)', caseSensitive: false).hasMatch(term)) {
      lookups.count++;
      String aDomain = term.contains(':') ? term.split(':').sublist(1).join(':') : domain;
      try {
        var addrs = await dns_cache.a(aDomain);
        for (var addr in addrs) {
          if (_normalizeIP(addr) == _normalizeIP(ip)) {
            return SpfResult(result: resultForQualifier, domain: domain, mechanism: term);
          }
        }
      } catch (_) {}
      
      try {
        var addrs6 = await dns_cache.aaaa(aDomain);
        for (var addr in addrs6) {
          if (_normalizeIP(addr) == _normalizeIP(ip)) {
            return SpfResult(result: resultForQualifier, domain: domain, mechanism: term);
          }
        }
      } catch (_) {}
      continue;
    }

    if (RegExp(r'^mx(?:$|:)', caseSensitive: false).hasMatch(term)) {
      lookups.count++;
      String mxDomain = term.contains(':') ? term.split(':').sublist(1).join(':') : domain;
      try {
        var mxRecords = await dns_cache.mx(mxDomain);
        var mxHosts = mxRecords.map((r) => r['exchange'] as String).toList();
        for (String mxHost in mxHosts) {
          try {
            var addrs = await dns_cache.a(mxHost);
            for (var addr in addrs) {
              if (_normalizeIP(addr) == _normalizeIP(ip)) {
                return SpfResult(result: resultForQualifier, domain: domain, mechanism: term);
              }
            }
          } catch (_) {}
        }
      } catch (_) {}
      continue;
    }

    if (term.toLowerCase().startsWith('include:')) {
      lookups.count++;
      String includeDomain = term.substring(8);
      try {
        var records = await dns_cache.txt(includeDomain);
        var flat = records.map((r) => r.join('')).toList();
        String? incSPF;
        for (var r in flat) {
          if (RegExp(r'^v=spf1\b', caseSensitive: false).hasMatch(r)) {
            incSPF = r;
            break;
          }
        }
        if (incSPF != null) {
          var incResult = await _evaluateSPF(ip, includeDomain, incSPF, lookups);
          if (incResult.result == 'pass') {
            return SpfResult(result: resultForQualifier, domain: domain, mechanism: term);
          }
        }
      } catch (_) {}
      continue;
    }

    if (term.toLowerCase().startsWith('redirect=')) {
      lookups.count++;
      String redirDomain = term.substring(9);
      try {
        var records = await dns_cache.txt(redirDomain);
        var flat = records.map((r) => r.join('')).toList();
        String? redirSPF;
        for (var r in flat) {
          if (RegExp(r'^v=spf1\b', caseSensitive: false).hasMatch(r)) {
            redirSPF = r;
            break;
          }
        }
        if (redirSPF != null) {
          return await _evaluateSPF(ip, redirDomain, redirSPF, lookups);
        }
      } catch (_) {}
      return SpfResult(result: 'permerror', domain: domain);
    }
  }

  return SpfResult(result: 'neutral', domain: domain);
}

// ============================================================
//  IP matching helpers
// ============================================================

String _normalizeIP(String? ip) {
  if (ip == null || ip.isEmpty) return '';
  return ip.replaceAll(RegExp(r'^::ffff:', caseSensitive: false), '').toLowerCase();
}

bool _matchIPv4(String ip, String cidr) {
  String normIP = _normalizeIP(ip);
  if (!_isIPv4(normIP)) return false;

  var parts = cidr.split('/');
  String addr = parts[0];
  int mask = parts.length > 1 ? int.parse(parts[1]) : 32;

  int ipNum = _ipv4ToNum(normIP);
  int addrNum = _ipv4ToNum(addr);
  int emptyBits = 32 - mask;
  int maskBits = mask == 0 ? 0 : (0xFFFFFFFF << emptyBits) & 0xFFFFFFFF;

  return (ipNum & maskBits) == (addrNum & maskBits);
}

bool _isIPv4(String ip) {
  return InternetAddress.tryParse(ip)?.type == InternetAddressType.IPv4;
}

int _ipv4ToNum(String ip) {
  var parts = ip.split('.');
  if (parts.length != 4) return 0;
  return ((int.parse(parts[0]) << 24) |
          (int.parse(parts[1]) << 16) |
          (int.parse(parts[2]) << 8) |
           int.parse(parts[3])) & 0xFFFFFFFF;
}

bool _matchIPv6(String ip, String cidr) {
  String normIP = _normalizeIP(ip);
  if (_isIPv4(normIP)) return false;

  var parts = cidr.split('/');
  String addr = parts[0];
  
  return _normalizeIP(addr) == normIP; // simplified match
}

String _qualifierToResult(String q) {
  if (q == '+') return 'pass';
  if (q == '-') return 'fail';
  if (q == '~') return 'softfail';
  if (q == '?') return 'neutral';
  return 'neutral';
}
