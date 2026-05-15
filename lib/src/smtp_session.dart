import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'smtp_wire.dart';
import 'utils.dart'; // toU8, u8ToStr, concatU8, indexOfCRLF, parseMailHeaders

// ============================================================
//  Typed authentication results attached to MailObject
// ============================================================

/// Per-message inbound authentication / reputation results.
/// Values for `dkim`, `spf`, `dmarc`, `rdns` are RFC-style verdicts
/// such as 'pass', 'fail', 'softfail', 'neutral', 'none', 'temperror',
/// 'permerror'. Null means "not yet evaluated".
class MailAuthResult {
  String? dkim; // RFC 6376
  String? spf; // RFC 7208
  String? dmarc; // RFC 7489
  String? dmarcPolicy; // 'none' | 'quarantine' | 'reject'
  String? rdns; // forward-confirmed reverse DNS
  String? rdnsHostname;
  String? dkimDomain; // d= tag of the verified signature

  MailAuthResult({
    this.dkim,
    this.spf,
    this.dmarc,
    this.dmarcPolicy,
    this.rdns,
    this.rdnsHostname,
    this.dkimDomain,
  });
}

// ============================================================
//  Constants
// ============================================================

const String DEFAULT_HOSTNAME = 'localhost';
const int DEFAULT_MAX_SIZE = 25 * 1024 * 1024;
const int DEFAULT_MAX_RECIPIENTS = 100;
const int DEFAULT_ACCEPT_TIMEOUT = 30000;

enum SessionState {
  NEW,
  GREETING,
  READY,
  MAIL,
  RCPT,
  DATA,
  BDAT,
  MESSAGE,
  CLOSING,
  CLOSED,
}

// ============================================================
//  SMTPSession
// ============================================================

class SmtpContext {
  SessionState state = SessionState.NEW;
  bool isServer = true;
  bool isSubmission = false;

  String hostname = DEFAULT_HOSTNAME;
  int maxSize = DEFAULT_MAX_SIZE;
  int maxRecipients = DEFAULT_MAX_RECIPIENTS;
  int acceptTimeout = DEFAULT_ACCEPT_TIMEOUT;

  String? remoteAddress;
  String? localAddress;
  bool isTLS = false;
  Map<String, dynamic>? tlsOptions;

  bool advertiseTLS = false;
  bool advertiseAuth = false;
  List<String> authMethods = ['PLAIN', 'LOGIN', 'XOAUTH2'];
  List<String> extraCapabilities = [];

  Map<String, dynamic>? remoteCaps;
  String? clientHostname;
  bool ehloReceived = false;

  bool authenticated = false;
  String? authUsername;
  bool authInProgress = false;
  String? authMechanism;
  Map<String, dynamic>? authData;

  String? mailFrom;
  Map<String, dynamic>? mailParams;
  List<String> rcptTo = [];
  List<Map<String, dynamic>> rcptParams = [];

  Uint8List inputBuf = Uint8List(0);
  List<Uint8List> dataChunks = [];
  int dataSize = 0;

  int bdatExpect = 0;
  List<Uint8List> bdatAccum = [];
  int bdatTotal = 0;
  bool bdatLast = false;

  Timer? acceptTimer;
  int messageCount = 0;

  Function? pendingReply;
}

class MailObject {
  String? from;
  List<String> to = [];
  Map<String, dynamic>? params;

  String? subject;
  String? messageId;
  String? date;
  String? headerFrom;
  String? headerTo;

  MailAuthResult auth = MailAuthResult();

  Uint8List raw = Uint8List(0);
  int size = 0;

  String? text;
  String? html;
  List<dynamic>? attachments;

  final EventEmitter _mailEv = EventEmitter();

  void on(String name, Function fn) => _mailEv.on(name, fn);
  void off(String name, Function fn) => _mailEv.off(name, fn);

  bool _accepted = false;
  bool _rejected = false;

  Function? _acceptFn;
  Function(int?, String?)? _rejectFn;
  Function(Uint8List)? _parseMessageFn;

  void emitBody() {
    if (_rejected) return;

    _mailEv.emit('data', raw);

    if (_parseMessageFn != null) {
      try {
        var parsed = _parseMessageFn!(raw);
        if (parsed != null) {
          text = parsed.text;
          html = parsed.html;
          attachments = parsed.attachments;
        }
      } catch (e) {}
    }

    _mailEv.emit('end');
  }

  void accept() {
    if (_accepted || _rejected) return;
    _accepted = true;
    if (_acceptFn != null) _acceptFn!();
  }

  void reject([int? code, String? message]) {
    if (_accepted || _rejected) return;
    _rejected = true;
    if (_rejectFn != null) _rejectFn!(code, message);
  }
}

