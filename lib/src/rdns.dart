import 'dns_cache.dart' as dns_cache;

// ============================================================
//  FCrDNS check (Forward-Confirmed Reverse DNS)
// ============================================================

class FCrDNSResult {
  final String result;
  final String? ip;
  final String? reason;
  final String? hostname;
  final List<String>? ptrHostnames;

  FCrDNSResult({
    required this.result,
    this.ip,
    this.reason,
    this.hostname,
    this.ptrHostnames,
  });
}

Future<FCrDNSResult> checkFCrDNS(String? ip) async {
  if (ip == null || ip.isEmpty) {
    return FCrDNSResult(result: 'none', reason: 'No IP');
  }

  String cleanIP = ip.replaceFirst(RegExp(r'^::ffff:', caseSensitive: false), '');

  // Step 1: PTR lookup
  List<String> hostnames;
  try {
    hostnames = await dns_cache.ptr(cleanIP);
    if (hostnames.isEmpty) {
      return FCrDNSResult(result: 'fail', ip: cleanIP, reason: 'No PTR record');
    }
  } catch (err) {
    return FCrDNSResult(result: 'fail', ip: cleanIP, reason: 'No PTR record');
  }

  // Step 2: Forward lookup — check each PTR hostname
  for (String hostname in hostnames) {
    try {
      List<String> addrs = await dns_cache.a(hostname);
      for (String addr in addrs) {
        if (addr == cleanIP) {
          return FCrDNSResult(
            result: 'pass',
            ip: cleanIP,
            hostname: hostname,
            ptrHostnames: hostnames,
          );
        }
      }
    } catch (_) {
      // Ignored, try next
    }
  }

  return FCrDNSResult(
    result: 'fail',
    ip: cleanIP,
    ptrHostnames: hostnames,
    reason: 'No forward match',
  );
}

// ============================================================
//  EHLO hostname verification
// ============================================================

class EhloHostnameResult {
  final String result;
  final String? hostname;
  final String? ip;
  final String? reason;

  EhloHostnameResult({
    required this.result,
    this.hostname,
    this.ip,
    this.reason,
  });
}

Future<EhloHostnameResult> checkEhloHostname(String? ip, String? ehloHostname) async {
  if (ip == null || ip.isEmpty || ehloHostname == null || ehloHostname.isEmpty) {
    return EhloHostnameResult(result: 'none');
  }

  String cleanIP = ip.replaceFirst(RegExp(r'^::ffff:', caseSensitive: false), '');

  try {
    List<String> addrs = await dns_cache.a(ehloHostname);
    for (String addr in addrs) {
      if (addr == cleanIP) {
        return EhloHostnameResult(result: 'pass', hostname: ehloHostname, ip: cleanIP);
      }
    }
  } catch (_) {
    // fallthrough to fail
  }

  return EhloHostnameResult(
    result: 'fail',
    hostname: ehloHostname,
    ip: cleanIP,
    reason: 'EHLO hostname does not resolve to IP',
  );
}
