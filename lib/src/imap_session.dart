import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'utils.dart';
import 'imap_wire.dart';
import 'imap_helpers.dart';
import 'imap_folders.dart';
import 'imap_messages.dart';
import 'imap_search.dart';
import 'imap_metadata.dart';

// ============================================================================
//  imap_session.dart  —  IMAP protocol session (RFC 3501)
// ----------------------------------------------------------------------------
//  Core engine for both server and client IMAP sessions. This class manages
//  protocol state, input buffering, command parsing, and dispatching to
//  specialized handlers (folders, search, messages, etc.).
// ============================================================================

const String DEFAULT_HOSTNAME = 'localhost';
const int DEFAULT_MAX_COMMAND = 12 * 1024 * 1024; // 12MB limit

enum SessionState {
  NEW,
  GREETING,
  NOT_AUTHENTICATED,
  AUTHENTICATED,
  SELECTED,
  LOGOUT,
  CLOSED,
}

const List<String> BASE_CAPABILITIES = [
  'IMAP4rev1',
  'SASL-IR',
  'LITERAL+',
  'IDLE',
  'NAMESPACE',
  'UIDPLUS',
  'ENABLE',
  'CONDSTORE',
  'QRESYNC',
  'LIST-EXTENDED',
  'LIST-STATUS',
  'SPECIAL-USE',
  'WITHIN',
  'MOVE',
  'METADATA',
  'QUOTA',
];

/// Typed construction options for [IMAPSession].
///
/// Replaces the previous `Map<String, dynamic>` constructor argument.
class IMAPSessionOptions {
  final bool isServer;
  final String hostname;
  final int maxCommandSize;
  final String? remoteAddress;
  final bool isTLS;
  final Map<String, dynamic>? tlsOptions;
  final bool advertiseTLS;
  final String delimiter;

  const IMAPSessionOptions({
    this.isServer = true,
    this.hostname = DEFAULT_HOSTNAME,
    this.maxCommandSize = DEFAULT_MAX_COMMAND,
    this.remoteAddress,
    this.isTLS = false,
    this.tlsOptions,
    this.advertiseTLS = false,
    this.delimiter = '/',
  });

  /// Construct from a legacy map. Internal compatibility shim.
  factory IMAPSessionOptions.fromMap(Map<String, dynamic>? m) {
    m ??= const {};
    return IMAPSessionOptions(
      isServer: m['isServer'] != false,
      hostname: (m['hostname'] as String?) ?? DEFAULT_HOSTNAME,
      maxCommandSize: (m['maxCommandSize'] as int?) ?? DEFAULT_MAX_COMMAND,
      remoteAddress: m['remoteAddress'] as String?,
      isTLS: m['isTLS'] == true,
      tlsOptions: m['tlsOptions'] as Map<String, dynamic>?,
      advertiseTLS: m['advertiseTLS'] == true,
      delimiter: (m['delimiter'] as String?) ?? '/',
    );
  }
}

/// Typed payload emitted on the `'imapAuth'` event from [IMAPSession].
class ImapAuthRequest {
  final String username;
  final String password;
  final String authMethod;
  final String? remoteAddress;
  final bool isTLS;
  final void Function(String, Function) on;
  final void Function(String, Function) off;
  final void Function() accept;
  final void Function([String? msg]) reject;

