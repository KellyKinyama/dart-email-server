import 'dart:typed_data';

import 'utils.dart';

// ============================================================
//  Constants
// ============================================================

const int CR = 13;
const int LF = 10;
const int SP = 32;
const int HTAB = 9;
const int DQUOTE = 34;
const int BACKSLASH = 92;
const int LPAREN = 40;
const int RPAREN = 41;
const int LBRACE = 123;
const int RBRACE = 125;
const int LBRACKET = 91;
const int RBRACKET = 93;
const int STAR = 42;
const int PLUS = 43;
const int PERCENT = 37;
const int MINUS = 45;
const int DOT = 46;
const int UNDERSCORE = 95;
const int PLUS_SIGN = 43;
const int TILDE = 126;

// Token types returned by tokenizer
const String TOK_ATOM = 'atom'; // Deprecated
const String TOK_NUMBER = 'number'; // Deprecated
const String TOK_QUOTED = 'quoted'; // Deprecated
const String TOK_LITERAL = 'literal'; // Deprecated
const String TOK_LIST = 'list'; // Deprecated
const String TOK_NIL = 'nil'; // Deprecated
const String TOK_BRACKETED = 'bracketed'; // Deprecated

/// Structured representation of an IMAP protocol token.
sealed class ImapToken {
  final int end;
  ImapToken(this.end);

  dynamic get value;
  String get type;

  /// Backward-compat map-style access used by some helpers
  /// (e.g. parseSearchCriteria).
  ///
  /// `tok['value']` and `tok['type']` mirror the equivalent property; any
  /// other key returns `null`.
  dynamic operator [](Object? key) {
    if (key == 'value') return value;
    if (key == 'type') return type;
    return null;
  }
}

class AtomToken extends ImapToken {
  @override
  final String value;
  @override
  String get type => TOK_ATOM;

  /// For section references like BODY[TEXT]
  final String? section;

  /// For partial fetches like BODY[]<0.100>
  final Map<String, int?>? partial;

  AtomToken(this.value, int end, {this.section, this.partial}) : super(end);
}

class NumberToken extends ImapToken {
  @override
  final int value;
  @override
  String get type => TOK_NUMBER;
  NumberToken(this.value, int end) : super(end);
}

class QuotedToken extends ImapToken {
  @override
  final String value;
  @override
  String get type => TOK_QUOTED;
  QuotedToken(this.value, int end) : super(end);
}

class LiteralToken extends ImapToken {
  @override
  final Uint8List value;
  @override
  String get type => TOK_LITERAL;
  final bool nonSync;
  final int size;
  LiteralToken(this.value, int end, {this.nonSync = false, this.size = 0})
    : super(end);
}

class NilToken extends ImapToken {
  @override
  dynamic get value => null;
  @override
  String get type => TOK_NIL;
  NilToken(int end) : super(end);
}

class ListToken extends ImapToken {
  @override
  final List<ImapToken> value;
  @override
  String get type => TOK_LIST;
  ListToken(this.value, int end) : super(end);
}

class BracketedToken extends ImapToken {
  @override
  final String value;
  @override
  String get type => TOK_BRACKETED;
  BracketedToken(this.value, int end) : super(end);
}

class ResponseCodeToken extends ImapToken {
  @override
  final dynamic value;
  @override
  String get type => 'respcode';
  ResponseCodeToken(this.value, int end) : super(end);
}

/// Represents a parsed IMAP command.
class ImapCommand {
  final String tag;
  final String name;
  final List<ImapToken> args;

  ImapCommand({required this.tag, required this.name, required this.args});

  Map<String, dynamic> toMap() => {'tag': tag, 'name': name, 'args': args};
}

/// Represents a parsed IMAP response.
class ImapResponse {
  final ResponseKind kind;
  final String? tag;
  final ImapStatus? status;
  final dynamic code;
  final String? text;
  final List<ImapToken>? data;
  final List<ImapToken>? tokens;

  ImapResponse({
    required this.kind,
    this.tag,
    this.status,
    this.code,
    this.text,
    this.data,
    this.tokens,
  });

