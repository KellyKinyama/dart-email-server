// import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'utils.dart';

// ============================================================================
//  pop3_session.dart  —  POP3 protocol session (RFC 1939)
// ----------------------------------------------------------------------------
//  Core engine for POP3 sessions. Supports server-side RFC 1939 commands
//  mapping them to the shared mailboxSession event interface.
// ============================================================================

const String DEFAULT_HOSTNAME = 'localhost';
const int DEFAULT_MAX_COMMAND = 64 * 1024; // 64KB for command lines

enum SessionState { NEW, GREETING, AUTHORIZATION, TRANSACTION, UPDATE, CLOSED }

class POP3Message {
  int seq;
  int uid;
  int size;
  bool deleted;
  POP3Message({
    required this.seq,
    required this.uid,
    required this.size,
    this.deleted = false,
  });
}

/// Typed construction options for [POP3Session].
class POP3SessionOptions {
  final bool isServer;
  final String hostname;
  final int maxCommandSize;
  final String? remoteAddress;
  final bool isTLS;
  final Map<String, dynamic>? tlsOptions;

  const POP3SessionOptions({
    this.isServer = true,
    this.hostname = DEFAULT_HOSTNAME,
    this.maxCommandSize = DEFAULT_MAX_COMMAND,
    this.remoteAddress,
    this.isTLS = false,
    this.tlsOptions,
  });

  factory POP3SessionOptions.fromMap(Map<String, dynamic>? m) {
    m ??= const {};
    return POP3SessionOptions(
      isServer: m['isServer'] != false,
      hostname: (m['hostname'] as String?) ?? DEFAULT_HOSTNAME,
      maxCommandSize: (m['maxCommandSize'] as int?) ?? DEFAULT_MAX_COMMAND,
      remoteAddress: m['remoteAddress'] as String?,
      isTLS: m['isTLS'] == true,
      tlsOptions: m['tlsOptions'] as Map<String, dynamic>?,
    );
  }
}

/// Typed payload emitted on the `'pop3Auth'` event from [POP3Session].
class Pop3AuthRequest {
  final String username;
  final String password;
  final String authMethod;
  final String? remoteAddress;
  final bool isTLS;
  final void Function(String, Function) on;
  final void Function(String, Function) off;
  final void Function() accept;
  final void Function([String? msg]) reject;

  const Pop3AuthRequest({
    required this.username,
    required this.password,
    required this.authMethod,
    required this.remoteAddress,
    required this.isTLS,
    required this.on,
    required this.off,
    required this.accept,
    required this.reject,
  });
}

class POP3Session {
  final EventEmitter _ev = EventEmitter();
  final POP3SessionOptions _options;

  SessionState state = SessionState.NEW;
  bool isServer = true;
  String hostname = DEFAULT_HOSTNAME;
  int maxCommandSize = DEFAULT_MAX_COMMAND;
  String? remoteAddress;
  bool isTLS = false;
  Map<String, dynamic>? tlsOptions;

  Uint8List inputBuf = Uint8List(0);
  String? pendingUser;
  Map<String, dynamic>? authInProgress;
  bool authenticated = false;
  String? username;
  List<POP3Message>? messages;

  // Client side
  Map<String, dynamic>? pendingCommand;
  List<Map<String, dynamic>> commandQueue = [];

  POP3Session([POP3SessionOptions? options])
    : _options = options ?? const POP3SessionOptions() {
    isServer = _options.isServer;
    hostname = _options.hostname;
    maxCommandSize = _options.maxCommandSize;
    remoteAddress = _options.remoteAddress;
    isTLS = _options.isTLS;
    tlsOptions = _options.tlsOptions;
  }

  void on(String name, Function fn) => _ev.on(name, fn);
  void off(String name, Function fn) => _ev.off(name, fn);

  void appendInput(Uint8List chunk) {
    if (inputBuf.isEmpty) {
      inputBuf = chunk;
    } else {
      var merged = Uint8List(inputBuf.length + chunk.length);
      merged.setAll(0, inputBuf);
      merged.setAll(inputBuf.length, chunk);
      inputBuf = merged;
    }
  }