  const ImapAuthRequest({
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

/// Argument for [IMAPSession.notifyVanished]. Either a list of UIDs,\n/// or a list of (start,end) range pairs.
class VanishedSet {
  /// UIDs explicitly listed; mutually exclusive with [ranges].
  final List<int>? uids;

  /// Flat (start,end) pairs; mutually exclusive with [uids].
  final List<int>? ranges;

  const VanishedSet.uids(List<int> this.uids) : ranges = null;
  const VanishedSet.ranges(List<int> this.ranges) : uids = null;
}

/// Tracks an in-flight client-side IMAP command awaiting a tagged response.
class PendingImapCommand {
  final String tag;
  final List<ImapResponse> untagged = [];
  final Function? cb;
  void Function(ImapResponse)? onContinuation;

  PendingImapCommand({required this.tag, this.cb, this.onContinuation});
}

/// Typed view over the result Map returned by [parseCommand] / [parseResponse].
class ImapParseResult {
  final Map<String, dynamic> _m;
  ImapParseResult(this._m);

  ParseStatus? get status => _m['status'] as ParseStatus?;
  int? get end => _m['end'] as int?;
  String? get tag => _m['tag'] as String?;
  String? get reason => _m['reason'] as String?;
  bool get nonSync => _m['nonSync'] == true;
  ImapCommand? get command =>
      _m['command'] is ImapCommand ? _m['command'] as ImapCommand : null;
  ImapResponse? get response =>
      _m['response'] is ImapResponse ? _m['response'] as ImapResponse : null;
}

/// The main IMAP session class.
class IMAPSession {
  final EventEmitter ev = EventEmitter();
  final IMAPSessionOptions _options;

  // Session state fields (used by context)
  SessionState state = SessionState.NEW;
  bool isServer = true;
  String hostname = DEFAULT_HOSTNAME;
  int maxCommandSize = DEFAULT_MAX_COMMAND;
  String? remoteAddress;
  bool isTLS = false;
  Map<String, dynamic>? tlsOptions;
  bool advertiseTLS = false;

  /// Mailbox hierarchy delimiter, e.g. `/`.
  String delimiter = '/';

  Uint8List inputBuf = Uint8List(0);
  bool idling = false;
  String? idleTag;
  Function? idleCb;
  Function? idleDoneCb;

  Map<String, dynamic>? authInProgress;
  bool awaitingLiteral = false;
  bool authenticated = false;
  String? authUsername;

  String? currentFolder;
  bool currentFolderReadOnly = false;
  int? currentFolderUidValidity;
  int currentFolderTotal = 0;
  int currentFolderHighestModseq = 0;

  bool condstoreEnabled = false;
  bool qresyncEnabled = false;
  bool compressed = false;

  Map<String, bool> remoteCaps = {};

  // Client mode helpers
  late Function tagGen;
  PendingImapCommand? pendingCommand;

  // Handlers attached by registerXXX methods
  late Function(String tag, List<ImapToken> args, bool subscribed) handleList;
  late Function(String tag, List<ImapToken> args, bool readOnly) handleSelect;
  late Function(String tag, List<ImapToken> args) handleCreate;
  late Function(String tag, List<ImapToken> args) handleDelete;
  late Function(String tag, List<ImapToken> args) handleRename;
  late Function(String tag, List<ImapToken> args) handleSubscribe;
  late Function(String tag, List<ImapToken> args) handleUnsubscribe;
  late Function(String tag, List<ImapToken> args) handleStatus;
  late Function(String tag) handleClose;
  late Function(String tag) handleUnselect;
  late Function(String tag, List<ImapToken> args, bool byUid) handleFetch;
  late Function(String tag, List<ImapToken> args, bool byUid) handleStore;
  late Function(String tag, List<ImapToken> args, bool byUid) handleCopy;
  late Function(String tag, List<ImapToken> args, bool byUid) handleSearch;
  late Function(String tag, List<ImapToken> args) handleAppend;
  late Function(String tag, List<ImapToken>? args) handleExpunge;
  late Function(String tag, List<ImapToken> args, bool byUid) handleMove;
  late Function(String tag) handleNamespace;
  late Function(String tag, List<ImapToken> args) handleGetQuota;
  late Function(String tag, List<ImapToken> args) handleGetQuotaRoot;
  late Function(String tag, List<ImapToken> args, bool byUid) handleSort;
  late Function(String tag, List<ImapToken> args, bool byUid) handleThread;
  late Function(String tag, List<ImapToken> args) handleGetMetadata;
  late Function(String tag, List<ImapToken> args) handleSetMetadata;
  late Function emitFetchResponse;

  IMAPSession([IMAPSessionOptions? options])
    : _options = options ?? const IMAPSessionOptions() {
    isServer = _options.isServer;
    hostname = _options.hostname;
    maxCommandSize = _options.maxCommandSize;
    remoteAddress = _options.remoteAddress;
    isTLS = _options.isTLS;
    tlsOptions = _options.tlsOptions;
    advertiseTLS = _options.advertiseTLS && !isTLS;
    delimiter = _options.delimiter;

    tagGen = _makeTagGenerator('A');

    // Register all protocol handlers
    _registerAllHandlers();
  }

  void _registerAllHandlers() {
    // These methods (defined in other lib/src files) will attach themselves to this session.
    registerMessageHandlers(this);
    registerSearchHandlers(this);
    registerFolderHandlers(this);
    registerMetadataHandlers(this);
  }

  /// Compatibility getter for handlers expecting a context object.
  IMAPSession get context => this;

  static Function _makeTagGenerator(String prefix) {
    int count = 0;
    return () {
      count++;
      String s = count.toString();
      while (s.length < 4) {
        s = '0$s';
      }
      return '$prefix$s';
    };
  }

  void on(String name, Function fn) => ev.on(name, fn);
  void off(String name, Function fn) => ev.off(name, fn);

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
    ev.emit('send', toU8(data));
  }

  void sendTagged(String tag, Object status, String text, [String? code]) {
    send(buildTagged(tag, status, text, code));
  }

  void sendUntagged(String data) {
    send(buildUntagged(data));
  }

  void sendContinuation(String text) {
    send(buildContinuation(text));
  }

  List<String> getCapabilities() {
    List<String> caps = List.from(BASE_CAPABILITIES);
    if (advertiseTLS) {
      caps.add('STARTTLS');
      caps.add('LOGINDISABLED');
    }
    if (ev.listenerCount('move') > 0) caps.add('MOVE');
    if (ev.listenerCount('quota') > 0) {
      caps.add('QUOTA');
      caps.add('QUOTA=RES-STORAGE');
      caps.add('QUOTA=RES-MESSAGE');
    }
    if (compressed) caps.remove('COMPRESS=DEFLATE');
    if (ev.listenerCount('getMetadata') > 0 ||
        ev.listenerCount('setMetadata') > 0) {
      caps.add('METADATA');
      caps.add('METADATA-SERVER');
    }
    return caps;
  }

  bool loginAllowed() {
    return !(advertiseTLS && !isTLS);
  }

  String getStringValue(ImapToken? tok) {
    if (tok == null) return '';
    if (tok is LiteralToken) return u8ToStr(tok.value);
    return tok.value?.toString() ?? '';
  }

  String quoteMailbox(String name) {
    if (name.toUpperCase() == 'INBOX') return 'INBOX';
    return quoteString(name);
  }

  void feed(Uint8List chunk) {
    if (state == SessionState.CLOSED) return;
    appendInput(chunk);
    if (isServer) {
      _feedServer();
    } else {
      _feedClient();
    }
  }

  void _feedServer() {
    while (state != SessionState.CLOSED) {
      if (idling) {
        int cr = indexOfCRLF(inputBuf);
        if (cr < 0) break;
        String line = u8ToStr(Uint8List.sublistView(inputBuf, 0, cr)).trim();
        consumeInput(cr + 2);
        if (line.toUpperCase() == 'DONE') {
          String tag = idleTag!;
          idling = false;
          idleTag = null;
          idleCb = null;
          idleDoneCb = null;
          sendTagged(tag, STATUS_OK, 'IDLE terminated');
          ev.emit('idleEnd');
        }
        continue;
      }

      if (authInProgress != null) {
        int cr = indexOfCRLF(inputBuf);
        if (cr < 0) break;
        String line = u8ToStr(Uint8List.sublistView(inputBuf, 0, cr)).trim();
        consumeInput(cr + 2);
        _handleAuthContinuation(line);
        continue;
      }

      if (inputBuf.length > maxCommandSize) {
        sendTagged('*', STATUS_BAD, 'Command too large');
        ev.emit('error', Exception('Command size limit exceeded'));
        close();
        return;
      }

      var result = ImapParseResult(parseCommand(inputBuf, 0));
      if (result.status == PARSE_INCOMPLETE) break;

      if (result.status == PARSE_NEED_CONTINUATION) {
        if (!awaitingLiteral) {
          if (!result.nonSync) sendContinuation('Ready for literal');
          awaitingLiteral = true;
        }
        break;
      }

      awaitingLiteral = false;

      if (result.status == PARSE_ERROR) {
        sendTagged(
          result.tag ?? '*',
          STATUS_BAD,
          result.reason ?? 'Syntax error',
        );
        int? end = result.end;
        if (end != null) {
          consumeInput(end);
        } else {
          int cr = indexOfCRLF(inputBuf);
          if (cr < 0) break;
          consumeInput(cr + 2);
        }
        continue;
      }

      consumeInput(result.end!);
      _processCommand(result.command!);
    }
  }

  void _processCommand(ImapCommand cmd) {
    ev.emit('command', cmd);
    String tag = cmd.tag;
    String name = cmd.name;
    List<ImapToken> args = cmd.args;

    switch (name) {
      case 'CAPABILITY':
        _handleCapability(tag);
        break;
      case 'NOOP':
        _handleNoop(tag);
        break;
      case 'LOGOUT':
        _handleLogout(tag);
        break;
      case 'STARTTLS':
        _handleStartTLS(tag);
        break;
      case 'LOGIN':
        _handleLogin(tag, args);
        break;
      case 'AUTHENTICATE':
        _handleAuthenticate(tag, args);
        break;
      case 'LIST':
        handleList(tag, args, false);
        break;
      case 'LSUB':
        handleList(tag, args, true);
        break;
      case 'SELECT':
        handleSelect(tag, args, false);
        break;
      case 'EXAMINE':
        handleSelect(tag, args, true);
        break;
      case 'CREATE':
        handleCreate(tag, args);
        break;
      case 'DELETE':
        handleDelete(tag, args);
        break;
      case 'RENAME':
        handleRename(tag, args);
        break;
      case 'SUBSCRIBE':
        handleSubscribe(tag, args);
        break;
      case 'UNSUBSCRIBE':
        handleUnsubscribe(tag, args);
        break;
      case 'STATUS':
        handleStatus(tag, args);
        break;
      case 'CLOSE':
        handleClose(tag);
        break;
      case 'UNSELECT':
        handleUnselect(tag);
        break;
      case 'FETCH':
        handleFetch(tag, args, false);
        break;
      case 'STORE':
        handleStore(tag, args, false);
        break;
      case 'COPY':
        handleCopy(tag, args, false);
        break;
      case 'SEARCH':
        handleSearch(tag, args, false);
        break;
      case 'UID':
        _handleUid(tag, args);
        break;
      case 'APPEND':
        handleAppend(tag, args);
        break;
      case 'EXPUNGE':
        handleExpunge(tag, null);
        break;
      case 'MOVE':
        handleMove(tag, args, false);
        break;
      case 'IDLE':
        _handleIdle(tag);
        break;
      case 'NAMESPACE':
        handleNamespace(tag);
        break;
      case 'GETQUOTA':
        handleGetQuota(tag, args);
        break;
      case 'GETQUOTAROOT':
        handleGetQuotaRoot(tag, args);
        break;
      case 'SORT':
        handleSort(tag, args, false);
        break;
      case 'THREAD':
        handleThread(tag, args, false);
        break;
      case 'ENABLE':
        _handleEnable(tag, args);
        break;
      case 'COMPRESS':
        _handleCompress(tag, args);
        break;
      case 'GETMETADATA':
        handleGetMetadata(tag, args);
        break;
      case 'SETMETADATA':
        handleSetMetadata(tag, args);
        break;
      default:
        sendTagged(tag, STATUS_BAD, 'Unknown command: $name');
    }
  }

  void _handleCapability(String tag) {
    sendUntagged('CAPABILITY ${getCapabilities().join(' ')}');
    sendTagged(tag, STATUS_OK, 'CAPABILITY completed');
  }

  void _handleNoop(String tag) {
    sendTagged(tag, STATUS_OK, 'NOOP completed');
  }

  void _handleLogout(String tag) {
    sendUntagged('BYE IMAP server signing off');
    sendTagged(tag, STATUS_OK, 'LOGOUT completed');
    state = SessionState.LOGOUT;
    ev.emit('close');
  }

  void _handleStartTLS(String tag) {
    if (isTLS) {
      sendTagged(tag, STATUS_BAD, 'Already in TLS');
      return;
    }
    if (tlsOptions == null && !advertiseTLS) {
      sendTagged(tag, STATUS_NO, 'STARTTLS not available');
      return;
    }
    sendTagged(tag, STATUS_OK, 'Begin TLS negotiation now');
    ev.emit('starttls');
  }

  void _handleLogin(String tag, List<ImapToken> args) {
    if (authenticated) {
      sendTagged(tag, STATUS_BAD, 'Already authenticated');
      return;
    }
    if (args.length < 2) {
      sendTagged(tag, STATUS_BAD, 'LOGIN requires username and password');
      return;
    }
    if (!loginAllowed()) {
      sendTagged(tag, STATUS_NO, 'LOGIN disabled — use STARTTLS first');
      return;
    }
    String user = getStringValue(args[0]);
    String pass = getStringValue(args[1]);
    _emitAuth(user, pass, tag, 'plain');
  }

  void _handleAuthenticate(String tag, List<ImapToken> args) {
    if (authenticated) {
      sendTagged(tag, STATUS_BAD, 'Already authenticated');
      return;
    }
    if (args.isEmpty) {
      sendTagged(tag, STATUS_BAD, 'AUTHENTICATE requires mechanism');
      return;
    }
    String mech = getStringValue(args[0]).toUpperCase();
    if (mech == 'PLAIN') {
      if (args.length > 1) {
        _handleSaslPlain(tag, getStringValue(args[1]));
      } else {
        authInProgress = {'mechanism': 'PLAIN', 'tag': tag};
        sendContinuation('');
      }
    } else {
      sendTagged(tag, STATUS_NO, 'Unsupported mechanism');
    }
  }

  void _handleAuthContinuation(String line) {
    var auth = authInProgress;
    if (auth == null) return;
    if (line == '*') {
      sendTagged(auth['tag'], STATUS_BAD, 'AUTHENTICATE cancelled');
      authInProgress = null;
      return;
    }
    if (auth['mechanism'] == 'PLAIN') {
      _handleSaslPlain(auth['tag'], line);
      authInProgress = null;
    }
  }

  void _handleSaslPlain(String tag, String b64) {
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
        throw Exception('Malformed PLAIN');
      }
      _emitAuth(user, pass, tag, 'plain');
    } catch (_) {
      sendTagged(tag, STATUS_BAD, 'Invalid SASL PLAIN');
    }
  }