  Map<String, dynamic> toMap() => {
    'kind': kind,
    'tag': tag,
    'status': status,
    'code': code,
    'text': text,
    'data': data,
    'tokens': tokens,
  };
}

// Parse result statuses
enum ParseStatus { ok, incomplete, needContinuation, error }

const ParseStatus PARSE_OK = ParseStatus.ok;
const ParseStatus PARSE_INCOMPLETE = ParseStatus.incomplete;
const ParseStatus PARSE_NEED_CONTINUATION = ParseStatus.needContinuation;
const ParseStatus PARSE_ERROR = ParseStatus.error;

// Response kinds (server → client)
enum ResponseKind { untagged, continuation, tagged }

const ResponseKind RESP_UNTAGGED = ResponseKind.untagged;
const ResponseKind RESP_CONTINUATION = ResponseKind.continuation;
const ResponseKind RESP_TAGGED = ResponseKind.tagged;

// IMAP known status values in tagged responses
enum ImapStatus { OK, NO, BAD, PREAUTH, BYE }

const ImapStatus STATUS_OK = ImapStatus.OK;
const ImapStatus STATUS_NO = ImapStatus.NO;
const ImapStatus STATUS_BAD = ImapStatus.BAD;
const ImapStatus STATUS_PREAUTH =
    ImapStatus.PREAUTH; // only as greeting (untagged)
const ImapStatus STATUS_BYE = ImapStatus.BYE; // only as untagged

// ============================================================
//  Byte-level helpers
// ============================================================

bool isCtl(int b) {
  return (b >= 0 && b <= 31) || b == 127;
}

bool isAtomChar(int b) {
  if (isCtl(b)) return false;
  if (b > 127) return false;
  switch (b) {
    case LPAREN:
    case RPAREN:
    case LBRACE:
    case SP:
    case HTAB:
    case DQUOTE:
    case RBRACKET:
      return false;
  }
  return true;
}

bool isAstringChar(int b) {
  if (b == RBRACKET) return true;
  return isAtomChar(b);
}

int skipSP(Uint8List buf, int pos) {
  while (pos < buf.length && (buf[pos] == SP || buf[pos] == HTAB)) pos++;
  return pos;
}

int findCRLFfrom(Uint8List buf, int pos) {
  for (int i = pos; i + 1 < buf.length; i++) {
    if (buf[i] == CR && buf[i + 1] == LF) return i;
  }
  return -1;
}

// ============================================================
//  Tokenizer (SHARED by server + client parsing)
// ============================================================

final RegExp RE_NUMBER = RegExp(r'^\d+$');
final RegExp RE_PARTIAL = RegExp(r'^(\d+)(?:\.(\d+))?$');

ImapToken? readAtom(Uint8List buf, int pos) {
  int start = pos;
  while (pos < buf.length && isAtomChar(buf[pos])) pos++;
  if (pos == start) return null;
  String str = u8ToStr(buf.sublist(start, pos));

  if (str.length == 3 && asciiEqCI(buf, start, 'NIL')) {
    return NilToken(pos);
  }

  if (RE_NUMBER.hasMatch(str)) {
    try {
      int n = int.parse(str);
      if (n.toString() == str) {
        return NumberToken(n, pos);
      }
    } catch (_) {}
  }

  return AtomToken(str, pos);
}

ImapToken? readAstringAtom(Uint8List buf, int pos) {
  int start = pos;
  while (pos < buf.length && isAstringChar(buf[pos])) pos++;
  if (pos == start) return null;
  String str = u8ToStr(buf.sublist(start, pos));
  return AtomToken(str, pos);
}

dynamic readQuoted(Uint8List buf, int pos) {
  if (buf[pos] != DQUOTE) return null;
  String out = '';
  int i = pos + 1;
  while (i < buf.length) {
    int b = buf[i];
    if (b == DQUOTE) {
      return QuotedToken(out, i + 1);
    }
    if (b == BACKSLASH) {
      if (i + 1 >= buf.length) return {'incomplete': true};
      int next = buf[i + 1];
      out += String.fromCharCode(next);
      i += 2;
      continue;
    }
    if (b == CR || b == LF) {
      return null;
    }
    out += String.fromCharCode(b);
    i++;
  }
  return {'incomplete': true};
}

