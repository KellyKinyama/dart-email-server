import 'dart:typed_data';
import 'utils.dart'; // toU8, u8ToStr, concatU8, asciiEqCI, isDigit, indexOfCRLF

// ============================================================
//  Constants
// ============================================================

const Map<int, String> smtpReplyClass = {
  2: 'success',
  3: 'intermediate',
  4: 'tempfail',
  5: 'permfail',
};

const Map<int, String> smtpReplyMeaning = {
  211: 'SystemStatus',
  214: 'Help',
  220: 'ServiceReady',
  221: 'ServiceClosing',
  235: 'AuthSuccessful',
  250: 'Ok',
  251: 'UserNotLocalWillForward',
  252: 'CannotVrfyAccepts',
  334: 'AuthContinue',
  354: 'StartMailInput',
  420: 'Timeout',
  421: 'ServiceNotAvailable',
  450: 'MailboxUnavailable',
  451: 'LocalError',
  452: 'InsufficientStorage',
  454: 'TempAuthFailure',
  500: 'SyntaxError',
  501: 'SyntaxParamError',
  502: 'NotImplemented',
  503: 'BadSequence',
  504: 'ParamNotImplemented',
  521: 'DoesNotAcceptMail',
  530: 'AuthRequired',
  535: 'AuthInvalid',
  550: 'MailboxUnavailable',
  551: 'UserNotLocal',
  552: 'ExceededStorage',
  553: 'MailboxNameNotAllowed',
  554: 'TransactionFailed',
  555: 'ParamNotRecognized',
};

const Map<String, String> enhancedStatus = {
  '2.0.0': 'Ok',
  '2.1.0': 'OriginatorValid',
  '2.1.5': 'DestinationValid',
  '2.6.0': 'MessageAccepted',
  '2.7.0': 'AuthSuccessful',
  '4.2.1': 'MailboxBusy',
  '4.2.2': 'MailboxFull',
  '4.3.0': 'SystemError',
  '4.3.1': 'SystemFull',
  '4.4.0': 'NetworkError',
  '4.4.2': 'ConnectionTimeout',
  '4.7.0': 'TempAuthFailure',
  '5.1.1': 'MailboxNotFound',
  '5.1.3': 'BadDestinationSyntax',
  '5.1.6': 'DestinationChanged',
  '5.1.10': 'RecipientSyntaxError',
  '5.2.2': 'MailboxFull',
  '5.2.3': 'MessageTooLarge',
  '5.3.2': 'SystemNotAccepting',
  '5.3.4': 'MessageSizeExceeded',
  '5.5.1': 'BadCommand',
  '5.5.2': 'SyntaxError',
  '5.5.4': 'BadParam',
  '5.6.0': 'MediaError',
  '5.7.0': 'SecurityPolicy',
  '5.7.1': 'DeliveryNotAuthorized',
  '5.7.8': 'AuthCredentialsInvalid',
};

const Map<String, String> enhancedSubject = {
  '0': 'other',
  '1': 'addressing',
  '2': 'mailbox',
  '3': 'mail-system',
  '4': 'network-routing',
  '5': 'protocol',
  '6': 'media',
  '7': 'security',
};

const Map<String, String> contextCode = {
  'MAIL_FROM_OK': '2.1.0',
  'RCPT_TO_OK': '2.1.5',
  'DATA_OK': '2.6.0',
  'AUTH_SUCCESS': '2.7.0',
  'AUTH_REQUIRED': '5.7.0',
  'AUTH_INVALID': '5.7.8',
  'POLICY_VIOLATION': '5.7.1',
  'MAILBOX_NOT_FOUND': '5.1.1',
  'MAILBOX_SYNTAX': '5.1.3',
  'MAILBOX_FULL': '4.2.2',
  'SYSTEM_ERROR': '4.3.0',
  'NETWORK_ERROR': '4.4.0',
  'CONNECTION_TIMEOUT': '4.4.2',
};

final Set<String> skipEnhanced = {'HELO', 'EHLO', 'LHLO'};

