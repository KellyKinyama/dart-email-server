import 'imap_wire.dart';
import 'imap_helpers.dart';
import 'imap_session.dart';

// ============================================================================
//  imap_search.dart
// ----------------------------------------------------------------------------
//  Server-side handlers for query commands: SEARCH, SORT, THREAD (+ UID
//  variants). These three share the same overall shape — accept a criteria
//  expression, delegate the actual matching to the developer via an event,
//  then format the results — so it's natural to group them in one module.
//
//  Commands covered:
//    SEARCH (RFC 3501 §6.4.4)
//    SORT   (RFC 5256 §3)
//    THREAD (RFC 5256 §4)  — ORDEREDSUBJECT / REFERENCES algorithms
//
//  The CONDSTORE MODSEQ search-result option (RFC 7162 §3.1.5) is implemented
//  here via `criteriaContainsModseq` + conditional MODSEQ response appending.
//
//  Dependencies injected via the `s` session interface passed to
//  `registerSearchHandlers(s)`. The function attaches three handlers:
//
//     s.handleSearch(tag, args, byUid)
//     s.handleSort  (tag, args, byUid)
//     s.handleThread(tag, args, byUid)
//
//  which the session dispatcher then calls. `s` provides:
//
//     s.context         — session state (currentFolder, condstoreEnabled, total)
//     s.ev              — EventEmitter (for search/sort/thread events)
//     s.sendTagged      — send tagged OK/NO/BAD reply
//     s.sendUntagged    — send untagged response
//     s.requireSelected — guard: verify SELECTED state
// ============================================================================