  void _emitAuth(String user, String pass, String tag, String method) {
    bool settled = false;
    final authCtx = ImapAuthRequest(
      username: user,
      password: pass,
      authMethod: method,
      remoteAddress: remoteAddress,
      isTLS: isTLS,
      on: ev.on,
      off: ev.off,
      accept: () {
        if (settled) return;
        settled = true;
        authenticated = true;
        authUsername = user;
        state = SessionState.AUTHENTICATED;
        Timer(Duration.zero, () {
          String caps = getCapabilities().join(' ');
          sendTagged(
            tag,
            STATUS_OK,
            'Authentication successful',
            'CAPABILITY $caps',
          );
        });
      },
      reject: ([String? msg]) {
        if (settled) return;
        settled = true;
        Timer(Duration.zero, () {
          sendTagged(tag, STATUS_NO, msg ?? 'Invalid credentials');
        });
      },
    );
    ev.emit('imapAuth', authCtx);
  }

  void _handleUid(String tag, List<ImapToken> args) {
    if (!requireSelected(tag)) return;
    if (args.isEmpty) {
      sendTagged(tag, STATUS_BAD, 'UID requires subcommand');
      return;
    }
    String sub = getStringValue(args[0]).toUpperCase();
    List<ImapToken> rest = args.sublist(1);
    switch (sub) {
      case 'FETCH':
        handleFetch(tag, rest, true);
        break;
      case 'STORE':
        handleStore(tag, rest, true);
        break;
      case 'COPY':
        handleCopy(tag, rest, true);
        break;
      case 'SEARCH':
        handleSearch(tag, rest, true);
        break;
      case 'EXPUNGE':
        handleExpunge(tag, rest);
        break;
      case 'MOVE':
        handleMove(tag, rest, true);
        break;
      case 'SORT':
        handleSort(tag, rest, true);
        break;
      case 'THREAD':
        handleThread(tag, rest, true);
        break;
      default:
        sendTagged(tag, STATUS_BAD, 'Unsupported UID subcommand: $sub');
    }
  }