/// Typed payload emitted on the `'auth'` event from [SMTPSession]
/// (server-side). Replaces the previous 4-arg loose tuple.
class SmtpAuthRequest {
  final String username;

  /// Password (PLAIN/LOGIN) or bearer token (XOAUTH2).
  final String password;

  /// `'plain'`, `'login'`, or `'xoauth2'`.
  final String authMethod;
  final void Function() accept;
  final void Function() reject;

  const SmtpAuthRequest({
    required this.username,
    required this.password,
    required this.authMethod,
    required this.accept,
    required this.reject,
  });
}

/// Typed construction options for [SMTPSession].
///
/// Replaces the previous `Map<String, dynamic>` constructor argument.
class SMTPSessionOptions {
  final bool isServer;
  final bool isSubmission;
  final String hostname;
  final int maxSize;
  final int maxRecipients;
  final int acceptTimeout;
  final String? remoteAddress;
  final String? localAddress;
  final bool isTLS;
  final Map<String, dynamic>? tlsOptions;
  final List<String>? authMethods;
  final List<String>? extraCapabilities;

  const SMTPSessionOptions({
    this.isServer = true,
    this.isSubmission = false,
    this.hostname = DEFAULT_HOSTNAME,
    this.maxSize = DEFAULT_MAX_SIZE,
    this.maxRecipients = DEFAULT_MAX_RECIPIENTS,
    this.acceptTimeout = DEFAULT_ACCEPT_TIMEOUT,
    this.remoteAddress,
    this.localAddress,
    this.isTLS = false,
    this.tlsOptions,
    this.authMethods,
    this.extraCapabilities,
  });

  factory SMTPSessionOptions.fromMap(Map<String, dynamic>? m) {
    m ??= const {};
    return SMTPSessionOptions(
      isServer: m['isServer'] != false,
      isSubmission: m['isSubmission'] == true,
      hostname: (m['hostname'] as String?) ?? DEFAULT_HOSTNAME,
      maxSize: (m['maxSize'] as int?) ?? DEFAULT_MAX_SIZE,
      maxRecipients: (m['maxRecipients'] as int?) ?? DEFAULT_MAX_RECIPIENTS,
      acceptTimeout: (m['acceptTimeout'] as int?) ?? DEFAULT_ACCEPT_TIMEOUT,
      remoteAddress: m['remoteAddress'] as String?,
      localAddress: m['localAddress'] as String?,
      isTLS: m['isTLS'] == true,
      tlsOptions: m['tlsOptions'] as Map<String, dynamic>?,
      authMethods: m['authMethods'] is List
          ? List<String>.from(m['authMethods'] as List)
          : null,
      extraCapabilities: m['extraCapabilities'] is List
          ? List<String>.from(m['extraCapabilities'] as List)
          : null,
    );
  }
}

class SMTPSession {
  final EventEmitter _ev = EventEmitter();
  final SmtpContext context = SmtpContext();

  dynamic Function(Uint8List) _parseMessage = (Uint8List buf) => null;

  SMTPSession([SMTPSessionOptions? options]) {
    final opts = options ?? const SMTPSessionOptions();

    context.isServer = opts.isServer;
    context.isSubmission = opts.isSubmission;

    context.hostname = opts.hostname;
    context.maxSize = opts.maxSize;
    context.maxRecipients = opts.maxRecipients;
    context.acceptTimeout = opts.acceptTimeout;

    context.remoteAddress = opts.remoteAddress;
    context.localAddress = opts.localAddress;
    context.isTLS = opts.isTLS;
    context.tlsOptions = opts.tlsOptions;

    context.advertiseTLS = !context.isTLS && context.tlsOptions != null;
    context.advertiseAuth = context.isSubmission;
    if (opts.authMethods != null) {
      context.authMethods = List<String>.from(opts.authMethods!);
    }
    if (opts.extraCapabilities != null) {
      context.extraCapabilities = List<String>.from(opts.extraCapabilities!);
    }
  }

  void on(String name, Function fn) => _ev.on(name, fn);
  void off(String name, Function fn) => _ev.off(name, fn);

  bool get isServer => context.isServer;
  SessionState get state => context.state;
  bool get authenticated => context.authenticated;
  String? get username => context.authUsername;
  String? get clientHostname => context.clientHostname;
  String? get remoteAddress => context.remoteAddress;
  bool get isTLS => context.isTLS;
  int get messageCount => context.messageCount;
  Map<String, dynamic>? get capabilities => context.remoteCaps;

