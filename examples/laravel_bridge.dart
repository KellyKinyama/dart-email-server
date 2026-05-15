// Bridge between dart_email_server and the Laravel client in
// ./laravel-client. Boots a minimal SMTP server on 2525, an IMAP server
// on 2143, and a POP3 server on 2110, and POSTs every accepted inbound
// message to the Laravel webhook at /api/incoming-mail.
//
//   dart run examples/laravel_bridge.dart
//
// On the Laravel side:
//   cd laravel-client
//   php artisan migrate
//   php artisan serve --port=8000
//
// Compose mail in the browser at http://127.0.0.1:8000/compose — Laravel
// will hand it back to this server's submission listener (2525), which
// will then loop it into the IMAP/webhook surfaces visible at
// /inbox and /webhook.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_email_server/dart_email_server.dart';

const _laravelBaseUrl = 'http://127.0.0.1:8000';
const _webhookSecret = 'change-me'; // must match DART_MAIL_WEBHOOK_SECRET

const _user = 'demo@example.com';
const _pass = 'demo';

// ===========================================================================
// Typed model layer
// ===========================================================================

/// One stored RFC-5322 message in the demo mailbox.
class StoredMessage {
  StoredMessage({
    required this.uid,
    required this.raw,
    required this.internalDate,
  });

  final int uid;
  final Uint8List raw;
  final DateTime internalDate;
  final List<String> flags = <String>[];
  bool deleted = false;

  int get size => raw.length;
}

/// In-memory mailbox keyed by username. Holds messages and assigns UIDs.
class Mailbox {
  Mailbox()
    : uidValidity = DateTime.now().millisecondsSinceEpoch ~/ 1000,
      _nextUid = 1;

  final List<StoredMessage> messages = <StoredMessage>[];
  final int uidValidity;
  int _nextUid;

  int get uidNext => _nextUid;

  void add(Uint8List raw) {
    messages.add(
      StoredMessage(
        uid: _nextUid++,
        raw: raw,
        internalDate: DateTime.now().toUtc(),
      ),
    );
  }

  List<StoredMessage> live() =>
      messages.where((m) => !m.deleted).toList(growable: false);

  void purgeDeleted() => messages.removeWhere((m) => m.deleted);
}

/// Immutable demo store keyed by user.
class MailboxStore {
  final Map<String, Mailbox> _byUser = <String, Mailbox>{};

  Mailbox forUser(String user) =>
      _byUser.putIfAbsent(user.toLowerCase(), () => Mailbox());
}

// Note: FolderInfo, OpenFolderResult, StatusResult, ResolveQuery, MessageRef,
// MessageMeta, Pop3Meta, BodyResponder, SetFlagsRequest, ExpungeOptions and
// the TypedMailboxFacade extension are provided by package:dart_email_server.

// ===========================================================================
// Webhook payload
// ===========================================================================

class WebhookPayload {
  const WebhookPayload({
    required this.messageId,
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
    messageId: null,
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

  final String? messageId;
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
    'messageId': messageId,
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
// Bridge wiring
// ===========================================================================

class LaravelBridge {
  LaravelBridge({required this.baseUrl, required this.webhookSecret});

  final String baseUrl;
  final String webhookSecret;
  final MailboxStore store = MailboxStore();

  Future<void> start() async {
    // Pre-create demo user mailbox so it shows up immediately.
    store.forUser(_user);

    final server = Server(
      const ServerOptions(
        hostname: 'mail.example.com',
        ports: ServerPorts(
          inbound: 2525, // SMTP relay (no auth)
          submission: 2587, // SMTP submission (auth)
          imap: 2143,
          pop3: 2110,
        ),
      ),
    );

    server.on('auth', _onAuth);
    server.on('smtpSession', _onSmtpSession);
    server.on('mailboxSession', _onMailboxSession);

    await server.listen();
    print('dart_email_server listening — SMTP 2525/2587, IMAP 2143, POP3 2110');
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
      _ingest(mail);
      // Accept first, push the webhook asynchronously. Otherwise we
      // deadlock when Laravel's single-worker `php artisan serve` is
      // the SMTP client AND the webhook target — the worker is blocked
      // on the SMTP 250 reply while we're trying to POST back to it.
      mail.accept();
      unawaited(_pushToLaravel(mail));
    });
  }

  void _onMailboxSession(MailboxFacade mb) {
    final box = store.forUser(mb.username ?? _user);
    if (mb.protocol == 'imap') {
      ImapHandler(mb, box).bind();
    } else if (mb.protocol == 'pop3') {
      Pop3Handler(mb, box).bind();
    }
  }

  void _ingest(MailObject mail) {
    for (final rcpt in mail.to) {
      store.forUser(rcpt).add(Uint8List.fromList(mail.raw));
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

// ---------------------------------------------------------------------------
// IMAP handler
// ---------------------------------------------------------------------------

class ImapHandler {
  ImapHandler(this.mb, this.box);

  final MailboxFacade mb;
  final Mailbox box;

  void bind() {
    mb.onFolders((respond) {
      respond.ok(const [FolderInfo(name: 'INBOX')]);
    });

    mb.onOpenFolder((name, respond) {
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
      final m = _findLive(uid);
      if (m == null) {
        body.error('No such message');
      } else {
        body.send(m.raw);
      }
    });

    mb.onSetFlags((name, req, respond) {
      final byUid = <int, StoredMessage>{for (var m in box.messages) m.uid: m};
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
      }
      respond.ok();
    });

    mb.onExpunge((name, opts, respond) {
      box.purgeDeleted();
      respond.ok();
    });

    // Minimal SEARCH support: ignore the criteria tree and return every
    // live message. Good enough for `SEARCH ALL` / `UID SEARCH ALL`,
    // which is what most clients (including webklex/php-imap) issue
    // before fetching a folder listing.
    mb.onSearch((name, criteria, respond) {
      final live = box.live();
      respond.ok([
        for (var i = 0; i < live.length; i++)
          MessageRef(seq: i + 1, uid: live[i].uid),
      ]);
    });
  }

  StoredMessage? _findLive(int uid) {
    for (final m in box.live()) {
      if (m.uid == uid) return m;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// POP3 handler
// ---------------------------------------------------------------------------

class Pop3Handler {
  Pop3Handler(this.mb, this.box);

  final MailboxFacade mb;
  final Mailbox box;

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
      final m = _findLive(uid);
      if (m == null) {
        body.error('No such message');
      } else {
        body.send(m.raw);
      }
    });

    mb.onSetFlags((name, req, respond) {
      final byUid = <int, StoredMessage>{for (var m in box.messages) m.uid: m};
      for (final u in req.uids) {
        final m = byUid[u];
        if (m == null) continue;
        if (req.flags.contains('\\Deleted')) m.deleted = true;
      }
      respond.ok();
    });

    mb.onExpunge((name, opts, respond) {
      box.purgeDeleted();
      respond.ok();
    });
  }

  StoredMessage? _findLive(int uid) {
    for (final m in box.live()) {
      if (m.uid == uid) return m;
    }
    return null;
  }
}

// ===========================================================================
// Entrypoint
// ===========================================================================

Future<void> main() async {
  final bridge = LaravelBridge(
    baseUrl: _laravelBaseUrl,
    webhookSecret: _webhookSecret,
  );
  await bridge.start();
}