void registerSearchHandlers(IMAPSession s) {
  var context = s.context;
  var ev = s.ev;
  var sendTagged = s.sendTagged;
  var sendUntagged = s.sendUntagged;
  var requireSelected = s.requireSelected;

  // --- HELPERS ---

  String serializeThreadNode(dynamic node, bool byUid) {
    var id = byUid ? node['uid'] : node['seq'];
    String out = id.toString();
    List<dynamic> children = node['children'] ?? [];

    if (children.isEmpty) return out;

    if (children.length == 1) {
      // Linear reply: no extra parens around the child
      return '$out ${serializeThreadNode(children[0], byUid)}';
    }

    // Multiple children — each becomes its own branch "(child...)"
    List<String> branches = [];
    for (int i = 0; i < children.length; i++) {
      branches.add('(${serializeThreadNode(children[i], byUid)})');
    }
    return '$out ${branches.join('')}';
  }

  // Serialize a forest of thread nodes into the RFC 5256 §4 paren form.
  //   →  "(3 6 (4 23)(44 7 96))"
  String serializeThreadForest(List<dynamic> forest, bool byUid) {
    List<String> parts = [];
    for (int i = 0; i < forest.length; i++) {
      parts.add('(${serializeThreadNode(forest[i], byUid)})');
    }
    return parts.join('');
  }

  // --- SEARCH / UID SEARCH ---
  void handleSearch(String tag, List<dynamic> args, bool byUid) {
    if (!requireSelected(tag)) return;

    // Optional CHARSET argument per RFC 3501 §6.4.4:
    //   SEARCH [CHARSET <charset>] <criteria...>
    // We accept and ignore it — the developer's matcher is charset-agnostic.
    int start = 0;
    if (args.length >= 2 &&
        (args[0]['value']?.toString() ?? '').toUpperCase() == 'CHARSET') {
      start = 2;
    }
    if (start >= args.length) {
      sendTagged(tag, STATUS_BAD, 'SEARCH requires criteria');
      return;
    }

    var parsed = parseSearchCriteria(args, start, context.currentFolderTotal);
    var criteria = parsed['node'];

    // Criteria must have at least one child — otherwise the client sent nothing meaningful
    if (criteria == null ||
        criteria['children'] == null ||
        (criteria['children'] as List).isEmpty) {
      sendTagged(tag, STATUS_BAD, 'SEARCH requires criteria');
      return;
    }

    // Walk a criteria tree looking for any MODSEQ predicate.
    bool criteriaContainsModseq(dynamic node) {
      if (node == null) return false;
      if (node['op'] == 'modseq') return true;
      if (node['children'] != null) {
        List<dynamic> children = node['children'];
        for (int i = 0; i < children.length; i++) {
          if (criteriaContainsModseq(children[i])) return true;
        }
      }
      if (node['child'] != null && criteriaContainsModseq(node['child']))
        return true;
      return false;
    }

    // RFC 7162 §3.1.5: if the criteria includes MODSEQ, the server MUST include
    // the MODSEQ search-result option. Also implicitly enables CONDSTORE.
    bool hasModseqCriterion = criteriaContainsModseq(criteria);
    if (hasModseqCriterion) context.condstoreEnabled = true;

    ev.emit('search', context.currentFolder, criteria, (err, results) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'SEARCH failed');
        return;
      }
      List<dynamic> res = results ?? [];

      // Extract seq or uid numbers AND track highest modseq
      List<int> nums = [];
      int highestModseq = 0;
      for (int i = 0; i < res.length; i++) {
        var r = res[i];
        if (r == null) continue;
        var n = byUid ? r['uid'] : r['seq'];
        if (n is int) nums.add(n);
        if (r['modseq'] is int && r['modseq'] as int > highestModseq) {
          highestModseq = r['modseq'];
        }
      }

      String respLine = 'SEARCH${nums.isNotEmpty ? ' ${nums.join(' ')}' : ''}';
      // Append (MODSEQ N) search-result option when required or when developer supplied it
      if ((hasModseqCriterion || context.condstoreEnabled == true) &&
          highestModseq > 0) {
        respLine += ' (MODSEQ $highestModseq)';
      }

      sendUntagged(respLine);
      sendTagged(tag, STATUS_OK, '${byUid ? 'UID ' : ''}SEARCH completed');
    });
  }

  // ============================================================
  //  SORT / THREAD (RFC 5256)
  // ============================================================

  // Parse the parenthesized sort criteria list into a JS array.
  // Wire:    (REVERSE DATE SUBJECT)
  // Tree:    [{key: 'date', reverse: true}, {key: 'subject', reverse: false}]
  //
  // Returns null on parse error so the caller can send BAD.
  List<Map<String, dynamic>>? parseSortCriteria(dynamic listTok) {
    if (listTok == null || listTok['type'] != TOK_LIST) return null;
    List<Map<String, dynamic>> out = [];
    bool reverseNext = false;
    List<dynamic> listValue = listTok['value'];
    for (int i = 0; i < listValue.length; i++) {
      var t = listValue[i];
      if (t == null || t['type'] != TOK_ATOM) return null;
      String name = (t['value']?.toString() ?? '').toUpperCase();
      if (name == 'REVERSE') {
        if (reverseNext) return null; // REVERSE REVERSE is illegal
        reverseNext = true;
        continue;
      }
      // Accept any atom that looks like a sort key — unknown keys passthrough
      // so extensions (DISPLAYFROM etc.) work without code changes.
      out.add({'key': name.toLowerCase(), 'reverse': reverseNext});
      reverseNext = false;
    }
    if (reverseNext) return null; // trailing REVERSE with no key
    if (out.isEmpty) return null;
    return out;
  }

  // --- SORT / UID SORT ---
  //   SORT (<criteria>) <charset> <search-criteria...>
  //
  // Emits 'sort' event; developer returns sorted [{uid, seq}] pairs.
  void handleSort(String tag, List<dynamic> args, bool byUid) {
    if (!requireSelected(tag)) return;
    if (args.length < 3) {
      sendTagged(
        tag,
        'BAD',
        'SORT requires criteria, charset, and search keys',
      );
      return;
    }

    // args[0] = sort criteria list
    var sortCriteria = parseSortCriteria(args[0]);
    if (sortCriteria == null) {
      sendTagged(tag, STATUS_BAD, 'Invalid SORT criteria');
      return;
    }

    // args[1] = charset (ignored — developer's matcher is charset-agnostic)

    // args[2+] = search criteria
    var parsed = parseSearchCriteria(args, 2, context.currentFolderTotal);
    if (parsed['node'] == null ||
        parsed['node']['children'] == null ||
        (parsed['node']['children'] as List).isEmpty) {
      sendTagged(tag, STATUS_BAD, 'SORT requires search criteria');
      return;
    }

    ev.emit('sort', context.currentFolder, sortCriteria, parsed['node'], (
      err,
      results,
    ) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'SORT failed');
        return;
      }
      List<dynamic> res = results ?? [];
      List<int> nums = [];
      for (int i = 0; i < res.length; i++) {
        var r = res[i];
        if (r == null) continue;
        var n = byUid ? r['uid'] : r['seq'];
        if (n is int) nums.add(n);
      }
      sendUntagged('SORT${nums.isNotEmpty ? ' ${nums.join(' ')}' : ''}');
      sendTagged(tag, STATUS_OK, '${byUid ? 'UID ' : ''}SORT completed');
    });
  }

  // --- THREAD / UID THREAD ---
  //   THREAD <algorithm> <charset> <search-criteria...>
  //
  // Developer returns a forest of thread nodes:
  //   [ { uid, seq, children?: [...] }, ... ]
  void handleThread(String tag, List<dynamic> args, bool byUid) {
    if (!requireSelected(tag)) return;
    if (args.length < 3) {
      sendTagged(
        tag,
        'BAD',
        'THREAD requires algorithm, charset, and search keys',
      );
      return;
    }

    String algo = (args[0]['value']?.toString() ?? '').toLowerCase();
    if (algo.isEmpty) {
      sendTagged(tag, STATUS_BAD, 'Invalid THREAD algorithm');
      return;
    }

    // args[1] = charset (ignored)
    var parsed = parseSearchCriteria(args, 2, context.currentFolderTotal);
    if (parsed['node'] == null ||
        parsed['node']['children'] == null ||
        (parsed['node']['children'] as List).isEmpty) {
      sendTagged(tag, STATUS_BAD, 'THREAD requires search criteria');
      return;
    }

    ev.emit('thread', context.currentFolder, algo, parsed['node'], (
      err,
      forest,
    ) {
      if (err != null) {
        sendTagged(tag, STATUS_NO, err.message ?? 'THREAD failed');
        return;
      }
      List<dynamic> threadForest = forest ?? [];
      sendUntagged(
        'THREAD${threadForest.isNotEmpty ? ' ${serializeThreadForest(threadForest, byUid)}' : ''}',
      );
      sendTagged(tag, STATUS_OK, '${byUid ? 'UID ' : ''}THREAD completed');
    });
  }

  s.handleSearch = handleSearch;
  s.handleSort = handleSort;
  s.handleThread = handleThread;
}