  void appendInput(Uint8List chunk) {
    if (context.inputBuf.isEmpty) {
      context.inputBuf = chunk;
    } else {
      Uint8List out = Uint8List(context.inputBuf.length + chunk.length);
      out.setAll(0, context.inputBuf);
      out.setAll(context.inputBuf.length, chunk);
      context.inputBuf = out;
    }
  }

  void consumeInput(int n) {
    if (n >= context.inputBuf.length) {
      context.inputBuf = Uint8List(0);
    } else {
      context.inputBuf = Uint8List.sublistView(context.inputBuf, n);
    }
  }

  void send(String data) {
    if (context.state == SessionState.CLOSED) return;
    _ev.emit('send', data);
  }

  void sendReply(int code, Object message, [String? enhanced]) {
    send(buildReply(code, message, enhanced: enhanced));
  }

  List<String> getCapabilities() {
    List<String> caps = [];
    caps.add('PIPELINING');
    caps.add('SIZE ${context.maxSize}');
    caps.add('8BITMIME');
    caps.add('SMTPUTF8');
    caps.add('DSN');
    caps.add('ENHANCEDSTATUSCODES');

    if (context.advertiseTLS) {
      caps.add('STARTTLS');
    }

    if (context.isTLS) {
      caps.add('REQUIRETLS');
    }

    if (context.advertiseAuth && context.authMethods.isNotEmpty) {
      caps.add('AUTH ${context.authMethods.join(" ")}');
    }

    caps.addAll(context.extraCapabilities);

    return caps;
  }

  void resetTransaction() {
    context.mailFrom = null;
    context.mailParams = null;
    context.rcptTo = [];
    context.rcptParams = [];
    context.dataChunks = [];
    context.dataSize = 0;
    context.bdatExpect = 0;
    context.bdatAccum = [];
    context.bdatTotal = 0;
    context.bdatLast = false;

    if (context.acceptTimer != null) {
      context.acceptTimer!.cancel();
      context.acceptTimer = null;
    }

    if (context.state != SessionState.CLOSING &&
        context.state != SessionState.CLOSED) {
      context.state = SessionState.READY;
    }
  }

  void startAcceptTimeout() {
    if (context.acceptTimeout > 0) {
      context.acceptTimer = Timer(
        Duration(milliseconds: context.acceptTimeout),
        () {
          sendReply(451, 'Timeout waiting for processing', '4.3.0');
          resetTransaction();
        },
      );
    }
  }

  void finalizeMessage(Uint8List rawU8) {
    context.state = SessionState.MESSAGE;
    context.messageCount++;

    // RFC 5321 §4.1.1.4: the message body MUST end with <CRLF>. The wire
    // dot-stuffed terminator is consumed before we get here, but if the
    // client sent a body that didn't end with CRLF the captured bytes won't
    // either. Normalize so downstream consumers (IMAP RFC822 fetch, POP3
    // RETR) always see a properly terminated message.
    if (rawU8.isEmpty ||
        rawU8.length < 2 ||
        rawU8[rawU8.length - 2] != 0x0D ||
        rawU8[rawU8.length - 1] != 0x0A) {
      final fixed = Uint8List(rawU8.length + 2);
      fixed.setRange(0, rawU8.length, rawU8);
      fixed[rawU8.length] = 0x0D;
      fixed[rawU8.length + 1] = 0x0A;
      rawU8 = fixed;
    }

    var parsed = parseMailHeaders(rawU8);
    var headers = parsed.map;

    MailObject mailObject = MailObject();
    mailObject.from = context.mailFrom;
    mailObject.to = List.from(context.rcptTo);
    mailObject.params = context.mailParams;
    mailObject.subject = headers['subject'];
    mailObject.messageId = headers['messageId'];
    mailObject.date = headers['date'];
    mailObject.headerFrom = headers['from'];
    mailObject.headerTo = headers['to'];
    mailObject.raw = rawU8;
    mailObject.size = rawU8.length;
    mailObject._parseMessageFn = _parseMessage;

    mailObject._acceptFn = () {
      if (context.acceptTimer != null) {
        context.acceptTimer!.cancel();
        context.acceptTimer = null;
      }
      sendReply(250, 'Ok queued', '2.0.0');
      resetTransaction();
    };

    mailObject._rejectFn = (int? code, String? message) {
      if (context.acceptTimer != null) {
        context.acceptTimer!.cancel();
        context.acceptTimer = null;
      }
      code ??= 550;
      message ??= 'Rejected';
      String enhanced = (code ~/ 100 == 5) ? '5.7.1' : '4.7.1';
      sendReply(code, message, enhanced);
      resetTransaction();
    };

    startAcceptTimeout();
    _ev.emit('message', mailObject);
  }

