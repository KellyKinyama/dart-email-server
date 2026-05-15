import 'dart:convert';
import 'dart:typed_data';

import 'imap_wire.dart';
import 'utils.dart';
import 'imap_session.dart';

// ============================================================================
//  imap_metadata.dart — IMAP METADATA (RFC 5464) handlers
// ----------------------------------------------------------------------------
//  METADATA lets clients attach arbitrary annotations to mailboxes or to the
//  server as a whole, keyed by hierarchical paths. Typical uses:
//    • Apple Mail: /private/color, /private/notes
//    • Thunderbird: /private/sort-order, /private/columns
//    • iOS Mail: sync state
//
//  Path conventions (from the RFC):
//    /private/<name>  — visible only to the authenticating user
//    /shared/<name>   — visible to everyone with access to the mailbox
//
//  Both GETMETADATA and SETMETADATA operate at two scopes:
//    • A named mailbox:  GETMETADATA "INBOX" (/private/color)
//    • The server itself: GETMETADATA "" (/shared/admin)
//
//  This module is the protocol layer only — the library emits two events:
//
//     session.on('getMetadata', function(mailbox, paths, cb) {
//       // mailbox = '' for server-scope, else folder name
//       // paths = ['/private/color', '/shared/admin']
//       cb(null, { '/private/color': '#ff0000', '/shared/admin': null });
//     });
//
//     session.on('setMetadata', function(mailbox, entries, cb) {
//       // entries = { '/private/color': '#ff0000', '/private/notes': null }
//       //           null value = delete
//       cb(null);
//     });
//
//  The developer decides where to persist the values. If no listener is
//  registered the server returns NO and the client falls back to local storage.
// ============================================================================

// Maximum value size advertised in CAPABILITY. Clients MUST NOT exceed this.
// 2 KB is Dovecot's default and is plenty for colors, sort orders, notes.
const int DEFAULT_MAXSIZE = 2048;

