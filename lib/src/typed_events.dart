// Public, type-safe wrappers around the raw map-based events emitted by
// IMAP/POP3 mailbox sessions and SMTP sessions. The underlying transport
// and tests still use Map<String, dynamic> for forward-compatibility, but
// applications should prefer the typed surface in this file via the
// extension methods on [MailboxFacade] (see bottom of file):
//
//   facade.onFolders((respond) => respond.ok([FolderInfo(name: 'INBOX')]));
//   facade.onOpenFolder((name, respond) => respond.ok(OpenFolderResult(...)));
//   facade.onResolveMessages((q, respond) {
//     respond.ok([MessageRef(seq: 1, uid: 1)]);
//   });
//
// All `respond.ok(...)` / `respond.error(...)` methods are fire-once.

import 'dart:typed_data';

import 'server.dart';

// ===========================================================================
// IMAP folder shapes
// ===========================================================================

/// One folder row returned for IMAP `LIST`/`LSUB`.
class FolderInfo {
  const FolderInfo({
    required this.name,
    this.subscribed = true,
    this.specialUse,
    this.delimiter = '/',
    this.children = false,
  });
  final String name;
  final bool subscribed;
  final String? specialUse;
  final String delimiter;
  final bool children;

  Map<String, dynamic> toMap() => {
    'name': name,
    'subscribed': subscribed,
    'specialUse': specialUse,
    'delimiter': delimiter,
    'children': children,
  };
}

/// Result of `openFolder` (IMAP SELECT/EXAMINE; POP3 USER/PASS).
class OpenFolderResult {
  const OpenFolderResult({
    required this.total,
    this.recent = 0,
    required this.uidValidity,
    required this.uidNext,
    this.flags = const <String>['\\Seen', '\\Deleted'],
    this.permanentFlags = const <String>['\\Seen', '\\Deleted'],
    this.readOnly = false,
  });
  final int total;
  final int recent;
  final int uidValidity;
  final int uidNext;
  final List<String> flags;
  final List<String> permanentFlags;
  final bool readOnly;

  Map<String, dynamic> toMap() => {
    'total': total,
    'recent': recent,
    'uidValidity': uidValidity,
    'uidNext': uidNext,
    // Defensive copies: dart_email_server's IMAP layer may mutate these
    // lists (e.g. appending '*' to permanentFlags), so callers passing
    // const lists must not have their data mutated in place.
    'flags': List<String>.from(flags),
    'permanentFlags': List<String>.from(permanentFlags),
    'readOnly': readOnly,
  };
}

/// Result of IMAP `STATUS`.
class StatusResult {
  const StatusResult({
    required this.messages,
    this.recent = 0,
    required this.uidnext,
    required this.uidvalidity,
    required this.unseen,
  });
  final int messages;
  final int recent;
  final int uidnext;
  final int uidvalidity;
  final int unseen;

  Map<String, dynamic> toMap() => {
    'messages': messages,
    'recent': recent,
    'uidnext': uidnext,
    'uidvalidity': uidvalidity,
    'unseen': unseen,
  };
}

// ===========================================================================
// Message resolution and metadata
// ===========================================================================

/// Typed view over the raw `resolveMessages` query map emitted by the
/// dart_email_server IMAP/POP3 layer.
class ResolveQuery {
  ResolveQuery._(this.byUid, this._flat, this.changedSince);

  factory ResolveQuery.fromMap(Map<String, dynamic> raw) {
    final type = raw['type'] as String? ?? 'seq';
    final flat = (raw['ranges'] as List?)?.cast<int>() ?? const <int>[];
    final cs = raw['changedSince'];
    return ResolveQuery._(type == 'uid', flat, cs is int ? cs : null);
  }

  /// True when the IMAP client used the UID variant of FETCH/SEARCH/STORE.
  final bool byUid;

  /// `CHANGEDSINCE` modseq filter, when present.
  final int? changedSince;

  /// Half-open `[lo, hi)` flat pairs as emitted by dart_email_server.
  final List<int> _flat;

  /// True if [n] is contained in any range. Empty ranges match all.
  bool includes(int n) {
    if (_flat.isEmpty) return true;
    for (var i = 0; i + 1 < _flat.length; i += 2) {
      final lo = _flat[i];
      final hi = _flat[i + 1];
      if (n >= lo && n < hi) return true;
    }
    return false;
  }
}

/// One `{seq, uid}` pair returned to the resolver callback.
class MessageRef {
  const MessageRef({required this.seq, required this.uid});
  final int seq;
  final int uid;