  void setParseMessage(dynamic Function(Uint8List) fn) {
    _parseMessage = fn;
  }

  Uint8List undotStuff(Uint8List body) {
    body = normalizeCRLF(body);

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
    return Uint8List.sublistView(out, 0, w);
  }

  Uint8List normalizeCRLF(Uint8List data) {
    int extra = 0;
    for (int i = 0; i < data.length; i++) {
      if (data[i] == 10 && (i == 0 || data[i - 1] != 13)) {
        extra++;
      } else if (data[i] == 13 && (i + 1 >= data.length || data[i + 1] != 10))
        extra++;
    }
    if (extra == 0) return data;

    Uint8List out = Uint8List(data.length + extra);
    int w = 0;
    for (int i = 0; i < data.length; i++) {
      if (data[i] == 13) {
        out[w++] = 13;
        if (i + 1 < data.length && data[i + 1] == 10) {
          out[w++] = 10;
          i++;
        } else {
          out[w++] = 10;
        }
      } else if (data[i] == 10) {
        if (i > 0 && data[i - 1] == 13) {
          out[w++] = 10;
        } else {
          out[w++] = 13;
          out[w++] = 10;
        }
      } else {
        out[w++] = data[i];
      }
    }
    return Uint8List.sublistView(out, 0, w);
  }

  void processCommand(Uint8List lineU8) {
    var cmd = parseCommandLine(lineU8);
    _ev.emit('command', cmd);

    switch (cmd['type']) {
      case 'EHLO':
        context.clientHostname = cmd['host'];
        context.ehloReceived = true;
        resetTransaction();
        context.state = SessionState.READY;
        send(buildEhloReply(context.hostname, getCapabilities()));
        _ev.emit('ehlo', cmd['host']);
        break;

      case 'HELO':
        context.clientHostname = cmd['host'];
        context.ehloReceived = true;
        resetTransaction();
        context.state = SessionState.READY;
        sendReply(250, context.hostname);
        break;

      case 'MAIL':
        if (cmd['error'] != null) {
          sendReply(501, 'Syntax error', '5.5.2');
          break;
        }
        if (context.state != SessionState.READY) {
          sendReply(503, 'Bad sequence', '5.5.1');
          break;
        }
        if (context.isSubmission && !context.authenticated) {
          sendReply(530, 'Authentication required', '5.7.0');
          break;
        }
        if (context.mailFrom != null) {
          sendReply(503, 'Nested MAIL', '5.5.1');
          break;
        }

        if (cmd['params'] != null &&
            cmd['params']['size'] != null &&
            (cmd['params']['size'] as int) > context.maxSize) {
          sendReply(552, 'Message size exceeds limit', '5.3.4');
          break;
        }

        if (cmd['params'] != null &&
            cmd['params']['requiretls'] == true &&
            !context.isTLS) {
          sendReply(550, 'REQUIRETLS requires active TLS', '5.7.10');
          break;
        }

        context.mailFrom = cmd['from'];
        context.mailParams = cmd['params'] ?? {};
        context.state = SessionState.MAIL;
        sendReply(250, 'Ok', contextCode['MAIL_FROM_OK']);
        _ev.emit('mail', cmd['from'], cmd['params']);
        break;

      case 'RCPT':
        if (cmd['error'] != null) {
          sendReply(501, 'Syntax error', '5.5.2');
          break;
        }
        if (context.state != SessionState.MAIL &&
            context.state != SessionState.RCPT) {
          sendReply(503, 'Bad sequence', '5.5.1');
          break;
        }
        if (context.rcptTo.length >= context.maxRecipients) {
          sendReply(452, 'Too many recipients', '4.5.3');
          break;
        }

        String rcptAddress = cmd['to'];
        Map<String, dynamic> rcptParams = cmd['params'] ?? {};
        bool rcptAccepted = true;
        int rcptRejectCode = 550;
        String rcptRejectMsg = 'User not found';

        _ev.emit('rcpt', rcptAddress, rcptParams, {
          'reject': (int? code, String? msg) {
            rcptAccepted = false;
            rcptRejectCode = code ?? 550;
            rcptRejectMsg = msg ?? 'User not found';
          },
        });

        if (!rcptAccepted) {
          sendReply(rcptRejectCode, rcptRejectMsg, '5.1.1');
          break;
        }

        context.rcptTo.add(rcptAddress);
        context.rcptParams.add(rcptParams);
        context.state = SessionState.RCPT;
        sendReply(250, 'Ok', contextCode['RCPT_TO_OK']);
        break;

      case 'DATA_START':
        if (context.state != SessionState.RCPT) {
          sendReply(503, 'Bad sequence', '5.5.1');
          break;
        }
        context.state = SessionState.DATA;
        context.dataChunks = [];
        context.dataSize = 0;
        sendReply(354, 'End data with <CRLF>.<CRLF>');
        break;

      case 'BDAT_HEADER_ONLY':
        if (context.state != SessionState.RCPT &&
            context.state != SessionState.BDAT) {
          sendReply(503, 'Bad sequence', '5.5.1');
          break;
        }
        var bh = parseBdatHeaderLine(cmd['raw'] ?? u8ToStr(lineU8));
        if (bh == null) {
          sendReply(501, 'Syntax error', '5.5.2');
          break;
        }
        context.state = SessionState.BDAT;
        context.bdatExpect = bh['size'];
        context.bdatLast = bh['last'];
        break;

      case 'AUTH':
        if (context.authenticated) {
          sendReply(503, 'Already authenticated', '5.5.1');
          break;
        }
        if (!context.advertiseAuth) {
          sendReply(502, 'Not implemented', '5.5.1');
          break;
        }
        if (cmd['error'] != null) {
          sendReply(501, 'Syntax error', '5.5.4');
          break;
        }

        String mech = cmd['mechanism'];
        if (!context.authMethods.contains(mech)) {
          sendReply(504, 'Unsupported mechanism', '5.5.4');
          break;
        }

        if (mech == 'PLAIN') {
          if (cmd['initial'] != null) {
            handleAuthPlain(cmd['initial']);
          } else {
            context.authInProgress = true;
            context.authMechanism = 'PLAIN';
            sendReply(334, '');
          }
        } else if (mech == 'LOGIN') {
          context.authInProgress = true;
          context.authMechanism = 'LOGIN';
          context.authData = {};
          sendReply(334, base64.encode(utf8.encode('Username:')));
        } else if (mech == 'XOAUTH2') {
          if (cmd['initial'] != null) {
            handleAuthXoauth2(cmd['initial']);
          } else {
            context.authInProgress = true;
            context.authMechanism = 'XOAUTH2';
            sendReply(334, '');
          }
        } else {
          sendReply(504, 'Mechanism not supported yet', '5.5.4');
        }
        break;

      case 'STARTTLS':
        if (context.isTLS) {
          sendReply(503, 'Already TLS', '5.5.1');
          break;
        }
        if (context.tlsOptions == null) {
          sendReply(502, 'Not available', '5.5.1');
          break;
        }
        sendReply(220, 'Ready to start TLS');
        _ev.emit('starttls');
        break;

      case 'RSET':
        resetTransaction();
        sendReply(250, 'Ok', '2.0.0');
        break;

      case 'NOOP':
        sendReply(250, 'Ok', '2.0.0');
        break;

      case 'QUIT':
        context.state = SessionState.CLOSING;
        sendReply(221, 'Bye', '2.0.0');
        _ev.emit('close');
        break;

      case 'VRFY':
        sendReply(252, 'Cannot VRFY user', '2.1.5');
        break;

      default:
        sendReply(502, 'Command not implemented', '5.5.1');
        break;
    }
  }

