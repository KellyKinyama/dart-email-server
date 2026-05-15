import 'dart:math';
import 'dart:typed_data';

import 'imap_wire.dart';
import 'imap_helpers.dart';
import 'imap_session.dart';

/// Parsed LIST/LSUB selection options (RFC 5258 §3).
class _ListSelectionOptions {
  bool subscribed = false;
  bool remote = false;
  bool recursiveMatch = false;
}

/// Parsed LIST RETURN options (RFC 5258 §4).
class _ListReturnOptions {
  bool children = false;
  bool subscribed = false;
  bool specialUse = false;
  List<String>? status;
}

void registerFolderHandlers(IMAPSession s) {
  var context = s.context;
  var ev = s.ev;
  var sendTagged = s.sendTagged;
  var sendUntagged = s.sendUntagged;
  var getStringValue = s.getStringValue;
  var emitFetchResponse = s.emitFetchResponse;
  var requireSelected = s.requireSelected;

  // ============================================================
  //  SERVER MODE — Phase 2 handlers: folders + SELECT
  // ============================================================

  bool requireAuth(String tag) {
    if (context.state == SessionState.NOT_AUTHENTICATED) {
      // Adjusting for typical Dart STATE map
      // context.authenticated is used in JS
      if (context.authenticated != true) {
        sendTagged(tag, STATUS_BAD, 'Command requires authentication');
        return false;
      }
    }
    if (context.authenticated != true) {
      sendTagged(tag, STATUS_BAD, 'Command requires authentication');
      return false;
    }
    return true;
  }

  void exitSelected() {
    context.state = SessionState.AUTHENTICATED;
    context.currentFolder = null;
    context.currentFolderReadOnly = false;
    context.currentFolderUidValidity = null;
    context.currentFolderTotal = 0;
  }

  void handleList(String tag, List<ImapToken> args, bool subscribedOnly) {
    if (!requireAuth(tag)) return;
    if (args.length < 2) {
      sendTagged(
        tag,
        STATUS_BAD,
        'LIST requires reference and mailbox pattern',
      );
      return;
    }

    int cursor = 0;
    final selectionOpts = _ListSelectionOptions();

    if (cursor < args.length && args[cursor] is ListToken) {
      var selTok = args[cursor++] as ListToken;
      for (int i = 0; i < selTok.value.length; i++) {
        String opt = selTok.value[i].value?.toString().toUpperCase() ?? '';
        if (opt == 'SUBSCRIBED')
          selectionOpts.subscribed = true;
        else if (opt == 'REMOTE')
          selectionOpts.remote = true;
        else if (opt == 'RECURSIVEMATCH')
          selectionOpts.recursiveMatch = true;
      }
    }

    if (cursor >= args.length) {
      sendTagged(tag, STATUS_BAD, 'LIST requires reference');
      return;
    }
    String reference = getStringValue(args[cursor++]);

    if (cursor >= args.length) {
      sendTagged(tag, STATUS_BAD, 'LIST requires mailbox pattern');
      return;
    }

    List<String> patterns = [];
    var patTok = args[cursor++];
    if (patTok is ListToken) {
      for (int i = 0; i < patTok.value.length; i++) {
        patterns.add(getStringValue(patTok.value[i]));
      }
    } else {
      patterns.add(getStringValue(patTok));
    }

    final returnOpts = _ListReturnOptions();

    if (cursor < args.length &&
        args[cursor] is AtomToken &&
        ((args[cursor] as AtomToken).value.toUpperCase() == 'RETURN')) {
      cursor++;
      if (cursor >= args.length || args[cursor] is! ListToken) {
        sendTagged(
          tag,
          STATUS_BAD,
          'RETURN requires a parenthesized option list',
        );
        return;
      }
      var retTok = args[cursor++] as ListToken;
      for (int i = 0; i < retTok.value.length; i++) {
        String opt = retTok.value[i].value?.toString().toUpperCase() ?? '';
        if (opt == 'CHILDREN')
          returnOpts.children = true;
        else if (opt == 'SUBSCRIBED')
          returnOpts.subscribed = true;
        else if (opt == 'SPECIAL-USE')
          returnOpts.specialUse = true;
        else if (opt == 'STATUS' &&
            i + 1 < retTok.value.length &&
            retTok.value[i + 1] is ListToken) {
          List<String> items = [];
          var itemList = (retTok.value[i + 1] as ListToken).value;
          for (int j = 0; j < itemList.length; j++) {
            items.add(itemList[j].value?.toString().toUpperCase() ?? '');
          }
          returnOpts.status = items;
          i++;
        }
      }
    }

    if (subscribedOnly) selectionOpts.subscribed = true;

    if (reference == '' && patterns.length == 1 && patterns[0] == '') {
      sendUntagged('LIST (\\Noselect) "${context.delimiter}" ""');
      sendTagged(tag, STATUS_OK, 'LIST completed');
      return;
    }

    ev.emit('folders', (err, folders) {
      void emitStatusForFolder(String name, List<String> items, Function done) {
        ev.emit('status', name, items, (err2, stats) {
          if (err2 != null || stats == null) {
            done();
            return;
          }
          List<String> parts = [];
          for (int i = 0; i < items.length; i++) {
            String k = items[i];
            dynamic v;
            switch (k) {
              case 'MESSAGES':
                v = stats['messages'];
                break;
              case 'UIDNEXT':
                v = stats['uidnext'];
                break;
              case 'UIDVALIDITY':
                v = stats['uidvalidity'];
                break;
              case 'UNSEEN':
                v = stats['unseen'];
                break;
              case 'RECENT':
                v = stats['recent'];
                break;
              case 'HIGHESTMODSEQ':
                v = stats['highestmodseq'];
                break;
              case 'DELETED':
                v = stats['deleted'];
                break;
              case 'SIZE':
                v = stats['size'];
                break;
            }
            if (v != null) parts.add('$k $v');
          }
          sendUntagged('STATUS ${s.quoteMailbox(name)} (${parts.join(' ')})');
          done();
        });
      }

      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'Cannot list folders');
        return;
      }

      List<dynamic> fList = folders ?? [];

      if (selectionOpts.subscribed) {
        fList = fList
            .where((f) => f != null && f['subscribed'] != false)
            .toList();
      }

      List<Function> matchers = patterns
          .map((p) => makeWildcardMatcher(reference, p, context.delimiter))
          .toList();
      List<String> allNames = fList.map((f) => f['name'].toString()).toList();

      Map<String, bool> seen = {};
      List<dynamic> matched = [];
      for (int i = 0; i < fList.length; i++) {
        var f = fList[i];
        if (f == null || f['name'] == null || seen.containsKey(f['name']))
          continue;
        for (int m = 0; m < matchers.length; m++) {
          if (matchers[m](f['name'])) {
            seen[f['name']] = true;
            matched.add(f);
            break;
          }
        }
      }

      String respName = subscribedOnly ? 'LSUB' : 'LIST';
      for (int i = 0; i < matched.length; i++) {
        var f = matched[i];
        List<String> attrs = [];
        attrs.add(
          hasChildren(f['name'], allNames, context.delimiter)
              ? '\\HasChildren'
              : '\\HasNoChildren',
        );

        String? su = normalizeSpecialUse(f['specialUse']?.toString() ?? '');
        if (su != null) attrs.add(su);

        if ((returnOpts.subscribed || subscribedOnly) &&
            f['subscribed'] != false) {
          attrs.add('\\Subscribed');
        }

        if (f['selectable'] == false) attrs.add('\\Noselect');

        sendUntagged(
          '$respName (${attrs.join(' ')}) "${context.delimiter}" ${s.quoteMailbox(f['name'])}',
        );
      }

      if (returnOpts.status != null && matched.isNotEmpty) {
        int pendingStatus = matched.length;
        void oneStatus() {
          if (--pendingStatus == 0) {
            sendTagged(tag, STATUS_OK, '$respName completed');
          }
        }

        for (int i = 0; i < matched.length; i++) {
          emitStatusForFolder(
            matched[i]['name'],
            returnOpts.status!,
            oneStatus,
          );
        }
        return;
      }

      sendTagged(tag, STATUS_OK, '$respName completed');
    });
  }

  void emitQresyncData(Map<String, dynamic> sync) {
    String? vanishedStr;
    if (sync['vanishedRanges'] != null && sync['vanishedRanges'].isNotEmpty) {
      vanishedStr = formatRanges(sync['vanishedRanges']);
    } else if (sync['vanishedUids'] != null &&
        sync['vanishedUids'].isNotEmpty) {
      vanishedStr = compressUids(sync['vanishedUids']);
    }

    if (vanishedStr != null && vanishedStr.isNotEmpty) {
      sendUntagged('VANISHED (EARLIER) $vanishedStr');
    }

    List<dynamic> changed = sync['changedMessages'] ?? [];
    for (int i = 0; i < changed.length; i++) {
      var m = changed[i];
      var meta = {'flags': m['flags'] ?? [], 'modseq': m['modseq']};
      var items = [
        {'name': 'UID'},
        {'name': 'FLAGS'},
        {'name': 'MODSEQ'},
      ];
      emitFetchResponse(m['seq'], m['uid'], meta, null, null, items, true);
    }
  }

  dynamic numericTokenValue(ImapToken? tok) {
    if (tok == null) return null;
    if (tok is NumberToken) return tok.value;
    if (tok is AtomToken) {
      try {
        return int.parse(tok.value);
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  Map<String, dynamic>? parseQresyncParam(ImapToken? listTok) {
    if (listTok == null || listTok is! ListToken) return null;
    var p = listTok.value;
    if (p.length < 2) return null;

    var uv = numericTokenValue(p[0]);
    var ms = numericTokenValue(p[1]);
    if (uv == null || ms == null) return null;

    dynamic knownUids;
    int idx = 2;
    if (idx < p.length && p[idx] is AtomToken) {
      var parsed = parseSequenceSet((p[idx] as AtomToken).value, {});
      if (parsed['error'] == null) knownUids = parsed['ranges'];
      idx++;
    }

    return {'uidValidity': uv, 'lastKnownModseq': ms, 'knownUids': knownUids};
  }

  void handleSelect(String tag, List<ImapToken> args, bool readOnly) {
    if (!requireAuth(tag)) return;
    if (args.isEmpty) {
      sendTagged(
        tag,
        'BAD',
        '${readOnly ? 'EXAMINE' : 'SELECT'} requires mailbox name',
      );
      return;
    }

    String name = getStringValue(args[0]);
    Map<String, dynamic>? qresyncParams;

    if (args.length >= 2 && args[1] is ListToken) {
      var params = (args[1] as ListToken).value;
      for (int i = 0; i < params.length; i++) {
        var p = params[i];
        if (p is! AtomToken) continue;
        String pname = p.value.toUpperCase();
        if (pname == 'CONDSTORE') {
          context.condstoreEnabled = true;
        } else if (pname == 'QRESYNC' &&
            i + 1 < params.length &&
            params[i + 1] is ListToken) {
          qresyncParams = parseQresyncParam(params[i + 1]);
          if (qresyncParams != null) {
            context.condstoreEnabled = true;
            context.qresyncEnabled = true;
          }
          i++;
        }
      }
    }

    exitSelected();

    ev.emit('openFolder', name, (err, info) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'Cannot open folder');
        return;
      }
      if (info == null) {
        sendTagged(tag, STATUS_NO, 'Folder not found');
        return;
      }

      List<dynamic> flags = info['flags'] ?? DEFAULT_FLAGS;
      List<dynamic> permanentFlags =
          info['permanentFlags'] ?? List.from(DEFAULT_FLAGS)
            ..add('*');
      int total = info['total'] ?? 0;
      int recent = info['recent'] ?? 0;
      int uidValidity = info['uidValidity'] ?? 1;
      int uidNext = info['uidNext'] ?? 1;
      int highestModseq = info['highestModseq'] ?? 0;

      sendUntagged('FLAGS ${serializeFlagList(flags)}');
      sendUntagged('$total EXISTS');
      sendUntagged('$recent RECENT');
      if (info['unseen'] != null) {
        sendUntagged(
          'OK [UNSEEN ${info['unseen']}] Message ${info['unseen']} is first unseen',
        );
      }
      sendUntagged('OK [UIDVALIDITY $uidValidity] UIDs valid');
      sendUntagged('OK [UIDNEXT $uidNext] Predicted next UID');
      sendUntagged(
        'OK [PERMANENTFLAGS ${serializeFlagList(permanentFlags)}] Limited',
      );
      if (info['highestModseq'] != null) {
        sendUntagged('OK [HIGHESTMODSEQ $highestModseq] Highest');
      } else {
        sendUntagged(
          'OK [NOMODSEQ] No permanent mod-sequences for this mailbox',
        );
      }

      context.state = SessionState.SELECTED;
      context.currentFolder = name;
      context.currentFolderReadOnly = readOnly;
      context.currentFolderUidValidity = uidValidity;
      context.currentFolderTotal = total;
      context.currentFolderHighestModseq = highestModseq;

      String code = readOnly ? 'READ-ONLY' : 'READ-WRITE';
      String cmdName = readOnly ? 'EXAMINE' : 'SELECT';

      if (qresyncParams != null && ev.listenerCount('qresync') > 0) {
        if (qresyncParams['uidValidity'] != uidValidity) {
          sendTagged(tag, STATUS_OK, '$cmdName completed', code);
          return;
        }
        ev.emit('qresync', name, qresyncParams, (qerr, sync) {
          if (qerr == null && sync != null) emitQresyncData(sync);
          sendTagged(tag, STATUS_OK, '$cmdName completed', code);
        });
        return;
      }

      sendTagged(tag, STATUS_OK, '$cmdName completed', code);
    });
  }

  List<String> extractUseFlags(List<ImapToken> args) {
    List<String> out = [];
    for (int i = 1; i < args.length; i++) {
      var a = args[i];
      if (a is ListToken && a.value.length >= 2) {
        var first = a.value[0];
        if (first.value?.toString().toUpperCase() == 'USE' &&
            a.value[1] is ListToken) {
          var flagList = (a.value[1] as ListToken).value;
          for (int j = 0; j < flagList.length; j++) {
            String v = flagList[j].value?.toString() ?? '';
            String? n = normalizeSpecialUse(v);
            if (n != null) out.add(n);
          }
        }
      }
    }
    return out;
  }

  void handleCreate(String tag, List<ImapToken> args) {
    if (!requireAuth(tag)) return;
    if (args.isEmpty) {
      sendTagged(tag, STATUS_BAD, 'CREATE requires mailbox name');
      return;
    }
    String name = getStringValue(args[0]);

    while (name.length > 1 && name.endsWith(context.delimiter)) {
      name = name.substring(0, name.length - 1);
    }

    if (name.toUpperCase() == 'INBOX') {
      sendTagged(tag, STATUS_NO, 'INBOX already exists');
      return;
    }

    var useFlags = extractUseFlags(args);
    Map<String, dynamic> payload = {'name': name};
    if (useFlags.isNotEmpty) payload['specialUse'] = useFlags[0];

    ev.emit('createFolder', name, payload, (err) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'Cannot create folder');
        return;
      }
      sendTagged(tag, STATUS_OK, 'CREATE completed');
    });
  }

  void handleDelete(String tag, List<ImapToken> args) {
    if (!requireAuth(tag)) return;
    if (args.isEmpty) {
      sendTagged(tag, STATUS_BAD, 'DELETE requires mailbox name');
      return;
    }
    String name = getStringValue(args[0]);

    if (name.toUpperCase() == 'INBOX') {
      sendTagged(tag, STATUS_NO, 'Cannot delete INBOX');
      return;
    }

    if (context.state == SessionState.SELECTED &&
        context.currentFolder == name) {
      exitSelected();
    }

    ev.emit('deleteFolder', name, (err) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'Cannot delete folder');
        return;
      }
      sendTagged(tag, STATUS_OK, 'DELETE completed');
    });
  }

  void handleRename(String tag, List<ImapToken> args) {
    if (!requireAuth(tag)) return;
    if (args.length < 2) {
      sendTagged(tag, STATUS_BAD, 'RENAME requires old and new names');
      return;
    }
    String oldName = getStringValue(args[0]);
    String newName = getStringValue(args[1]);

    if (context.state == SessionState.SELECTED &&
        context.currentFolder == oldName) {
      exitSelected();
    }

    ev.emit('renameFolder', oldName, newName, (err) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'Cannot rename folder');
        return;
      }
      sendTagged(tag, STATUS_OK, 'RENAME completed');
    });
  }

  void handleSubscribe(String tag, List<ImapToken> args) {
    if (!requireAuth(tag)) return;
    if (args.isEmpty) {
      sendTagged(tag, STATUS_BAD, 'SUBSCRIBE requires mailbox name');
      return;
    }
    String name = getStringValue(args[0]);
    ev.emit('subscribe', name, (err) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'Cannot subscribe');
        return;
      }
      sendTagged(tag, STATUS_OK, 'SUBSCRIBE completed');
    });
  }

  void handleUnsubscribe(String tag, List<ImapToken> args) {
    if (!requireAuth(tag)) return;
    if (args.isEmpty) {
      sendTagged(tag, STATUS_BAD, 'UNSUBSCRIBE requires mailbox name');
      return;
    }
    String name = getStringValue(args[0]);
    ev.emit('unsubscribe', name, (err) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'Cannot unsubscribe');
        return;
      }
      sendTagged(tag, STATUS_OK, 'UNSUBSCRIBE completed');
    });
  }

  void handleStatus(String tag, List<ImapToken> args) {
    if (!requireAuth(tag)) return;
    if (args.length < 2) {
      sendTagged(tag, STATUS_BAD, 'STATUS requires mailbox name and items');
      return;
    }
    String name = getStringValue(args[0]);
    if (args[1] is! ListToken) {
      sendTagged(tag, STATUS_BAD, 'STATUS items must be a parenthesized list');
      return;
    }

    List<String> requestedItems = [];
    var listValue = (args[1] as ListToken).value;
    for (int i = 0; i < listValue.length; i++) {
      String v = listValue[i].value?.toString().toUpperCase() ?? '';
      if (v.isNotEmpty) requestedItems.add(v);
    }

    ev.emit('status', name, requestedItems, (err, info) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'Cannot get status');
        return;
      }
      if (info == null) {
        sendTagged(tag, STATUS_NO, 'Folder not found');
        return;
      }

      List<String> parts = [];
      for (int i = 0; i < requestedItems.length; i++) {
        String item = requestedItems[i];
        dynamic val;
        if (item == 'MESSAGES' && info['messages'] != null)
          val = info['messages'];
        else if (item == 'RECENT' && info['recent'] != null)
          val = info['recent'];
        else if (item == 'UIDNEXT' && info['uidNext'] != null)
          val = info['uidNext'];
        else if (item == 'UIDVALIDITY' && info['uidValidity'] != null)
          val = info['uidValidity'];
        else if (item == 'UNSEEN' && info['unseen'] != null)
          val = info['unseen'];
        if (val != null) parts.add('$item $val');
      }

      sendUntagged('STATUS ${s.quoteMailbox(name)} (${parts.join(' ')})');
      sendTagged(tag, STATUS_OK, 'STATUS completed');
    });
  }

  void handleClose(String tag) {
    if (!requireAuth(tag)) return;
    if (context.state != SessionState.SELECTED) {
      sendTagged(tag, STATUS_BAD, 'No folder selected');
      return;
    }
    exitSelected();
    sendTagged(tag, STATUS_OK, 'CLOSE completed');
  }

  void handleUnselect(String tag) {
    if (!requireAuth(tag)) return;
    if (context.state != SessionState.SELECTED) {
      sendTagged(tag, STATUS_BAD, 'No folder selected');
      return;
    }
    exitSelected();
    sendTagged(tag, STATUS_OK, 'UNSELECT completed');
  }

  void handleAppend(String tag, List<ImapToken> args) {
    if (context.state != SessionState.AUTHENTICATED &&
        context.state != SessionState.SELECTED) {
      sendTagged(tag, STATUS_BAD, 'APPEND requires authentication');
      return;
    }
    if (args.length < 2) {
      sendTagged(tag, STATUS_BAD, 'APPEND requires mailbox and message');
      return;
    }

    String folder = getStringValue(args[0]);
    List<String>? flags;
    DateTime? internalDate;
    dynamic literal;

    for (int i = 1; i < args.length; i++) {
      var a = args[i];
      if (a is ListToken) {
        flags = [];
        for (int j = 0; j < a.value.length; j++) {
          var f = a.value[j];
          var norm = normalizeFlag(f.value?.toString() ?? '');
          if (norm != null) flags.add(norm);
        }
      } else if (a is LiteralToken) {
        literal = a.value;
      } else if (a is QuotedToken || a is AtomToken) {
        String s_val = getStringValue(a);
        DateTime? d = parseInternalDate(s_val);
        if (d != null) internalDate = d;
      }
    }

    if (literal == null) {
      sendTagged(tag, STATUS_BAD, 'APPEND requires message literal');
      return;
    }

    Uint8List raw = literal is Uint8List
        ? literal
        : Uint8List.fromList((literal as List).cast<int>());
    Map<String, dynamic> options = {};
    if (flags != null) options['flags'] = flags;
    if (internalDate != null) options['internalDate'] = internalDate;

    ev.emit('append', folder, raw, options, (err, result) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'APPEND failed');
        return;
      }
      String? code;
      if (result != null &&
          result['uid'] != null &&
          result['uidValidity'] != null) {
        code = 'APPENDUID ${result['uidValidity']} ${result['uid']}';
      }
      sendTagged(tag, STATUS_OK, 'APPEND completed', code);
    });
  }

  void sendExpungeResponses(List<dynamic>? deleted) {
    if (deleted == null || deleted.isEmpty) return;
    var sorted = List.of(deleted);
    sorted.sort((a, b) => (b['seq'] as int).compareTo(a['seq'] as int));
    for (int i = 0; i < sorted.length; i++) {
      if (sorted[i]['seq'] is int) {
        sendUntagged('${sorted[i]['seq']} EXPUNGE');
      }
    }
    context.currentFolderTotal = max(
      0,
      context.currentFolderTotal - sorted.length,
    );
  }

  void handleExpunge(String tag, List<ImapToken>? args) {
    if (!requireSelected(tag)) return;
    if (context.currentFolderReadOnly == true) {
      sendTagged(tag, STATUS_NO, 'Cannot expunge in EXAMINE mode');
      return;
    }

    Map<String, dynamic>? options;
    bool isUidExpunge = false;
    if (args != null && args.isNotEmpty) {
      isUidExpunge = true;
      String setStr = getStringValue(args[0]);
      var parsed = parseSequenceSet(setStr, {
        'isUid': true,
        'total': context.currentFolderTotal,
      });
      if (parsed['error'] != null) {
        sendTagged(tag, STATUS_BAD, 'Invalid UID set: ${parsed['error']}');
        return;
      }
      options = {'uidRanges': parsed['ranges']};
    }

    ev.emit('expunge', context.currentFolder, options, (err, deleted) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'EXPUNGE failed');
        return;
      }
      sendExpungeResponses(deleted);
      sendTagged(
        tag,
        STATUS_OK,
        '${isUidExpunge ? 'UID ' : ''}EXPUNGE completed',
      );
    });
  }

  void handleMove(String tag, List<ImapToken> args, bool byUid) {
    if (!requireSelected(tag)) return;
    if (context.currentFolderReadOnly == true) {
      sendTagged(tag, STATUS_NO, 'Cannot move from read-only folder');
      return;
    }
    if (args.length < 2) {
      sendTagged(tag, STATUS_BAD, 'MOVE requires sequence set and destination');
      return;
    }
    if (ev.listenerCount('move') == 0) {
      sendTagged(tag, STATUS_NO, 'MOVE not supported');
      return;
    }

    String setStr = getStringValue(args[0]);
    String dst = getStringValue(args[1]);
    var parsed = parseSequenceSet(setStr, {
      'isUid': byUid,
      'total': context.currentFolderTotal,
    });
    if (parsed['error'] != null) {
      sendTagged(tag, STATUS_BAD, 'Invalid sequence set: ${parsed['error']}');
      return;
    }

    ev.emit(
      'resolveMessages',
      context.currentFolder,
      {'type': byUid ? 'uid' : 'seq', 'ranges': parsed['ranges']},
      (err, messages) {
        if (err != null) {
          sendTagged(tag, STATUS_NO, err.message);
          return;
        }
        List<dynamic> msgs = messages ?? [];
        if (msgs.isEmpty) {
          sendTagged(tag, STATUS_OK, '${byUid ? 'UID ' : ''}MOVE completed');
          return;
        }
        List<dynamic> uids = msgs.map((m) => m['uid']).toList();

        ev.emit('move', context.currentFolder, uids, dst, (err2, mapping) {
          if (err2 != null) {
            sendTagged(tag, STATUS_NO, err2.message ?? 'MOVE failed');
            return;
          }
          String? code = buildCopyUidCode(mapping);
          if (code != null) {
            sendUntagged('OK [$code] Moved');
          }
          sendExpungeResponses(msgs);
          sendTagged(tag, STATUS_OK, '${byUid ? 'UID ' : ''}MOVE completed');
        });
      },
    );
  }

  String nsQuote(dynamic s) {
    if (s == null) return 'NIL';
    return '"${s.toString().replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }

  String buildNamespaceGroup(List<dynamic>? entries) {
    if (entries == null || entries.isEmpty) return 'NIL';
    List<String> parts = [];
    for (int i = 0; i < entries.length; i++) {
      var e = entries[i];
      parts.add('(${nsQuote(e['prefix'])} ${nsQuote(e['delimiter'])})');
    }
    return '(${parts.join('')})';
  }

  void handleNamespace(String tag) {
    if (context.state != SessionState.AUTHENTICATED &&
        context.state != SessionState.SELECTED) {
      sendTagged(tag, STATUS_BAD, 'NAMESPACE requires authentication');
      return;
    }

    void respond(List<dynamic>? entries) {
      List<dynamic> ents = entries ?? [];
      List<dynamic> personal = [], others = [], shared = [];
      for (int i = 0; i < ents.length; i++) {
        var e = ents[i];
        String typ = (e['type']?.toString() ?? 'personal').toLowerCase();
        if (typ == 'personal')
          personal.add(e);
        else if (typ == 'otherusers' || typ == 'other' || typ == 'otheruser')
          others.add(e);
        else if (typ == 'shared')
          shared.add(e);
      }
      if (personal.isEmpty && others.isEmpty && shared.isEmpty) {
        personal = [
          {'prefix': '', 'delimiter': '/'},
        ];
      }

      sendUntagged(
        'NAMESPACE ${buildNamespaceGroup(personal)} ${buildNamespaceGroup(others)} ${buildNamespaceGroup(shared)}',
      );
      sendTagged(tag, STATUS_OK, 'NAMESPACE completed');
    }

    if (ev.listenerCount('namespace') == 0) {
      respond(null);
      return;
    }
    ev.emit('namespace', (err, entries) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'NAMESPACE failed');
        return;
      }
      respond(entries);
    });
  }

  void emitQuotaResponse(Map<String, dynamic> info) {
    String rootName = info['root']?.toString() ?? '';
    List<dynamic> pairs = [];
    List<dynamic> resources = info['resources'] ?? [];
    for (int i = 0; i < resources.length; i++) {
      var r = resources[i];
      if (r == null || r['name'] == null) continue;
      pairs.add(r['name'].toString().toUpperCase());
      pairs.add(max(0, (r['usage'] as num? ?? 0).floor()));
      pairs.add(max(0, (r['limit'] as num? ?? 0).floor()));
    }
    sendUntagged('QUOTA ${nsQuote(rootName)} (${pairs.join(' ')})');
  }

  void handleGetQuota(String tag, List<ImapToken> args) {
    if (!requireAuth(tag)) return;
    if (args.isEmpty) {
      sendTagged(tag, STATUS_BAD, 'GETQUOTA requires a quota root name');
      return;
    }
    if (ev.listenerCount('quota') == 0) {
      sendTagged(tag, STATUS_NO, 'Quota not implemented');
      return;
    }
    String root = getStringValue(args[0]);
    ev.emit('quota', root, (err, info) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'Quota lookup failed');
        return;
      }
      if (info != null) emitQuotaResponse(info);
      sendTagged(tag, STATUS_OK, 'GETQUOTA completed');
    });
  }

  void handleGetQuotaRoot(String tag, List<ImapToken> args) {
    if (!requireAuth(tag)) return;
    if (args.isEmpty) {
      sendTagged(tag, STATUS_BAD, 'GETQUOTAROOT requires a mailbox name');
      return;
    }
    if (ev.listenerCount('quotaRoot') == 0 && ev.listenerCount('quota') == 0) {
      sendTagged(tag, STATUS_NO, 'Quota not implemented');
      return;
    }
    String mailbox = getStringValue(args[0]);

    List<String>? roots;
    void afterRoots() {
      sendUntagged(
        'QUOTAROOT ${s.quoteMailbox(mailbox)}${roots!.isNotEmpty ? ' ' + roots!.map(nsQuote).join(' ') : ''}',
      );

      if (roots!.isEmpty) {
        sendTagged(tag, STATUS_OK, 'GETQUOTAROOT completed');
        return;
      }
      int pending = roots!.length;
      void oneRoot() {
        if (--pending == 0)
          sendTagged(tag, STATUS_OK, 'GETQUOTAROOT completed');
      }

      for (int i = 0; i < roots!.length; i++) {
        ev.emit('quota', roots![i], (err, info) {
          if (err == null && info != null) emitQuotaResponse(info);
          oneRoot();
        });
      }
    }

    if (ev.listenerCount('quotaRoot') > 0) {
      ev.emit('quotaRoot', mailbox, (err, list) {
        roots = list is List ? List<String>.from(list) : [];
        afterRoots();
      });
    } else {
      roots = [''];
      afterRoots();
    }
  }

  s.handleList = handleList;
  s.handleSelect = handleSelect;
  s.handleCreate = handleCreate;
  s.handleDelete = handleDelete;
  s.handleRename = handleRename;
  s.handleSubscribe = handleSubscribe;
  s.handleUnsubscribe = handleUnsubscribe;
  s.handleStatus = handleStatus;
  s.handleClose = handleClose;
  s.handleUnselect = handleUnselect;
  s.handleAppend = handleAppend;
  s.handleExpunge = handleExpunge;
  s.handleMove = handleMove;
  s.handleNamespace = handleNamespace;
  s.handleGetQuota = handleGetQuota;
  s.handleGetQuotaRoot = handleGetQuotaRoot;
}
