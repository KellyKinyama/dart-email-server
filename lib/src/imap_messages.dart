import 'dart:async';
import 'dart:typed_data';
import 'dart:math';

import 'imap_wire.dart';
import 'imap_helpers.dart';
import 'message.dart';
import 'utils.dart'; // toU8, u8ToStr, concatU8, indexOfCRLF etc.
import 'imap_session.dart';

void registerMessageHandlers(IMAPSession s) {
  var context = s.context;
  var ev = s.ev;
  Function sendTagged = s.sendTagged;
  Function sendUntagged = s.sendUntagged;
  Function send = s.send;
  Function requireSelected = s.requireSelected;
  Function getStringValue = s.getStringValue;

  Map<String, dynamic>? parseCommandModifiers(ImapToken? listTok) {
    if (listTok == null || listTok is! ListToken) return null;

    var VALUED = {'CHANGEDSINCE': true, 'UNCHANGEDSINCE': true};
    Map<String, dynamic> out = {};
    List<ImapToken> items = listTok.value;

    for (int i = 0; i < items.length; i++) {
      var tok = items[i];
      if (tok is! AtomToken) continue;
      String name = tok.value.toUpperCase();
      if (VALUED[name] == true) {
        var val = (i + 1 < items.length) ? items[i + 1] : null;
        if (val is NumberToken) {
          out[name] = val.value;
          i++;
        } else if (val is AtomToken) {
          int? n = int.tryParse(val.value);
          out[name] = n ?? val.value;
          i++;
        } else {
          out[name] = null;
        }
      } else {
        out[name] = true;
      }
    }
    return out;
  }

  void collectStream(
    Stream<List<int>> stream,
    int expectedLength,
    Function cb,
  ) {
    List<List<int>> chunks = [];
    bool done = false;
    stream.listen(
      (chunk) {
        chunks.add(chunk);
      },
      onDone: () {
        if (done) return;
        done = true;
        cb(null, concatU8(chunks.map((e) => toU8(e)).toList()));
      },
      onError: (err) {
        if (done) return;
        done = true;
        cb(err, null);
      },
    );
  }

  Map<String, dynamic> createBodyResponder(
    bool canStream,
    Function onBuffer,
    Function onStream,
    Function onError,
  ) {
    bool called = false;
    return {
      'send': (dynamic data) {
        if (called) return;
        called = true;

        if (data is Uint8List) {
          onBuffer(data);
          return;
        }
        if (data is List<int>) {
          onBuffer(Uint8List.fromList(data));
          return;
        }
        if (data is String) {
          onBuffer(toU8(data));
          return;
        }
        if (data is Map &&
            data['length'] is int &&
            data['stream'] is Stream<List<int>>) {
          if (canStream) {
            onStream(data['length'], data['stream']);
          } else {
            collectStream(data['stream'], data['length'], (err, buf) {
              if (err != null) {
                onError(err);
              } else {
                onBuffer(buf);
              }
            });
          }
          return;
        }
        onBuffer(Uint8List(0));
      },
      'error': (String? msg) {
        if (called) return;
        called = true;
        onError(Exception(msg ?? 'body unavailable'));
      },
    };
  }

  Uint8List serializeBuiltToken(dynamic tok) {
    return toU8(serializeValue(tok));
  }

  Uint8List extractBodySectionBytes(
    dynamic tree,
    Uint8List? raw,
    Map<String, dynamic> item,
  ) {
    if (raw == null) return Uint8List(0);
    var sec = parseBodySection(item['section'] ?? '');
    if (sec == null || sec['type'] == 'error') return Uint8List(0);

    if (tree == null &&
        sec['type'] == null &&
        (sec['part'] == null || sec['part'].isEmpty)) {
      Uint8List bytes = raw;
      if (item['partial'] != null) {
        int off = item['partial']['offset'];
        int? len = item['partial']['length'];
        if (off >= bytes.length) return Uint8List(0);
        int endPos = len != null ? min(off + len, bytes.length) : bytes.length;
        bytes = bytes.sublist(off, endPos);
      }
      return bytes;
    }

    if (tree == null) return Uint8List(0);

    var node = tree;
    if (sec['part'] != null && sec['part'].isNotEmpty) {
      for (int i = 0; i < sec['part'].length; i++) {
        int idx = sec['part'][i] - 1;
        if (node['parts'] == null || idx < 0 || idx >= node['parts'].length) {
          return Uint8List(0);
        }
        node = node['parts'][idx];
      }
    }

    Uint8List bytes;
    if (sec['type'] == null) {
      bytes = raw.sublist(node['start'] ?? 0, node['end'] ?? raw.length);
    } else if (sec['type'] == 'HEADER') {
      bytes = raw.sublist(node['headerStart'] ?? 0, node['headerEnd'] ?? 0);
    } else if (sec['type'] == 'TEXT') {
      bytes = raw.sublist(
        node['bodyStart'] ?? 0,
        node['bodyEnd'] ?? raw.length,
      );
    } else if (sec['type'] == 'MIME') {
      bytes = raw.sublist(node['headerStart'] ?? 0, node['headerEnd'] ?? 0);
    } else if (sec['type'] == 'HEADER.FIELDS' ||
        sec['type'] == 'HEADER.FIELDS.NOT') {
      List<String> wanted =
          (sec['fields'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [];
      bool isNot = sec['type'] == 'HEADER.FIELDS.NOT';
      BytesBuilder builder = BytesBuilder(copy: false);
      if (node['headers'] != null) {
        for (var h in node['headers']) {
          bool isMatch = wanted.contains((h['name'] as String).toUpperCase());
          if (isMatch != isNot) {
            builder.add(raw.sublist(h['rawStart'], h['rawEnd']));
          }
        }
      }
      builder.add(toU8('\r\n'));
      bytes = builder.toBytes();
    } else {
      bytes = Uint8List(0);
    }

    if (item['partial'] != null) {
      int off = item['partial']['offset'];
      int? len = item['partial']['length'];
      if (off >= bytes.length) {
        bytes = Uint8List(0);
      } else {
        int endPos = len != null ? min(off + len, bytes.length) : bytes.length;
        bytes = bytes.sublist(off, endPos);
      }
    }
    return bytes;
  }

  void emitFetchResponse(
    int seq,
    int? uid,
    Map<String, dynamic>? meta,
    Uint8List? raw,
    dynamic tree,
    List<Map<String, dynamic>> items,
    bool alwaysUid,
    dynamic cachedEnv,
    dynamic cachedBs,
  ) {
    String head = '* $seq FETCH (';
    List<Uint8List>? binaryParts;
    bool first = true;

    void addText(String name, String text) {
      head += '${first ? '' : ' '}$name $text';
      first = false;
    }

    void addBinary(String name, Uint8List contentBytes) {
      if (binaryParts == null) binaryParts = [];
      binaryParts!.add(
        toU8('$head${first ? '' : ' '}$name {${contentBytes.length}}\r\n'),
      );
      binaryParts!.add(contentBytes);
      head = '';
      first = false;
    }

    void addItem(String name, dynamic formatted) {
      if (formatted is Uint8List) {
        addBinary(name, formatted);
      } else {
        addText(name, formatted.toString());
      }
    }

    var order = List<Map<String, dynamic>>.from(items);
    if (alwaysUid) {
      bool hasUid = false;
      for (var it in items) {
        if (it['name'] == 'UID') hasUid = true;
      }
      if (!hasUid) order.insert(0, {'name': 'UID'});
    }

    for (var item in order) {
      switch (item['name']) {
        case 'UID':
          addText('UID', uid.toString());
          break;
        case 'FLAGS':
          addText(
            'FLAGS',
            serializeFlagList(meta != null ? (meta['flags'] ?? []) : []),
          );
          break;
        case 'INTERNALDATE':
          addText(
            'INTERNALDATE',
            '"${formatInternalDate(meta != null ? (meta['internalDate'] ?? DateTime.now()) : DateTime.now())}"',
          );
          break;
        case 'RFC822.SIZE':
          addText(
            'RFC822.SIZE',
            (meta != null && meta['size'] != null
                    ? meta['size']
                    : (raw != null ? raw.length : 0))
                .toString(),
          );
          break;
        case 'RFC822':
          addItem(
            'RFC822',
            extractBodySectionBytes(tree, raw, {
              'section': '',
              'partial': null,
            }),
          );
          break;
        case 'RFC822.HEADER':
          addItem(
            'RFC822.HEADER',
            extractBodySectionBytes(tree, raw, {
              'section': 'HEADER',
              'partial': null,
            }),
          );
          break;
        case 'RFC822.TEXT':
          addItem(
            'RFC822.TEXT',
            extractBodySectionBytes(tree, raw, {
              'section': 'TEXT',
              'partial': null,
            }),
          );
          break;
        case 'BODY':
          if (item.containsKey('responseName')) {
            addItem(
              item['responseName'],
              extractBodySectionBytes(tree, raw, item),
            );
          } else {
            addItem('BODY', 'NIL');
          }
          break;
        case 'ENVELOPE':
          if (cachedEnv != null) {
            addText(
              'ENVELOPE',
              u8ToStr(serializeBuiltToken(buildEnvelopeFromJson(cachedEnv))),
            );
          } else if (tree != null) {
            addText(
              'ENVELOPE',
              u8ToStr(serializeBuiltToken(buildEnvelope(tree))),
            );
          } else {
            addText('ENVELOPE', 'NIL');
          }
          break;
        case 'BODYSTRUCTURE':
          if (cachedBs != null) {
            addText(
              'BODYSTRUCTURE',
              u8ToStr(
                serializeBuiltToken(buildBodyStructureFromJson(cachedBs, true)),
              ),
            );
          } else if (tree != null) {
            addText(
              'BODYSTRUCTURE',
              u8ToStr(serializeBuiltToken(buildBodyStructure(tree, true))),
            );
          } else {
            addText('BODYSTRUCTURE', 'NIL');
          }
          break;
        case 'BODY_STRUCT':
          if (cachedBs != null) {
            addText(
              'BODY',
              u8ToStr(
                serializeBuiltToken(
                  buildBodyStructureFromJson(cachedBs, false),
                ),
              ),
            );
          } else if (tree != null) {
            addText(
              'BODY',
              u8ToStr(serializeBuiltToken(buildBodyStructure(tree, false))),
            );
          } else {
            addText('BODY', 'NIL');
          }
          break;
        case 'MODSEQ':
          addText(
            'MODSEQ',
            '(${meta != null && meta['modseq'] != null ? meta['modseq'] : 0})',
          );
          break;
        default:
          addText(item['name'], 'NIL');
      }
    }

    if (binaryParts == null) {
      send(toU8('$head)\r\n'));
    } else {
      binaryParts!.add(toU8('$head)\r\n'));
      for (var bp in binaryParts!) {
        send(bp);
      }
    }
  }

  void emitFetchResponseStreaming(
    int seq,
    int? uid,
    Map<String, dynamic>? meta,
    int bodyLength,
    Stream<List<int>> bodyStream,
    List<Map<String, dynamic>> items,
    bool alwaysUid,
    Function onDone,
  ) {
    var order = List<Map<String, dynamic>>.from(items);
    if (alwaysUid) {
      bool hasUid = false;
      for (var it in items) {
        if (it['name'] == 'UID') hasUid = true;
      }
      if (!hasUid) order.insert(0, {'name': 'UID'});
    }

    Map<String, dynamic>? bodyItem;
    List<Map<String, dynamic>> textItems = [];
    for (var it in order) {
      if (it['name'] == 'BODY' || it['name'] == 'RFC822') {
        bodyItem = it;
      } else {
        textItems.add(it);
      }
    }

    String head = '* $seq FETCH (';
    bool first = true;
    for (var item in textItems) {
      String? text;
      switch (item['name']) {
        case 'UID':
          text = uid.toString();
          break;
        case 'FLAGS':
          text = serializeFlagList(meta != null ? (meta['flags'] ?? []) : []);
          break;
        case 'INTERNALDATE':
          text =
              '"${formatInternalDate(meta != null ? (meta['internalDate'] ?? DateTime.now()) : DateTime.now())}"';
          break;
        case 'RFC822.SIZE':
          text =
              (meta != null && meta['size'] != null ? meta['size'] : bodyLength)
                  .toString();
          break;
        case 'MODSEQ':
          text =
              '(${(meta != null && meta['modseq'] != null ? meta['modseq'] : 0)})';
          break;
        default:
          continue;
      }
      head += '${(first ? '' : ' ') + item['name']} ${text}';
      first = false;
    }

    String bodyName = bodyItem?['name'] == 'RFC822'
        ? 'RFC822'
        : (bodyItem?['responseName'] ?? 'BODY[]');
    head += '${first ? '' : ' '}$bodyName {$bodyLength}\r\n';
    send(toU8(head));

    int bytesSent = 0;
    bool finished = false;
    void finish() {
      if (finished) return;
      finished = true;
      if (bytesSent < bodyLength) {
        send(Uint8List(bodyLength - bytesSent));
      }
      send(toU8(')\r\n'));
      onDone();
    }

    bodyStream.listen(
      (chunk) {
        if (finished) return;
        Uint8List u8 = toU8(chunk);
        if (bytesSent + u8.length > bodyLength) {
          u8 = u8.sublist(0, bodyLength - bytesSent);
        }
        bytesSent += u8.length;
        send(u8);
      },
      onDone: finish,
      onError: (err) {
        finish();
      },
    );
  }

  Map<int, dynamic> indexByUidField(List<dynamic> arr, String field) {
    Map<int, dynamic> map = {};
    for (var r in arr) {
      if (r != null && r['uid'] is int && r[field] != null) {
        map[r['uid'] as int] = r[field];
      }
    }
    return map;
  }

  Map<int, dynamic> indexByUid(List<dynamic> arr) {
    Map<int, dynamic> map = {};
    for (var r in arr) {
      if (r != null && r['uid'] is int) {
        map[r['uid'] as int] = r;
      }
    }
    return map;
  }

  List<Map<String, dynamic>> parseFetchItems(ImapToken arg) {
    List<Map<String, dynamic>> items = [];

    void add(ImapToken tok) {
      if (tok.value == null && tok is! BracketedToken) return;
      String n = tok.value?.toString().toUpperCase() ?? '';

      if (tok is AtomToken && tok.section != null) {
        String base = tok.value.toUpperCase();
        if (base == 'BODY' || base == 'BODY.PEEK') {
          items.add({
            'name': 'BODY',
            'peek': base == 'BODY.PEEK',
            'section': tok.section ?? '',
            'partial': tok.partial,
            'responseName': buildBodyResponseName(
              tok.section ?? '',
              tok.partial,
            ),
          });
          return;
        }
      }

      if (n == 'BODY') {
        items.add({'name': 'BODY_STRUCT'});
        return;
      }

      if (n == 'FAST') {
        items.addAll([
          {'name': 'FLAGS'},
          {'name': 'INTERNALDATE'},
          {'name': 'RFC822.SIZE'},
        ]);
        return;
      }
      if (n == 'ALL') {
        items.addAll([
          {'name': 'FLAGS'},
          {'name': 'INTERNALDATE'},
          {'name': 'RFC822.SIZE'},
          {'name': 'ENVELOPE'},
        ]);
        return;
      }
      if (n == 'FULL') {
        items.addAll([
          {'name': 'FLAGS'},
          {'name': 'INTERNALDATE'},
          {'name': 'RFC822.SIZE'},
          {'name': 'ENVELOPE'},
          {'name': 'BODY_STRUCT'},
        ]);
        return;
      }
      items.add({'name': n});
    }

    if (arg is ListToken) {
      for (int i = 0; i < arg.value.length; i++) {
        add(arg.value[i]);
      }
    } else {
      add(arg);
    }
    return items;
  }

  void fetchEachMessage(
    String tag,
    List<dynamic> messages,
    List<Map<String, dynamic>> items,
    Map<dynamic, dynamic>? metas,
    Map<dynamic, dynamic>? envelopes,
    Map<dynamic, dynamic>? bodyStrs,
    bool needsBody,
    bool needsTree,
    bool alwaysUid,
    bool byUid,
  ) {
    int idx = 0;
    bool canStream = false;

    if (!needsTree) {
      int bodyItemCount = 0;
      for (var it in items) {
        if (it['name'] == 'BODY' || it['name'] == 'RFC822') bodyItemCount++;
      }
      canStream = bodyItemCount == 1;
    }

    void processBatch() {
      int count = 0;
      int SYNC_BATCH = 100;
      while (idx < messages.length && count < SYNC_BATCH) {
        var msg = messages[idx];
        var meta = metas != null ? metas[msg['uid']] : null;
        var cachedEnv = envelopes != null ? envelopes[msg['uid']] : null;
        var cachedBs = bodyStrs != null ? bodyStrs[msg['uid']] : null;

        if (!needsBody) {
          idx++;
          count++;
          emitFetchResponse(
            msg['seq'],
            msg['uid'],
            meta,
            null,
            null,
            items,
            alwaysUid,
            cachedEnv,
            cachedBs,
          );
          continue;
        }

        idx++;
        var capturedMsg = msg;
        var capturedMeta = meta;
        var capturedEnv = cachedEnv;
        var capturedBs = cachedBs;

        var responder = createBodyResponder(
          canStream,
          (Uint8List buf) {
            var tree = needsTree ? parseMessageTree(buf) : null;
            emitFetchResponse(
              capturedMsg['seq'],
              capturedMsg['uid'],
              capturedMeta,
              buf,
              tree,
              items,
              alwaysUid,
              capturedEnv,
              capturedBs,
            );
            scheduleMicrotask(processBatch);
          },
          (int length, Stream<List<int>> stream) {
            emitFetchResponseStreaming(
              capturedMsg['seq'],
              capturedMsg['uid'],
              capturedMeta,
              length,
              stream,
              items,
              alwaysUid,
              () {
                scheduleMicrotask(processBatch);
              },
            );
          },
          (dynamic err) {
            scheduleMicrotask(processBatch);
          },
        );

        ev.emit(
          'messageBody',
          context.currentFolder,
          capturedMsg['uid'],
          responder,
        );
        return;
      }

      if (idx >= messages.length) {
        sendTagged(tag, STATUS_OK, '${byUid ? 'UID ' : ''}FETCH completed');
        return;
      }
      scheduleMicrotask(processBatch);
    }

    processBatch();
  }

  void fetchMessages(
    String tag,
    List<dynamic> messages,
    List<Map<String, dynamic>> items,
    bool byUid,
  ) {
    int listenerCount(String eventName) {
      return ev.listenerCount(eventName);
    }

    bool hasEnvelopeListener = listenerCount('messageEnvelope') > 0;
    bool hasBsListener = listenerCount('messageBodyStructure') > 0;

    bool needsEnv = false;
    bool needsBs = false;
    bool needsBody = false;
    bool needsTree = false;

    for (int i = 0; i < items.length; i++) {
      String n = items[i]['name'];
      if (n == 'RFC822' || n == 'BODY') {
        needsBody = true;
        if (n == 'BODY' &&
            items[i]['section'] != null &&
            items[i]['section'] != '')
          needsTree = true;
      }
      if (n == 'RFC822.HEADER' || n == 'RFC822.TEXT') {
        needsBody = true;
        needsTree = true;
      }
      if (n == 'ENVELOPE') {
        needsEnv = true;
        if (!hasEnvelopeListener) {
          needsBody = true;
          needsTree = true;
        }
      }
      if (n == 'BODYSTRUCTURE' || n == 'BODY_STRUCT') {
        needsBs = true;
        if (!hasBsListener) {
          needsBody = true;
          needsTree = true;
        }
      }
    }

    bool needsMeta = false;
    for (int i = 0; i < items.length; i++) {
      String n = items[i]['name'];
      if (n == 'FLAGS' ||
          n == 'INTERNALDATE' ||
          n == 'RFC822.SIZE' ||
          n == 'MODSEQ') {
        needsMeta = true;
        break;
      }
    }

    bool alwaysUid = byUid;
    for (var it in items) {
      if (it['name'] == 'UID') alwaysUid = true;
    }

    List<dynamic> uids = messages.map((m) => m['uid']).toList();

    var metas;
    var envelopes;
    var bodyStrs;

    int pending = 0;
    if (needsMeta) pending++;
    if (needsEnv && hasEnvelopeListener) pending++;
    if (needsBs && hasBsListener) pending++;

    void allGathered() {
      fetchEachMessage(
        tag,
        messages,
        items,
        metas,
        envelopes,
        bodyStrs,
        needsBody,
        needsTree,
        alwaysUid,
        byUid,
      );
    }

    if (pending == 0) {
      allGathered();
      return;
    }

    void one(dynamic err) {
      if (err != null) {
        if (pending >= 0)
          sendTagged(tag, STATUS_NO, err.message ?? 'Cannot fetch');
        pending = -1;
        return;
      }
      if (pending < 0) return;
      pending--;
      if (pending == 0) allGathered();
    }

    if (needsMeta) {
      ev.emit('messageMeta', context.currentFolder, uids, (
        dynamic err,
        dynamic results,
      ) {
        if (err == null) {
          metas = indexByUid(results ?? []);
          for (var r in (results ?? [])) {
            if (r != null && r['flags'] != null)
              checkFlagsHygiene(r['flags'], 'messageMeta');
          }
        }
        one(err);
      });
    }
    if (needsEnv && hasEnvelopeListener) {
      ev.emit('messageEnvelope', context.currentFolder, uids, (
        dynamic err,
        dynamic results,
      ) {
        if (err == null) envelopes = indexByUidField(results ?? [], 'envelope');
        one(err);
      });
    }
    if (needsBs && hasBsListener) {
      ev.emit('messageBodyStructure', context.currentFolder, uids, (
        dynamic err,
        dynamic results,
      ) {
        if (err == null)
          bodyStrs = indexByUidField(results ?? [], 'bodyStructure');
        one(err);
      });
    }
  }

  void handleFetch(String tag, List<ImapToken> args, bool byUid) {
    if (!requireSelected(tag)) return;
    if (args.length < 2) {
      sendTagged(tag, STATUS_BAD, 'FETCH requires sequence set and items');
      return;
    }

    String setStr = getStringValue(args[0]);
    var parsed = parseSequenceSet(setStr, {
      'isUid': byUid,
      'total': context.currentFolderTotal,
    });
    if (parsed['error'] != null) {
      sendTagged(tag, STATUS_BAD, 'Invalid sequence set: ${parsed['error']}');
      return;
    }

    List<Map<String, dynamic>> items = parseFetchItems(args[1]);
    if (items.isEmpty) {
      sendTagged(tag, STATUS_BAD, 'Invalid FETCH items');
      return;
    }

    dynamic changedSince = null;
    bool wantVanished = false;

    if (args.length >= 3 && args[2] is ListToken) {
      var mods = parseCommandModifiers(args[2]);
      if (mods != null && mods['CHANGEDSINCE'] != null) {
        changedSince = mods['CHANGEDSINCE'];
        context.condstoreEnabled = true;
        bool hasModseq = false;
        for (int i = 0; i < items.length; i++) {
          if (items[i]['name'] == 'MODSEQ') hasModseq = true;
        }
        if (!hasModseq) items.add({'name': 'MODSEQ'});
      }
      if (mods != null && mods['VANISHED'] == true) {
        if (context.qresyncEnabled == true && changedSince != null) {
          wantVanished = true;
        } else {
          sendTagged(
            tag,
            'BAD',
            'VANISHED modifier requires QRESYNC enabled and CHANGEDSINCE',
          );
          return;
        }
      }
    }

    void doResolveAndFetch() {
      Map<String, dynamic> query = {
        'type': byUid ? 'uid' : 'seq',
        'ranges': parsed['ranges'],
      };
      if (changedSince != null) query['changedSince'] = changedSince;

      ev.emit('resolveMessages', context.currentFolder, query, (
        dynamic err,
        dynamic messages,
      ) {
        if (err != null) {
          sendTagged(tag, STATUS_NO, err.message ?? 'Cannot resolve messages');
          return;
        }
        List<dynamic> msgs = messages ?? [];
        if (msgs.isEmpty) {
          sendTagged(tag, STATUS_OK, '${byUid ? 'UID ' : ''}FETCH completed');
          return;
        }
        fetchMessages(tag, msgs, items, byUid);
      });
    }

    int listenerCount(String eventName) {
      return ev.listenerCount(eventName);
    }

    if (wantVanished && listenerCount('resolveVanished') > 0) {
      ev.emit(
        'resolveVanished',
        context.currentFolder,
        {
          'changedSince': changedSince,
          'type': byUid ? 'uid' : 'seq',
          'ranges': parsed['ranges'],
        },
        (dynamic verr, dynamic vanished) {
          if (verr == null && vanished != null) {
            String? str;
            if (vanished is Map &&
                vanished['ranges'] != null &&
                vanished['ranges'].length > 0) {
              str = formatRanges(vanished['ranges'].cast<int>());
            } else if (vanished is List && vanished.isNotEmpty) {
              str = compressUids(vanished);
            } else if (vanished is Map &&
                vanished['uids'] != null &&
                vanished['uids'].length > 0) {
              str = compressUids(vanished['uids']);
            }
            if (str != null) sendUntagged('VANISHED (EARLIER) $str');
          }
          doResolveAndFetch();
        },
      );
      return;
    }
    doResolveAndFetch();
  }

  void storeBatch(
    String tag,
    List<dynamic> messages,
    List<dynamic> flags,
    String mode,
    bool silent,
    bool byUid,
    dynamic unchangedSince,
  ) {
    List<dynamic> uids = messages.map((m) => m['uid']).toList();
    Map<String, dynamic> query = {
      'uids': uids,
      'flags': flags,
      'mode': mode,
      'condstoreEnabled': context.condstoreEnabled,
    };
    if (unchangedSince != null) query['unchangedSince'] = unchangedSince;

    ev.emit('setFlags', context.currentFolder, query, (
      dynamic err,
      dynamic results,
    ) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'STORE failed');
        return;
      }
      List<dynamic> res = results ?? [];
      Map<dynamic, dynamic> byUidMap = {};
      for (var r in res) {
        if (r != null && r['uid'] != null) byUidMap[r['uid']] = r;
        if (r != null && r['flags'] != null)
          checkFlagsHygiene(r['flags'], 'setFlags');
      }

      List<dynamic> skippedUids = [];
      for (var msg in messages) {
        var r = byUidMap[msg['uid']];
        if (r == null) continue;
        if (r['skipped'] == true) {
          skippedUids.add(msg['uid']);
          continue;
        }

        bool shouldEmit = !silent || byUid || context.condstoreEnabled == true;
        if (!shouldEmit) continue;

        List<Map<String, dynamic>> items = [];
        if (byUid) items.add({'name': 'UID'});
        items.add({'name': 'FLAGS'});
        if (context.condstoreEnabled == true) items.add({'name': 'MODSEQ'});

        Map<String, dynamic> meta = {'flags': r['flags'] ?? flags};
        if (r['modseq'] != null) meta['modseq'] = r['modseq'];

        emitFetchResponse(
          msg['seq'],
          msg['uid'],
          meta,
          null,
          null,
          items,
          byUid,
          null,
          null,
        );
      }

      String? code;
      if (skippedUids.isNotEmpty) {
        code = 'MODIFIED ${compressUids(skippedUids)}';
      }
      sendTagged(tag, STATUS_OK, '${byUid ? 'UID ' : ''}STORE completed', code);
    });
  }

  void handleStore(String tag, List<ImapToken> args, bool byUid) {
    if (!requireSelected(tag)) return;
    if (args.length < 3) {
      sendTagged(
        tag,
        'BAD',
        'STORE requires sequence set, operation, and flags',
      );
      return;
    }

    String setStr = getStringValue(args[0]);
    dynamic unchangedSince;
    int opIdx = 1;
    if (args[opIdx] is ListToken) {
      var mods = parseCommandModifiers(args[opIdx]);
      if (mods != null && mods['UNCHANGEDSINCE'] != null) {
        unchangedSince = mods['UNCHANGEDSINCE'];
        context.condstoreEnabled = true;
      }
      opIdx = 2;
    }

    if (args.length < opIdx + 2) {
      sendTagged(tag, STATUS_BAD, 'STORE requires operation and flags');
      return;
    }

    String opStr = (args[opIdx].value?.toString() ?? '').toUpperCase();
    String mode = 'set';
    bool silent = false;

    if (opStr.startsWith('+')) {
      mode = 'add';
      opStr = opStr.substring(1);
    } else if (opStr.startsWith('-')) {
      mode = 'remove';
      opStr = opStr.substring(1);
    }

    if (opStr == 'FLAGS.SILENT') {
      silent = true;
      opStr = 'FLAGS';
    }
    if (opStr != 'FLAGS') {
      sendTagged(tag, STATUS_BAD, 'Unsupported STORE operation: $opStr');
      return;
    }

    var flagArg = args[opIdx + 1];
    List<String?> flags = [];
    if (flagArg is ListToken) {
      for (var v in flagArg.value) {
        flags.add(normalizeFlag(v.value?.toString()));
      }
    } else {
      flags.add(normalizeFlag(flagArg.value?.toString()));
    }

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
      (dynamic err, dynamic messages) {
        if (err != null) {
          sendTagged(tag, STATUS_NO, err.message ?? 'Cannot resolve messages');
          return;
        }
        storeBatch(
          tag,
          messages ?? [],
          flags,
          mode,
          silent,
          byUid,
          unchangedSince,
        );
      },
    );
  }

  void handleCopy(String tag, List<dynamic> args, bool byUid) {
    if (!requireSelected(tag)) return;
    if (args.length < 2) {
      sendTagged(tag, STATUS_BAD, 'COPY requires sequence set and destination');
      return;
    }
    String setStr = getStringValue(args[0]) ?? '';
    String dst = getStringValue(args[1]) ?? '';

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
      (dynamic err, dynamic messages) {
        if (err != null) {
          sendTagged(tag, STATUS_NO, err.message ?? 'Cannot resolve messages');
          return;
        }
        List<dynamic> msgs = messages ?? [];
        if (msgs.isEmpty) {
          sendTagged(tag, STATUS_OK, '${byUid ? 'UID ' : ''}COPY completed');
          return;
        }
        List<dynamic> uids = msgs.map((m) => m['uid']).toList();
        ev.emit('copyMessages', context.currentFolder, uids, dst, (
          dynamic cerr,
          dynamic mapping,
        ) {
          if (cerr != null) {
            sendTagged(tag, STATUS_NO, cerr.message ?? 'Cannot copy messages');
            return;
          }
          String? code = buildCopyUidCode(mapping);
          sendTagged(
            tag,
            STATUS_OK,
            '${byUid ? 'UID ' : ''}COPY completed',
            code,
          );
        });
      },
    );
  }

  s.handleFetch = handleFetch;
  s.handleStore = handleStore;
  s.handleCopy = handleCopy;
  s.emitFetchResponse = emitFetchResponse;
}