  void handleAuthPlain(String data) {
    String decoded;
    try {
      decoded = utf8.decode(base64.decode(data));
    } catch (e) {
      sendReply(535, 'Invalid encoding', '5.7.8');
      context.authInProgress = false;
      return;
    }

    List<String> parts = decoded.split('\x00');
    if (parts.length < 3) {
      sendReply(535, 'Invalid credentials', '5.7.8');
      context.authInProgress = false;
      return;
    }

    String username = parts[1].isNotEmpty ? parts[1] : parts[0];
    String password = parts[2];

    context.authInProgress = false;
    context.authMechanism = null;

    _ev.emit(
      'auth',
      SmtpAuthRequest(
        username: username,
        password: password,
        authMethod: 'plain',
        accept: () {
          context.authenticated = true;
          context.authUsername = username;
          sendReply(235, 'Authentication successful', '2.7.0');
        },
        reject: () {
          sendReply(535, 'Authentication failed', '5.7.8');
        },
      ),
    );
  }

  void handleAuthLogin(String data) {
    if (context.authData?['username'] == null) {
      try {
        context.authData ??= {};
        context.authData!['username'] = utf8.decode(base64.decode(data));
      } catch (e) {
        sendReply(535, 'Invalid encoding', '5.7.8');
        context.authInProgress = false;
        context.authData = null;
        return;
      }
      sendReply(334, base64.encode(utf8.encode('Password:')));
    } else {
      String password;
      try {
        password = utf8.decode(base64.decode(data));
      } catch (e) {
        sendReply(535, 'Invalid encoding', '5.7.8');
        context.authInProgress = false;
        context.authData = null;
        return;
      }

      String username = context.authData!['username'];
      context.authInProgress = false;
      context.authMechanism = null;
      context.authData = null;

      _ev.emit(
        'auth',
        SmtpAuthRequest(
          username: username,
          password: password,
          authMethod: 'login',
          accept: () {
            context.authenticated = true;
            context.authUsername = username;
            sendReply(235, 'Authentication successful', '2.7.0');
          },
          reject: () {
            sendReply(535, 'Authentication failed', '5.7.8');
          },
        ),
      );
    }
  }