  void _handleIdle(String tag) {
    if (state != SessionState.AUTHENTICATED && state != SessionState.SELECTED) {
      sendTagged(tag, STATUS_BAD, 'IDLE requires authentication');
      return;
    }
    idling = true;
    idleTag = tag;
    sendContinuation('idling');
    ev.emit('idleStart', currentFolder);
  }

  void _handleEnable(String tag, List<ImapToken> args) {
    if (state != SessionState.AUTHENTICATED && state != SessionState.SELECTED) {
      sendTagged(tag, STATUS_BAD, 'ENABLE only in authenticated state');
      return;
    }
    List<String> enabled = [];
    for (var arg in args) {
      String name = getStringValue(arg).toUpperCase();
      if (name == 'CONDSTORE') {
        condstoreEnabled = true;
        enabled.add('CONDSTORE');
      } else if (name == 'QRESYNC') {
        condstoreEnabled = true;
        qresyncEnabled = true;
        enabled.add('QRESYNC');
      }
    }
    if (enabled.isNotEmpty) sendUntagged('ENABLED ${enabled.join(' ')}');
    sendTagged(tag, STATUS_OK, 'ENABLE completed');
  }

  void _handleCompress(String tag, List<ImapToken> args) {
    if (state == SessionState.NOT_AUTHENTICATED ||
        state == SessionState.LOGOUT) {
      sendTagged(tag, STATUS_BAD, 'COMPRESS requires auth');
      return;
    }
    if (compressed) {
      sendTagged(
        tag,
        STATUS_NO,
        'Compression already active',
        'COMPRESSIONACTIVE',
      );
      return;
    }
    if (args.isEmpty || getStringValue(args[0]).toUpperCase() != 'DEFLATE') {
      sendTagged(tag, STATUS_BAD, 'Only DEFLATE supported');
      return;
    }
    compressed = true;
    sendTagged(tag, STATUS_OK, 'DEFLATE active');
    ev.emit('compress');
  }

