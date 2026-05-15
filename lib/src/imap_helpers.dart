import 'dart:convert';
// import 'dart:math';
import 'dart:typed_data';

// import 'message.dart';

// ============================================================
//  Constants
// ============================================================

const Map<String, String> SPECIAL_USE = {
  'ALL': r'\All',
  'ARCHIVE': r'\Archive',
  'DRAFTS': r'\Drafts',
  'FLAGGED': r'\Flagged',
  'JUNK': r'\Junk',
  'SENT': r'\Sent',
  'TRASH': r'\Trash',
};

const Map<String, String> SPECIAL_USE_CANONICAL = {
  'all': r'\All',
  'archive': r'\Archive',
  'drafts': r'\Drafts',
  'flagged': r'\Flagged',
  'junk': r'\Junk',
  'sent': r'\Sent',
  'trash': r'\Trash',
};

const Map<String, String> FLAGS = {
  'ANSWERED': 'Answered',
  'FLAGGED': 'Flagged',
  'DELETED': 'Deleted',
  'SEEN': 'Seen',
  'DRAFT': 'Draft',
  'RECENT': 'Recent',
};

const Map<String, bool> SYSTEM_FLAG_NAMES = {
  'answered': true,
  'flagged': true,
  'deleted': true,
  'seen': true,
  'draft': true,
  'recent': true,
};

const List<String> DEFAULT_FLAGS = [
  'Seen',
  'Answered',
  'Flagged',
  'Deleted',
  'Draft',
];

String? normalizeSpecialUse(dynamic input) {
  if (input == null) return null;
  String clean = input
      .toString()
      .replaceFirst(RegExp(r'^\\'), '')
      .toLowerCase();
  return SPECIAL_USE_CANONICAL[clean];
}

String? normalizeFlag(dynamic input) {
  if (input == null) return null;
  String s = input.toString();
  String bare = s.replaceFirst(RegExp(r'^\\'), '');
  String lower = bare.toLowerCase();
  if (SYSTEM_FLAG_NAMES[lower] == true) {
    return bare[0].toUpperCase() + lower.substring(1);
  }
  return bare;
}