  void consumeInput(int n) {
    if (n >= inputBuf.length) {
      inputBuf = Uint8List(0);
    } else {
      inputBuf = Uint8List.sublistView(inputBuf, n);
    }
  }

  void send(dynamic data) {
    if (state == SessionState.CLOSED) return;
    _ev.emit('send', toU8(data));
  }

  void sendOk([String text = '']) => send('+OK $text\r\n');
  void sendErr([String text = '']) => send('-ERR $text\r\n');
  void sendLine(String text) => send('$text\r\n');
  void sendEnd() => send('.\r\n');

  void feed(dynamic chunk) {
    if (state == SessionState.CLOSED) return;
    appendInput(toU8(chunk));
    if (isServer) {
      _feedServer();
    } else {
      _feedClient();
    }
  }

  void tlsUpgraded() {
    isTLS = true;
    _ev.emit('tlsUpgraded');
  }

  void _feedServer() {
    while (state != SessionState.CLOSED) {
      if (authInProgress != null) {
        int cr = indexOfCRLF(inputBuf);
        if (cr < 0) break;
        String line = u8ToStr(Uint8List.sublistView(inputBuf, 0, cr)).trim();
        consumeInput(cr + 2);
        _handleAuthContinuation(line);
        continue;
      }

      int cr = indexOfCRLF(inputBuf);
      if (cr < 0) {
        if (inputBuf.length > maxCommandSize) {
          sendErr('Command too long');
          close();
        }
        break;
      }

      String line = u8ToStr(Uint8List.sublistView(inputBuf, 0, cr));
      consumeInput(cr + 2);
      _dispatchCommand(line);
    }
  }

  void _dispatchCommand(String line) {
    var parts = line.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return;
    String cmd = parts[0].toUpperCase();
    List<String> args = parts.length > 1 ? parts.sublist(1) : [];

    switch (cmd) {
      case 'CAPA':
        _handleCapa();
        break;
      case 'NOOP':
        _handleNoop();
        break;
      case 'STLS':
        _handleStls();
        break;
      case 'USER':
        _handleUser(args);
        break;
      case 'PASS':
        _handlePass(args);
        break;
      case 'AUTH':
        _handleAuth(args);
        break;
      case 'STAT':
        _handleStat();
        break;
      case 'LIST':
        _handleList(args);
        break;
      case 'UIDL':
        _handleUidl(args);
        break;
      case 'RETR':
        _handleRetr(args);
        break;
      case 'TOP':
        _handleTop(args);
        break;
      case 'DELE':
        _handleDele(args);
        break;
      case 'RSET':
        _handleRset();
        break;
      case 'QUIT':
        _handleQuit();
        break;
      default:
        sendErr('Unknown command: $cmd');
    }
  }

  // --- Handlers ---
  void _handleCapa() {
    sendOk('Capability list follows');
    sendLine('USER');
    sendLine('UIDL');
    sendLine('TOP');
    sendLine('RESP-CODES');
    sendLine('PIPELINING');
    sendLine('SASL PLAIN XOAUTH2');
    if (tlsOptions != null && !isTLS) sendLine('STLS');
    sendLine('IMPLEMENTATION email-server');
    sendEnd();
  }

  void _handleNoop() => sendOk();

  void _handleStls() {
    if (state != SessionState.AUTHORIZATION) {
      sendErr('STLS only in authorization');
      return;
    }
    if (tlsOptions == null) {
      sendErr('STLS not available');
      return;
    }
    if (isTLS) {
      sendErr('Already under TLS');
      return;
    }
    sendOk('Begin TLS negotiation');
    _ev.emit('starttls');
  }

  void _handleUser(List<String> args) {
    if (state != SessionState.AUTHORIZATION) {
      sendErr('Already logged in');
      return;
    }
    if (args.isEmpty) {
      sendErr('USER requires username');
      return;
    }
    pendingUser = args.join(' ');
    sendOk('User accepted');
  }

  void _handlePass(List<String> args) {
    if (state != SessionState.AUTHORIZATION) {
      sendErr('Already logged in');
      return;
    }
    if (pendingUser == null) {
      sendErr('USER first');
      return;
    }
    if (args.isEmpty) {
      sendErr('PASS requires password');
      return;
    }
    String pass = args.join(' ');
    _emitAuth(pendingUser!, pass, 'plain');
    pendingUser = null;
  }