const Map<String, String> authCanon = {
  'PLAIN': 'PLAIN',
  'LOGIN': 'LOGIN',
  'XOAUTH2': 'XOAUTH2',
  'OAUTHBEARER': 'OAUTHBEARER',
  'CRAM-MD5': 'CRAM-MD5',
  'CRAMMD5': 'CRAM-MD5',
  'SCRAM-SHA-1': 'SCRAM-SHA-1',
  'SCRAM-SHA1': 'SCRAM-SHA-1',
  'SCRAM-SHA-256': 'SCRAM-SHA-256',
  'SCRAM-SHA256': 'SCRAM-SHA-256',
  'GSSAPI': 'GSSAPI',
  'NTLM': 'NTLM',
  'ANONYMOUS': 'ANONYMOUS',
  'EXTERNAL': 'EXTERNAL',
};

bool looksLikeReply(Uint8List u8) {
  if (u8.length < 6) return false;
  return isDigit(u8[0]) &&
      isDigit(u8[1]) &&
      isDigit(u8[2]) &&
      (u8[3] == 32 || u8[3] == 45);
}

class ReplyClass {
  final String cls;
  final String meaning;
  ReplyClass(this.cls, this.meaning);
}

ReplyClass mapReplyCode(int code) {
  int cls = code ~/ 100;
  return ReplyClass(
    smtpReplyClass[cls] ?? 'unknown',
    smtpReplyMeaning[code] ?? 'Unspecified',
  );
}

class EnhancedCode {
  final String code;
  final String cls;
  final String subject;
  final String? label;
  EnhancedCode(this.code, this.cls, this.subject, this.label);
}

EnhancedCode mapEnhancedCode(String e) {
  List<String> parts = e.split('.');
  String cls = parts[0] == '2'
      ? 'success'
      : parts[0] == '4'
      ? 'tempfail'
      : 'permfail';
  return EnhancedCode(
    e,
    cls,
    enhancedSubject[parts[1]] ?? 'other',
    enhancedStatus[e],
  );
}

List<Uint8List> splitReplyLines(Uint8List u8) {
  List<Uint8List> lines = [];
  int start = 0;
  for (int i = 0; i + 1 < u8.length; i++) {
    if (u8[i] == 13 && u8[i + 1] == 10) {
      lines.add(Uint8List.sublistView(u8, start, i + 2));
      start = i + 2;
      i++;
    }
  }
  if (start < u8.length) lines.add(Uint8List.sublistView(u8, start));
  return lines;
}

final RegExp _reEnhanced = RegExp(r'^(\d\.\d+\.\d+)(?:\s|$)');
final RegExp _reKnownCap = RegExp(
  r'^(?:SIZE(?:\s+\d+)?|AUTH(?:=|\s)|STARTTLS|PIPELINING|CHUNKING|8BITMIME|SMTPUTF8|ENHANCEDSTATUSCODES|DSN|BINARYMIME|DELIVERBY|MT-PRIORITY|REQUIRETLS|ETRN|VRFY|HELP)\b',
  caseSensitive: false,
);

/// A parsed multi-line SMTP reply (e.g. EHLO response, status reply).
///
/// Strongly-typed view over the legacy `Map<String, dynamic>` returned by
/// [parseReplyBlock]. Use [SmtpReply.fromMap] to wrap an existing map and
/// [toMap] to convert back when interfacing with code that still consumes
/// the map form.
class SmtpReply {
  /// Numeric SMTP reply code (e.g. 250).
  final int code;

  /// Reply class label: 'success' | 'intermediate' | 'tempfail' | 'permfail'.
  final String cls;

  /// Human-readable meaning for [code], e.g. 'Ok'.
  final String meaning;

  /// Parsed enhanced status code (RFC 3463), if any.
  final EnhancedCode? enhanced;

  /// Per-line reply text (without the leading code/space-or-dash).
  final List<String> replyLines;

  /// True when this reply is a 250 multi-line capability list.
  final bool isEhloCaps;

  /// 334 AUTH challenge text, base64-encoded; null otherwise.
  final String? authChallenge;

  /// Parsed EHLO capabilities map, populated only when [isEhloCaps] is true.
  final Map<String, dynamic>? capabilities;