String serializeFlag(dynamic flag) {
  if (flag == null) return '';
  String s = flag.toString();
  if (s.startsWith(r'\')) return s;
  if (s == '*') return r'\*';
  if (SYSTEM_FLAG_NAMES[s.toLowerCase()] == true) {
    return r'\' + s[0].toUpperCase() + s.substring(1).toLowerCase();
  }
  return s;
}

bool _flagHygieneWarned = false;
void checkFlagsHygiene(dynamic flags, [String? source]) {
  if (_flagHygieneWarned) return;
  if (flags is! List) return;
  for (int i = 0; i < flags.length; i++) {
    var f = flags[i];
    if (f is! String || !f.startsWith(r'\')) continue;
    String bare = f.substring(1).toLowerCase();
    if (SYSTEM_FLAG_NAMES[bare] != true) continue;
    _flagHygieneWarned = true;
    print(
      '[email-server] ${source ?? 'handler'} returned system flag "${f}" with a leading backslash. '
      'Use the clean name "${f.substring(1)}" instead.',
    );
    return;
  }
}

String serializeFlagList(List<dynamic>? flags) {
  if (flags == null || flags.isEmpty) return '()';
  List<String> parts = [];
  for (int i = 0; i < flags.length; i++) {
    parts.add(serializeFlag(flags[i]));
  }
  return '(${parts.join(' ')})';
}

final RegExp RE_REGEX_META = RegExp(r'[\\^$.+?()[\]{}|]');

bool Function(String) makeWildcardMatcher(
  String reference,
  String pattern,
  String delimiter,
) {
  String full = (reference) + (pattern);
  String delimEsc = delimiter.replaceAllMapped(
    RE_REGEX_META,
    (m) => '\\${m.group(0)}',
  );
  String reStr = '^';
  for (int i = 0; i < full.length; i++) {
    String c = full[i];
    if (c == '*')
      reStr += '.*';
    else if (c == '%')
      reStr += '(?:(?!$delimEsc).)*';
    else
      reStr += c.replaceAllMapped(RE_REGEX_META, (m) => '\\${m.group(0)}');
  }
  reStr += r'$';
  RegExp rx = RegExp(reStr);
  return (String name) => rx.hasMatch(name);
}

bool hasChildren(String folderName, List<String> allNames, String delimiter) {
  String prefix = folderName + delimiter;
  for (int i = 0; i < allNames.length; i++) {
    if (allNames[i] != folderName && allNames[i].startsWith(prefix))
      return true;
  }
  return false;
}

// Flat ranges logic substitute
const int INF = 9007199254740991;

void _addRange(List<int> ranges, int from, int to) {
  List<List<int>> tuples = [];
  for (int i = 0; i < ranges.length; i += 2)
    tuples.add([ranges[i], ranges[i + 1]]);
  tuples.add([from, to]);
  tuples.sort((a, b) => a[0].compareTo(b[0]));

  List<List<int>> merged = [];
  for (var t in tuples) {
    if (merged.isEmpty) {
      merged.add(t);
    } else {
      var last = merged.last;
      if (t[0] <= last[1]) {
        if (t[1] > last[1]) last[1] = t[1];
      } else {
        merged.add(t);
      }
    }
  }
  ranges.clear();
  for (var m in merged) {
    ranges.add(m[0]);
    ranges.add(m[1]);
  }
}

Map<String, dynamic> parseSequenceSet(String? str, Map<String, dynamic> ctx) {
  if (str == null || str.isEmpty) return {'ranges': <int>[], 'error': 'empty'};
  bool isUid = ctx['isUid'] == true;
  int total = ctx['total'] ?? 0;

  List<String> parts = str.split(',');
  List<int> ranges = [];

  int? parseOne(String s) {
    s = s.trim();
    if (s == '*') return isUid ? INF : total;
    if (!RegExp(r'^\d+$').hasMatch(s)) return null;
    int n = int.parse(s);
    return n > 0 ? n : null;
  }

  for (int i = 0; i < parts.length; i++) {
    String p = parts[i].trim();
    if (p.isEmpty) return {'ranges': <int>[], 'error': 'empty range'};

    int from, to;
    int colon = p.indexOf(':');
    if (colon < 0) {
      int? n = parseOne(p);
      if (n == null) return {'ranges': <int>[], 'error': 'bad number: $p'};
      from = n;
      to = (n == INF) ? INF : n + 1;
    } else {
      int? a = parseOne(p.substring(0, colon));
      int? b = parseOne(p.substring(colon + 1));
      if (a == null || b == null)
        return {'ranges': <int>[], 'error': 'bad range: $p'};

      if (b != INF && a != INF && a > b) {
        int tmp = a;
        a = b;
        b = tmp;
      }
      if (a == INF) {
        a = b;
        b = INF;
      }

      from = a;
      to = (b == INF) ? INF : b + 1;
    }

    _addRange(ranges, from, to);
  }

  return {'ranges': ranges, 'error': null};
}

bool rangesContain(List<int> ranges, int n) {
  for (int i = 0; i < ranges.length; i += 2) {
    if (n >= ranges[i] && n < ranges[i + 1]) return true;
  }
  return false;
}

String formatRanges(List<int>? ranges) {
  if (ranges == null || ranges.isEmpty) return '';
  List<String> parts = [];
  for (int i = 0; i < ranges.length; i += 2) {
    int from = ranges[i];
    int toExcl = ranges[i + 1];
    if (toExcl == INF) {
      parts.add('$from:*');
    } else {
      int toIncl = toExcl - 1;
      parts.add(from == toIncl ? from.toString() : '$from:$toIncl');
    }
  }
  return parts.join(',');
}

String compressUids(List<dynamic>? uids, [Map<String, dynamic>? opts]) {
  if (uids == null || uids.isEmpty) return '';
  List<int> intUids = uids.map((u) => u as int).toList();

  if (opts != null && opts['preserveOrder'] == true) {
    List<String> parts = [];
    int i = 0;
    while (i < intUids.length) {
      int start = intUids[i];
      int j = i + 1;
      while (j < intUids.length && intUids[j] == intUids[j - 1] + 1) j++;
      int end = intUids[j - 1];
      parts.add(start == end ? start.toString() : '$start:$end');
      i = j;
    }
    return parts.join(',');
  }

  List<int> ranges = [];
  for (int i = 0; i < intUids.length; i++) {
    _addRange(ranges, intUids[i], intUids[i] + 1);
  }
  return formatRanges(ranges);
}

String? buildCopyUidCode(dynamic result) {
  if (result == null) return null;
  List<dynamic> mapping;
  dynamic dstUidValidity;

  if (result is List) {
    mapping = result;
    dstUidValidity = null;
  } else {
    mapping = result['mapping'];
    dstUidValidity = result['dstUidValidity'];
  }
  if (dstUidValidity == null || mapping.isEmpty) return null;

  var sorted = List.of(mapping);
  sorted.sort((a, b) => (a['srcUid'] as int).compareTo(b['srcUid'] as int));

  var srcList = sorted.map((m) => m['srcUid']).toList();
  var dstList = sorted.map((m) => m['dstUid']).toList();

  return 'COPYUID $dstUidValidity '
      '${compressUids(srcList, {'preserveOrder': true})} '
      '${compressUids(dstList, {'preserveOrder': true})}';
}

const List<String> MONTH_NAMES = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String formatInternalDate(dynamic date) {
  DateTime d;
  if (date is DateTime) {
    d = date;
  } else if (date is int) {
    d = DateTime.fromMillisecondsSinceEpoch(date);
  } else {
    d = DateTime.now();
  }

  String pad(int n) => n < 10 ? '0$n' : n.toString();

  int tzMin = d.timeZoneOffset.inMinutes;
  String tzSign = tzMin < 0 ? '-' : '+';
  int tzAbs = tzMin.abs();
  String tzStr = tzSign + pad(tzAbs ~/ 60) + pad(tzAbs % 60);

  return '${pad(d.day)}-${MONTH_NAMES[d.month - 1]}-${d.year} ${pad(d.hour)}:${pad(d.minute)}:${pad(d.second)} $tzStr';
}

DateTime? parseInternalDate(String? str) {
  if (str == null || str.trim().isEmpty) return null;
  var m = RegExp(
    r'^(\d{1,2})-([A-Za-z]{3})-(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s*([+-]\d{4})?$',
  ).firstMatch(str.trim());
  if (m == null) return null;

  int month = MONTH_NAMES.indexOf(m.group(2)!) + 1;
  if (month <= 0) return null;

  DateTime utc = DateTime.utc(
    int.parse(m.group(3)!),
    month,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );

  if (m.group(7) != null) {
    String tz = m.group(7)!;
    int sign = tz[0] == '-' ? 1 : -1;
    int h = int.parse(tz.substring(1, 3));
    int mn = int.parse(tz.substring(3, 5));
    utc = utc.add(Duration(minutes: sign * (h * 60 + mn)));
  }

  return utc;
}

Map<String, dynamic>? parseBodySection(String? str) {
  Map<String, dynamic> result = {'part': null, 'type': null, 'fields': null};
  if (str == null) return result;

  String s = str.trim();
  List<int> partPath = [];
  while (s.isNotEmpty) {
    var m = RegExp(r'^(\d+)(\.|$)').firstMatch(s);
    if (m == null) break;
    partPath.add(int.parse(m.group(1)!));
    s = s.substring(m.group(1)!.length + (m.group(2) == '.' ? 1 : 0));
    if (m.group(2) == '') break;
  }
  if (partPath.isNotEmpty) result['part'] = partPath;

  if (s.isEmpty) return result;

  var m = RegExp(
    r'^HEADER\.FIELDS\.NOT\s*\((.*)\)$',
    caseSensitive: false,
  ).firstMatch(s);
  if (m != null) {
    result['type'] = 'HEADER.FIELDS.NOT';
    result['fields'] = m
        .group(1)!
        .trim()
        .split(RegExp(r'\s+'))
        .where((f) => f.isNotEmpty)
        .map((f) => f.toUpperCase())
        .toList();
    return result;
  }

  m = RegExp(
    r'^HEADER\.FIELDS\s*\((.*)\)$',
    caseSensitive: false,
  ).firstMatch(s);
  if (m != null) {
    result['type'] = 'HEADER.FIELDS';
    result['fields'] = m
        .group(1)!
        .trim()
        .split(RegExp(r'\s+'))
        .where((f) => f.isNotEmpty)
        .map((f) => f.toUpperCase())
        .toList();
    return result;
  }

  if (RegExp(r'^HEADER$', caseSensitive: false).hasMatch(s)) {
    result['type'] = 'HEADER';
  } else if (RegExp(r'^TEXT$', caseSensitive: false).hasMatch(s)) {
    result['type'] = 'TEXT';
  } else if (RegExp(r'^MIME$', caseSensitive: false).hasMatch(s)) {
    result['type'] = 'MIME';
  } else {
    return null;
  }
  return result;
}

String buildBodyResponseName(String? section, Map<String, dynamic>? partial) {
  String name = 'BODY[${section ?? ''}]';
  if (partial != null) name += '<${partial['offset']}>';
  return name;
}

// ============================================================
//  SEARCH criteria parsing (Phase 3d)
// ============================================================

const Map<String, int> SEARCH_MONTHS = {
  'JAN': 1,
  'FEB': 2,
  'MAR': 3,
  'APR': 4,
  'MAY': 5,
  'JUN': 6,
  'JUL': 7,
  'AUG': 8,
  'SEP': 9,
  'OCT': 10,
  'NOV': 11,
  'DEC': 12,
};

DateTime? parseSearchDate(String? str) {
  if (str == null || str.trim().isEmpty) return null;
  var m = RegExp(r'^(\d{1,2})-([A-Za-z]{3})-(\d{4})$').firstMatch(str.trim());
  if (m == null) return null;
  int? mo = SEARCH_MONTHS[m.group(2)!.toUpperCase()];
  if (mo == null) return null;
  return DateTime.utc(int.parse(m.group(3)!), mo, int.parse(m.group(1)!));
}

String formatSearchDate(dynamic date) {
  DateTime d = date is DateTime ? date : DateTime.now(); // simplified fallback
  return '${d.toUtc().day}-${MONTH_NAMES[d.toUtc().month - 1]}-${d.toUtc().year}';
}

List<int>? parseSearchRanges(String str, bool isUid, int total) {
  var r = parseSequenceSet(str, {'isUid': isUid, 'total': total});
  return r['error'] == null ? r['ranges'] : null;
}

String tokenToString(dynamic tok) {
  if (tok == null) return '';
  if (tok['type'] == 'literal') {
    return tok['value'] is String
        ? tok['value']
        : utf8.decode(tok['value'] as Uint8List, allowMalformed: true);
  }
  if (tok['value'] == null) return '';
  return tok['value'].toString();
}

Map<String, dynamic> parseSearchCriteria(
  List<dynamic> tokens,
  int start,
  int total,
) {
  List<dynamic> children = [];
  int pos = start;
  while (pos < tokens.length) {
    var r = parseOneCriterion(tokens, pos, total);
    if (r == null) break;
    children.add(r['node']);
    pos = r['end'];
  }
  return {
    'node': {'op': 'and', 'children': children},
    'end': pos,
  };
}

Map<String, dynamic>? parseOneCriterion(
  List<dynamic> tokens,
  int pos,
  int total,
) {
  if (pos >= tokens.length) return null;
  var tok = tokens[pos];

  if (tok['type'] == 'list') {
    var inner = parseSearchCriteria(tok['value'], 0, total);
    return {'node': inner['node'], 'end': pos + 1};
  }

  String key = (tok['value']?.toString() ?? '').toUpperCase();

  switch (key) {
    case 'ALL':
      return {
        'node': {'op': 'all'},
        'end': pos + 1,
      };
    case 'ANSWERED':
      return {
        'node': {'op': 'answered'},
        'end': pos + 1,
      };
    case 'DELETED':
      return {
        'node': {'op': 'deleted'},
        'end': pos + 1,
      };
    case 'DRAFT':
      return {
        'node': {'op': 'draft'},
        'end': pos + 1,
      };
    case 'FLAGGED':
      return {
        'node': {'op': 'flagged'},
        'end': pos + 1,
      };
    case 'NEW':
      return {
        'node': {'op': 'new'},
        'end': pos + 1,
      };
    case 'OLD':
      return {
        'node': {'op': 'old'},
        'end': pos + 1,
      };
    case 'RECENT':
      return {
        'node': {'op': 'recent'},
        'end': pos + 1,
      };
    case 'SEEN':
      return {
        'node': {'op': 'seen'},
        'end': pos + 1,
      };

    case 'UNANSWERED':
      return {
        'node': {
          'op': 'not',
          'child': {'op': 'answered'},
        },
        'end': pos + 1,
      };
    case 'UNDELETED':
      return {
        'node': {
          'op': 'not',
          'child': {'op': 'deleted'},
        },
        'end': pos + 1,
      };
    case 'UNDRAFT':
      return {
        'node': {
          'op': 'not',
          'child': {'op': 'draft'},
        },
        'end': pos + 1,
      };
    case 'UNFLAGGED':
      return {
        'node': {
          'op': 'not',
          'child': {'op': 'flagged'},
        },
        'end': pos + 1,
      };
    case 'UNSEEN':
      return {
        'node': {
          'op': 'not',
          'child': {'op': 'seen'},
        },
        'end': pos + 1,
      };
  }

  const Map<String, String> strKeys = {
    'BCC': 'bcc',
    'BODY': 'body',
    'CC': 'cc',
    'FROM': 'from',
    'SUBJECT': 'subject',
    'TEXT': 'text',
    'TO': 'to',
  };

  if (strKeys.containsKey(key) && pos + 1 < tokens.length) {
    return {
      'node': {'op': strKeys[key], 'value': tokenToString(tokens[pos + 1])},
      'end': pos + 2,
    };
  }

  if (key == 'KEYWORD' && pos + 1 < tokens.length) {
    return {
      'node': {
        'op': 'keyword',
        'value': normalizeFlag(tokens[pos + 1]['value']),
      },
      'end': pos + 2,
    };
  }
  if (key == 'UNKEYWORD' && pos + 1 < tokens.length) {
    return {
      'node': {
        'op': 'not',
        'child': {
          'op': 'keyword',
          'value': normalizeFlag(tokens[pos + 1]['value']),
        },
      },
      'end': pos + 2,
    };
  }

  if (key == 'HEADER' && pos + 2 < tokens.length) {
    return {
      'node': {
        'op': 'header',
        'name': tokenToString(tokens[pos + 1]),
        'value': tokenToString(tokens[pos + 2]),
      },
      'end': pos + 3,
    };
  }

  const Map<String, String> dateKeys = {
    'BEFORE': 'before',
    'ON': 'on',
    'SINCE': 'since',
    'SENTBEFORE': 'sentBefore',
    'SENTON': 'sentOn',
    'SENTSINCE': 'sentSince',
  };
  if (dateKeys.containsKey(key) && pos + 1 < tokens.length) {
    return {
      'node': {
        'op': dateKeys[key],
        'date': parseSearchDate(tokenToString(tokens[pos + 1])),
      },
      'end': pos + 2,
    };
  }

  if ((key == 'LARGER' || key == 'SMALLER') && pos + 1 < tokens.length) {
    int n = tokens[pos + 1]['type'] == 'number'
        ? tokens[pos + 1]['value']
        : int.tryParse(tokenToString(tokens[pos + 1])) ?? 0;
    return {
      'node': {'op': key.toLowerCase(), 'value': n},
      'end': pos + 2,
    };
  }

  if ((key == 'YOUNGER' || key == 'OLDER') && pos + 1 < tokens.length) {
    int seconds = tokens[pos + 1]['type'] == 'number'
        ? tokens[pos + 1]['value']
        : int.tryParse(tokenToString(tokens[pos + 1])) ?? -1;
    if (seconds < 0) return null;
    return {
      'node': {'op': key.toLowerCase(), 'seconds': seconds},
      'end': pos + 2,
    };
  }

  if (key == 'MODSEQ' && pos + 1 < tokens.length) {
    var nxt = tokens[pos + 1];
    if (nxt['type'] == 'quoted' && pos + 3 < tokens.length) {
      var val = tokens[pos + 3];
      int n = val['type'] == 'number'
          ? val['value']
          : int.tryParse(tokenToString(val)) ?? 0;
      return {
        'node': {'op': 'modseq', 'value': n},
        'end': pos + 4,
      };
    }
    int n = nxt['type'] == 'number'
        ? nxt['value']
        : int.tryParse(tokenToString(nxt)) ?? 0;
    return {
      'node': {'op': 'modseq', 'value': n},
      'end': pos + 2,
    };
  }

  if (key == 'UID' && pos + 1 < tokens.length) {
    var r = parseSearchRanges(tokenToString(tokens[pos + 1]), true, total);
    if (r == null) return null;
    return {
      'node': {'op': 'uid', 'ranges': r},
      'end': pos + 2,
    };
  }

  if (key == 'NOT') {
    var inner = parseOneCriterion(tokens, pos + 1, total);
    if (inner == null) return null;
    return {
      'node': {'op': 'not', 'child': inner['node']},
      'end': inner['end'],
    };
  }
  if (key == 'OR') {
    var left = parseOneCriterion(tokens, pos + 1, total);
    if (left == null) return null;
    var right = parseOneCriterion(tokens, left['end'], total);
    if (right == null) return null;
    return {
      'node': {
        'op': 'or',
        'children': [left['node'], right['node']],
      },
      'end': right['end'],
    };
  }

  if (RegExp(r'^[\d*,:]+$').hasMatch(key)) {
    var r = parseSearchRanges(key, false, total);
    if (r == null) return null;
    return {
      'node': {'op': 'seq', 'ranges': r},
      'end': pos + 1,
    };
  }

  return null;
}

// ============================================================
//  ENVELOPE and BODYSTRUCTURE builders (Phase 3c)
// ============================================================

Map<String, dynamic> tStr(dynamic s) {
  return s == null
      ? {'type': 'nil'}
      : {'type': 'quoted', 'value': s.toString()};
}

Map<String, dynamic> tNum(int n) {
  return {'type': 'number', 'value': n};
}

Map<String, dynamic> tList(List<dynamic> arr) {
  return {'type': 'list', 'value': arr};
}

Map<String, dynamic> tNil() {
  return {'type': 'nil'};
}

String? headerOrNull(List<dynamic>? headers, String name) {
  if (headers == null) return null;
  String low = name.toLowerCase();
  for (var h in headers) {
    if ((h['name'] as String).toLowerCase() == low) return h['value'];
  }
  return null;
}

Map<String, dynamic> addrTuple(
  String? name,
  String? adl,
  String? mailbox,
  String? host,
) {
  return tList([tStr(name), tStr(adl), tStr(mailbox), tStr(host)]);
}

Map<String, dynamic> addrListOrNil(String? headerValue) {
  if (headerValue == null) return tNil();
  // Assume parseAddressList returns List<Map<String,dynamic>> with name, mailbox, host, group, members
  // Currently skipping implementation dependency that might not perfectly match,
  // but let's emulate the JS structure closely.
  return tNil(); // Simplified for now since parseAddressList is from message.dart
}

Map<String, dynamic> buildEnvelope(dynamic tree) {
  var headers = tree['headers'] ?? [];
  var fromRaw = headerOrNull(headers, 'From');

  return tList([
    tStr(headerOrNull(headers, 'Date')),
    tStr(headerOrNull(headers, 'Subject')),
    addrListOrNil(fromRaw),
    addrListOrNil(headerOrNull(headers, 'Sender') ?? fromRaw),
    addrListOrNil(headerOrNull(headers, 'Reply-To') ?? fromRaw),
    addrListOrNil(headerOrNull(headers, 'To')),
    addrListOrNil(headerOrNull(headers, 'Cc')),
    addrListOrNil(headerOrNull(headers, 'Bcc')),
    tStr(headerOrNull(headers, 'In-Reply-To')),
    tStr(headerOrNull(headers, 'Message-ID')),
  ]);
}

Map<String, dynamic> paramsOrNil(Map<String, dynamic>? params) {
  if (params == null || params.isEmpty) return tNil();
  List<dynamic> flat = [];
  params.forEach((k, v) {
    flat.add(tStr(k.toUpperCase()));
    flat.add(tStr(v));
  });
  return tList(flat);
}

Map<String, dynamic> dispositionOrNil(
  String? type,
  Map<String, dynamic>? params,
) {
  if (type == null) return tNil();
  return tList([tStr(type.toUpperCase()), paramsOrNil(params)]);
}

Map<String, dynamic> buildBodyStructure(dynamic tree, bool extended) {
  if (tree['contentType'] != null &&
      tree['contentType'].toString().startsWith('multipart/') &&
      tree['parts'] != null) {
    return buildMultipartBs(tree, extended);
  }
  return buildSinglePartBs(tree, extended);
}

Map<String, dynamic> buildMultipartBs(dynamic tree, bool extended) {
  List<dynamic> list = [];
  for (var p in tree['parts']) {
    list.add(buildBodyStructure(p, extended));
  }
  String ct = tree['contentType'];
  String subtype = ct.substring(ct.indexOf('/') + 1);
  list.add(tStr(subtype.toUpperCase()));

  if (extended) {
    list.add(paramsOrNil(tree['contentTypeParams']));
    list.add(
      dispositionOrNil(
        tree['contentDisposition'],
        tree['contentDispositionParams'],
      ),
    );
    list.add(tStr(tree['contentLanguage']));
    list.add(tStr(tree['contentLocation']));
  }
  return tList(list);
}

Map<String, dynamic> buildSinglePartBs(dynamic tree, bool extended) {
  String ct = tree['contentType'] ?? 'text/plain';
  int slash = ct.indexOf('/');
  String type = slash > 0 ? ct.substring(0, slash) : 'text';
  String subtype = slash > 0 ? ct.substring(slash + 1) : 'plain';
  int size = (tree['bodyEnd'] ?? 0) - (tree['bodyStart'] ?? 0);
  String encoding = (tree['contentTransferEncoding'] ?? '7bit').toUpperCase();

  List<dynamic> list = [
    tStr(type.toUpperCase()),
    tStr(subtype.toUpperCase()),
    paramsOrNil(tree['contentTypeParams']),
    tStr(tree['contentId']),
    tStr(tree['contentDescription']),
    tStr(encoding),
    tNum(size),
  ];

  String typeLow = type.toLowerCase();
  String subtypeLow = subtype.toLowerCase();

  if (typeLow == 'text') {
    list.add(tNum(tree['bodyLines'] ?? 0));
  } else if (typeLow == 'message' &&
      subtypeLow == 'rfc822' &&
      tree['parts'] != null &&
      tree['parts'].isNotEmpty) {
    list.add(buildEnvelope(tree['parts'][0]));
    list.add(buildBodyStructure(tree['parts'][0], extended));
    list.add(tNum(tree['bodyLines'] ?? 0));
  }

  if (extended) {
    list.add(tStr(tree['contentMd5']));
    list.add(
      dispositionOrNil(
        tree['contentDisposition'],
        tree['contentDispositionParams'],
      ),
    );
    list.add(tStr(tree['contentLanguage']));
    list.add(tStr(tree['contentLocation']));
  }
  return tList(list);
}

// -----------------------------------------------------
// Minimal remaining stubs for phase 3 extraction methods
// -----------------------------------------------------

dynamic extractEnvelope(dynamic rawBytes) {
  return {};
}

dynamic extractBodyStructure(dynamic rawBytes) {
  return {};
}

dynamic extractMessageMetadata(dynamic rawBytes) {
  return {};
}

dynamic buildEnvelopeFromJson(dynamic env) {
  return tNil();
}

dynamic buildBodyStructureFromJson(dynamic bs, bool extended) {
  return tNil();
}