  void _handleAuth(List<String> args) {
    if (state != SessionState.AUTHORIZATION) {
      sendErr('Already logged in');
      return;
    }
    if (args.isEmpty) {
      sendErr('AUTH requires mechanism');
      return;
    }
    String mech = args[0].toUpperCase();
    String? initial = args.length > 1 ? args[1] : null;

    if (mech == 'PLAIN') {
      if (initial != null) {
        _processSaslPlain(initial);
      } else {
        authInProgress = {'mech': 'PLAIN'};
        send('+ \r\n');
      }
    } else if (mech == 'XOAUTH2') {
      if (initial != null) {
        _processSaslXoauth2(initial);
      } else {
        authInProgress = {'mech': 'XOAUTH2'};
        send('+ \r\n');
      }
    } else {
      sendErr('Unsupported mechanism: $mech');
    }
  }

  void _handleAuthContinuation(String line) {
    if (authInProgress == null) return;
    if (line == '*') {
      authInProgress = null;
      sendErr('AUTH cancelled');
      return;
    }
    String mech = authInProgress!['mech'];
    authInProgress = null;
    if (mech == 'PLAIN') {
      _processSaslPlain(line);
    } else if (mech == 'XOAUTH2')
      _processSaslXoauth2(line);
  }

  void _processSaslPlain(String b64) {
    try {
      var decoded = utf8.decode(base64.decode(b64));
      var parts = decoded.split('\x00');
      String user, pass;
      if (parts.length >= 3) {
        user = parts[1].isNotEmpty ? parts[1] : parts[0];
        pass = parts[2];
      } else if (parts.length == 2) {
        user = parts[0];
        pass = parts[1];
      } else {
        throw Exception();
      }
      _emitAuth(user, pass, 'plain');
    } catch (_) {
      sendErr('Invalid SASL PLAIN');
    }
  }

  void _processSaslXoauth2(String b64) {
    try {
      var decoded = utf8.decode(base64.decode(b64));
      var parts = decoded.split('\x01');
      String? user, token;
      for (var p in parts) {
        if (p.startsWith('user=')) user = p.substring(5);
        if (p.startsWith('auth=Bearer ')) token = p.substring(12);
      }
      if (user == null || token == null) throw Exception();
      _emitAuth(user, token, 'xoauth2');
    } catch (_) {
      sendErr('Invalid SASL XOAUTH2');
    }
  }

  void _emitAuth(String user, String pass, String method) {
    bool decided = false;
    final authCtx = Pop3AuthRequest(
      username: user,
      password: pass,
      authMethod: method,
      remoteAddress: remoteAddress,
      isTLS: isTLS,
      on: _ev.on,
      off: _ev.off,
      accept: () {
        if (decided) return;
        decided = true;
        authenticated = true;
        username = user;
        _loadInbox((err) {
          if (err != null) {
            sendErr('Mailbox unavailable');
            close();
            return;
          }
          state = SessionState.TRANSACTION;
          sendOk('$user authenticated (${messages?.length ?? 0} messages)');
        });
      },
      reject: ([String? msg]) {
        if (decided) return;
        decided = true;
        sendErr(msg ?? 'Authentication failed');
      },
    );
    _ev.emit('pop3Auth', authCtx);
  }

