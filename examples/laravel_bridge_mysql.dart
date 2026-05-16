// Persistent (MySQL-backed) variant of examples/laravel_bridge.dart.
//
// Stores the IMAP mailbox tree in MySQL via the `eloquent` package, so
// messages survive restarts. Same surface (SMTP 2525/2587, IMAP 2143,
// POP3 2110) and same webhook push to the Laravel client.
//
// Quick start:
//   1. Create the database and a native-auth user (the eloquent driver
//      doesn't support MySQL 8's caching_sha2_password without TLS):
//        mysql -uroot -e "CREATE DATABASE IF NOT EXISTS dart_email_server
//          CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
//          CREATE USER IF NOT EXISTS 'dart'@'127.0.0.1'
//            IDENTIFIED WITH mysql_native_password BY 'dart';
//          GRANT ALL ON dart_email_server.* TO 'dart'@'127.0.0.1';"
//   2. Override defaults via env if needed:
//        $env:DART_MAIL_DB_HOST="127.0.0.1"
//        $env:DART_MAIL_DB_PORT="3306"
//        $env:DART_MAIL_DB_NAME="dart_email_server"
//        $env:DART_MAIL_DB_USER="dart"
//        $env:DART_MAIL_DB_PASS="dart"
//   3. Run the bridge:
//        dart run examples/laravel_bridge_mysql.dart
//
// On the Laravel side, see laravel-client/README.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_email_server/dart_email_server.dart';
import 'package:eloquent/eloquent.dart';

const _laravelBaseUrl = 'http://127.0.0.1:8000';
const _webhookSecret = 'change-me';

const _user = 'demo@example.com';
const _pass = 'demo';

// ===========================================================================
// MySQL-backed model
// ===========================================================================

class StoredMessage {
  StoredMessage({
    required this.id,
    required this.uid,
    required this.raw,
    required this.internalDate,
    List<String>? flags,
    this.deleted = false,
  }) : flags = flags ?? <String>[];

  /// Database primary key. `0` until [PersistentMailbox.add] inserts it.
  int id;
  final int uid;
  final Uint8List raw;
  final DateTime internalDate;
  final List<String> flags;
  bool deleted;

  int get size => raw.length;
}

class PersistentMailbox {
  PersistentMailbox({
    required this.id,
    required this.name,
    required this.specialUse,
    required this.uidValidity,
    required int uidNext,
    required this.persistence,
    required this.userId,
  }) : _nextUid = uidNext;

  final int id;
  final String name;
  final String? specialUse;
  final int uidValidity;
  final int userId;
  final MysqlPersistence persistence;
  final List<StoredMessage> messages = <StoredMessage>[];
  int _nextUid;

  int get uidNext => _nextUid;

  /// Synchronous add: assigns a UID, appends in memory, and fires a
  /// fire-and-forget INSERT into MySQL.
  void add(Uint8List raw, {List<String> initialFlags = const []}) {
    final msg = StoredMessage(
      id: 0,
      uid: _nextUid++,
      raw: raw,
      internalDate: DateTime.now().toUtc(),
      flags: List<String>.from(initialFlags),
    );
    messages.add(msg);
    unawaited(persistence._insertMessage(this, msg));
  }

  List<StoredMessage> live() =>
      messages.where((m) => !m.deleted).toList(growable: false);

  void purgeDeleted() {
    final purged = messages.where((m) => m.deleted).toList();
    messages.removeWhere((m) => m.deleted);
    if (purged.isNotEmpty) {
      unawaited(persistence._deleteMessages(this, purged));
    }
  }
}

class Account {
  Account({required this.id, required this.username});

  final int id;
  final String username;
  final Map<String, PersistentMailbox> _folders = {};

  Iterable<PersistentMailbox> get folders => _folders.values;
  PersistentMailbox? folder(String name) => _folders[name.toLowerCase()];
  PersistentMailbox get inbox => _folders['inbox']!;