  Map<String, dynamic> toMap() => {'seq': seq, 'uid': uid};
}

/// IMAP per-message metadata for `messageMeta`.
class MessageMeta {
  const MessageMeta({
    required this.uid,
    required this.seq,
    required this.flags,
    required this.internalDate,
    required this.size,
  });
  final int uid;
  final int seq;
  final List<String> flags;
  final DateTime internalDate;
  final int size;

  Map<String, dynamic> toMap() => {
    'uid': uid,
    'seq': seq,
    'flags': flags,
    'internalDate': internalDate,
    'size': size,
  };
}

/// POP3 per-message metadata (LIST/STAT-friendly subset of [MessageMeta]).
class Pop3Meta {
  const Pop3Meta({
    required this.uid,
    required this.size,
    this.flags = const <String>[],
  });
  final int uid;
  final int size;
  final List<String> flags;

  Map<String, dynamic> toMap() => {'uid': uid, 'size': size, 'flags': flags};
}

// ===========================================================================
// Body responder (IMAP `messageBody` / POP3 `messageBody`)
// ===========================================================================

/// Typed wrapper around the `responder` map. IMAP exposes `send` and
/// `error`; POP3 exposes `respond` and `error`. This hides the keying.
///
/// Use [BodyResponder.imap] / [BodyResponder.pop3] from inside a typed
/// `messageBody` handler — both call sites collapse to [send] and [error].
class BodyResponder {
  BodyResponder.imap(Map<String, dynamic> raw)
    : _send = raw['send'] as Function,
      _error = raw['error'] as Function;
  BodyResponder.pop3(Map<String, dynamic> raw)
    : _send = raw['respond'] as Function,
      _error = raw['error'] as Function;

  final Function _send;
  final Function _error;

  void send(Uint8List bytes) => _send(bytes);
  void error(String message) => _error(message);
}

// ===========================================================================
// Flag / expunge requests
// ===========================================================================

/// Typed view over the raw `setFlags` query map.
class SetFlagsRequest {
  SetFlagsRequest._(this.action, this.flags, this.uids);

  factory SetFlagsRequest.fromMap(Map<String, dynamic> raw) {
    final action = raw['action'] as String? ?? 'set';
    final flags = (raw['flags'] as List?)?.cast<String>() ?? const <String>[];
    final uids = (raw['uids'] as List?)?.cast<int>() ?? const <int>[];
    return SetFlagsRequest._(action, flags, uids);
  }

  /// `'add' | 'remove' | 'set'`.
  final String action;
  final List<String> flags;
  final List<int> uids;

  bool get isAdd => action == 'add';
  bool get isRemove => action == 'remove';
  bool get isSet => action == 'set';
}

/// Typed view over the raw `expunge` options map.
class ExpungeOptions {
  ExpungeOptions._(this.uids);

  factory ExpungeOptions.fromMap(Map<String, dynamic> raw) {
    final uids = (raw['uids'] as List?)?.cast<int>() ?? const <int>[];
    return ExpungeOptions._(uids);
  }

  /// When non-empty: only these UIDs were marked `\Deleted` and should
  /// be removed (used by `UID EXPUNGE`).
  final List<int> uids;
}

// ===========================================================================
// Generic responder helpers
// ===========================================================================

/// Fire-once OK/error responder used by handlers that don't return a value.
///
/// All dart_email_server IMAP/POP3 callbacks are `(err, result)` shaped,
/// so even "void" responses pass `null` for both slots.
class VoidResponder {
  VoidResponder(this._cb);
  final Function _cb;
  bool _called = false;

  void ok() {
    if (_called) return;
    _called = true;
    _cb(null, null);
  }

  void error(Object err) {
    if (_called) return;
    _called = true;
    _cb(err, null);
  }
}

/// Fire-once OK/error responder that returns a value to dart_email_server.
class ValueResponder<T> {
  ValueResponder(this._cb, this._toMap);
  final Function _cb;
  final dynamic Function(T) _toMap;
  bool _called = false;

  void ok(T value) {
    if (_called) return;
    _called = true;
    _cb(null, _toMap(value));
  }

  void error(Object err) {
    if (_called) return;
    _called = true;
    _cb(err);
  }
}

dynamic _listToMap<T>(List<T> list, dynamic Function(T) project) => [
  for (final e in list) project(e),
];

// ===========================================================================
// Typed handler API on MailboxFacade
// ===========================================================================