  void _loadInbox(Function cb) {
    _ev.emit('openFolder', 'INBOX', (err, info) {
      if (err != null) {
        cb(err);
        return;
      }
      int total = info != null && info['total'] is int ? info['total'] : 0;
      if (total == 0) {
        messages = [];
        cb(null);
        return;
      }
      var query = {
        'ranges': [1, total],
        'isUid': false,
        'total': total,
      };
      _ev.emit('resolveMessages', 'INBOX', query, (rerr, pairs) {
        if (rerr != null) {
          cb(rerr);
          return;
        }
        List<dynamic> list = pairs is List ? pairs : [];
        list.sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));

        List<int> uids = list.map((p) => p['uid'] as int).toList();
        _ev.emit('messageMeta', 'INBOX', uids, (merr, metas) {
          if (merr != null) {
            cb(merr);
            return;
          }
          Map<int, dynamic> metaMap = {};
          if (metas is List) {
            for (var m in metas) {
              if (m != null && m['uid'] != null) metaMap[m['uid']] = m;
            }
          }
          messages = list.map((p) {
            var m = metaMap[p['uid']] ?? {};
            return POP3Message(
              seq: p['seq'],
              uid: p['uid'],
              size: m['size'] ?? 0,
            );
          }).toList();
          cb(null);
        });
      });
    });
  }

  void _handleStat() {
    if (state != SessionState.TRANSACTION) {
      sendErr('Not in transaction');
      return;
    }
    int count = 0, size = 0;
    for (var m in messages!) {
      if (!m.deleted) {
        count++;
        size += m.size;
      }
    }
    sendOk('$count $size');
  }

  void _handleList(List<String> args) {
    if (state != SessionState.TRANSACTION) {
      sendErr('Not in transaction');
      return;
    }
    if (args.isEmpty) {
      sendOk('scan listing follows');
      for (var m in messages!) {
        if (!m.deleted) sendLine('${m.seq} ${m.size}');
      }
      sendEnd();
      return;
    }
    int? n = int.tryParse(args[0]);
    var m = _getMessage(n);
    if (m == null || m.deleted) {
      sendErr('No such message');
      return;
    }
    sendOk('${m.seq} ${m.size}');
  }

  void _handleUidl(List<String> args) {
    if (state != SessionState.TRANSACTION) {
      sendErr('Not in transaction');
      return;
    }
    if (args.isEmpty) {
      sendOk('unique-id listing follows');
      for (var m in messages!) {
        if (!m.deleted) sendLine('${m.seq} ${m.uid}');
      }
      sendEnd();
      return;
    }
    int? n = int.tryParse(args[0]);
    var m = _getMessage(n);
    if (m == null || m.deleted) {
      sendErr('No such message');
      return;
    }
    sendOk('${m.seq} ${m.uid}');
  }

  void _handleRetr(List<String> args) {
    if (state != SessionState.TRANSACTION) {
      sendErr('Not in transaction');
      return;
    }
    if (args.isEmpty) {
      sendErr('RETR requires msg number');
      return;
    }
    int? n = int.tryParse(args[0]);
    var m = _getMessage(n);
    if (m == null || m.deleted) {
      sendErr('No such message');
      return;
    }

    bool decided = false;
    var responder = {
      'respond': (dynamic raw) {
        if (decided) return;
        decided = true;
        sendOk('message follows');
        send(_dotStuff(toU8(raw)));
        sendEnd();
      },
      'error': ([String? msg]) {
        if (decided) return;
        decided = true;
        sendErr(msg ?? 'Retrieve failed');
      },
    };
    _ev.emit('messageBody', 'INBOX', m.uid, responder);
  }

  void _handleTop(List<String> args) {
    if (state != SessionState.TRANSACTION) {
      sendErr('Not in transaction');
      return;
    }
    if (args.length < 2) {
      sendErr('TOP requires msg number and line count');
      return;
    }
    int? n = int.tryParse(args[0]);
    int? lines = int.tryParse(args[1]);
    var m = _getMessage(n);
    if (m == null || m.deleted) {
      sendErr('No such message');
      return;
    }
    if (lines == null || lines < 0) {
      sendErr('Invalid line count');
      return;
    }

    bool decided = false;
    var responder = {
      'respond': (dynamic raw) {
        if (decided) return;
        decided = true;
        sendOk('top follows');
        send(_dotStuff(_extractTop(toU8(raw), lines)));
        sendEnd();
      },
      'error': ([String? msg]) {
        if (decided) return;
        decided = true;
        sendErr(msg ?? 'Retrieve failed');
      },
    };
    _ev.emit('messageBody', 'INBOX', m.uid, responder);
  }

  void _handleDele(List<String> args) {
    if (state != SessionState.TRANSACTION) {
      sendErr('Not in transaction');
      return;
    }
    if (args.isEmpty) {
      sendErr('DELE msg number required');
      return;
    }
    int? n = int.tryParse(args[0]);
    var m = _getMessage(n);
    if (m == null || m.deleted) {
      sendErr('No such message');
      return;
    }
    m.deleted = true;
    sendOk('message $n marked for deletion');
  }

  void _handleRset() {
    if (state != SessionState.TRANSACTION) {
      sendErr('Not in transaction');
      return;
    }
    if (messages != null)
      for (var m in messages!) {
        m.deleted = false;
      }
    sendOk('reset');
  }

  void _handleQuit() {
    if (state == SessionState.AUTHORIZATION) {
      sendOk('$hostname signing off');
      close();
      return;
    }
    if (state != SessionState.TRANSACTION) {
      sendErr('QUIT rejected');
      close();
      return;
    }

    state = SessionState.UPDATE;
    List<int> toDelete = messages!
        .where((m) => m.deleted)
        .map((m) => m.uid)
        .toList();
    if (toDelete.isEmpty) {
      sendOk('$hostname signing off');
      close();
      return;
    }

    _applyDeletions(toDelete, () {
      sendOk('$hostname signing off (${toDelete.length} deleted)');
      close();
    });
  }

  void _applyDeletions(List<int> uids, Function done) {
    var query = {
      'isUid': true,
      'uids': uids,
      'flags': ['Deleted'],
      'mode': 'add',
      'silent': true,
    };
    _ev.emit('setFlags', 'INBOX', query, (serr) {
      _ev.emit('expunge', 'INBOX', {'uids': uids}, (eerr) {
        done();
      });
    });
  }

  Uint8List _dotStuff(Uint8List raw) {
    BytesBuilder bb = BytesBuilder();
    int start = 0;
    for (int i = 0; i < raw.length; i++) {
      if (raw[i] == 46) {
        // '.'
        if (i == 0 || (i >= 2 && raw[i - 2] == 13 && raw[i - 1] == 10)) {
          bb.add(raw.sublist(start, i));
          bb.addByte(46);
          start = i;
        }
      }
    }
    bb.add(raw.sublist(start));
    return bb.toBytes();
  }

  Uint8List _extractTop(Uint8List raw, int lines) {
    int headerEnd = -1;
    for (int i = 0; i + 3 < raw.length; i++) {
      if (raw[i] == 13 &&
          raw[i + 1] == 10 &&
          raw[i + 2] == 13 &&
          raw[i + 3] == 10) {
        headerEnd = i;
        break;
      }
    }
    if (headerEnd < 0) {
      headerEnd = raw.length;
    } else {
      headerEnd += 4;
    }

    if (lines == 0) return raw.sublist(0, headerEnd);

    int count = 0;
    int pos = headerEnd;
    while (pos < raw.length && count < lines) {
      int next = indexOfCRLF(raw, pos);
      if (next < 0) {
        pos = raw.length;
        break;
      }
      pos = next + 2;
      count++;
    }
    return raw.sublist(0, pos);
  }

  POP3Message? _getMessage(int? n) {
    if (n == null || messages == null) return null;
    try {
      return messages!.firstWhere((m) => m.seq == n);
    } catch (_) {
      return null;
    }
  }

  void greet() {
    if (isServer) {
      state = SessionState.AUTHORIZATION;
      sendOk('$hostname POP3 ready');
    } else {
      state = SessionState.GREETING;
    }
  }

  void close() {
    if (state == SessionState.CLOSED) return;
    state = SessionState.CLOSED;
    inputBuf = Uint8List(0);
    _ev.emit('close');
    _ev.removeAllListeners();
  }

  // --- Client Mode ---
  void _feedClient() {
    while (state != SessionState.CLOSED) {
      int cr = indexOfCRLF(inputBuf);
      if (cr < 0) break;
      String line = u8ToStr(Uint8List.sublistView(inputBuf, 0, cr));
      consumeInput(cr + 2);
      _routeResponse(line);
    }
  }

  void _routeResponse(String line) {
    if (state == SessionState.GREETING) {
      state = SessionState.AUTHORIZATION;
      _ev.emit('ready');
      return;
    }
    if (pendingCommand != null) {
      var cb = pendingCommand!['cb'];
      pendingCommand = null;
      if (cb != null) cb(null, line);
    }
  }
}