  void register(PersistentMailbox box) {
    _folders[box.name.toLowerCase()] = box;
  }
}

// ===========================================================================
// Persistence layer (eloquent)
// ===========================================================================

class MysqlPersistence {
  MysqlPersistence({
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
  });

  final String host;
  final String port;
  final String database;
  final String username;
  final String password;

  late final Manager _manager;
  late final dynamic _db; // Connection
  final Map<String, Account> _cache = {};
  bool _ready = false;

  static const List<({String name, String? specialUse})> _defaultFolders = [
    (name: 'INBOX', specialUse: null),
    (name: 'Sent', specialUse: '\\Sent'),
    (name: 'Drafts', specialUse: '\\Drafts'),
    (name: 'Trash', specialUse: '\\Trash'),
    (name: 'Junk', specialUse: '\\Junk'),
  ];

  Future<void> bootstrap() async {
    _manager = Manager();
    _manager.addConnection({
      'driver': 'mysql',
      'host': host,
      'port': port,
      'database': database,
      'username': username,
      'password': password,
      'prefix': '',
      // MySQL 8/9 default to `caching_sha2_password`, which the
      // mysql_dart driver only accepts over a TLS connection. Telling
      // eloquent to require SSL flips the connection into secure mode
      // and unblocks auth. Use 'disable' if you've explicitly created a
      // mysql_native_password user.
      'sslmode': Platform.environment['DART_MAIL_DB_SSL'] ?? 'require',
      // NB: do not pass 'charset' here — the eloquent driver forwards
      // it as the connection collation, and only real collation names
      // (e.g. utf8mb4_general_ci) are accepted. Leaving it null lets
      // the driver default to utf8mb4_general_ci.
    });
    _manager.setAsGlobal();
    _db = await _manager.connection();
    await _createSchema();
    _ready = true;
    print('[mysql] connected to $username@$host:$port/$database');
  }

  Future<void> _createSchema() async {
    await _db.execute('''
      CREATE TABLE IF NOT EXISTS mailbox_users (
        id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        username VARCHAR(255) NOT NULL UNIQUE,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ''');
    await _db.execute('''
      CREATE TABLE IF NOT EXISTS mailbox_folders (
        id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        user_id INT NOT NULL,
        name VARCHAR(255) NOT NULL,
        special_use VARCHAR(64) NULL,
        uid_validity BIGINT NOT NULL,
        uid_next INT NOT NULL DEFAULT 1,
        UNIQUE KEY uniq_user_folder (user_id, name),
        CONSTRAINT fk_folder_user FOREIGN KEY (user_id)
          REFERENCES mailbox_users(id) ON DELETE CASCADE
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ''');
    await _db.execute('''
      CREATE TABLE IF NOT EXISTS mailbox_messages (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        folder_id INT NOT NULL,
        uid INT NOT NULL,
        raw_b64 LONGTEXT NOT NULL,
        internal_date DATETIME NOT NULL,
        flags TEXT NOT NULL,
        deleted TINYINT(1) NOT NULL DEFAULT 0,
        size INT NOT NULL,
        UNIQUE KEY uniq_folder_uid (folder_id, uid),
        CONSTRAINT fk_msg_folder FOREIGN KEY (folder_id)
          REFERENCES mailbox_folders(id) ON DELETE CASCADE
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ''');
  }

  /// Synchronous accessor used by SMTP/IMAP handlers. The first call for a
  /// given user is served from cache; if the user has never been seen, an
  /// empty in-memory account is returned immediately and a load is scheduled.
  Account forUser(String user) {
    final key = user.toLowerCase();
    final hit = _cache[key];
    if (hit != null) return hit;
    // Synchronous bootstrap by blocking? Not possible. We return a stub
    // and kick off a background load that will be queryable on the next
    // request — for the demo user we always preload during start().
    final stub = Account(id: 0, username: user);
    _cache[key] = stub;
    unawaited(
      _loadOrCreateUser(user).then((real) {
        // Replace the stub with the loaded version. Subsequent calls get
        // the real one. Anything written into the stub between now and the
        // load completing would be lost — in practice we always preload
        // known users at startup so this stub path only triggers for
        // unknown logins, which IMAP rejects anyway.
        _cache[key] = real;
      }),
    );
    return stub;
  }