/// Typed event registration for [MailboxFacade]. These extensions wrap the
/// raw `mb.on('eventName', Function)` API so callers work with classes
/// instead of `Map<String, dynamic>`.
extension TypedMailboxFacade on MailboxFacade {
  void onFolders(void Function(ValueResponder<List<FolderInfo>> respond) h) {
    on('folders', (Function cb) {
      h(
        ValueResponder<List<FolderInfo>>(
          cb,
          (list) => _listToMap<FolderInfo>(list, (f) => f.toMap()),
        ),
      );
    });
  }

  void onOpenFolder(
    void Function(String name, ValueResponder<OpenFolderResult> respond) h,
  ) {
    on('openFolder', (String name, Function cb) {
      h(name, ValueResponder<OpenFolderResult>(cb, (r) => r.toMap()));
    });
  }

  void onStatus(
    void Function(
      String name,
      List<String> items,
      ValueResponder<StatusResult> respond,
    )
    h,
  ) {
    on('status', (String name, List<dynamic> items, Function cb) {
      h(
        name,
        items.map((e) => e.toString()).toList(growable: false),
        ValueResponder<StatusResult>(cb, (r) => r.toMap()),
      );
    });
  }

  void onResolveMessages(
    void Function(
      String folder,
      ResolveQuery query,
      ValueResponder<List<MessageRef>> respond,
    )
    h,
  ) {
    on('resolveMessages', (String name, Map<String, dynamic> raw, Function cb) {
      h(
        name,
        ResolveQuery.fromMap(raw),
        ValueResponder<List<MessageRef>>(
          cb,
          (list) => _listToMap<MessageRef>(list, (m) => m.toMap()),
        ),
      );
    });
  }

  void onMessageMeta(
    void Function(
      String folder,
      List<int> uids,
      ValueResponder<List<MessageMeta>> respond,
    )
    h,
  ) {
    on('messageMeta', (String name, List<dynamic> uids, Function cb) {
      h(
        name,
        uids.whereType<int>().toList(growable: false),
        ValueResponder<List<MessageMeta>>(
          cb,
          (list) => _listToMap<MessageMeta>(list, (m) => m.toMap()),
        ),
      );
    });
  }

  void onPop3MessageMeta(
    void Function(
      String folder,
      List<int> uids,
      ValueResponder<List<Pop3Meta>> respond,
    )
    h,
  ) {
    on('messageMeta', (String name, List<dynamic> uids, Function cb) {
      h(
        name,
        uids.whereType<int>().toList(growable: false),
        ValueResponder<List<Pop3Meta>>(
          cb,
          (list) => _listToMap<Pop3Meta>(list, (m) => m.toMap()),
        ),
      );
    });
  }

  /// IMAP body delivery (`responder['send']`).
  void onImapMessageBody(
    void Function(String folder, int uid, BodyResponder respond) h,
  ) {
    on('messageBody', (String name, int uid, Map<String, dynamic> rawResp) {
      h(name, uid, BodyResponder.imap(rawResp));
    });
  }

  /// POP3 body delivery (`responder['respond']`).
  void onPop3MessageBody(
    void Function(String folder, int uid, BodyResponder respond) h,
  ) {
    on('messageBody', (String name, int uid, Map<String, dynamic> rawResp) {
      h(name, uid, BodyResponder.pop3(rawResp));
    });
  }

  void onSetFlags(
    void Function(String folder, SetFlagsRequest req, VoidResponder respond) h,
  ) {
    on('setFlags', (String name, Map<String, dynamic> raw, Function cb) {
      h(name, SetFlagsRequest.fromMap(raw), VoidResponder(cb));
    });
  }

  void onExpunge(
    void Function(String folder, ExpungeOptions opts, VoidResponder respond) h,
  ) {
    on('expunge', (String name, Map<String, dynamic> raw, Function cb) {
      h(name, ExpungeOptions.fromMap(raw), VoidResponder(cb));
    });
  }

  /// IMAP `SEARCH` / `UID SEARCH`. The `criteria` map is the parsed
  /// criteria tree (`{op, children, ...}`); inspecting it is optional —
  /// returning all live messages is a valid simple implementation.
  /// The handler must respond with a list of `{seq, uid}` refs that match.
  void onSearch(
    void Function(
      String folder,
      Map<String, dynamic> criteria,
      ValueResponder<List<MessageRef>> respond,
    )
    h,
  ) {
    on('search', (String name, Map<String, dynamic> criteria, Function cb) {
      h(
        name,
        criteria,
        ValueResponder<List<MessageRef>>(
          cb,
          (list) => _listToMap<MessageRef>(list, (m) => m.toMap()),
        ),
      );
    });
  }
}
