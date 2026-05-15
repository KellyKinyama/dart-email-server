import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'utils.dart'; // toU8, u8ToStr, hasNonAscii

// ============================================================
//  Text encoding utilities
// ============================================================

final RegExp _reAdjacentEncoded = RegExp(r'\?=\s+=\?');
final RegExp _reEncodedWord = RegExp(
  r'=\?UTF-8\?([QB])\?(.+?)\?=',
  caseSensitive: false,
);
final RegExp _reUnderscore = RegExp(r'_');
final RegExp _reCrlfNormalize = RegExp(r'\r?\n');
final RegExp _reQpSoftbreak = RegExp(r'=\r?\n');

String ensureCRLF(String str) {
  return str.replaceAll(_reCrlfNormalize, '\r\n');
}

// ============================================================
//  Base64
// ============================================================

String base64Encode(Uint8List u8) {
  return base64.encode(u8);
}

String base64Wrap76(String b64) {
  StringBuffer out = StringBuffer();
  for (int i = 0; i < b64.length; i += 76) {
    if (i + 76 <= b64.length) {
      out.write(b64.substring(i, i + 76));
    } else {
      out.write(b64.substring(i));
    }
    out.write('\r\n');
  }
  return out.toString();
}

Uint8List base64DecodeRaw(String str) {
  String s = str.replaceAll(RegExp(r'\s+'), '');
  int padding = s.length % 4;
  if (padding > 0) {
    s += '=' * (4 - padding);
  }
  try {
    return base64.decode(s);
  } catch (e) {
    return Uint8List(0);
  }
}

// ============================================================
//  Quoted-Printable
// ============================================================

String qpEncode(Uint8List u8) {
  StringBuffer out = StringBuffer();
  int lineLen = 0;
  for (int i = 0; i < u8.length; i++) {
    int b = u8[i];
    bool isSafe =
        (b == 9) || (b == 32) || (b >= 33 && b <= 60) || (b >= 62 && b <= 126);
    String token;
    if (!isSafe || b == 61) {
      String hex = b.toRadixString(16).toUpperCase().padLeft(2, '0');
      token = '=$hex';
    } else {
      token = String.fromCharCode(b);
    }
    if (lineLen + token.length > 73) {
      out.write('=\r\n');
      lineLen = 0;
    }
    out.write(token);
    lineLen += token.length;
    if (b == 10 && i > 0 && u8[i - 1] == 13) lineLen = 0;
  }
  return ensureCRLF(out.toString());
}

Uint8List qpDecode(String str) {
  String s = str.replaceAll(_reQpSoftbreak, '');
  BytesBuilder out = BytesBuilder();
  for (int i = 0; i < s.length; i++) {
    if (s[i] == '=' && i + 2 < s.length) {
      String hex = s.substring(i + 1, i + 3);
      int? v = int.tryParse(hex, radix: 16);
      if (v != null) {
        out.addByte(v);
        i += 2;
        continue;
      }
    }
    out.addByte(s.codeUnitAt(i));
  }
  return out.toBytes();
}

// ============================================================
//  Encoded-word (RFC 2047) for headers
// ============================================================

bool needsEncodedWord(String s) {
  for (int i = 0; i < s.length; i++) {
    int c = s.codeUnitAt(i);
    if (c < 32 || c > 126) return true;
  }
  return false;
}

String headerQEncode(String utf8String) {
  Uint8List u8 = toU8(utf8String);
  StringBuffer s = StringBuffer();
  for (int i = 0; i < u8.length; i++) {
    int b = u8[i];
    if (b == 32) {
      s.write('_');
      continue;
    }
    bool isAscii = (b >= 33 && b <= 60) || (b >= 62 && b <= 126);
    if (isAscii && b != 61 && b != 63 && b != 95) {
      s.write(String.fromCharCode(b));
    } else {
      String h = b.toRadixString(16).toUpperCase().padLeft(2, '0');
      s.write('=$h');
    }
  }
  String prefix = '=?UTF-8?Q?';
  String suffix = '?=';
  int max = 75 - prefix.length;
  StringBuffer out = StringBuffer();
  int pos = 0;
  String str = s.toString();
  while (pos < str.length) {
    int end = pos + max > str.length ? str.length : pos + max;
    String chunk = str.substring(pos, end);
    out.write(prefix + chunk + suffix);
    pos = end;
    if (pos < str.length) out.write('\r\n ');
  }
  return out.toString();
}

String headerBEncode(String utf8String) {
  Uint8List u8 = toU8(utf8String);
  String prefix = '=?UTF-8?B?';
  String suffix = '?=';
  int maxBytes = 45;
  StringBuffer out = StringBuffer();
  int pos = 0;

  while (pos < u8.length) {
    int end = min(pos + maxBytes, u8.length);
    while (end < u8.length && end > pos && (u8[end] & 0xC0) == 0x80) {
      end--;
    }
    if (end == pos) end = min(pos + maxBytes, u8.length);

    Uint8List chunk = Uint8List.sublistView(u8, pos, end);
    String b64 = base64Encode(chunk);
    if (out.isNotEmpty) out.write('\r\n ');
    out.write(prefix + b64 + suffix);
    pos = end;
  }

  return out.toString();
}

String encodeHeaderValue(dynamic value) {
  String v = value == null ? '' : value.toString();
  if (!needsEncodedWord(v)) return v;
  Uint8List u8 = toU8(v);
  return (u8.length < 40) ? headerQEncode(v) : headerBEncode(v);
}

String decodeEncodedWords(String? v) {
  if (v == null || v.isEmpty) return '';
  String result = v.replaceAll(_reAdjacentEncoded, '?==?');

  result = result.replaceAllMapped(_reEncodedWord, (match) {
    String mode = match.group(1)!.toUpperCase();
    String data = match.group(2)!;
    if (mode == 'B') return u8ToStr(base64DecodeRaw(data));
    return u8ToStr(qpDecode(data.replaceAll(_reUnderscore, ' ')));
  });

  return result;
}

// ============================================================
//  Header folding
// ============================================================