void registerMetadataHandlers(IMAPSession s) {
  var ev = s.ev;
  var sendTagged = s.sendTagged;
  var sendUntagged = s.sendUntagged;
  var getStringValue = s.getStringValue;

  // --- HELPERS ---

  // Paths must be case-insensitive-ish, start with /private/ or /shared/,
  // and not contain '*', '%', or NULL. RFC 5464 §2.1.
  bool validPath(String? path) {
    if (path == null || path.isEmpty) return false;
    if (!path.startsWith('/')) return false;
    String lower = path.toLowerCase();
    if (!lower.startsWith('/private/') && !lower.startsWith('/shared/'))
      return false;
    if (RegExp(r'[*%\x00-\x1F]').hasMatch(path)) return false;
    return true;
  }

  // Quote a mailbox name for the wire (minimal quoting — handles empty
  // and names with spaces/specials by wrapping in "..." with escapes).
  String quoteMailbox(String name) {
    if (name == '') return '""';
    if (RegExp(r'^[A-Za-z0-9._\-\/]+$').hasMatch(name)) return name;
    return '"${name.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }

  // Serialize a value. Short ASCII → quoted; long or containing CR/LF → literal.
  // RFC 5464 §4.3: values may be binary; we emit as literal when non-ASCII.
  String serializeValue(String str) {
    // Use literal for values that contain CR/LF, NUL, or very long content —
    // otherwise quoted form is fine and cheaper to parse.
    Uint8List bytes = toU8(str);
    bool needsLiteral = false;
    for (int i = 0; i < bytes.length; i++) {
      int b = bytes[i];
      if (b == 0 || b == 13 || b == 10) {
        needsLiteral = true;
        break;
      }
    }
    if (!needsLiteral && bytes.length > 1024) needsLiteral = true;
    if (needsLiteral) {
      return '{${bytes.length}}\r\n${u8ToStr(bytes)}';
    }
    // Quoted form
    String esc = str.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$esc"';
  }

  // Per-session config — bumped later if developer sets server.metadataMaxSize
  const int maxSize = DEFAULT_MAXSIZE;

  // --- GETMETADATA ---
  //   GETMETADATA [ (options) ] <mailbox> (<entry> <entry> ...)
  //
  // Options (all optional, all rare in practice):
  //   MAXSIZE <n>    — client asks server to skip values > n bytes
  //   DEPTH 0 | 1 | infinity  — sub-path traversal; we implement depth 0 only
  //                             (explicit paths; no "all under /private/*" yet).
  //
  // Most clients just send the basic form. We parse options leniently and
  // ignore anything we don't implement.
  void handleGetMetadata(String tag, List<ImapToken> args) {
    if (ev.listenerCount('getMetadata') == 0) {
      sendTagged(tag, STATUS_NO, 'METADATA not implemented');
      return;
    }
    if (args.length < 2) {
      sendTagged(tag, STATUS_BAD, 'GETMETADATA requires mailbox and entry list');
      return;
    }

    int cursor = 0;
    int? clientMaxSize;
    // ignore: unused_local_variable
    int depth = 0;

    // Optional leading options list
    if (args[cursor] is ListToken) {
      var optTok = args[cursor++] as ListToken;
      List<ImapToken> optValue = optTok.value;
      for (int i = 0; i + 1 < optValue.length; i += 2) {
        String name = optValue[i].value.toString().toUpperCase();
        var val = optValue[i + 1];
        if (name == 'MAXSIZE') {
          clientMaxSize = (val is NumberToken)
              ? val.value
              : int.tryParse(val.value.toString());
        } else if (name == 'DEPTH') {
          String d = val.value.toString().toLowerCase();
          depth = (d == 'infinity') ? -1 : (int.tryParse(d) ?? 0);
        }
      }
    }

    if (cursor >= args.length) {
      sendTagged(tag, STATUS_BAD, 'GETMETADATA requires mailbox');
      return;
    }
    String mailbox = getStringValue(args[cursor++]);

    // Entry list — either a single atom or a parenthesized list
    List<String> paths = [];
    if (cursor < args.length) {
      var entryTok = args[cursor++];
      if (entryTok is ListToken) {
        List<ImapToken> entryValue = entryTok.value;
        for (int i = 0; i < entryValue.length; i++) {
          String p = getStringValue(entryValue[i]);
          if (p.isNotEmpty) paths.add(p);
        }
      } else {
        String p = getStringValue(entryTok);
        if (p.isNotEmpty) paths.add(p);
      }
    }

    // Validate paths — must start with /private/ or /shared/
    for (String p in paths) {
      if (!validPath(p)) {
        sendTagged(tag, STATUS_BAD, 'Invalid METADATA path: $p');
        return;
      }
    }

    ev.emit('getMetadata', mailbox, paths, (err, values) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'GETMETADATA failed');
        return;
      }
      Map<String, dynamic> vals =
          (values as Map<dynamic, dynamic>?)?.cast<String, dynamic>() ?? {};

      // Honor client-supplied MAXSIZE: entries with values exceeding it are
      // reported with a LONGENTRIES response code rather than the value.
      int effMax = (clientMaxSize != null && clientMaxSize < maxSize)
          ? clientMaxSize
          : maxSize;
      int longest = 0;

      // Build METADATA untagged response — one line with all key/value pairs
      //   "* METADATA <mailbox> (<key> <value> <key> <value> ...)"
      List<String> parts = [];
      for (String p in paths) {
        var v = vals[p];
        if (v == null) continue; // not set → skip
        String str = v.toString();
        int byteLen = utf8.encode(str).length;
        if (byteLen > effMax) {
          if (byteLen > longest) longest = byteLen;
          continue;
        }
        parts.add(p);
        parts.add(serializeValue(str));
      }

      if (parts.isNotEmpty) {
        sendUntagged('METADATA ${quoteMailbox(mailbox)} (${parts.join(' ')})');
      }

      String? code;
      if (longest > 0) code = 'METADATA LONGENTRIES $longest';
      sendTagged(tag, STATUS_OK, 'GETMETADATA completed', code);
    });
  }

  // --- SETMETADATA ---
  //   SETMETADATA <mailbox> (<entry> <value> <entry> <value> ...)
  //
  // Value of NIL (as atom, unquoted) means delete the entry. Strings may be
  // quoted or literal. Paths must start with /private/ or /shared/.
  void handleSetMetadata(String tag, List<ImapToken> args) {
    if (ev.listenerCount('setMetadata') == 0) {
      sendTagged(tag, STATUS_NO, 'METADATA not implemented');
      return;
    }
    if (args.length < 2) {
      sendTagged(tag, STATUS_BAD, 'SETMETADATA requires mailbox and entry list');
      return;
    }
    String mailbox = getStringValue(args[0]);
    var entryTok = args[1];
    if (entryTok is! ListToken) {
      sendTagged(tag, STATUS_BAD, 'SETMETADATA requires entry-value list');
      return;
    }

    Map<String, String?> entries = {};
    List<ImapToken> toks = entryTok.value;
    if (toks.length % 2 != 0) {
      sendTagged(tag, STATUS_BAD, 'SETMETADATA entries must be name/value pairs');
      return;
    }

    for (int i = 0; i + 1 < toks.length; i += 2) {
      String path = getStringValue(toks[i]);
      if (!validPath(path)) {
        sendTagged(tag, STATUS_BAD, 'Invalid METADATA path: $path');
        return;
      }
      var valTok = toks[i + 1];
      String? val;
      if (valTok is NilToken) {
        val = null; // delete
      } else if (valTok is LiteralToken) {
        val = u8ToStr(valTok.value);
      } else {
        val = valTok.value?.toString() ?? '';
      }

      // Enforce server-side MAXSIZE
      if (val != null && utf8.encode(val).length > maxSize) {
        sendTagged(
          tag,
          'NO',
          'Value exceeds METADATA MAXSIZE',
          'METADATA MAXSIZE $maxSize',
        );
        return;
      }
      entries[path] = val;
    }

    ev.emit('setMetadata', mailbox, entries, (err) {
      if (err != null) {
        // RFC 5464 defines specific codes:
        //   METADATA TOOMANY     — too many entries in mailbox
        //   METADATA NOPRIVATE   — server doesn't accept /private/
        // We default to a generic NO; the developer's error object can
        // override by setting err.code.
        sendTagged(tag, STATUS_NO, err.message ?? 'SETMETADATA failed', err.code);
        return;
      }
      sendTagged(tag, STATUS_OK, 'SETMETADATA completed');
    });
  }

  // Expose handlers for the dispatcher
  s.handleGetMetadata = handleGetMetadata;
  s.handleSetMetadata = handleSetMetadata;
}