  bool requireSelected(String tag) {
    if (state != SessionState.SELECTED) {
      sendTagged(tag, STATUS_BAD, 'No folder selected');
      return false;
    }
    return true;
  }

  // --- Push Notifications ---
  void notifyExists(int total) {
    if (!isServer || state != SessionState.SELECTED) return;
    currentFolderTotal = total;
    sendUntagged('$total EXISTS');
  }

  void notifyRecent(int count) {
    if (!isServer || state != SessionState.SELECTED) return;
    sendUntagged('$count RECENT');
  }

  void notifyExpunge(int seq, [int? uid]) {
    if (!isServer || state != SessionState.SELECTED) return;
    if (qresyncEnabled && uid != null) {
      sendUntagged('VANISHED $uid');
    } else {
      sendUntagged('$seq EXPUNGE');
    }
    if (currentFolderTotal > 0) currentFolderTotal--;
  }

  void notifyFlags(int seq, int? uid, List<String>? flags) {
    if (!isServer || state != SessionState.SELECTED) return;
    List<String> items = [];
    if (uid != null) items.add('UID $uid');
    items.add('FLAGS ${serializeFlagList(flags)}');
    sendUntagged('$seq FETCH (${items.join(' ')})');
  }

  void notifyVanished(VanishedSet arg) {
    if (!isServer || state != SessionState.SELECTED) return;
    String? str;
    int count = 0;
    if (arg.ranges != null) {
      final r = arg.ranges!;
      str = formatRanges(r);
      for (int i = 0; i < r.length; i += 2) {
        count += (r[i + 1] - r[i]);
      }
    } else if (arg.uids != null && arg.uids!.isNotEmpty) {
      str = compressUids(arg.uids!);
      count = arg.uids!.length;
    }
    if (str == null) return;
    sendUntagged('VANISHED $str');
    if (currentFolderTotal > count) {
      currentFolderTotal -= count;
    } else {
      currentFolderTotal = 0;
    }
  }