dynamic readLiteral(Uint8List buf, int pos) {
  if (buf[pos] != LBRACE) return null;

  int i = pos + 1;
  int numStart = i;
  while (i < buf.length && isDigit(buf[i])) i++;
  if (i == numStart) {
    if (i >= buf.length) return {'incompleteHeader': true};
    return null;
  }

  String sizeStr = u8ToStr(buf.sublist(numStart, i));
  int size = int.parse(sizeStr);

  bool nonSync = false;
  if (i < buf.length && buf[i] == PLUS_SIGN) {
    nonSync = true;
    i++;
  }

  if (i >= buf.length) return {'incompleteHeader': true};
  if (buf[i] != RBRACE) return null;
  i++;

  if (i >= buf.length) return {'incompleteHeader': true};
  if (buf[i] != CR) return null;
  if (i + 1 >= buf.length) return {'incompleteHeader': true};
  if (buf[i + 1] != LF) return null;
  i += 2;

  int headerEnd = i;

  if (buf.length - headerEnd < size) {
    return {
      'headerOnly': true,
      'size': size,
      'nonSync': nonSync,
      'headerEnd': headerEnd,
    };
  }

  Uint8List bytes = buf.sublist(headerEnd, headerEnd + size);
  return LiteralToken(bytes, headerEnd + size, nonSync: nonSync, size: size);
}

dynamic readList(Uint8List buf, int pos) {
  if (buf[pos] != LPAREN) return null;
  int p = pos + 1;
  List<ImapToken> items = [];

  p = skipSP(buf, p);
  if (p >= buf.length) return {'incomplete': true};
  if (buf[p] == RPAREN) {
    return ListToken(items, p + 1);
  }

  while (p < buf.length) {
    var tok = readAnyToken(buf, p);
    if (tok == null) return {'error': 'BAD_LIST_ITEM'};
    if (tok is Map) {
      if (tok['incomplete'] == true) return {'incomplete': true};
      if (tok['needLiteral'] != null) return tok;
      if (tok['error'] != null) return tok;
    }
    items.add(tok as ImapToken);
    p = tok.end;

    p = skipSP(buf, p);
    if (p >= buf.length) return {'incomplete': true};

    if (buf[p] == RPAREN) {
      return ListToken(items, p + 1);
    }
  }
  return {'incomplete': true};
}

dynamic readBracketed(Uint8List buf, int pos) {
  if (buf[pos] != LBRACKET) return null;
  int depth = 1;
  int i = pos + 1;
  int start = i;
  while (i < buf.length) {
    if (buf[i] == LBRACKET)
      depth++;
    else if (buf[i] == RBRACKET) {
      depth--;
      if (depth == 0) {
        String inner = u8ToStr(buf.sublist(start, i));
        return BracketedToken(inner, i + 1);
      }
    } else if (buf[i] == CR || buf[i] == LF)
      return null;
    i++;
  }
  return {'incomplete': true};
}

