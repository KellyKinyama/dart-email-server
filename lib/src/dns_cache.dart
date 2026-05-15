import 'dart:async';
import 'dart:io';

import 'utils.dart';

const int defaultTtl = 300000; // 5 minutes

/// Single MX entry returned by an MX lookup.
class MxDnsRecord {
  final String exchange;
  final int priority;
  const MxDnsRecord({required this.exchange, this.priority = 10});

  /// Backwards-compatible map view (used by callers that still consume
  /// `Map<String, dynamic>` MX records).
  Map<String, dynamic> toMap() => {'exchange': exchange, 'priority': priority};
}

/// Discriminator for a cached DNS payload.
enum DnsRecordType { a, aaaa, ptr, txt, mx }

/// A typed cache payload. Exactly one of the typed fields is populated,
/// matching [type].
class DnsCacheData {
  final DnsRecordType type;
  final List<String>? addresses; // A / AAAA / PTR
  final List<List<String>>? txtRecords; // TXT
  final List<MxDnsRecord>? mxRecords; // MX

  const DnsCacheData._({
    required this.type,
    this.addresses,
    this.txtRecords,
    this.mxRecords,
  });

  factory DnsCacheData.addresses(DnsRecordType type, List<String> v) =>
      DnsCacheData._(type: type, addresses: List.unmodifiable(v));

  factory DnsCacheData.txt(List<List<String>> v) =>
      DnsCacheData._(type: DnsRecordType.txt, txtRecords: v);

  factory DnsCacheData.mx(List<MxDnsRecord> v) =>
      DnsCacheData._(type: DnsRecordType.mx, mxRecords: v);
}

class _CacheEntry {
  final DnsCacheData data;
  final int expires;
  const _CacheEntry(this.data, this.expires);
}

final Map<String, _CacheEntry> _cache = {};

String? normalizeName(String type, String? name) {
  if (name == null) return name;
  if (type == 'PTR') return name;
  if (isAscii(name)) return name;
  final ascii = domainToAscii(name);
  return ascii.isNotEmpty ? ascii : name;
}

/// Typed lookup. Throws if the name is invalid or the type is unknown.
Future<DnsCacheData> lookup(String type, String name) async {
  final normalized = normalizeName(type, name);
  if (normalized == null) throw ArgumentError('Invalid name');

  final key = '$type:$normalized';
  final cached = _cache[key];
  if (cached != null &&
      cached.expires > DateTime.now().millisecondsSinceEpoch) {
    return cached.data;
  }

  DnsCacheData data;
  switch (type) {
    case 'A':
      final list = await InternetAddress.lookup(
        normalized,
        type: InternetAddressType.IPv4,
      );
      data = DnsCacheData.addresses(
        DnsRecordType.a,
        list.map((a) => a.address).toList(),
      );
      break;
    case 'AAAA':
      final list = await InternetAddress.lookup(
        normalized,
        type: InternetAddressType.IPv6,
      );
      data = DnsCacheData.addresses(
        DnsRecordType.aaaa,
        list.map((a) => a.address).toList(),
      );
      break;
    case 'PTR':
      final addr = InternetAddress(normalized);
      final host = await addr.reverse();
      data = DnsCacheData.addresses(DnsRecordType.ptr, <String>[host.host]);
      break;
    case 'TXT':
      // dart:io has no TXT support out of the box.
      data = DnsCacheData.txt(const <List<String>>[]);
      break;
    case 'MX':
      // dart:io has no MX support out of the box.
      data = DnsCacheData.mx(const <MxDnsRecord>[]);
      break;
    default:
      throw ArgumentError('Unknown DNS type: $type');
  }

  _cache[key] = _CacheEntry(
    data,
    DateTime.now().millisecondsSinceEpoch + defaultTtl,
  );
  return data;
}

Future<List<String>> a(String name) async {
  final res = await lookup('A', name);
  return res.addresses ?? const <String>[];
}

Future<List<String>> aaaa(String name) async {
  final res = await lookup('AAAA', name);
  return res.addresses ?? const <String>[];
}

Future<List<List<String>>> txt(String name) async {
  final res = await lookup('TXT', name);
  return res.txtRecords ?? const <List<String>>[];
}

/// Typed MX lookup.
Future<List<MxDnsRecord>> mxRecords(String name) async {
  final res = await lookup('MX', name);
  return res.mxRecords ?? const <MxDnsRecord>[];
}

/// Backwards-compatible MX lookup that returns plain maps. New callers
/// should prefer [mxRecords].
Future<List<Map<String, dynamic>>> mx(String name) async {
  final list = await mxRecords(name);
  return list.map((r) => r.toMap()).toList();
}

Future<List<String>> ptr(String ip) async {
  final res = await lookup('PTR', ip);
  return res.addresses ?? const <String>[];
}

void clearCache() {
  _cache.clear();
}

void removeFromCache(String name) {
  _cache.removeWhere((key, _) => key.contains(name));
}

/// Pre-seed the DNS cache with a typed payload. Primarily intended for
/// tests so they can run offline (DKIM verify, SPF/DMARC fixtures, ...).
///
/// [ttlMs] defaults to one hour.
void setCacheEntry(
  String type,
  String name,
  DnsCacheData data, {
  int ttlMs = 3600 * 1000,
}) {
  final normalized = normalizeName(type, name) ?? name;
  _cache['$type:$normalized'] = _CacheEntry(
    data,
    DateTime.now().millisecondsSinceEpoch + ttlMs,
  );
}