  // --- Client Mode ---

  void _feedClient() {
    while (state != SessionState.CLOSED) {
      var result = ImapParseResult(parseResponse(inputBuf, 0));
      if (result.status == PARSE_INCOMPLETE) break;
      if (result.status == PARSE_ERROR) {
        int? end = result.end;
        if (end != null) {
          consumeInput(end);
        } else {
          int cr = indexOfCRLF(inputBuf);
          if (cr < 0) break;
          consumeInput(cr + 2);
        }
        continue;
      }
      consumeInput(result.end!);
      _routeResponse(result.response!);
    }
  }

  void _routeResponse(ImapResponse resp) {
    if (state == SessionState.GREETING && resp.kind == RESP_UNTAGGED) {
      _handleClientBanner(resp);
      return;
    }

    if (resp.kind == RESP_UNTAGGED) {
      if (pendingCommand != null) {
        pendingCommand!.untagged.add(resp);
      }
      ev.emit('untagged', resp);
      return;
    }

    if (resp.kind == RESP_CONTINUATION) {
      if (idling && idleCb != null) {
        var cb = idleCb!;
        idleCb = null;
        cb(null);
        return;
      }
      if (pendingCommand != null && pendingCommand!.onContinuation != null) {
        pendingCommand!.onContinuation!(resp);
        return;
      }
      ev.emit('continuation', resp);
      return;
    }

    if (resp.kind == RESP_TAGGED) {
      if (idling && resp.tag == idleTag) {
        var cb = idleDoneCb;
        idling = false;
        idleTag = null;
        idleDoneCb = null;
        idleCb = null;
        if (cb != null) cb(null, resp);
        return;
      }
      var pending = pendingCommand;
      if (pending != null && pending.tag == resp.tag) {
        pendingCommand = null;
        if (pending.cb != null) pending.cb!(null, resp);
      } else {
        ev.emit('untagged', resp);
      }
    }
  }