  void handleAuthXoauth2(String data) {
    String decoded;
    try {
      decoded = utf8.decode(base64.decode(data));
    } catch (e) {
      sendReply(535, 'Invalid encoding', '5.7.8');
      context.authInProgress = false;
      context.authMechanism = null;
      return;
    }

    List<String> parts = decoded.split('\x01');
    String? username;
    String? token;
    for (String p in parts) {
      if (p.startsWith('user=')) {
        username = p.substring(5);
      } else if (p.startsWith('auth=Bearer '))
        token = p.substring(12);
    }
    if (username == null || token == null) {
      sendReply(535, 'Invalid XOAUTH2 payload', '5.7.8');
      context.authInProgress = false;
      context.authMechanism = null;
      return;
    }

    context.authInProgress = false;
    context.authMechanism = null;

    _ev.emit(
      'auth',
      SmtpAuthRequest(
        username: username,
        password: token,
        authMethod: 'xoauth2',
        accept: () {
          context.authenticated = true;
          context.authUsername = username;
          sendReply(235, 'Authentication successful', '2.7.0');
        },
        reject: () {
          sendReply(535, 'Authentication failed', '5.7.8');
        },
      ),
    );
  }

  void feed(Uint8List chunk) {
    if (context.state == SessionState.CLOSED) return;
    appendInput(chunk);

    if (!context.isServer) {
      feedClient();
      return;
    }

    while (true) {
      if (context.state != SessionState.DATA &&
          context.state != SessionState.BDAT) {
        if (context.authInProgress) {
          int cr = indexOfCRLF(context.inputBuf, 0);
          if (cr < 0) break;
          String line = u8ToStr(
            Uint8List.sublistView(context.inputBuf, 0, cr),
          ).trim();
          consumeInput(cr + 2);

          if (line == '*') {
            context.authInProgress = false;
            context.authMechanism = null;
            context.authData = null;
            sendReply(501, 'Authentication cancelled', '5.7.0');
          } else if (context.authMechanism == 'PLAIN') {
            handleAuthPlain(line);
          } else if (context.authMechanism == 'LOGIN') {
            handleAuthLogin(line);
          } else if (context.authMechanism == 'XOAUTH2') {
            handleAuthXoauth2(line);
          }
          continue;
        }

        int cr = indexOfCRLF(context.inputBuf, 0);
        if (cr < 0) break;
        Uint8List lineU8 = Uint8List.sublistView(context.inputBuf, 0, cr);
        consumeInput(cr + 2);

        if (lineU8.isEmpty) continue;

        processCommand(lineU8);
        continue;
      }

      if (context.state == SessionState.DATA) {
        int termAt = -1;
        var buf = context.inputBuf;
        for (int i = 2; i + 2 < buf.length; i++) {
          if (buf[i - 2] == 13 &&
              buf[i - 1] == 10 &&
              buf[i] == 46 &&
              buf[i + 1] == 13 &&
              buf[i + 2] == 10) {
            termAt = i - 2;
            break;
          }
        }

        if (termAt < 0) {
          context.dataChunks.add(Uint8List.fromList(context.inputBuf));
          context.dataSize += context.inputBuf.length;
          context.inputBuf = Uint8List(0);

          if (context.dataSize > context.maxSize) {
            sendReply(552, 'Message size exceeds limit', '5.3.4');
            resetTransaction();
          }
          break;
        }

        Uint8List bodyPart = Uint8List.sublistView(context.inputBuf, 0, termAt);
        context.dataChunks.add(Uint8List.fromList(bodyPart));
        context.dataSize += bodyPart.length;
        consumeInput(termAt + 5);

        Uint8List concatenated = Uint8List(context.dataSize);
        int offset = 0;
        for (var c in context.dataChunks) {
          concatenated.setAll(offset, c);
          offset += c.length;
        }

        Uint8List body = undotStuff(concatenated);
        context.dataChunks = [];
        context.dataSize = 0;
        finalizeMessage(body);
        continue;
      }

      if (context.state == SessionState.BDAT) {
        if (context.bdatExpect > 0) {
          if (context.inputBuf.isEmpty) break;
          int take = min(context.bdatExpect, context.inputBuf.length);
          Uint8List piece = Uint8List.sublistView(context.inputBuf, 0, take);
          context.bdatAccum.add(piece);
          context.bdatTotal += piece.length;
          context.bdatExpect -= take;
          consumeInput(take);

          if (context.bdatExpect > 0) break;

          sendReply(250, 'Ok chunk', '2.0.0');

          if (context.bdatLast) {
            Uint8List raw = Uint8List(context.bdatTotal);
            int off = 0;
            for (var c in context.bdatAccum) {
              raw.setAll(off, c);
              off += c.length;
            }
            context.bdatAccum = [];
            context.bdatTotal = 0;
            context.bdatLast = false;
            context.state = SessionState.READY;
            finalizeMessage(raw);
          } else {
            context.state = SessionState.RCPT;
          }
        } else {
          context.state = SessionState.RCPT;
        }
        continue;
      }

      break;
    }
  }