dynamic readValue(Uint8List buf, int pos) {
  if (pos >= buf.length) return {'incomplete': true};
  int b = buf[pos];

  if (b == DQUOTE) {
    var q = readQuoted(buf, pos);
    if (q == null) return {'error': 'BAD_QUOTED'};
    if (q is Map && q['incomplete'] == true) return {'incomplete': true};
    return q;
  }

  if (b == LPAREN) return readList(buf, pos);

  if (b == LBRACE) {
    var lit = readLiteral(buf, pos);
    if (lit == null) return {'error': 'BAD_LITERAL'};
    if (lit is Map) {
      if (lit['incompleteHeader'] == true) return {'incomplete': true};
      if (lit['headerOnly'] == true) {
        return {
          'needLiteral': {
            'size': lit['size'],
            'nonSync': lit['nonSync'],
            'headerEnd': lit['headerEnd'],
          },
        };
      }
    }
    return lit;
  }

  int start = pos;
  while (pos < buf.length && isAtomChar(buf[pos]) && buf[pos] != LBRACKET)
    pos++;
  if (pos == start) return null;
  String atomStr = u8ToStr(buf.sublist(start, pos));
  int atomEnd = pos;

  if (atomEnd < buf.length && buf[atomEnd] == LBRACKET) {
    var bracket = readBracketed(buf, atomEnd);
    if (bracket == null) return {'error': 'BAD_BRACKETED'};
    if (bracket is Map && bracket['incomplete'] == true)
      return {'incomplete': true};

    int end = (bracket as ImapToken).end;
    Map<String, int?>? partial;
    if (end < buf.length && buf[end] == 60) {
      // '<'
      int close = end + 1;
      while (close < buf.length && buf[close] != 62) close++; // '>'
      if (close >= buf.length) return {'incomplete': true};
      String pStr = u8ToStr(buf.sublist(end + 1, close));
      var m = RE_PARTIAL.firstMatch(pStr);
      if (m == null) return {'error': 'BAD_PARTIAL'};
      partial = {
        'offset': int.parse(m.group(1)!),
        'length': m.group(2) != null ? int.parse(m.group(2)!) : null,
      };
      end = close + 1;
    }

    return AtomToken(
      atomStr,
      end,
      section: (bracket as BracketedToken).value,
      partial: partial,
    );
  }

  if (atomStr == 'NIL') {
    return NilToken(atomEnd);
  }

  if (RE_NUMBER.hasMatch(atomStr)) {
    try {
      int n = int.parse(atomStr);
      if (n.toString() == atomStr) {
        return NumberToken(n, atomEnd);
      }
    } catch (_) {}
  }

  return AtomToken(atomStr, atomEnd);
}

Function readAnyToken = readValue;

// ============================================================
//  Server-side: parseCommand (client → server)
// ============================================================

Map<String, dynamic> parseCommand(Uint8List buf, [int pos = 0]) {
  var tagTok = readAtom(buf, pos);
  if (tagTok == null) {
    if (pos >= buf.length) return {'status': PARSE_INCOMPLETE};
    int cr = findCRLFfrom(buf, pos);
    if (cr < 0) return {'status': PARSE_INCOMPLETE};
    return {'status': PARSE_ERROR, 'reason': 'BAD_TAG', 'end': cr + 2};
  }
  pos = tagTok.end;
  String tag = tagTok.value.toString();

  if (pos >= buf.length) return {'status': PARSE_INCOMPLETE};
  if (buf[pos] != SP) {
    int cr = findCRLFfrom(buf, pos);
    if (cr < 0) return {'status': PARSE_INCOMPLETE};
    return {
      'status': PARSE_ERROR,
      'reason': 'BAD_TAG_SEP',
      'tag': tag,
      'end': cr + 2,
    };
  }
  pos = skipSP(buf, pos);

  var cmdTok = readAtom(buf, pos);
  if (cmdTok == null) {
    int cr = findCRLFfrom(buf, pos);
    if (cr < 0) return {'status': PARSE_INCOMPLETE};
    return {
      'status': PARSE_ERROR,
      'reason': 'BAD_COMMAND',
      'tag': tag,
      'end': cr + 2,
    };
  }
  pos = cmdTok.end;
  String name = cmdTok.value.toString().toUpperCase();

  List<ImapToken> args = [];
  while (true) {
    if (pos >= buf.length) return {'status': PARSE_INCOMPLETE};
    if (buf[pos] == CR) {
      if (pos + 1 >= buf.length) return {'status': PARSE_INCOMPLETE};
      if (buf[pos + 1] == LF) {
        return {
          'status': PARSE_OK,
          'command': ImapCommand(tag: tag, name: name, args: args),
          'end': pos + 2,
        };
      }
      return {
        'status': PARSE_ERROR,
        'reason': 'BAD_EOL',
        'tag': tag,
        'end': pos + 1,
      };
    }

    if (buf[pos] == SP || buf[pos] == HTAB) {
      pos = skipSP(buf, pos);
      if (pos >= buf.length) return {'status': PARSE_INCOMPLETE};
      if (buf[pos] == CR) continue;
    }

    var tok = readValue(buf, pos);
    if (tok == null) {
      int cr = findCRLFfrom(buf, pos);
      if (cr < 0) return {'status': PARSE_INCOMPLETE};
      return {
        'status': PARSE_ERROR,
        'reason': 'BAD_ARG',
        'tag': tag,
        'end': cr + 2,
      };
    }
    if (tok is Map) {
      if (tok['incomplete'] == true) return {'status': PARSE_INCOMPLETE};
      if (tok['needLiteral'] != null) {
        return {
          'status': PARSE_NEED_CONTINUATION,
          'tag': tag,
          'command': name,
          'literalSize': tok['needLiteral']['size'],
          'nonSync': tok['needLiteral']['nonSync'],
          'after': tok['needLiteral']['headerEnd'],
          'partial': {
            'tag': tag,
            'name': name,
            'argsParsed': List<ImapToken>.from(args),
          },
        };
      }
      if (tok['error'] != null) {
        int cr = findCRLFfrom(buf, pos);
        return {
          'status': PARSE_ERROR,
          'reason': tok['error'],
          'tag': tag,
          'end': cr >= 0 ? cr + 2 : null,
        };
      }
    }
    args.add(tok as ImapToken);
    pos = tok.end;
  }
}