  void _handleClientBanner(ImapResponse resp) {
    var data = resp.data;
    var statusVal = data != null && data.isNotEmpty
        ? (data[0].value?.toString().toUpperCase() ?? '')
        : '';
    if (statusVal == 'BYE') {
      ev.emit('error', Exception('Server rejected connection'));
      return;
    }
    if (statusVal == 'PREAUTH') {
      authenticated = true;
      state = SessionState.AUTHENTICATED;
    } else {
      state = SessionState.NOT_AUTHENTICATED;
    }
    ev.emit('ready');
  }

  void clientSend(String command, [List<dynamic>? args, Function? cb]) {
    if (state == SessionState.CLOSED) {
      if (cb != null) cb(Exception('Closed'));
      return;
    }
    if (idling) {
      if (cb != null) cb(Exception('Idling'));
      return;
    }
    if (pendingCommand != null) {
      if (cb != null) cb(Exception('Busy'));
      return;
    }
    String tag = tagGen();
    pendingCommand = PendingImapCommand(tag: tag, cb: cb);
    send(buildCommand(tag, command, args));
  }

  // --- lifecycle ---
  void tlsUpgraded() {
    isTLS = true;
    advertiseTLS = false;
    inputBuf = Uint8List(0);
    if (isServer) {
      authenticated = false;
      authUsername = null;
      state = SessionState.NOT_AUTHENTICATED;
      authInProgress = null;
    } else {
      // client side re-auth etc
    }
  }

  void greet() {
    if (isServer) {
      state = SessionState.NOT_AUTHENTICATED;
      List<String> caps = getCapabilities();
      sendUntagged('OK [CAPABILITY ${caps.join(' ')}] $hostname IMAP ready');
    } else {
      if (state == SessionState.NEW) state = SessionState.GREETING;
    }
  }

  void close() {
    if (state == SessionState.CLOSED) return;
    state = SessionState.CLOSED;
    inputBuf = Uint8List(0);
    authInProgress = null;
    pendingCommand = null;
    awaitingLiteral = false;
    ev.emit('close');
    ev.removeAllListeners();
  }

  // Client command wrappers... (skipped many for brevity, but I should add the important ones)
  void clientLogin(String user, String pass, Function cb) {
    clientSend('LOGIN', [user, pass], (err, info) {
      ImapResponse resp = info as ImapResponse;
      if (err == null && resp.status == STATUS_OK) {
        authenticated = true;
        authUsername = user;
        state = SessionState.AUTHENTICATED;
      }
      cb(err, info);
    });
  }

  void clientLogout(Function cb) {
    clientSend('LOGOUT', [], (err, info) {
      state = SessionState.LOGOUT;
      cb(err, info);
    });
  }

  void clientSelect(
    String name, [
    Map<String, dynamic>? options,
    Function? cb,
  ]) {
    if (options is Function) {
      cb = options as Function;
      options = null;
    }
    clientSend('SELECT', [name], (err, info) {
      ImapResponse resp = info as ImapResponse;
      if (err == null && resp.status == STATUS_OK) {
        state = SessionState.SELECTED;
        currentFolder = name;
      }
      if (cb != null) cb(err, info);
    });
  }
}