  /// 220 banner domain (greeting), if available.
  final String? bannerDomain;

  const SmtpReply({
    required this.code,
    required this.cls,
    required this.meaning,
    this.enhanced,
    this.replyLines = const [],
    this.isEhloCaps = false,
    this.authChallenge,
    this.capabilities,
    this.bannerDomain,
  });

  /// Single-line text view (joined with spaces).
  String get text => replyLines.join(' ');

  bool get isSuccess => code >= 200 && code < 300;
  bool get isIntermediate => code >= 300 && code < 400;
  bool get isTempFail => code >= 400 && code < 500;
  bool get isPermFail => code >= 500 && code < 600;

  factory SmtpReply.fromMap(Map<String, dynamic> m) => SmtpReply(
    code: m['code'] as int,
    cls: (m['class'] as String?) ?? 'unknown',
    meaning: (m['meaning'] as String?) ?? 'Unspecified',
    enhanced: m['enhanced'] as EnhancedCode?,
    replyLines: (m['replyLines'] as List?)?.cast<String>() ?? const [],
    isEhloCaps: m['isEhloCaps'] == true,
    authChallenge: m['authChallenge'] as String?,
    capabilities: m['capabilities'] as Map<String, dynamic>?,
    bannerDomain: m['bannerDomain'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'type': 'REPLY',
    'code': code,
    'class': cls,
    'meaning': meaning,
    'enhanced': enhanced,
    'replyLines': replyLines,
    'isEhloCaps': isEhloCaps,
    if (authChallenge != null) 'authChallenge': authChallenge,
    if (capabilities != null) 'capabilities': capabilities,
    if (bannerDomain != null) 'bannerDomain': bannerDomain,
  };
}

/// Typed wrapper around [parseReplyBlock]. Prefer this in new code.
SmtpReply parseReplyBlockTyped(Uint8List u8) =>
    SmtpReply.fromMap(parseReplyBlock(u8));

Map<String, dynamic> parseReplyBlock(Uint8List u8) {
  List<Uint8List> lines = splitReplyLines(u8);
  int code = (u8[0] - 48) * 100 + (u8[1] - 48) * 10 + (u8[2] - 48);
  String? enhanced;

  List<String> texts = [];
  for (int i = 0; i < lines.length; i++) {
    Uint8List L = lines[i];
    int end = L.length;
    if (end >= 2 && L[end - 2] == 13 && L[end - 1] == 10) end -= 2;
    String txt = u8ToStr(Uint8List.sublistView(L, 4, end));
    texts.add(txt);
    if (enhanced == null) {
      Match? m = _reEnhanced.firstMatch(txt);
      if (m != null) enhanced = m.group(1);
    }
  }

  ReplyClass base = mapReplyCode(code);
  EnhancedCode? enh = enhanced != null ? mapEnhancedCode(enhanced) : null;

  bool isMulti = lines.length > 1 && u8[3] == 45;
  bool hasKnown = texts.any((t) => _reKnownCap.hasMatch(t));

  Map<String, dynamic> obj = {
    'type': 'REPLY',
    'code': code,
    'class': base.cls,
    'meaning': base.meaning,
    'enhanced': enh,
    'replyLines': List<String>.from(texts),
    'isEhloCaps': (code == 250) && (isMulti || hasKnown),
  };

  if (code == 334) {
    obj['authChallenge'] = texts.isNotEmpty ? texts[0].trim() : null;
    if (obj['authChallenge'] == '') obj['authChallenge'] = null;
  }

  if (code == 250 && obj['isEhloCaps'] == true) {
    obj['capabilities'] = extractEhloCapabilities(texts);
  }

  if (code == 220) {
    Match? m = RegExp(
      r'^([^\s]+)\s+',
    ).firstMatch(texts.isNotEmpty ? texts[0] : '');
    if (m != null) obj['bannerDomain'] = m.group(1);
  }

  return obj;
}

Map<String, dynamic> extractEhloCapabilities(List<String> lines) {
  Map<String, dynamic> caps = {
    'auth': {'mechanisms': <String>[], 'advertised': false},
    'other': <String, dynamic>{},
  };

  void addAuthMechs(String str) {
    caps['auth']['advertised'] = true;
    String norm = str.replaceFirst(
      RegExp(r'^AUTH[=\s]+', caseSensitive: false),
      '',
    );
    List<String> tokens = norm
        .split(RegExp(r'[,\s]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    for (String token in tokens) {
      String up = token.toUpperCase();
      String canon = authCanon[up] ?? up;
      if (!caps['auth']['mechanisms'].contains(canon)) {
        caps['auth']['mechanisms'].add(canon);
      }
    }
  }

  void addOther(String key, dynamic val) {
    String K = key.toUpperCase();
    dynamic V = (val is String && val.trim().isNotEmpty) ? val.trim() : true;
    if (caps['other'][K] == null) caps['other'][K] = V;
  }

  for (int idx = 0; idx < lines.length; idx++) {
    String line = lines[idx].trim();
    if (line.isEmpty) continue;
    String upper = line.toUpperCase();

    if (upper.startsWith('SIZE')) {
      Match? m = RegExp(
        r'^SIZE(?:\s+(\d+))?$',
        caseSensitive: false,
      ).firstMatch(line);
      if (m != null) {
        caps['size'] = m.group(1) != null ? int.parse(m.group(1)!) : true;
        continue;
      }
    }

    if (RegExp(r'^AUTH(?:[=\s]+)', caseSensitive: false).hasMatch(line)) {
      addAuthMechs(line);
      continue;
    }

    if (upper == 'STARTTLS') {
      caps['starttls'] = true;
      continue;
    }
    if (upper == 'PIPELINING') {
      caps['pipelining'] = true;
      continue;
    }
    if (upper == 'CHUNKING') {
      caps['chunking'] = true;
      continue;
    }
    if (upper == '8BITMIME') {
      caps['eightBitMime'] = true;
      continue;
    }
    if (upper == 'SMTPUTF8') {
      caps['smtputf8'] = true;
      continue;
    }
    if (upper == 'ENHANCEDSTATUSCODES') {
      caps['enhancedStatusCodes'] = true;
      continue;
    }
    if (upper == 'DSN') {
      caps['dsn'] = true;
      continue;
    }
    if (upper == 'BINARYMIME') {
      caps['binarymime'] = true;
      continue;
    }
    if (upper == 'DELIVERBY') {
      caps['deliverby'] = true;
      continue;
    }
    if (upper == 'MT-PRIORITY') {
      caps['mtPriority'] = true;
      continue;
    }
    if (upper == 'REQUIRETLS') {
      caps['requiretls'] = true;
      continue;
    }
    if (upper == 'ETRN') {
      caps['etrn'] = true;
      continue;
    }
    if (upper == 'VRFY') {
      caps['vrfy'] = true;
      continue;
    }
    if (upper == 'HELP') {
      caps['help'] = true;
      continue;
    }
    if (upper == 'PRDR') {
      caps['prdr'] = true;
      continue;
    }
    if (upper == 'XCLIENT') {
      caps['xclient'] = true;
      continue;
    }
    if (upper == 'XFORWARD') {
      caps['xforward'] = true;
      continue;
    }

    if (idx == 0) {
      caps['greeting'] = line;
      Match? m = RegExp(r'^([^\s]+)(?:\s|$)').firstMatch(line);
      if (m != null &&
          !RegExp(
            r'^(?:SIZE|AUTH|STARTTLS|PIPELINING|CHUNKING|8BITMIME|SMTPUTF8|ENHANCEDSTATUSCODES)\b',
            caseSensitive: false,
          ).hasMatch(m.group(1)!)) {
        caps['serverName'] = m.group(1);
      }
      continue;
    }

    Match? mKV = RegExp(
      r'^([A-Za-z0-9][A-Za-z0-9\-_.]*)(?:[=\s]+(.+))?$',
    ).firstMatch(line);
    if (mKV != null) {
      addOther(
        mKV.group(1)!,
        mKV.groupCount > 1 && mKV.group(2) != null ? mKV.group(2)! : true,
      );
      continue;
    }
  }

  return caps;
}

final RegExp _reCommand = RegExp(r'^([A-Za-z]{3,16})(?:\s+(.*))?$');

Map<String, dynamic> parseCommandLine(Uint8List u8) {
  String line = u8ToStr(u8).trim();
  Match? m = _reCommand.firstMatch(line);
  if (m == null) return {'type': 'UNKNOWN', 'raw': line};
  String cmd = m.group(1)!.toUpperCase();
  String rest = (m.groupCount > 1 && m.group(2) != null ? m.group(2)! : '')
      .trim();

  switch (cmd) {
    case 'HELO':
      return {'type': 'HELO', 'host': rest.isNotEmpty ? rest : null};
    case 'EHLO':
      return {'type': 'EHLO', 'host': rest.isNotEmpty ? rest : null};
    case 'LHLO':
      return {'type': 'LHLO', 'host': rest.isNotEmpty ? rest : null};

    case 'MAIL':
      {
        var p = parsePathWithParams(rest, 'FROM');
        if (p['err'] == true) return {'type': 'MAIL', 'error': 'SYNTAX'};
        return {'type': 'MAIL', 'from': p['address'], 'params': p['params']};
      }
    case 'RCPT':
      {
        var p = parsePathWithParams(rest, 'TO');
        if (p['err'] == true) return {'type': 'RCPT', 'error': 'SYNTAX'};
        return {'type': 'RCPT', 'to': p['address'], 'params': p['params']};
      }

    case 'AUTH':
      {
        if (rest.isEmpty) return {'type': 'AUTH', 'error': 'SYNTAX'};
        List<String> sp = rest.split(RegExp(r'\s+'));
        String mech = sp[0].toUpperCase();
        String? initial = sp.length > 1
            ? rest.substring(sp[0].length + 1).trim()
            : null;
        if (initial != null && initial.isEmpty) initial = null;
        return {'type': 'AUTH', 'mechanism': mech, 'initial': initial};
      }

    case 'STARTTLS':
      return {'type': 'STARTTLS'};
    case 'RSET':
      return {'type': 'RSET'};
    case 'NOOP':
      return rest.isNotEmpty
          ? {'type': 'NOOP', 'argument': rest}
          : {'type': 'NOOP'};
    case 'QUIT':
      return {'type': 'QUIT'};
    case 'VRFY':
      return {'type': 'VRFY', 'target': rest.isNotEmpty ? rest : null};
    case 'EXPN':
      return {'type': 'EXPN', 'list': rest.isNotEmpty ? rest : null};
    case 'HELP':
      return {'type': 'HELP', 'argument': rest.isNotEmpty ? rest : null};

    case 'DATA':
      return {'type': 'DATA_START'};
    case 'BDAT':
      return {'type': 'BDAT_HEADER_ONLY', 'raw': line};

    default:
      return {'type': 'UNKNOWN', 'raw': line};
  }
}

final RegExp _rePathFrom = RegExp(
  r'^(FROM)\s*:\s*<([^>]*)>\s*(.*)$',
  caseSensitive: false,
);
final RegExp _rePathTo = RegExp(
  r'^(TO)\s*:\s*<([^>]*)>\s*(.*)$',
  caseSensitive: false,
);
final Map<String, RegExp> _rePath = {'FROM': _rePathFrom, 'TO': _rePathTo};

Map<String, dynamic> parsePathWithParams(String rest, String expectedKey) {
  RegExp re =
      _rePath[expectedKey] ??
      RegExp(
        '^($expectedKey)\\s*:\\s*<([^>]*)>\\s*(.*)\$',
        caseSensitive: false,
      );
  Match? m = re.firstMatch(rest);
  if (m == null) return {'err': true};
  String address = m.group(2) ?? '';
  String tail = (m.groupCount > 2 ? m.group(3) ?? '' : '').trim();
  Map<String, dynamic>? params = parseEsmtpParams(tail);
  return {'address': address, 'params': params};
}

Map<String, dynamic> parseEsmtpParams(String tail) {
  Map<String, dynamic> params = {};
  if (tail.isEmpty) return params;
  List<String> parts = tail.split(RegExp(r'\s+'));
  for (String token in parts) {
    if (token.isEmpty) continue;
    int eq = token.indexOf('=');
    if (eq == -1) {
      String tk = token.toUpperCase();
      if (tk == 'SMTPUTF8') {
        params['smtputf8'] = true;
        continue;
      }
      if (tk == 'REQUIRETLS') {
        params['requiretls'] = true;
        continue;
      }
      params[tk] = true;
      continue;
    }
    String k = token.substring(0, eq).toUpperCase();
    String v = token.substring(eq + 1);

    if (k == 'BODY') {
      String vv = v.toUpperCase();
      if (vv == '7BIT' || vv == '8BITMIME' || vv == 'BINARYMIME')
        params['body'] = vv;
      else
        params['BODY'] = v;
      continue;
    }
    if (k == 'SIZE') {
      params['size'] = int.tryParse(v) ?? 0;
      continue;
    }
    if (k == 'SMTPUTF8') {
      params['smtputf8'] = true;
      continue;
    }
    if (k == 'RET') {
      String vv = v.toUpperCase();
      if (vv == 'FULL' || vv == 'HDRS')
        params['ret'] = vv;
      else
        params['RET'] = v;
      continue;
    }
    if (k == 'ENVID') {
      params['envid'] = decodeXtext(v);
      continue;
    }

    if (k == 'NOTIFY') {
      Map<String, bool> flags = {
        'never': false,
        'success': false,
        'failure': false,
        'delay': false,
      };
      List<String> tokens = v.split(',');
      for (String tkStr in tokens) {
        String tk = tkStr.trim().toUpperCase();
        if (tk == 'NEVER')
          flags['never'] = true;
        else if (tk == 'SUCCESS')
          flags['success'] = true;
        else if (tk == 'FAILURE')
          flags['failure'] = true;
        else if (tk == 'DELAY')
          flags['delay'] = true;
      }
      params['notify'] = flags;
      continue;
    }

    if (k == 'ORCPT') {
      int semi = v.indexOf(';');
      if (semi > 0) {
        params['orcpt'] = {
          'addrType': v.substring(0, semi).toLowerCase(),
          'addr': decodeXtext(v.substring(semi + 1)),
        };
      } else {
        params['orcpt'] = {'addrType': 'rfc822', 'addr': decodeXtext(v)};
      }
      continue;
    }

    params[k] = v;
  }
  return params;
}

String? decodeXtext(String? s) {
  if (s == null || !s.contains('+')) return s;
  return s.replaceAllMapped(RegExp(r'\+([0-9A-Fa-f]{2})'), (Match m) {
    return String.fromCharCode(int.parse(m.group(1)!, radix: 16));
  });
}

bool startsWithDATA(Uint8List u8) {
  return u8.length >= 4 && asciiEqCI(u8, 0, 'DATA');
}

bool startsWithBDAT(Uint8List u8) {
  return u8.length >= 4 && asciiEqCI(u8, 0, 'BDAT');
}

Map<String, dynamic> parseDATAframe(Uint8List u8) {
  if (u8.length == 4) return {'type': 'DATA', 'body': Uint8List(0)};
  Uint8List body = Uint8List.sublistView(u8, 4);

  Uint8List out = Uint8List(body.length);
  int w = 0;
  for (int i = 0; i < body.length; i++) {
    if (i >= 2 &&
        body[i - 2] == 13 &&
        body[i - 1] == 10 &&
        body[i] == 46 &&
        i + 1 < body.length &&
        body[i + 1] == 46) {
      out[w++] = 46;
      i++;
      continue;
    }
    out[w++] = body[i];
  }
  return {'type': 'DATA', 'body': Uint8List.sublistView(out, 0, w)};
}

Map<String, dynamic> parseBDATframe(Uint8List u8) {
  int headerEnd = findBdatHeaderEnd(u8);
  if (headerEnd < 4) return {'type': 'BDAT', 'error': 'SYNTAX'};
  String headerStr = u8ToStr(Uint8List.sublistView(u8, 0, headerEnd));
  Match? m = RegExp(
    r'^BDAT[\t ]+(\d+)(?:[\t ]+LAST)?$',
    caseSensitive: false,
  ).firstMatch(headerStr);
  if (m == null) return {'type': 'BDAT', 'error': 'SYNTAX'};
  int size = int.tryParse(m.group(1)!) ?? 0;
  bool hasLast = RegExp(r'\bLAST\b', caseSensitive: false).hasMatch(headerStr);
  Uint8List payload = Uint8List.sublistView(u8, headerEnd);
  if (payload.length != size)
    return {
      'type': 'BDAT',
      'error': 'SIZE_MISMATCH',
      'declared': size,
      'got': payload.length,
    };
  return {'type': 'BDAT', 'size': size, 'last': hasLast, 'chunk': payload};
}

int findBdatHeaderEnd(Uint8List u8) {
  int n = u8.length < 256 ? u8.length : 256;
  String s = u8ToStr(Uint8List.sublistView(u8, 0, n));
  Match? m = RegExp(
    r'^BDAT[\t ]+\d+(?:[\t ]+LAST)?',
    caseSensitive: false,
  ).firstMatch(s);
  return m != null ? m.group(0)!.length : -1;
}

Map<String, dynamic>? parseBdatHeaderLine(String lineStr) {
  Match? m = RegExp(
    r'^BDAT[\t ]+(\d+)(?:[\t ]+LAST)?$',
    caseSensitive: false,
  ).firstMatch(lineStr.trim());
  if (m == null) return null;
  return {
    'size': int.tryParse(m.group(1)!) ?? 0,
    'last': RegExp(r'\bLAST\b', caseSensitive: false).hasMatch(lineStr),
  };
}

Map<String, dynamic> parseSmtpFrame(dynamic u8Input) {
  Uint8List u8 = u8Input is Uint8List ? u8Input : toU8(u8Input.toString());
  if (looksLikeReply(u8)) return parseReplyBlock(u8);
  if (startsWithDATA(u8)) return parseDATAframe(u8);
  if (startsWithBDAT(u8)) return parseBDATframe(u8);
  return parseCommandLine(u8);
}

class ReadLineRec {
  final int start;
  final int endCRLF;
  ReadLineRec(this.start, this.endCRLF);
}

List<Uint8List> splitSmtpFrames(List<dynamic> incomingChunks) {
  int total = 0;
  List<Uint8List> parts = [];
  for (int i = 0; i < incomingChunks.length; i++) {
    var c = incomingChunks[i];
    Uint8List b;
    if (c is String)
      b = toU8(c);
    else if (c is Uint8List)
      b = c;
    else if (c is List<int>)
      b = Uint8List.fromList(c);
    else
      b = Uint8List(0);
    parts.add(b);
    total += b.length;
  }
  Uint8List buf = Uint8List(total);
  int off = 0;
  for (int j = 0; j < parts.length; j++) {
    buf.setAll(off, parts[j]);
    off += parts[j].length;
  }

  List<Uint8List> frames = [];
  int pos = 0;
  int len = buf.length;

  Uint8List sliceBytes(int s, int e) => Uint8List.sublistView(buf, s, e);

  int findCRLF(int from) {
    for (int k = from; k < len - 1; k++) {
      if (buf[k] == 13 && buf[k + 1] == 10) return k;
    }
    return -1;
  }

  ReadLineRec? readLineRec() {
    int e = findCRLF(pos);
    if (e == -1) return null;
    int start = pos;
    pos = e + 2;
    return ReadLineRec(start, e + 2);
  }

  Uint8List sliceNoCRLF(ReadLineRec rec) =>
      Uint8List.sublistView(buf, rec.start, rec.endCRLF - 2);

  bool isSp(int b) => b == 32;
  int toUpper(int b) => (b >= 97 && b <= 122) ? (b - 32) : b;

  bool looksLikeReplyRec(ReadLineRec rec) {
    int s = rec.start;
    int e = rec.endCRLF;
    if (e - s < 6) return false;
    return isDigit(buf[s]) &&
        isDigit(buf[s + 1]) &&
        isDigit(buf[s + 2]) &&
        (isSp(buf[s + 3]) || buf[s + 3] == 45);
  }

  Uint8List? readReplyBlock(ReadLineRec rec0) {
    int start = rec0.start;
    int lastEnd = rec0.endCRLF;
    if (isSp(buf[rec0.start + 3])) return sliceBytes(start, lastEnd);
    while (true) {
      ReadLineRec? n = readLineRec();
      if (n == null) {
        pos = start;
        return null;
      }
      if (!looksLikeReplyRec(n)) {
        pos = start;
        return null;
      }
      lastEnd = n.endCRLF;
      if (isSp(buf[n.start + 3])) break;
    }
    return sliceBytes(start, lastEnd);
  }

  bool isDATAline(ReadLineRec rec) {
    int s = rec.start;
    return (rec.endCRLF - s == 6 &&
        toUpper(buf[s]) == 68 &&
        toUpper(buf[s + 1]) == 65 &&
        toUpper(buf[s + 2]) == 84 &&
        toUpper(buf[s + 3]) == 65 &&
        buf[s + 4] == 13 &&
        buf[s + 5] == 10);
  }

  int findDataTerminator(int from) {
    for (int q = from + 2; q < len - 2; q++) {
      if (buf[q - 2] == 13 &&
          buf[q - 1] == 10 &&
          buf[q] == 46 &&
          buf[q + 1] == 13 &&
          buf[q + 2] == 10)
        return q - 2;
    }
    return -1;
  }

  Map<String, dynamic>? parseBdatHeaderRec(ReadLineRec rec) {
    String s = u8ToStr(sliceNoCRLF(rec));
    Match? m = RegExp(
      r'^BDAT[\t ]+(\d+)(?:[\t ]+LAST)?$',
      caseSensitive: false,
    ).firstMatch(s);
    return m != null ? {'size': int.tryParse(m.group(1)!) ?? 0} : null;
  }

  while (pos < len) {
    ReadLineRec? L = readLineRec();
    if (L == null) break;

    if (looksLikeReplyRec(L)) {
      Uint8List? rep = readReplyBlock(L);
      if (rep == null) break;
      frames.add(rep);
      continue;
    }

    if (isDATAline(L)) {
      Uint8List head = sliceNoCRLF(L);
      int bodyStart = L.endCRLF;
      int termAt = findDataTerminator(bodyStart);
      if (termAt == -1) {
        pos = L.start;
        break;
      }
      Uint8List body = sliceBytes(bodyStart, termAt);
      Uint8List out = Uint8List(head.length + body.length);
      out.setAll(0, head);
      out.setAll(head.length, body);
      frames.add(out);
      pos = termAt + 5;
      continue;
    }

    var bd = parseBdatHeaderRec(L);
    if (bd != null) {
      int payloadEnd = pos + (bd['size'] as int);
      if (payloadEnd > len) {
        pos = L.start;
        break;
      }
      Uint8List header = sliceNoCRLF(L);
      Uint8List payload = sliceBytes(pos, payloadEnd);
      Uint8List outB = Uint8List(header.length + payload.length);
      outB.setAll(0, header);
      outB.setAll(header.length, payload);
      frames.add(outB);
      pos = payloadEnd;
      continue;
    }

    frames.add(sliceNoCRLF(L));
  }

  return frames;
}

String buildReply(int code, Object message, {String? enhanced}) {
  final List<Object?> lines = message is List
      ? List<Object?>.from(message)
      : [message];
  String out = '';

  for (int i = 0; i < lines.length; i++) {
    String sep = (i < lines.length - 1) ? '-' : ' ';
    String prefix = '$code$sep';
    if (enhanced != null) prefix += '$enhanced ';
    out += '$prefix${lines[i]}\r\n';
  }

  return out;
}

String buildEhloReply(String hostname, [List<String>? capabilities]) {
  List<String> lines = [];
  lines.add(hostname);
  if (capabilities != null) {
    for (var c in capabilities) lines.add(c);
  }
  String out = '';
  for (int i = 0; i < lines.length; i++) {
    String sep = (i < lines.length - 1) ? '-' : ' ';
    out += '250$sep${lines[i]}\r\n';
  }
  return out;
}