  /// Eager loader. Prefer this from `start()` for any user you want to
  /// be ready before SMTP traffic hits.
  Future<Account> loadOrCreateUser(String user) async {
    final key = user.toLowerCase();
    final acc = await _loadOrCreateUser(user);
    _cache[key] = acc;
    return acc;
  }

  Future<Account> _loadOrCreateUser(String user) async {
    assert(_ready, 'bootstrap() must be awaited first');
    // Insert-or-fetch user.
    await _db.statement(
      'INSERT IGNORE INTO mailbox_users (username) VALUES (?)',
      [user],
    );
    final rows = await _db.select(
      'SELECT id FROM mailbox_users WHERE username = ?',
      [user],
    );
    final userId = (rows.first['id'] as num).toInt();
    final account = Account(id: userId, username: user);

    // Ensure default folders exist.
    for (final spec in _defaultFolders) {
      final uidValidity = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _db.statement(
        'INSERT IGNORE INTO mailbox_folders '
        '(user_id, name, special_use, uid_validity, uid_next) '
        'VALUES (?, ?, ?, ?, 1)',
        [userId, spec.name, spec.specialUse, uidValidity],
      );
    }

    final folderRows = await _db.select(
      'SELECT id, name, special_use, uid_validity, uid_next '
      'FROM mailbox_folders WHERE user_id = ?',
      [userId],
    );
    for (final row in folderRows) {
      final box = PersistentMailbox(
        id: (row['id'] as num).toInt(),
        name: row['name'] as String,
        specialUse: row['special_use'] as String?,
        uidValidity: (row['uid_validity'] as num).toInt(),
        uidNext: (row['uid_next'] as num).toInt(),
        persistence: this,
        userId: userId,
      );
      account.register(box);
      // Hydrate messages.
      final msgs = await _db.select(
        'SELECT id, uid, raw_b64, internal_date, flags, deleted, size '
        'FROM mailbox_messages WHERE folder_id = ? ORDER BY uid ASC',
        [box.id],
      );
      for (final m in msgs) {
        final flagsStr = (m['flags'] as String?) ?? '';
        final raw = base64.decode(m['raw_b64'] as String);
        box.messages.add(
          StoredMessage(
            id: (m['id'] as num).toInt(),
            uid: (m['uid'] as num).toInt(),
            raw: Uint8List.fromList(raw),
            internalDate: m['internal_date'] is DateTime
                ? m['internal_date'] as DateTime
                : DateTime.parse(m['internal_date'].toString()),
            flags: flagsStr.isEmpty ? <String>[] : flagsStr.split(' '),
            deleted: _toBool(m['deleted']),
          ),
        );
      }
    }
    return account;
  }