// ============================================================
//  Client-side: parseResponse (server → client)
// ============================================================

String tokenToText(dynamic tok) {
  if (tok == null) return '';
  if (tok is ImapToken) {
    if (tok is AtomToken || tok is QuotedToken) return tok.value.toString();
    if (tok is NumberToken) return tok.value.toString();
    if (tok is NilToken) return 'NIL';
    if (tok is LiteralToken) return u8ToStr(tok.value);
    if (tok is ResponseCodeToken) return '[${tok.value}]';
  }
  if (tok is Map) {
    if (tok['type'] == TOK_ATOM || tok['type'] == TOK_QUOTED)
      return tok['value'].toString();
    if (tok['type'] == TOK_NUMBER) return tok['value'].toString();
    if (tok['type'] == TOK_NIL) return 'NIL';
    if (tok['type'] == TOK_LITERAL) return u8ToStr(tok['value']);
    if (tok['type'] == 'respcode') return '[${tok['value']}]';
  }
  return '';
}

Map<String, dynamic> parseResponseTail(
  Uint8List buf,
  int pos,
  ResponseKind kind,
  String? tag,
) {
  List<ImapToken> tokens = [];
  int p = pos;

  while (true) {
    if (p >= buf.length) return {'status': PARSE_INCOMPLETE};
    if (buf[p] == CR) {
      if (p + 1 >= buf.length) return {'status': PARSE_INCOMPLETE};
      if (buf[p + 1] == LF) {
        p += 2;
        break;
      }
      return {'status': PARSE_ERROR, 'reason': 'BAD_EOL', 'end': p + 1};
    }
    if (buf[p] == SP || buf[p] == HTAB) {
      p = skipSP(buf, p);
      continue;
    }

    if (buf[p] == LBRACKET && tokens.isNotEmpty) {
      var br = readBracketed(buf, p);
      if (br == null) return {'status': PARSE_ERROR, 'reason': 'BAD_BRACKETED'};
      if (br is Map && br['incomplete'] == true)
        return {'status': PARSE_INCOMPLETE};
      var brTok = br as ImapToken;
      tokens.add(ResponseCodeToken(brTok.value, brTok.end));
      p = brTok.end;
      continue;
    }

    var tok = readValue(buf, p);
    if (tok == null) {
      int cr = findCRLFfrom(buf, p);
      if (cr < 0) return {'status': PARSE_INCOMPLETE};
      var textTok = AtomToken(u8ToStr(buf.sublist(p, cr)), cr);
      tokens.add(textTok);
      p = cr;
      continue;
    }
    if (tok is Map) {
      if (tok['incomplete'] == true) return {'status': PARSE_INCOMPLETE};
      if (tok['error'] != null) {
        int cr = findCRLFfrom(buf, p);
        return {
          'status': PARSE_ERROR,
          'reason': tok['error'],
          'end': cr >= 0 ? cr + 2 : null,
        };
      }
      if (tok['needLiteral'] != null) {
        return {'status': PARSE_INCOMPLETE};
      }
    }
    tokens.add(tok as ImapToken);
    p = tok.end;
  }

  if (kind == RESP_TAGGED) {
    var statusTok = tokens.isNotEmpty ? tokens[0] : null;
    String statusVal = statusTok != null && statusTok is AtomToken
        ? statusTok.value.toUpperCase()
        : '';
    ImapStatus? statusEnum;
    for (final s in ImapStatus.values) {
      if (s.name == statusVal) {
        statusEnum = s;
        break;
      }
    }

    dynamic codeTok;
    int textStart = 1;
    if (tokens.length > 1 && tokens[1] is ResponseCodeToken) {
      codeTok = tokens[1].value;
      textStart = 2;
    }

    List<String> textParts = [];
    for (int i = textStart; i < tokens.length; i++) {
      textParts.add(tokenToText(tokens[i]));
    }

    return {
      'status': PARSE_OK,
      'response': ImapResponse(
        kind: RESP_TAGGED,
        tag: tag,
        status: statusEnum,
        code: codeTok,
        text: textParts.join(' '),
        tokens: tokens.length > 1 ? tokens.sublist(1) : [],
      ),
      'end': p,
    };
  }

  return {
    'status': PARSE_OK,
    'response': ImapResponse(kind: RESP_UNTAGGED, data: tokens),
    'end': p,
  };
}

