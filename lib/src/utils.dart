import 'dart:convert';
import 'dart:typed_data';

Uint8List toU8(Object x) {
  if (x is Uint8List) return x;
  if (x is List<int>) return Uint8List.fromList(x);
  if (x is String) return Uint8List.fromList(utf8.encode(x));
  return Uint8List(0);
}

String u8ToStr(Uint8List? u8) {
  if (u8 == null || u8.isEmpty) return '';
  try {
    return utf8.decode(u8);
  } catch (_) {
    return String.fromCharCodes(u8);
  }
}

Uint8List concatU8(List<Uint8List> arrays) {
  var b = BytesBuilder(copy: false);
  for (var a in arrays) {
    b.add(a);
  }
  return b.toBytes();
}

bool u8Equal(Uint8List? a, Uint8List? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool hasNonAscii(Uint8List u8) {
  for (int i = 0; i < u8.length; i++) {
    if (u8[i] > 0x7F) return true;
  }
  return false;
}

bool asciiEqCI(Uint8List u8, int pos, String str) {
  if (pos + str.length > u8.length) return false;
  for (int i = 0; i < str.length; i++) {
    int b = u8[pos + i];
    int bu = (b >= 97 && b <= 122) ? (b - 32) : b;
    int cu = str.codeUnitAt(i);
    cu = (cu >= 97 && cu <= 122) ? (cu - 32) : cu;
    if (bu != cu) return false;
  }
  return true;
}

bool isDigit(int b) {
  return b >= 48 && b <= 57;
}

int indexOfCRLF(Uint8List buf, [int from = 0]) {
  for (int i = from; i + 1 < buf.length; i++) {
    if (buf[i] == 13 && buf[i + 1] == 10) return i;
  }
  return -1;
}

bool isAscii(String s) {
  for (int i = 0; i < s.length; i++) {
    if (s.codeUnitAt(i) > 0x7F) return false;
  }
  return true;
}

String domainToAscii(String? domain) {
  if (domain == null || domain.isEmpty) return '';
  if (isAscii(domain)) return domain;
  try {
    var uri = Uri.parse('http://$domain');
    return uri.host;
  } catch (e) {
    return '';
  }
}

String domainToUnicode(String? domain) {
  if (domain == null || domain.isEmpty) return '';
  if (!domain.contains('xn--')) return domain;
  try {
    // A robust server would need a punycode library,
    // but for now we just return the original string.
    return domain;
  } catch (e) {
    return domain;
  }
}

class AddressParts {
  final String local;
  final String domain;
  AddressParts(this.local, this.domain);
}

AddressParts? splitAddress(String? addr) {
  if (addr == null || addr.isEmpty) return null;
  int at = -1;
  bool inQuote = false;
  for (int i = 0; i < addr.length; i++) {
    int c = addr.codeUnitAt(i);
    if (c == 0x5C) { // \
      i++; continue;
    }
    if (c == 0x22) { // "
      inQuote = !inQuote; continue;
    }
    if (c == 0x40 && !inQuote) { // @
      at = i;
    }
  }
  if (at < 0) return null;
  return AddressParts(addr.substring(0, at), addr.substring(at + 1));
}

bool addressNeedsSmtputf8(String? addr) {
  var s = splitAddress(addr);
  if (s == null) return !isAscii(addr ?? '');
  return !isAscii(s.local);
}

String? addressForAsciiOnlyPeer(String? addr) {
  var s = splitAddress(addr);
  if (s == null) return isAscii(addr ?? '') ? addr : null;
  if (!isAscii(s.local)) return null;
  var d = domainToAscii(s.domain);
  if (d.isEmpty) return null;
  return '${s.local}@$d';
}

String? extractAddress(Object? val) {
  if (val == null) return null;
  if (val is Map && val['address'] != null) return val['address'].toString();
  String s = val.toString();
  var m = RegExp(r'<([^>]+)>').firstMatch(s);
  if (m != null) return m.group(1);
  if (s.contains('@')) return s.trim();
  return null;
}

List<String> extractAddressList(List<Object> arr) {
  List<String> out = [];
  for (var item in arr) {
    if (item is String) {
      var parts = item.split(',');
      for (var p in parts) {
        var a = extractAddress(p.trim());
        if (a != null) out.add(a);
      }
    } else {
      var a = extractAddress(item);
      if (a != null) out.add(a);
    }
  }
  return out;
}

Map<String, String> parseTags(String value, [bool lowercaseKeys = false]) {
  Map<String, String> tags = {};
  var parts = value.split(';');
  for (var p in parts) {
    var p0 = p.trim();
    int eq = p0.indexOf('=');
    if (eq > 0) {
      var k = p0.substring(0, eq).trim();
      if (lowercaseKeys) k = k.toLowerCase();
      tags[k] = p0.substring(eq + 1).trim();
    }
  }
  return tags;
}

class MailHeader {
  final String name;
  String value;
  String raw;
  MailHeader(this.name, this.value, this.raw);
}

class ParsedMailHeaders {
  final List<MailHeader> headers;
  final Map<String, String> map;
  final String body;
  ParsedMailHeaders(this.headers, this.map, this.body);
}

ParsedMailHeaders parseMailHeaders(Object raw) {
  String str;
  if (raw is Uint8List) {
    str = u8ToStr(raw);
  } else if (raw is List<int>) {
    str = u8ToStr(Uint8List.fromList(raw));
  } else {
    str = raw.toString();
  }

  int idx = str.indexOf('\r\n\r\n');
  String headStr = idx >= 0 ? str.substring(0, idx) : str;
  String bodyStr = idx >= 0 ? str.substring(idx + 4) : '';

  List<MailHeader> headers = [];
  var lines = headStr.split('\r\n');
  MailHeader? cur;

  for (var L in lines) {
    if (RegExp(r'^[ \t]').hasMatch(L)) {
      if (cur != null) cur.raw += '\r\n' + L;
      continue;
    }
    var m = RegExp(r'^([^:]+):\s*(.*)$').firstMatch(L);
    if (m != null) {
      if (cur != null) headers.add(cur);
      cur = MailHeader(m.group(1)!, m.group(2)!, L);
    } else if (cur != null) {
      cur.raw += '\r\n' + L;
    }
  }
  if (cur != null) headers.add(cur);

  for (var h in headers) {
    h.value = h.raw.replaceFirst(RegExp(r'^[^:]+:\s*'), '').replaceAll(RegExp(r'\r\n[ \t]+'), ' ');
  }

  Map<String, String> map = {};
  for (var h in headers) {
    var n = h.name.toLowerCase();
    if (n == 'subject') map['subject'] = h.value;
    else if (n == 'message-id') map['messageId'] = h.value;
    else if (n == 'date') map['date'] = h.value;
    else if (n == 'from') map['from'] = h.value;
    else if (n == 'to') map['to'] = h.value;
  }

  return ParsedMailHeaders(headers, map, bodyStr);
}
class EventEmitter {
  final Map<String, List<Function>> _listeners = {};

  void on(String event, Function listener) {
    _listeners.putIfAbsent(event, () => []).add(listener);
  }

  void off(String event, Function listener) {
    _listeners[event]?.remove(listener);
  }

  void once(String event, Function listener) {
    void wrapper([dynamic a, dynamic b, dynamic c, dynamic d]) {
      off(event, wrapper);
      if (listener is Function()) listener();
      else if (listener is Function(dynamic)) listener(a);
      else if (listener is Function(dynamic, dynamic)) listener(a, b);
      else if (listener is Function(dynamic, dynamic, dynamic)) listener(a, b, c);
      else if (listener is Function(dynamic, dynamic, dynamic, dynamic)) listener(a, b, c, d);
      else Function.apply(listener, [a, b, c, d].where((x) => x != null).toList());
    }
    on(event, wrapper);
  }

  void emit(String event, [dynamic a, dynamic b, dynamic c, dynamic d]) {
    final listeners = _listeners[event]?.toList() ?? [];
    for (final listener in listeners) {
      if (listener is Function()) listener();
      else if (listener is Function(dynamic)) listener(a);
      else if (listener is Function(dynamic, dynamic)) listener(a, b);
      else if (listener is Function(dynamic, dynamic, dynamic)) listener(a, b, c);
      else if (listener is Function(dynamic, dynamic, dynamic, dynamic)) listener(a, b, c, d);
      else Function.apply(listener, [a, b, c, d].where((x) => x != null).toList());
    }
  }

  int listenerCount(String event) {
    return _listeners[event]?.length ?? 0;
  }

  void removeAllListeners() {
    _listeners.clear();
  }
}