  Future<void> _insertMessage(PersistentMailbox box, StoredMessage msg) async {
    try {
      await _db.statement(
        'INSERT INTO mailbox_messages '
        '(folder_id, uid, raw_b64, internal_date, flags, deleted, size) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          box.id,
          msg.uid,
          base64.encode(msg.raw),
          _formatDateTime(msg.internalDate),
          msg.flags.join(' '),
          msg.deleted ? 1 : 0,
          msg.size,
        ],
      );
      await _db.statement(
        'UPDATE mailbox_folders SET uid_next = ? WHERE id = ?',
        [box.uidNext, box.id],
      );
      // Fetch the assigned PK so future updates can target it.
      final row = await _db.select(
        'SELECT id FROM mailbox_messages WHERE folder_id = ? AND uid = ?',
        [box.id, msg.uid],
      );
      if (row.isNotEmpty) {
        msg.id = (row.first['id'] as num).toInt();
      }
    } catch (e) {
      stderr.writeln('[mysql] insertMessage failed: $e');
    }
  }

  Future<void> updateMessage(PersistentMailbox box, StoredMessage msg) async {
    if (msg.id == 0) return; // Insert hasn't completed yet; skip.
    try {
      await _db.statement(
        'UPDATE mailbox_messages SET flags = ?, deleted = ? WHERE id = ?',
        [msg.flags.join(' '), msg.deleted ? 1 : 0, msg.id],
      );
    } catch (e) {
      stderr.writeln('[mysql] updateMessage failed: $e');
    }
  }

  Future<void> _deleteMessages(
    PersistentMailbox box,
    List<StoredMessage> msgs,
  ) async {
    for (final m in msgs) {
      if (m.id == 0) continue;
      try {
        await _db.statement('DELETE FROM mailbox_messages WHERE id = ?', [m.id]);
      } catch (e) {
        stderr.writeln('[mysql] deleteMessage failed: $e');
      }
    }
  }

  String _formatDateTime(DateTime dt) {
    final u = dt.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year}-${two(u.month)}-${two(u.day)} '
        '${two(u.hour)}:${two(u.minute)}:${two(u.second)}';
  }

  static bool _toBool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v == '1' || v.toLowerCase() == 'true';
    return false;
  }
}

// ===========================================================================
// Webhook payload (identical shape to laravel_bridge.dart)
// ===========================================================================

class WebhookPayload {
  const WebhookPayload({
    required this.envelopeFrom,
    required this.envelopeTo,
    required this.headerFrom,
    required this.subject,
    required this.text,
    required this.html,
    required this.rawBytes,
    required this.size,
    required this.spf,
    required this.dkim,
    required this.dmarc,
    required this.rdns,
  });

  factory WebhookPayload.fromMail(MailObject mail) => WebhookPayload(
    envelopeFrom: mail.from,
    envelopeTo: List<String>.from(mail.to),
    headerFrom: mail.headerFrom,
    subject: mail.subject,
    text: mail.text,
    html: mail.html,
    rawBytes: Uint8List.fromList(mail.raw),
    size: mail.size,
    spf: mail.auth.spf,
    dkim: mail.auth.dkim,
    dmarc: mail.auth.dmarc,
    rdns: mail.auth.rdns,
  );

  final String? envelopeFrom;
  final List<String> envelopeTo;
  final String? headerFrom;
  final String? subject;
  final String? text;
  final String? html;
  final Uint8List rawBytes;
  final int size;
  final String? spf;
  final String? dkim;
  final String? dmarc;
  final String? rdns;

  Map<String, dynamic> toJson() => {
    'envelopeFrom': envelopeFrom,
    'envelopeTo': envelopeTo,
    'headerFrom': headerFrom,
    'subject': subject,
    'text': text,
    'html': html,
    'raw': base64.encode(rawBytes),
    'size': size,
    'auth': {'spf': spf, 'dkim': dkim, 'dmarc': dmarc, 'rdns': rdns},
  };
}

// ===========================================================================
// Bridge
// ===========================================================================

class LaravelBridge {
  LaravelBridge({
    required this.baseUrl,
    required this.webhookSecret,
    required this.persistence,
  });

  final String baseUrl;
  final String webhookSecret;
  final MysqlPersistence persistence;