Map<String, dynamic> parseResponse(Uint8List buf, [int pos = 0]) {
  if (pos >= buf.length) return {'status': PARSE_INCOMPLETE};

  if (buf[pos] == PLUS) {
    int cr = findCRLFfrom(buf, pos);
    if (cr < 0) return {'status': PARSE_INCOMPLETE};
    int afterPlus = pos + 1;
    if (afterPlus < cr && (buf[afterPlus] == SP || buf[afterPlus] == HTAB))
      afterPlus++;
    String text = u8ToStr(buf.sublist(afterPlus, cr));
    return {
      'status': PARSE_OK,
      'response': ImapResponse(kind: RESP_CONTINUATION, text: text),
      'end': cr + 2,
    };
  }

  if (buf[pos] == STAR) {
    int p = pos + 1;
    if (p >= buf.length) return {'status': PARSE_INCOMPLETE};
    if (buf[p] != SP) {
      int cr = findCRLFfrom(buf, p);
      if (cr < 0) return {'status': PARSE_INCOMPLETE};
      return {
        'status': PARSE_ERROR,
        'reason': 'BAD_UNTAGGED_SEP',
        'end': cr + 2,
      };
    }
    p = skipSP(buf, p);
    return parseResponseTail(buf, p, RESP_UNTAGGED, null);
  }

  var tagTok = readAtom(buf, pos);
  if (tagTok == null) return {'status': PARSE_INCOMPLETE};
  String tag = tagTok.value.toString();
  int p = tagTok.end;

  if (p >= buf.length) return {'status': PARSE_INCOMPLETE};
  if (buf[p] != SP) {
    int cr = findCRLFfrom(buf, p);
    if (cr < 0) return {'status': PARSE_INCOMPLETE};
    return {'status': PARSE_ERROR, 'reason': 'BAD_TAG_SEP', 'end': cr + 2};
  }
  p = skipSP(buf, p);
  return parseResponseTail(buf, p, RESP_TAGGED, tag);
}

// ============================================================
//  Serializers (SHARED by server responses + client commands)
// ============================================================