String foldHeader(String name, String value) {
  if (value.contains('=?')) {
    return '$name: $value';
  }
  String line = '$name: $value';
  StringBuffer out = StringBuffer();
  while (line.length > 78) {
    int cut = line.lastIndexOf(' ', 78);
    if (cut <= name.length + 2) cut = 78;
    out.write(line.substring(0, cut) + '\r\n ');
    if (cut + 1 < line.length) {
      line = line.substring(cut + 1);
    } else {
      line = '';
      break;
    }
  }
  out.write(line);
  return out.toString();
}

// ============================================================
//  Address helpers
// ============================================================

class AddressObj {
  final String name;
  final String address;
  AddressObj({required this.name, required this.address});
}

AddressObj? normalizeAddress(dynamic a) {
  if (a == null) return null;
  if (a is String) {
    RegExp re = RegExp(r'^(.*)<([^>]+)>$');
    Match? m = re.firstMatch(a);
    if (m != null) {
      String n = (m.group(1) ?? '').trim().replaceAll(RegExp(r'(^"|"$)'), '');
      String addr = (m.group(2) ?? '').trim();
      return AddressObj(name: n, address: addr);
    }
    return AddressObj(name: '', address: a.trim());
  }
  if (a is Map) {
    return AddressObj(
      name: a['name']?.toString() ?? '',
      address: a['address']?.toString() ?? '',
    );
  }
  if (a is AddressObj) return a;
  return null;
}

String formatAddressForHeader(AddressObj obj) {
  String name = obj.name;
  String addr = obj.address;
  if (name.isNotEmpty) {
    String disp = encodeHeaderValue(name).replaceAll(RegExp(r'\r\n\s*'), ' ');
    return '"$disp" <$addr>';
  }
  return '<$addr>';
}

String? addressListToHeader(dynamic val) {
  if (val == null) return null;
  List<dynamic> arr = val is List ? val : [val];
  List<String> out = [];
  for (var v in arr) {
    AddressObj? o = normalizeAddress(v);
    if (o == null || o.address.isEmpty) continue;
    out.add(formatAddressForHeader(o));
  }
  return out.isNotEmpty ? out.join(', ') : null;
}

// ============================================================
//  MIME type detection
// ============================================================

const Map<String, String> mimeTypes = {
  'txt': 'text/plain',
  'html': 'text/html',
  'htm': 'text/html',
  'css': 'text/css',
  'csv': 'text/csv',
  'xml': 'text/xml',
  'json': 'application/json',
  'js': 'application/javascript',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'gz': 'application/gzip',
  'tar': 'application/x-tar',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'svg': 'image/svg+xml',
  'webp': 'image/webp',
  'ico': 'image/x-icon',
  'bmp': 'image/bmp',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'avi': 'video/x-msvideo',
  'eml': 'message/rfc822',
  'ics': 'text/calendar',
  '7z': 'application/x-7z-compressed',
  'rar': 'application/x-rar-compressed',
};

String detectMimeType(String? filename) {
  if (filename == null || filename.isEmpty) return 'application/octet-stream';
  List<String> parts = filename.split('.');
  String ext = parts.last.toLowerCase();
  return mimeTypes[ext] ?? 'application/octet-stream';
}

// ============================================================
//  Content-Type builder
// ============================================================