  Future<void> start() async {
    await persistence.bootstrap();
    // Preload the demo user so its mailbox is immediately addressable.
    await persistence.loadOrCreateUser(_user);

    int portFromEnv(String key, int fallback) =>
        int.tryParse(Platform.environment[key] ?? '') ?? fallback;
    final smtpPort       = portFromEnv('DART_MAIL_SMTP_PORT', 2525);
    final submissionPort = portFromEnv('DART_MAIL_SUBMISSION_PORT', 2587);
    final imapPort       = portFromEnv('DART_MAIL_IMAP_PORT', 2143);
    final pop3Port       = portFromEnv('DART_MAIL_POP3_PORT', 2110);

    final server = Server(
      ServerOptions(
        hostname: 'mail.example.com',
        ports: ServerPorts(
          inbound: smtpPort,
          submission: submissionPort,
          imap: imapPort,
          pop3: pop3Port,
        ),
      ),
    );

    server.on('auth', _onAuth);
    server.on('smtpSession', _onSmtpSession);
    server.on('mailboxSession', _onMailboxSession);

    await server.listen();
    print(
      'dart_email_server (mysql) listening — '
      'SMTP $smtpPort/$submissionPort, IMAP $imapPort, POP3 $pop3Port',
    );
    print('Webhook target: $baseUrl/api/incoming-mail');
  }

  void _onAuth(AuthInfo a) {
    if (a.username == _user && a.password == _pass) {
      a.accept();
    } else {
      a.reject('Bad credentials');
    }
  }

  void _onSmtpSession(dynamic sess, SmtpFacadeState st) {
    sess.on('mail', (MailObject mail) {
      _ingest(mail, st);
      mail.accept();
      unawaited(_pushToLaravel(mail));
    });
  }

  void _onMailboxSession(MailboxFacade mb) {
    final account = persistence.forUser(mb.username ?? _user);
    if (mb.protocol == 'imap') {
      ImapHandler(mb, account, persistence).bind();
    } else if (mb.protocol == 'pop3') {
      Pop3Handler(mb, account.inbox).bind();
    }
  }

  void _ingest(MailObject mail, SmtpFacadeState st) {
    final raw = Uint8List.fromList(mail.raw);
    for (final rcpt in mail.to) {
      persistence.forUser(rcpt).inbox.add(raw);
    }
    if (st.isSubmission && st.username != null) {
      final sent = persistence.forUser(st.username!).folder('Sent');
      sent?.add(raw);
    }
  }

  Future<void> _pushToLaravel(MailObject mail) async {
    final payload = WebhookPayload.fromMail(mail);
    HttpClient? client;
    try {
      client = HttpClient();
      final req = await client.postUrl(Uri.parse('$baseUrl/api/incoming-mail'));
      req.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.authorizationHeader, 'Bearer $webhookSecret');
      req.add(utf8.encode(jsonEncode(payload.toJson())));
      final resp = await req.close();
      await resp.drain();
      if (resp.statusCode >= 300) {
        stderr.writeln('[webhook] HTTP ${resp.statusCode}');
      }
    } catch (e) {
      stderr.writeln('[webhook] push failed: $e');
    } finally {
      client?.close();
    }
  }
}

// ===========================================================================
// IMAP handler — same logic as in-memory version, but persists mutations.
// ===========================================================================

class ImapHandler {
  ImapHandler(this.mb, this.account, this.persistence);

  final MailboxFacade mb;
  final Account account;
  final MysqlPersistence persistence;