String quoteString(dynamic str) {
  if (str == null) return 'NIL';
  String s = str.toString();
  if (s.isEmpty) return '""';

  bool needLiteral = false;
  bool needQuote = false;
  for (int i = 0; i < s.length; i++) {
    int c = s.codeUnitAt(i);
    if (c == CR || c == LF || c == 0) {
      needLiteral = true;
      break;
    }
    if (c > 127) {
      needLiteral = true;
      break;
    }
    if (c < 32) {
      needLiteral = true;
      break;
    }
    if (c == DQUOTE || c == BACKSLASH) needQuote = true;
    if (c == SP || c == LPAREN || c == RPAREN || c == LBRACE || c == RBRACKET)
      needQuote = true;
  }

  if (needLiteral) {
    Uint8List u8 = toU8(s);
    return '{${u8.length}}\r\n${u8ToStr(u8)}';
  }

  if (needQuote) {
    String escaped = s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  return '"$s"';
}

String atomString(dynamic str) {
  return str.toString();
}

String serializeValue(dynamic val) {
  if (val == null) return 'NIL';
  if (val is num) return val.toString();
  if (val is String) return quoteString(val);
  if (val is List) return serializeList(val);
  if (val is Uint8List) return '{${val.length}}\r\n${u8ToStr(val)}';

  if (val is Map && val.containsKey('type')) {
    if (val['type'] == TOK_ATOM) return atomString(val['value']);
    if (val['type'] == TOK_QUOTED) return quoteString(val['value']);
    if (val['type'] == TOK_NUMBER) return val['value'].toString();
    if (val['type'] == TOK_NIL) return 'NIL';
    if (val['type'] == TOK_LITERAL) {
      Uint8List bytes;
      if (val['value'] is Uint8List) {
        bytes = val['value'] as Uint8List;
      } else if (val['value'] is List<int>) {
        bytes = Uint8List.fromList(val['value'] as List<int>);
      } else {
        bytes = toU8(val['value'].toString());
      }
      return '{${bytes.length}}\r\n${u8ToStr(bytes)}';
    }
    if (val['type'] == TOK_LIST) return serializeList(val['value']);
  }
  return quoteString(val.toString());
}

String serializeList(List<dynamic> items) {
  String out = '(';
  for (int i = 0; i < items.length; i++) {
    if (i > 0) out += ' ';
    out += serializeValue(items[i]);
  }
  return out + ')';
}

// ============================================================
//  Server response builders (server → client)
// ============================================================

String buildTagged(
  String tag,
  Object status, [
  String text = '',
  String? code,
]) {
  final s = status is ImapStatus ? status.name : status.toString();
  String out = '$tag $s ';
  if (code != null) out += '[$code] ';
  out += '$text\r\n';
  return out;
}

String buildUntagged(String data) {
  return '* $data\r\n';
}

String buildContinuation([String text = 'Ready']) {
  return '+ $text\r\n';
}

String buildCapability(List<String> capabilities) {
  return buildUntagged('CAPABILITY ${capabilities.join(' ')}');
}

String buildExists(int count) {
  return buildUntagged('$count EXISTS');
}

String buildRecent(int count) {
  return buildUntagged('$count RECENT');
}

String buildExpunge(int seq) {
  return buildUntagged('$seq EXPUNGE');
}

String buildFlags(List<String> flags) {
  return buildUntagged(
    'FLAGS ${serializeList(flags.map((f) => {'type': TOK_ATOM, 'value': f}).toList())}',
  );
}

String buildFetch(int seq, List<List<dynamic>> attrs) {
  List<String> parts = [];
  for (int i = 0; i < attrs.length; i++) {
    parts.add('${attrs[i][0]} ${serializeValue(attrs[i][1])}');
  }
  return buildUntagged('$seq FETCH (${parts.join(' ')})');
}

String buildList(List<String> attrs, String? delimiter, String name) {
  String attrList = '(${attrs.join(' ')})';
  String delim = delimiter == null ? 'NIL' : quoteString(delimiter);
  return buildUntagged('LIST $attrList $delim ${quoteString(name)}');
}

// ============================================================
//  Client command builders (client → server)
// ============================================================

String buildCommand(String tag, String command, [List<dynamic>? args]) {
  String out = '$tag $command';
  if (args != null && args.isNotEmpty) {
    for (int i = 0; i < args.length; i++) {
      out += ' ${serializeValue(args[i])}';
    }
  }
  out += '\r\n';
  return out;
}

String buildCommandRaw(String tag, String command, [String? rawTail]) {
  return '$tag $command${rawTail != null && rawTail.isNotEmpty ? ' $rawTail' : ''}\r\n';
}

// ============================================================
//  Tag generation helper (for client sessions)
// ============================================================

Function makeTagGenerator([String prefix = 'A']) {
  int n = 0;
  return () {
    n++;
    String s = n.toString();
    while (s.length < 4) s = '0$s';
    return '$prefix$s';
  };
}