String buildContentType(
  String type,
  String subtype, [
  Map<String, String>? params,
]) {
  String s = '$type/$subtype';
  if (params != null) {
    params.forEach((k, v) {
      if (RegExp(r'[\s";]').hasMatch(v)) {
        s += '; $k="${v.replaceAll(RegExp(r'["\\]'), r'\\$&')}"';
      } else {
        s += '; $k=$v';
      }
    });
  }
  return s;
}

// ============================================================
//  Transfer encoding selection
// ============================================================

String chooseTextTE(Uint8List u8, bool allow8bit) {
  if (!hasNonAscii(u8)) return '7bit';
  return allow8bit ? '8bit' : 'quoted-printable';
}

class EncodedPart {
  final String transfer;
  final String data;
  EncodedPart(this.transfer, this.data);
}

EncodedPart encodeTextPart(Uint8List u8, bool allow8bit) {
  String te = chooseTextTE(u8, allow8bit);
  if (te == '7bit' || te == '8bit')
    return EncodedPart(te, ensureCRLF(u8ToStr(u8)));
  return EncodedPart('quoted-printable', qpEncode(u8));
}

EncodedPart encodeAttachmentPart(Uint8List u8) {
  return EncodedPart('base64', base64Wrap76(base64Encode(u8)));
}

// ============================================================
//  Helpers
// ============================================================

final Random _rnd = Random();

String boundary() {
  String r = _rnd.nextInt(1000000000).toRadixString(36);
  String t = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  return 'b-$r-$t';
}

String nowRfc2822Date() {
  DateTime d = DateTime.now().toUtc();
  List<String> wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  List<String> mo = [
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
  String day = wd[d.weekday - 1];
  String m = mo[d.month - 1];
  String dd = d.day.toString().padLeft(2, '0');
  String hh = d.hour.toString().padLeft(2, '0');
  String mm = d.minute.toString().padLeft(2, '0');
  String ss = d.second.toString().padLeft(2, '0');
  return '$day, $dd $m ${d.year} $hh:$mm:$ss +0000';
}

String genMessageId([String? domainHint]) {
  int r = _rnd.nextInt(1000000000);
  int t = DateTime.now().millisecondsSinceEpoch;
  String d =
      (domainHint != null && RegExp(r'[A-Za-z0-9.-]').hasMatch(domainHint))
      ? domainHint
      : 'localhost';
  return '<${t.toRadixString(36)}.${r.toRadixString(36)}@$d>';
}

class MimePart {
  final List<String> headers;
  final String body;
  MimePart({required this.headers, required this.body});
}

String buildMultipart(String b, List<MimePart> parts) {
  StringBuffer out = StringBuffer();
  for (MimePart part in parts) {
    out.write('--$b\r\n');
    for (String h in part.headers) {
      out.write('$h\r\n');
    }
    out.write('\r\n');
    out.write(part.body);
    String currentOut = out.toString();
    if (!currentOut.endsWith('\r\n')) {
      out.write('\r\n');
    }
  }
  out.write('--$b--\r\n');
  return out.toString();
}

// ============================================================
//  composeMessage
// ============================================================

class ComposeResult {
  final Uint8List raw;
  final String messageId;
  final Map<String, dynamic> profile;
  ComposeResult(this.raw, this.messageId, this.profile);
}

/// Typed input for [composeMessageTyped].
///
/// Use this in preference to the legacy `Map<String, dynamic>` form taken
/// by [composeMessage]. Either supply [text]/[html]/[attachments] for a
/// composed message, or provide individual fields needed by the MIME
/// builder.
class ComposeMessageOptions {
  final dynamic from; // String | AddressObj | Map | List
  final dynamic sender;
  final dynamic replyTo;
  final dynamic to;
  final dynamic cc;
  final dynamic bcc;
  final String? subject;
  final String? text;
  final String? html;
  final List<Map<String, dynamic>>? attachments;
  final dynamic headers; // Map | List<{key,value}>
  final String? messageId;
  final String? date;
  final String? priority; // 'high' | 'normal' | 'low'

  const ComposeMessageOptions({
    this.from,
    this.sender,
    this.replyTo,
    this.to,
    this.cc,
    this.bcc,
    this.subject,
    this.text,
    this.html,
    this.attachments,
    this.headers,
    this.messageId,
    this.date,
    this.priority,
  });

  Map<String, dynamic> toMap() => {
    if (from != null) 'from': from,
    if (sender != null) 'sender': sender,
    if (replyTo != null) 'replyTo': replyTo,
    if (to != null) 'to': to,
    if (cc != null) 'cc': cc,
    if (bcc != null) 'bcc': bcc,
    if (subject != null) 'subject': subject,
    if (text != null) 'text': text,
    if (html != null) 'html': html,
    if (attachments != null) 'attachments': attachments,
    if (headers != null) 'headers': headers,
    if (messageId != null) 'messageId': messageId,
    if (date != null) 'date': date,
    if (priority != null) 'priority': priority,
  };
}

/// SMTP server / pipeline capability flags consumed by [composeMessage].
class ComposeCapabilities {
  final bool eightBitMime;
  const ComposeCapabilities({this.eightBitMime = false});

  Map<String, dynamic> toMap() => {'eightBitMime': eightBitMime};
}

/// Typed wrapper around [composeMessage]. Prefer this in new code.
ComposeResult composeMessageTyped(
  ComposeMessageOptions options, [
  ComposeCapabilities caps = const ComposeCapabilities(),
]) => composeMessage(options.toMap(), caps.toMap());

ComposeResult composeMessage(
  Map<String, dynamic> options, [
  Map<String, dynamic>? caps,
]) {
  caps ??= {};

  List<String> hdr = [];

  hdr.add(foldHeader('Date', options['date']?.toString() ?? nowRfc2822Date()));

  String fromAddr = '';
  if (options['from'] != null) {
    var n = normalizeAddress(options['from']);
    if (n != null) fromAddr = n.address;
  }

  List<String> fromParts = fromAddr.split('@');
  String msgId =
      options['messageId']?.toString() ??
      genMessageId(fromParts.length > 1 ? fromParts[1] : 'localhost');
  hdr.add(foldHeader('Message-ID', msgId));

  hdr.add(foldHeader('MIME-Version', '1.0'));

  String? fromH = addressListToHeader(options['from']);
  if (fromH != null) hdr.add(foldHeader('From', fromH));
  String? senderH = addressListToHeader(options['sender']);
  if (senderH != null) hdr.add(foldHeader('Sender', senderH));
  String? replyH = addressListToHeader(options['replyTo']);
  if (replyH != null) hdr.add(foldHeader('Reply-To', replyH));

  String? toH = addressListToHeader(options['to']);
  if (toH != null) hdr.add(foldHeader('To', toH));
  String? ccH = addressListToHeader(options['cc']);
  if (ccH != null) hdr.add(foldHeader('Cc', ccH));

  if (options['subject'] != null) {
    hdr.add(foldHeader('Subject', encodeHeaderValue(options['subject'])));
  }

  if (options['priority'] == 'high') {
    hdr.add(foldHeader('X-Priority', '1 (Highest)'));
    hdr.add(foldHeader('Importance', 'High'));
  } else if (options['priority'] == 'low') {
    hdr.add(foldHeader('X-Priority', '5 (Lowest)'));
    hdr.add(foldHeader('Importance', 'Low'));
  }

  if (options['headers'] != null) {
    if (options['headers'] is List) {
      for (var kv in options['headers']) {
        if (kv == null || kv['key'] == null) continue;
        hdr.add(
          foldHeader(kv['key'].toString(), (kv['value'] ?? '').toString()),
        );
      }
    } else if (options['headers'] is Map) {
      (options['headers'] as Map).forEach((k, v) {
        hdr.add(foldHeader(k.toString(), v.toString()));
      });
    }
  }

  Uint8List? textU8 = options['text'] != null
      ? toU8(ensureCRLF(options['text'].toString()))
      : null;
  Uint8List? htmlU8 = options['html'] != null
      ? toU8(ensureCRLF(options['html'].toString()))
      : null;
  List<dynamic> atts = options['attachments'] is List
      ? List.from(options['attachments'])
      : [];

  bool allow8bit = caps['eightBitMime'] == true;

  String? rootContentType;
  String rootBody = '';

  if (htmlU8 == null && atts.isEmpty && textU8 != null) {
    var enc = encodeTextPart(textU8, allow8bit);
    hdr.add(
      foldHeader(
        'Content-Type',
        buildContentType('text', 'plain', {'charset': 'UTF-8'}),
      ),
    );
    hdr.add(foldHeader('Content-Transfer-Encoding', enc.transfer));
    rootBody = enc.data;
  } else {
    List<MimePart> altParts = [];

    if (textU8 != null) {
      var e = encodeTextPart(textU8, allow8bit);
      altParts.add(
        MimePart(
          headers: [
            foldHeader(
              'Content-Type',
              buildContentType('text', 'plain', {'charset': 'UTF-8'}),
            ),
            foldHeader('Content-Transfer-Encoding', e.transfer),
          ],
          body: e.data,
        ),
      );
    }

    if (htmlU8 != null) {
      var e = encodeTextPart(htmlU8, allow8bit);
      altParts.add(
        MimePart(
          headers: [
            foldHeader(
              'Content-Type',
              buildContentType('text', 'html', {'charset': 'UTF-8'}),
            ),
            foldHeader('Content-Transfer-Encoding', e.transfer),
          ],
          body: e.data,
        ),
      );
    }

    List<dynamic> inlineAtts = [];
    List<dynamic> regularAtts = [];
    for (var a in atts) {
      if (a == null || a['content'] == null) continue;
      if (a['cid'] != null)
        inlineAtts.add(a);
      else
        regularAtts.add(a);
    }

    MimePart buildAttPart(dynamic att) {
      Uint8List u8 = att['content'] is Uint8List
          ? att['content']
          : toU8(att['content'].toString());
      var enc = encodeAttachmentPart(u8);
      String ct =
          att['contentType'] ?? detectMimeType(att['filename']?.toString());
      String disp = att['cid'] != null ? 'inline' : 'attachment';
      String filename = att['filename']?.toString() ?? 'file';
      String dispVal = '$disp; filename="$filename"';
      List<String> headers = [
        foldHeader('Content-Type', '$ct; name="$filename"'),
        foldHeader('Content-Transfer-Encoding', enc.transfer),
        foldHeader('Content-Disposition', dispVal),
      ];
      if (att['cid'] != null) {
        headers.add(foldHeader('Content-ID', '<${att['cid']}>'));
      }
      return MimePart(headers: headers, body: enc.data);
    }

    bool hasInline = inlineAtts.isNotEmpty;

    if (altParts.isNotEmpty && hasInline) {
      String relBoundary = boundary();
      MimePart? htmlPart;
      try {
        htmlPart = altParts.firstWhere(
          (p) => p.headers[0].contains('text/html'),
        );
      } catch (_) {}

      List<MimePart> relatedParts = [];
      if (htmlPart != null) relatedParts.add(htmlPart);
      for (var a in inlineAtts) relatedParts.add(buildAttPart(a));
      String relatedBody = buildMultipart(relBoundary, relatedParts);

      List<MimePart> altOuter = [];
      MimePart? textPart;
      try {
        textPart = altParts.firstWhere(
          (p) => p.headers[0].contains('text/plain'),
        );
      } catch (_) {}
      if (textPart != null) altOuter.add(textPart);

      altOuter.add(
        MimePart(
          headers: [
            foldHeader(
              'Content-Type',
              buildContentType('multipart', 'related', {
                'boundary': relBoundary,
              }),
            ),
          ],
          body: relatedBody,
        ),
      );

      String topBoundary = boundary();
      String altBody = buildMultipart(topBoundary, altOuter);

      if (regularAtts.isNotEmpty) {
        String mixBoundary = boundary();
        List<MimePart> mixParts = [
          MimePart(
            headers: [
              foldHeader(
                'Content-Type',
                buildContentType('multipart', 'alternative', {
                  'boundary': topBoundary,
                }),
              ),
            ],
            body: altBody,
          ),
        ];
        for (var a in regularAtts) mixParts.add(buildAttPart(a));
        rootContentType = buildContentType('multipart', 'mixed', {
          'boundary': mixBoundary,
        });
        rootBody = buildMultipart(mixBoundary, mixParts);
      } else {
        rootContentType = buildContentType('multipart', 'alternative', {
          'boundary': topBoundary,
        });
        rootBody = altBody;
      }
    } else if (altParts.length > 1) {
      String bAlt = boundary();
      rootContentType = buildContentType('multipart', 'alternative', {
        'boundary': bAlt,
      });
      rootBody = buildMultipart(bAlt, altParts);

      if (regularAtts.isNotEmpty) {
        String mixB = boundary();
        List<MimePart> mixParts = [
          MimePart(
            headers: [foldHeader('Content-Type', rootContentType)],
            body: rootBody,
          ),
        ];
        for (var a in regularAtts) mixParts.add(buildAttPart(a));
        rootContentType = buildContentType('multipart', 'mixed', {
          'boundary': mixB,
        });
        rootBody = buildMultipart(mixB, mixParts);
      }
    } else if (regularAtts.isNotEmpty || altParts.isNotEmpty) {
      String mixB = boundary();
      List<MimePart> mixParts = [];
      mixParts.addAll(altParts);
      for (var a in regularAtts) mixParts.add(buildAttPart(a));
      rootContentType = buildContentType('multipart', 'mixed', {
        'boundary': mixB,
      });
      rootBody = buildMultipart(mixB, mixParts);
    }

    if (rootContentType != null) {
      hdr.add(foldHeader('Content-Type', rootContentType));
    }
  }

  String headerStr = hdr.join('\r\n');
  String full = '$headerStr\r\n\r\n$rootBody';
  Uint8List rawU8 = toU8(full);

  Uint8List bodyU8 = toU8(rootBody);
  bool smtpUtf8Needed = false;
  List<dynamic> addrFields = [
    options['from'],
    options['sender'],
    options['to'],
    options['cc'],
    options['bcc'],
  ];
  for (var val in addrFields) {
    if (val == null) continue;
    List<dynamic> arr = val is List ? val : [val];
    for (var v in arr) {
      var n = normalizeAddress(v);
      if (n != null && n.address.isNotEmpty && hasNonAscii(toU8(n.address))) {
        smtpUtf8Needed = true;
        break;
      }
    }
    if (smtpUtf8Needed) break;
  }

  return ComposeResult(rawU8, msgId, {
    'smtpUtf8Needed': smtpUtf8Needed,
    'bodyIs8bit': hasNonAscii(bodyU8) && allow8bit,
    'size': rawU8.length,
  });
}

// ============================================================
//  parseMessage
// ============================================================

class ParsedMessage {
  final List<ParsedHeader> headers;
  final String subject;
  final String from;
  final String to;
  final String cc;
  final String date;
  final String messageId;
  final String? text;
  final String? html;
  final List<ParsedAttachment> attachments;

  ParsedMessage({
    required this.headers,
    required this.subject,
    required this.from,
    required this.to,
    required this.cc,
    required this.date,
    required this.messageId,
    this.text,
    this.html,
    required this.attachments,
  });
}

class ParsedHeader {
  final String name;
  String value;
  ParsedHeader(this.name, this.value);
}

class ParsedAttachment {
  final String filename;
  final String contentType;
  final int size;
  final Uint8List content;
  final String? cid;
  final bool related;

  ParsedAttachment({
    required this.filename,
    required this.contentType,
    required this.size,
    required this.content,
    this.cid,
    required this.related,
  });
}

class _HeadBody {
  final String head;
  final String body;
  _HeadBody(this.head, this.body);
}

_HeadBody splitHeadersBody(Uint8List u8) {
  String s = u8ToStr(u8);
  int idx = s.indexOf('\r\n\r\n');
  if (idx < 0) return _HeadBody(s, '');
  return _HeadBody(s.substring(0, idx), s.substring(idx + 4));
}

List<ParsedHeader> parseHeaders(String headStr) {
  List<String> lines = headStr.split(RegExp(r'\r\n'));
  List<ParsedHeader> out = [];
  ParsedHeader? cur;
  for (String l in lines) {
    if (RegExp(r'^\s').hasMatch(l)) {
      if (cur != null) cur.value += '\r\n$l';
      continue;
    }
    Match? m = RegExp(r'^([^:]+):\s*(.*)$').firstMatch(l);
    if (m != null) {
      if (cur != null) out.add(cur);
      cur = ParsedHeader(m.group(1)!, m.group(2)!);
    } else if (cur != null) {
      cur.value += '\r\n$l';
    }
  }
  if (cur != null) out.add(cur);
  for (var h in out) {
    h.value = h.value.replaceAll(RegExp(r'\r\n[ \t]+'), ' ');
  }
  return out;
}

String? headerLookup(List<dynamic> headers, String name) {
  String low = name.toLowerCase();
  for (var h in headers) {
    String n = h is ParsedHeader ? h.name : h['name'];
    String v = h is ParsedHeader ? h.value : h['value'];
    if (n.toLowerCase() == low) return v;
  }
  return null;
}

class ParsedContentType {
  final String type;
  final String subtype;
  final Map<String, String> params;
  ParsedContentType(this.type, this.subtype, this.params);
}

ParsedContentType parseContentType(String? v) {
  if (v == null || v.isEmpty) return ParsedContentType('text', 'plain', {});
  Match? m = RegExp(r'^\s*([^\/\s;]+)\/([^;\s]+)\s*(;.*)?$').firstMatch(v);
  if (m == null) return ParsedContentType('text', 'plain', {});
  Map<String, String> params = {};
  if (m.group(3) != null) {
    RegExp rx = RegExp(r';\s*([^\s=;]+)\s*=\s*(?:"([^"]*)"|([^;\s]*))');
    for (Match t in rx.allMatches(m.group(3)!)) {
      String key = t.group(1)!.toLowerCase();
      String val = t.group(2) ?? t.group(3) ?? '';
      params[key] = val;
    }
  }
  return ParsedContentType(
    m.group(1)!.toLowerCase(),
    m.group(2)!.toLowerCase(),
    params,
  );
}

String parseTransfer(String? v) {
  if (v == null || v.isEmpty) return '7bit';
  return v.trim().toLowerCase();
}

class MultipartNode {
  List<ParsedHeader> headers = [];
  String raw = '';
  String body = '';
}

List<MultipartNode> splitMultipart(String bodyStr, String boundaryStr) {
  String b = '--$boundaryStr';
  String end = '--$boundaryStr--';
  List<String> lines = bodyStr.split(RegExp(r'\r\n'));
  List<MultipartNode> parts = [];
  MultipartNode? cur;
  for (String l in lines) {
    if (l == b) {
      if (cur != null) parts.add(cur);
      cur = MultipartNode();
      continue;
    }
    if (l == end) {
      if (cur != null) {
        parts.add(cur);
        cur = null;
      }
      break;
    }
    if (cur != null) cur.raw += '$l\r\n';
  }
  if (cur != null) parts.add(cur);
  for (var p in parts) {
    var hnb = splitHeadersBody(toU8(p.raw));
    p.headers = parseHeaders(hnb.head);
    p.body = hnb.body;
  }
  return parts;
}

Uint8List decodeBodyByTE(String bodyStr, String? te) {
  String t = te ?? '7bit';
  if (t == 'base64') return base64DecodeRaw(bodyStr);
  if (t == 'quoted-printable') return qpDecode(bodyStr);
  return toU8(bodyStr);
}

ParsedMessage parseMessage(dynamic rawInput) {
  Uint8List rawU8 = rawInput is String ? toU8(rawInput) : rawInput;
  var hb = splitHeadersBody(rawU8);
  var headers = parseHeaders(hb.head);

  String subjRaw = headerLookup(headers, 'Subject') ?? '';
  String subject = decodeEncodedWords(subjRaw);
  if (subject.isEmpty) subject = subjRaw;

  String from = headerLookup(headers, 'From') ?? '';
  String to = headerLookup(headers, 'To') ?? '';
  String cc = headerLookup(headers, 'Cc') ?? '';
  String date = headerLookup(headers, 'Date') ?? '';
  String messageId = headerLookup(headers, 'Message-ID') ?? '';

  var ct = parseContentType(headerLookup(headers, 'Content-Type'));
  var te = parseTransfer(headerLookup(headers, 'Content-Transfer-Encoding'));

  String? text;
  String? html;
  List<ParsedAttachment> attachments = [];

  void handleSingle(
    ParsedContentType ctObj,
    String teStr,
    String bodyStr,
    List<dynamic>? partHeaders,
  ) {
    Uint8List dataU8 = decodeBodyByTE(bodyStr, teStr);
    String mime = '${ctObj.type}/${ctObj.subtype}'.toLowerCase();

    if (mime == 'text/plain' && text == null) {
      text = u8ToStr(dataU8).replaceAll(RegExp(r'\r\n$'), '');
      return;
    }
    if (mime == 'text/html' && html == null) {
      html = u8ToStr(dataU8).replaceAll(RegExp(r'\r\n$'), '');
      return;
    }

    String cd = headerLookup(partHeaders ?? [], 'Content-Disposition') ?? '';
    bool isAttach =
        RegExp(r'attachment', caseSensitive: false).hasMatch(cd) ||
        RegExp(r'inline', caseSensitive: false).hasMatch(cd) ||
        (mime != 'text/plain' && mime != 'text/html');

    if (isAttach) {
      Match? fn = RegExp(
        r'filename\*?="?([^";]+)"?',
        caseSensitive: false,
      ).firstMatch(cd);
      if (fn == null) {
        fn = RegExp(
          r'name="?([^";]+)"?',
          caseSensitive: false,
        ).firstMatch(headerLookup(partHeaders ?? [], 'Content-Type') ?? '');
      }
      String filename = fn != null ? fn.group(1)! : 'file';
      String cidRaw = headerLookup(partHeaders ?? [], 'Content-ID') ?? '';
      String? cid = cidRaw.replaceAll(RegExp(r'[<>]'), '');
      if (cid.isEmpty) cid = null;

      attachments.add(
        ParsedAttachment(
          filename: filename,
          contentType: mime,
          size: dataU8.length,
          content: dataU8,
          cid: cid,
          related: RegExp(r'inline', caseSensitive: false).hasMatch(cd),
        ),
      );
    }
  }

  if (ct.type == 'multipart') {
    List<MultipartNode> parts = splitMultipart(
      hb.body,
      ct.params['boundary'] ?? '',
    );
    for (var p in parts) {
      var pCT = parseContentType(headerLookup(p.headers, 'Content-Type'));
      var pTE = parseTransfer(
        headerLookup(p.headers, 'Content-Transfer-Encoding'),
      );
      if (pCT.type == 'multipart') {
        List<MultipartNode> subparts = splitMultipart(
          p.body,
          pCT.params['boundary'] ?? '',
        );
        for (var s in subparts) {
          var sCT = parseContentType(headerLookup(s.headers, 'Content-Type'));
          var sTE = parseTransfer(
            headerLookup(s.headers, 'Content-Transfer-Encoding'),
          );
          handleSingle(sCT, sTE, s.body, s.headers);
        }
      } else {
        handleSingle(pCT, pTE, p.body, p.headers);
      }
    }
  } else {
    handleSingle(ct, te, hb.body, headers);
  }

  return ParsedMessage(
    headers: headers,
    subject: subject,
    from: from,
    to: to,
    cc: cc,
    date: date,
    messageId: messageId,
    text: text,
    html: html,
    attachments: attachments,
  );
}

// ============================================================
//  Tree-based parser (byte-accurate, offset-preserving)
// ============================================================

const int CR = 0x0D, LF = 0x0A, SP = 0x20, HT = 0x09, DASH = 0x2D;

int findHeadersBodySplit(Uint8List buf, int start, int end) {
  for (int i = start; i <= end - 4; i++) {
    if (buf[i] == CR &&
        buf[i + 1] == LF &&
        buf[i + 2] == CR &&
        buf[i + 3] == LF) {
      return i + 4;
    }
  }
  for (int i = start; i <= end - 2; i++) {
    if (buf[i] == LF && buf[i + 1] == LF) return i + 2;
  }
  return end;
}

class OffsetHeader {
  final String name;
  final String value;
  final int rawStart;
  final int rawEnd;
  OffsetHeader({
    required this.name,
    required this.value,
    required this.rawStart,
    required this.rawEnd,
  });

  /// Map-style accessor used by the IMAP fetch path, which treats
  /// header records as `Map<String, dynamic>` for forward compatibility.
  dynamic operator [](String key) {
    switch (key) {
      case 'name':
        return name;
      case 'value':
        return value;
      case 'rawStart':
        return rawStart;
      case 'rawEnd':
        return rawEnd;
    }
    return null;
  }
}

int _findEol(Uint8List buf, int start, int end) {
  for (int i = start; i < end; i++) {
    if (buf[i] == CR || buf[i] == LF) return i;
  }
  return -1;
}

List<OffsetHeader> parseHeadersWithOffsets(Uint8List buf, int start, int end) {
  List<OffsetHeader> out = [];
  int i = start;
  while (i < end) {
    if (buf[i] == CR && i + 1 < end && buf[i + 1] == LF) {
      i += 2;
      break;
    }
    if (buf[i] == LF) {
      i += 1;
      break;
    }

    int lineStart = i;
    int lineEnd = i;
    while (lineEnd < end) {
      int eol = _findEol(buf, lineEnd, end);
      if (eol < 0) {
        lineEnd = end;
        break;
      }
      int afterEol =
          eol +
          ((buf[eol] == CR && eol + 1 < end && buf[eol + 1] == LF) ? 2 : 1);
      if (afterEol < end && (buf[afterEol] == SP || buf[afterEol] == HT)) {
        lineEnd = afterEol;
        continue;
      }
      lineEnd = afterEol;
      break;
    }

    String logical = utf8.decode(
      buf.sublist(lineStart, lineEnd),
      allowMalformed: true,
    );
    int colon = logical.indexOf(':');
    if (colon > 0) {
      String name = logical.substring(0, colon).trim();
      String value = logical
          .substring(colon + 1)
          .replaceAll(RegExp(r'\r?\n[ \t]+'), ' ')
          .replaceAll(RegExp(r'\r?\n$'), '')
          .trim();
      out.add(
        OffsetHeader(
          name: name,
          value: value,
          rawStart: lineStart,
          rawEnd: lineEnd,
        ),
      );
    }

    i = lineEnd;
  }
  return out;
}

class OffsetPart {
  final int start;
  final int end;
  OffsetPart(this.start, this.end);
}

class _Marker {
  final int pos;
  final int preCRLFBytes;
  _Marker(this.pos, this.preCRLFBytes);
}

List<OffsetPart> splitMultipartOffsets(
  Uint8List buf,
  int bodyStart,
  int bodyEnd,
  String? boundary,
) {
  if (boundary == null || boundary.isEmpty) return [];
  Uint8List dashBoundary = toU8('--$boundary');
  Uint8List crlfDashBoundary = toU8('\r\n--$boundary');

  List<_Marker> markers = [];

  int indexOf(Uint8List source, Uint8List target, int start) {
    if (target.isEmpty) return start;
    if (source.length - start < target.length) return -1;
    for (int i = start; i <= source.length - target.length; i++) {
      bool match = true;
      for (int j = 0; j < target.length; j++) {
        if (source[i + j] != target[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  bool isMatch(Uint8List source, int start, Uint8List target) {
    if (start + target.length > source.length) return false;
    for (int i = 0; i < target.length; i++) {
      if (source[start + i] != target[i]) return false;
    }
    return true;
  }

  if (bodyEnd - bodyStart >= dashBoundary.length &&
      isMatch(buf, bodyStart, dashBoundary)) {
    markers.add(_Marker(bodyStart, 0));
  }

  int search = bodyStart;
  while (true) {
    int idx = indexOf(buf, crlfDashBoundary, search);
    if (idx < 0 || idx + crlfDashBoundary.length > bodyEnd) break;
    markers.add(_Marker(idx + 2, 2));
    search = idx + crlfDashBoundary.length;
  }

  markers.sort((a, b) => a.pos.compareTo(b.pos));

  List<OffsetPart> parts = [];
  int? currentStart;
  for (int j = 0; j < markers.length; j++) {
    var m = markers[j];
    int afterDash = m.pos + dashBoundary.length;
    bool isClose =
        afterDash + 1 < bodyEnd &&
        buf[afterDash] == DASH &&
        buf[afterDash + 1] == DASH;

    int scanner = isClose ? afterDash + 2 : afterDash;
    while (scanner < bodyEnd && (buf[scanner] == SP || buf[scanner] == HT))
      scanner++;
    int afterDelim;
    if (scanner + 1 < bodyEnd && buf[scanner] == CR && buf[scanner + 1] == LF) {
      afterDelim = scanner + 2;
    } else if (scanner < bodyEnd && buf[scanner] == LF) {
      afterDelim = scanner + 1;
    } else if (isClose) {
      afterDelim = scanner;
    } else {
      continue;
    }

    if (currentStart != null) {
      int partEnd = m.pos - m.preCRLFBytes;
      parts.add(OffsetPart(currentStart, partEnd));
    }

    if (isClose) break;
    currentStart = afterDelim;
  }

  return parts;
}

int countBodyLines(Uint8List buf, int start, int end) {
  int count = 0;
  for (int i = start; i < end; i++) {
    if (buf[i] == LF) count++;
  }
  return count;
}

String? findHeaderOffset(List<OffsetHeader> headers, String name) {
  String low = name.toLowerCase();
  for (var h in headers) {
    if (h.name.toLowerCase() == low) return h.value;
  }
  return null;
}

class ParsedContentDisposition {
  final String? type;
  final Map<String, String> params;
  ParsedContentDisposition(this.type, this.params);
}

ParsedContentDisposition _parseContentDisposition(String? v) {
  if (v == null || v.isEmpty) return ParsedContentDisposition(null, {});
  int semi = v.indexOf(';');
  String type = (semi < 0 ? v : v.substring(0, semi)).trim().toLowerCase();
  Map<String, String> params = {};
  if (semi >= 0) {
    RegExp rx = RegExp(r';\s*([^\s=;]+)\s*=\s*(?:"([^"]*)"|([^;\s]*))');
    for (var m in rx.allMatches(v)) {
      String key = m.group(1)!.toLowerCase();
      String val = m.group(2) ?? m.group(3) ?? '';
      params[key] = val;
    }
  }
  return ParsedContentDisposition(type.isNotEmpty ? type : null, params);
}

class MimeTreeNode {
  final int start;
  final int end;
  final int headerStart;
  final int headerEnd;
  final int bodyStart;
  final int bodyEnd;

  final String contentType;
  final Map<String, String> contentTypeParams;
  final String? contentTransferEncoding;
  final String? contentDisposition;
  final Map<String, String> contentDispositionParams;
  final String? contentId;
  final String? contentDescription;
  final String? contentLanguage;
  final String? contentLocation;
  final String? contentMd5;

  final List<OffsetHeader> headers;
  final int bodyLines;
  final List<MimeTreeNode>? parts;

  MimeTreeNode({
    required this.start,
    required this.end,
    required this.headerStart,
    required this.headerEnd,
    required this.bodyStart,
    required this.bodyEnd,
    required this.contentType,
    required this.contentTypeParams,
    this.contentTransferEncoding,
    this.contentDisposition,
    required this.contentDispositionParams,
    this.contentId,
    this.contentDescription,
    this.contentLanguage,
    this.contentLocation,
    this.contentMd5,
    required this.headers,
    required this.bodyLines,
    this.parts,
  });

  /// Map-style accessor used by the IMAP fetch path, which treats
  /// mime tree nodes as `Map<String, dynamic>` for forward compatibility.
  dynamic operator [](String key) {
    switch (key) {
      case 'start':
        return start;
      case 'end':
        return end;
      case 'headerStart':
        return headerStart;
      case 'headerEnd':
        return headerEnd;
      case 'bodyStart':
        return bodyStart;
      case 'bodyEnd':
        return bodyEnd;
      case 'parts':
        return parts;
      case 'headers':
        return headers;
      case 'contentType':
        return contentType;
      case 'contentTypeParams':
        return contentTypeParams;
      case 'contentTransferEncoding':
        return contentTransferEncoding;
      case 'contentDisposition':
        return contentDisposition;
      case 'contentDispositionParams':
        return contentDispositionParams;
      case 'contentId':
        return contentId;
      case 'contentDescription':
        return contentDescription;
      case 'contentLanguage':
        return contentLanguage;
      case 'contentLocation':
        return contentLocation;
      case 'contentMd5':
        return contentMd5;
      case 'bodyLines':
        return bodyLines;
    }
    return null;
  }
}

MimeTreeNode parseMessageTree(dynamic inputBuf) {
  Uint8List buf;
  if (inputBuf is String) {
    buf = toU8(inputBuf);
  } else if (inputBuf is Uint8List) {
    buf = inputBuf;
  } else {
    buf = Uint8List(0);
  }
  return _parseMimeNode(buf, 0, buf.length);
}

MimeTreeNode _parseMimeNode(Uint8List buf, int start, int end) {
  int headerEnd = findHeadersBodySplit(buf, start, end);
  int bodyStart = headerEnd;
  int bodyEnd = end;

  var headers = parseHeadersWithOffsets(buf, start, headerEnd);

  String? ctRaw = findHeaderOffset(headers, 'Content-Type');
  var ct = parseContentType(ctRaw);
  String? cte = findHeaderOffset(headers, 'Content-Transfer-Encoding');
  String? cd = findHeaderOffset(headers, 'Content-Disposition');
  var cdParsed = _parseContentDisposition(cd);

  List<MimeTreeNode>? parts;

  if (ct.type == 'multipart' && ct.params['boundary'] != null) {
    var childRanges = splitMultipartOffsets(
      buf,
      bodyStart,
      bodyEnd,
      ct.params['boundary'],
    );
    parts = [];
    for (var r in childRanges) {
      parts.add(_parseMimeNode(buf, r.start, r.end));
    }
  } else if (ct.type == 'message' && ct.subtype == 'rfc822') {
    parts = [_parseMimeNode(buf, bodyStart, bodyEnd)];
  }

  return MimeTreeNode(
    start: start,
    end: end,
    headerStart: start,
    headerEnd: headerEnd,
    bodyStart: bodyStart,
    bodyEnd: bodyEnd,
    contentType: '${ct.type}/${ct.subtype}',
    contentTypeParams: ct.params,
    contentTransferEncoding: cte?.trim().toLowerCase(),
    contentDisposition: cdParsed.type,
    contentDispositionParams: cdParsed.params,
    contentId: findHeaderOffset(headers, 'Content-ID'),
    contentDescription: findHeaderOffset(headers, 'Content-Description'),
    contentLanguage: findHeaderOffset(headers, 'Content-Language'),
    contentLocation: findHeaderOffset(headers, 'Content-Location'),
    contentMd5: findHeaderOffset(headers, 'Content-MD5'),
    headers: headers,
    bodyLines: countBodyLines(buf, bodyStart, bodyEnd),
    parts: parts,
  );
}

// ============================================================
//  Address-list parser (RFC 5322 pragmatic subset)
// ============================================================

class ParseState {
  final String s;
  int i;
  ParseState(this.s, this.i);
}

class AddressGroup {
  final String? group;
  final List<dynamic> members;
  AddressGroup(this.group, this.members);
}

void _apSkipCfws(ParseState st) {
  while (st.i < st.s.length) {
    String c = st.s[st.i];
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      st.i++;
      continue;
    }
    if (c == '(') {
      _apSkipComment(st);
      continue;
    }
    break;
  }
}

void _apSkipComment(ParseState st) {
  int depth = 1;
  st.i++;
  while (st.i < st.s.length && depth > 0) {
    String c = st.s[st.i];
    if (c == r'\' && st.i + 1 < st.s.length) {
      st.i += 2;
      continue;
    }
    if (c == '(')
      depth++;
    else if (c == ')')
      depth--;
    st.i++;
  }
}

String _apReadQuoted(ParseState st) {
  st.i++;
  StringBuffer out = StringBuffer();
  while (st.i < st.s.length) {
    String c = st.s[st.i];
    if (c == '"') {
      st.i++;
      return out.toString();
    }
    if (c == r'\' && st.i + 1 < st.s.length) {
      out.write(st.s[st.i + 1]);
      st.i += 2;
      continue;
    }
    out.write(c);
    st.i++;
  }
  return out.toString();
}

String _apReadAtom(ParseState st) {
  StringBuffer out = StringBuffer();
  while (st.i < st.s.length) {
    String c = st.s[st.i];
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') break;
    if ('"<>()@,:;'.indexOf(c) >= 0) break;
    out.write(c);
    st.i++;
  }
  return out.toString();
}

dynamic _apReadAddressOrGroup(ParseState st) {
  List<String> nameParts = [];
  String? localPart;
  String? domain;
  bool hasAngle = false;

  while (st.i < st.s.length) {
    _apSkipCfws(st);
    if (st.i >= st.s.length) break;
    String c = st.s[st.i];

    if (c == ',' || c == ';') break;

    if (c == ':') {
      st.i++;
      String gname = nameParts.join(' ').trim();
      List<dynamic> members = [];
      _apSkipCfws(st);
      while (st.i < st.s.length && st.s[st.i] != ';') {
        if (st.s[st.i] == ',') {
          st.i++;
          _apSkipCfws(st);
          continue;
        }
        var m = _apReadAddressOrGroup(st);
        if (m != null) members.add(m);
        _apSkipCfws(st);
      }
      if (st.i < st.s.length && st.s[st.i] == ';') st.i++;
      return AddressGroup(gname.isNotEmpty ? gname : null, members);
    }

    if (c == '"') {
      nameParts.add(_apReadQuoted(st));
      continue;
    }

    if (c == '<') {
      hasAngle = true;
      st.i++;
      _apSkipCfws(st);
      String lp = _apReadAtom(st);
      if (st.i < st.s.length && st.s[st.i] == '"') lp = _apReadQuoted(st);
      _apSkipCfws(st);
      if (st.i < st.s.length && st.s[st.i] == '@') {
        st.i++;
        _apSkipCfws(st);
        String d = _apReadAtom(st);
        localPart = lp;
        domain = d;
      } else {
        localPart = lp;
      }
      _apSkipCfws(st);
      if (st.i < st.s.length && st.s[st.i] == '>') st.i++;
      continue;
    }

    String atom = _apReadAtom(st);
    if (atom.isEmpty) {
      st.i++;
      continue;
    }

    int save = st.i;
    _apSkipCfws(st);
    if (st.i < st.s.length && st.s[st.i] == '@' && !hasAngle) {
      st.i++;
      _apSkipCfws(st);
      String d = _apReadAtom(st);
      localPart = atom;
      domain = d;
      continue;
    }

    st.i = save;
    nameParts.add(atom);
  }

  String name = nameParts.join(' ').trim();
  if (localPart == null && domain == null && name.isEmpty) return null;
  return {
    'name': name.isNotEmpty ? name : null,
    'mailbox': localPart,
    'host': domain,
  };
}

List<dynamic> parseAddressList(String? str) {
  if (str == null || str.isEmpty) return [];
  ParseState st = ParseState(str, 0);
  List<dynamic> out = [];
  _apSkipCfws(st);
  while (st.i < st.s.length) {
    if (st.s[st.i] == ',') {
      st.i++;
      _apSkipCfws(st);
      continue;
    }
    var a = _apReadAddressOrGroup(st);
    if (a != null) out.add(a);
    _apSkipCfws(st);
  }
  return out;
}