  void bind() {
    mb.onFolders((respond) {
      respond.ok([
        for (final f in account.folders)
          FolderInfo(name: f.name, specialUse: f.specialUse),
      ]);
    });

    mb.onOpenFolder((name, respond) {
      final box = account.folder(name);
      if (box == null) return respond.error('Folder not found: $name');
      final live = box.live();
      respond.ok(
        OpenFolderResult(
          total: live.length,
          uidValidity: box.uidValidity,
          uidNext: box.uidNext,
        ),
      );
    });

    mb.onStatus((name, items, respond) {
      final box = account.folder(name);
      if (box == null) return respond.error('Folder not found: $name');
      final live = box.live();
      final unseen = live.where((m) => !m.flags.contains('\\Seen')).length;
      respond.ok(
        StatusResult(
          messages: live.length,
          uidnext: box.uidNext,
          uidvalidity: box.uidValidity,
          unseen: unseen,
        ),
      );
    });

    mb.onResolveMessages((name, query, respond) {
      final box = account.folder(name);
      if (box == null) return respond.ok(const <MessageRef>[]);
      final live = box.live();
      final out = <MessageRef>[];
      for (var i = 0; i < live.length; i++) {
        final ref = MessageRef(seq: i + 1, uid: live[i].uid);
        final key = query.byUid ? ref.uid : ref.seq;
        if (query.includes(key)) out.add(ref);
      }
      respond.ok(out);
    });

    mb.onMessageMeta((name, uids, respond) {
      final box = account.folder(name);
      if (box == null) return respond.ok(const <MessageMeta>[]);
      final live = box.live();
      final byUid = <int, StoredMessage>{for (var m in live) m.uid: m};
      final indexByUid = <int, int>{
        for (var i = 0; i < live.length; i++) live[i].uid: i,
      };
      final out = <MessageMeta>[];
      for (final u in uids) {
        final m = byUid[u];
        if (m == null) continue;
        out.add(
          MessageMeta(
            uid: m.uid,
            seq: indexByUid[m.uid]! + 1,
            flags: List<String>.from(m.flags),
            internalDate: m.internalDate,
            size: m.size,
          ),
        );
      }
      respond.ok(out);
    });

    mb.onImapMessageBody((name, uid, body) {
      final box = account.folder(name);
      final m = box == null ? null : _findLive(box, uid);
      if (m == null) {
        body.error('No such message');
      } else {
        body.send(m.raw);
      }
    });

    mb.onSetFlags((name, req, respond) {
      final box = account.folder(name);
      if (box == null) return respond.ok();
      final byUid = <int, StoredMessage>{for (var m in box.messages) m.uid: m};
      final touched = <StoredMessage>[];
      for (final u in req.uids) {
        final m = byUid[u];
        if (m == null) continue;
        if (req.isAdd) {
          for (final f in req.flags) {
            if (!m.flags.contains(f)) m.flags.add(f);
          }
        } else if (req.isRemove) {
          m.flags.removeWhere(req.flags.contains);
        } else {
          m.flags
            ..clear()
            ..addAll(req.flags);
        }
        if (m.flags.contains('\\Deleted')) m.deleted = true;
        touched.add(m);
      }
      for (final m in touched) {
        unawaited(persistence.updateMessage(box, m));
      }
      respond.ok();
    });

    mb.onExpunge((name, opts, respond) {
      account.folder(name)?.purgeDeleted();
      respond.ok();
    });

    mb.onSearch((name, criteria, respond) {
      final box = account.folder(name);
      if (box == null) return respond.ok(const <MessageRef>[]);
      final live = box.live();
      respond.ok([
        for (var i = 0; i < live.length; i++)
          MessageRef(seq: i + 1, uid: live[i].uid),
      ]);
    });

    mb.onAppend((name, raw, options, respond) {
      final box = account.folder(name);
      if (box == null) return respond.error('Folder not found: $name');
      final assignedUid = box.uidNext;
      box.add(raw, initialFlags: options.flags);
      respond.ok(AppendResult(uid: assignedUid, uidValidity: box.uidValidity));
    });

    mb.onCopyMessages((src, uids, destination, respond) {
      final from = account.folder(src);
      final to = account.folder(destination);
      if (from == null || to == null) return respond.error('Folder not found');
      final byUid = <int, StoredMessage>{for (var m in from.messages) m.uid: m};
      final mapping = <CopyMapping>[];
      for (final u in uids) {
        final m = byUid[u];
        if (m == null) continue;
        final newUid = to.uidNext;
        to.add(Uint8List.fromList(m.raw), initialFlags: m.flags);
        mapping.add(CopyMapping(srcUid: u, dstUid: newUid));
      }
      respond.ok(CopyResult(dstUidValidity: to.uidValidity, mapping: mapping));
    });

    mb.onMoveMessages((src, uids, destination, respond) {
      final from = account.folder(src);
      final to = account.folder(destination);
      if (from == null || to == null) return respond.error('Folder not found');
      final byUid = <int, StoredMessage>{for (var m in from.messages) m.uid: m};
      final mapping = <CopyMapping>[];
      final movedSrc = <StoredMessage>[];
      for (final u in uids) {
        final m = byUid[u];
        if (m == null) continue;
        final newUid = to.uidNext;
        to.add(Uint8List.fromList(m.raw), initialFlags: m.flags);
        mapping.add(CopyMapping(srcUid: u, dstUid: newUid));
        movedSrc.add(m);
      }
      from.messages.removeWhere((m) => uids.contains(m.uid));
      if (movedSrc.isNotEmpty) {
        unawaited(persistence._deleteMessages(from, movedSrc));
      }
      respond.ok(CopyResult(dstUidValidity: to.uidValidity, mapping: mapping));
    });
  }