  void feedClient() {
    if (context.pendingReply == null) return;

    var buf = context.inputBuf;
    int endIdx = -1;

    for (int i = 0; i + 1 < buf.length; i++) {
      if (buf[i] == 13 && buf[i + 1] == 10) {
        int nextLineStart = i + 2;
        if (nextLineStart + 3 < buf.length &&
            buf[nextLineStart] >= 48 &&
            buf[nextLineStart] <= 57 &&
            buf[nextLineStart + 1] >= 48 &&
            buf[nextLineStart + 1] <= 57 &&
            buf[nextLineStart + 2] >= 48 &&
            buf[nextLineStart + 2] <= 57 &&
            buf[nextLineStart + 3] == 32) {
          for (int k = nextLineStart + 4; k + 1 < buf.length; k++) {
            if (buf[k] == 13 && buf[k + 1] == 10) {
              endIdx = k + 2;
              break;
            }
          }
          if (endIdx >= 0) break;
        }
      }
    }

    if (endIdx < 0 &&
        buf.length >= 5 &&
        buf[0] >= 48 &&
        buf[0] <= 57 &&
        buf[1] >= 48 &&
        buf[1] <= 57 &&
        buf[2] >= 48 &&
        buf[2] <= 57 &&
        buf[3] == 32) {
      for (int k = 4; k + 1 < buf.length; k++) {
        if (buf[k] == 13 && buf[k + 1] == 10) {
          endIdx = k + 2;
          break;
        }
      }
    }

    if (endIdx < 0) return;

    Uint8List replyData = Uint8List.sublistView(context.inputBuf, 0, endIdx);
    consumeInput(endIdx);
    var parsed = SmtpReply.fromMap(parseReplyBlock(replyData));
    Function fn = context.pendingReply!;
    context.pendingReply = null;
    fn(parsed);
  }

  void clientReadReply(void Function(SmtpReply) onReply) {
    context.pendingReply = onReply;
    feedClient();
  }

  void clientSendLine(String line) {
    send('$line\r\n');
  }

  void clientEhlo(Function cb) {
    clientSendLine('EHLO ${context.hostname}');
    clientReadReply((reply) {
      if (reply.code != 250) {
        clientSendLine('HELO ${context.hostname}');
        clientReadReply((helo) {
          if (helo.code != 250) {
            return cb(Exception('HELO rejected: ${helo.code}'));
          }
          context.remoteCaps = {};
          context.state = SessionState.READY;
          cb(null);
        });
        return;
      }
      context.remoteCaps = reply.capabilities ?? {};
      context.state = SessionState.READY;
      cb(null);
    });
  }

  void clientStartTLS(Function cb) {
    clientSendLine('STARTTLS');
    clientReadReply((reply) {
      if (reply.code != 220) {
        return cb(Exception('STARTTLS rejected: ${reply.code}'));
      }
      _ev.emit('starttls');
      cb(null);
    });
  }

  void clientAuthPlain(String user, String pass, Function cb) {
    String creds = base64.encode(utf8.encode('\x00$user\x00$pass'));
    clientSendLine('AUTH PLAIN $creds');
    clientReadReply((reply) {
      if (reply.code == 235) {
        context.authenticated = true;
        context.authUsername = user;
        cb(null);
      } else {
        cb(Exception('Auth failed: ${reply.code}'));
      }
    });
  }