  StoredMessage? _findLive(PersistentMailbox box, int uid) {
    for (final m in box.live()) {
      if (m.uid == uid) return m;
    }
    return null;
  }
}

// ===========================================================================
// POP3 handler (read-only view of INBOX, identical to the in-memory bridge)
// ===========================================================================

class Pop3Handler {
  Pop3Handler(this.mb, this.box);

  final MailboxFacade mb;
  final PersistentMailbox box;

  void bind() {
    mb.onOpenFolder((name, respond) {
      respond.ok(
        OpenFolderResult(
          total: box.live().length,
          uidValidity: box.uidValidity,
          uidNext: box.uidNext,
        ),
      );
    });

    mb.onResolveMessages((name, query, respond) {
      final live = box.live();
      respond.ok([
        for (var i = 0; i < live.length; i++)
          MessageRef(seq: i + 1, uid: live[i].uid),
      ]);
    });

    mb.onPop3MessageMeta((name, uids, respond) {
      final byUid = <int, StoredMessage>{for (var m in box.live()) m.uid: m};
      final out = <Pop3Meta>[];
      for (final u in uids) {
        final m = byUid[u];
        if (m == null) continue;
        out.add(
          Pop3Meta(uid: m.uid, size: m.size, flags: List<String>.from(m.flags)),
        );
      }
      respond.ok(out);
    });

    mb.onPop3MessageBody((name, uid, body) {
      StoredMessage? found;
      for (final m in box.live()) {
        if (m.uid == uid) {
          found = m;
          break;
        }
      }
      if (found == null) {
        body.error('No such message');
      } else {
        body.send(found.raw);
      }
    });

    mb.onSetFlags((name, req, respond) {
      final byUid = <int, StoredMessage>{for (var m in box.messages) m.uid: m};
      final touched = <StoredMessage>[];
      for (final u in req.uids) {
        final m = byUid[u];
        if (m == null) continue;
        if (req.flags.contains('\\Deleted')) {
          m.deleted = true;
          touched.add(m);
        }
      }
      for (final m in touched) {
        unawaited(box.persistence.updateMessage(box, m));
      }
      respond.ok();
    });

    mb.onExpunge((name, opts, respond) {
      box.purgeDeleted();
      respond.ok();
    });
  }
}

// ===========================================================================
// Entry point
// ===========================================================================

Future<void> main() async {
  final persistence = MysqlPersistence(
    host: Platform.environment['DART_MAIL_DB_HOST'] ?? '127.0.0.1',
    port: Platform.environment['DART_MAIL_DB_PORT'] ?? '3306',
    database: Platform.environment['DART_MAIL_DB_NAME'] ?? 'dart_email_server',
    username: Platform.environment['DART_MAIL_DB_USER'] ?? 'dart',
    password: Platform.environment['DART_MAIL_DB_PASS'] ?? 'dart',
  );

  final bridge = LaravelBridge(
    baseUrl: _laravelBaseUrl,
    webhookSecret: _webhookSecret,
    persistence: persistence,
  );
  await bridge.start();
}