  void clientMailFrom(
    String address,
    Map<String, dynamic>? params,
    Function cb,
  ) {
    String line = 'MAIL FROM:<$address>';
    if (params != null && params['size'] != null) {
      line += ' SIZE=${params['size']}';
    }
    if (params != null && params['body'] != null) {
      line += ' BODY=${params['body']}';
    }
    if (params != null && params['smtputf8'] == true) line += ' SMTPUTF8';
    if (params != null && params['requiretls'] == true) line += ' REQUIRETLS';
    clientSendLine(line);
    clientReadReply((reply) {
      if (reply.code == 250) {
        context.mailFrom = address;
        context.mailParams = params ?? {};
        context.state = SessionState.MAIL;
        cb(null);
      } else {
        String msg = reply.replyLines.isNotEmpty ? reply.replyLines[0] : '';
        cb(Exception('MAIL FROM rejected: ${reply.code} $msg'));
      }
    });
  }

  void clientRcptTo(String address, Function cb) {
    clientSendLine('RCPT TO:<$address>');
    clientReadReply((reply) {
      if (reply.code == 250 || reply.code == 251) {
        context.rcptTo.add(address);
        context.state = SessionState.RCPT;
        cb(null);
      } else {
        String msg = reply.replyLines.isNotEmpty ? reply.replyLines[0] : '';
        cb(Exception('RCPT TO rejected: ${reply.code} $msg'));
      }
    });
  }

  void clientData(Object rawMessage, Function cb) {
    clientSendLine('DATA');
    clientReadReply((reply) {
      if (reply.code != 354) {
        return cb(Exception('DATA rejected: ${reply.code}'));
      }

      String str;
      if (rawMessage is Uint8List) {
        str = u8ToStr(rawMessage);
      } else if (rawMessage is List<int>) {
        str = utf8.decode(rawMessage);
      } else {
        str = rawMessage.toString();
      }

      String stuffed = str.replaceAll('\r\n.', '\r\n..');
      send('$stuffed\r\n.\r\n');

      clientReadReply((reply2) {
        if (reply2.code == 250) {
          context.messageCount++;
          resetTransaction();
          cb(null, reply2);
        } else {
          String msg = reply2.replyLines.isNotEmpty ? reply2.replyLines[0] : '';
          cb(Exception('Message rejected: ${reply2.code} $msg'));
        }
      });
    });
  }

  void clientQuit() {
    clientSendLine('QUIT');
    context.state = SessionState.CLOSING;
  }

  void greet() {
    if (context.isServer) {
      context.state = SessionState.GREETING;
      sendReply(220, '${context.hostname} ESMTP ready');
    } else {
      context.state = SessionState.GREETING;
      clientReadReply((banner) {
        if (banner.code != 220) {
          _ev.emit('error', Exception('Bad banner: ${banner.code}'));
          return;
        }
        if (banner.bannerDomain != null) {
          context.clientHostname = banner.bannerDomain;
        }

        clientEhlo((err) {
          if (err != null) {
            _ev.emit('error', err);
            return;
          }

          if (context.remoteCaps != null &&
              context.remoteCaps!['starttls'] == true &&
              !context.isTLS) {
            clientStartTLS((err) {
              if (err != null) {
                _ev.emit('ready');
                return;
              }
            });
          } else {
            _ev.emit('ready');
          }
        });
      });
    }
  }

  void close() {
    if (context.state == SessionState.CLOSED) return;

    if (context.acceptTimer != null) {
      context.acceptTimer!.cancel();
      context.acceptTimer = null;
    }

    context.pendingReply = null;
    context.inputBuf = Uint8List(0);
    context.dataChunks = [];
    context.dataSize = 0;
    context.bdatAccum = [];

    context.state = SessionState.CLOSED;
    _ev.emit('close');
    _ev.removeAllListeners();
  }

  void tlsUpgraded() {
    context.isTLS = true;
    context.advertiseTLS = false;
    context.inputBuf = Uint8List(0);

    if (context.isServer) {
      context.ehloReceived = false;
      context.clientHostname = null;
      context.authenticated = false;
      context.authUsername = null;
      resetTransaction();
      context.state = SessionState.GREETING;
    } else {
      clientEhlo((err) {
        if (err != null) {
          _ev.emit('error', err);
          return;
        }
        _ev.emit('ready');
      });
    }
  }

  // Client aliases
  void mailFrom(String from, Map<String, dynamic> params, Function cb) =>
      clientMailFrom(from, params, cb);
  void rcptTo(String to, Function cb) => clientRcptTo(to, cb);
  void data(Object rawMessage, Function cb) => clientData(rawMessage, cb);
  void authPlain(String user, String pass, Function cb) =>
      clientAuthPlain(user, pass, cb);
  void quit() => clientQuit();
  void sendLine(String line) => clientSendLine(line);
  void readReply(void Function(SmtpReply) cb) => clientReadReply(cb);
}
