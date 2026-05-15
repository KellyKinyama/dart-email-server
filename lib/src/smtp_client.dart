import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'smtp_session.dart';
import 'smtp_wire.dart' show SmtpReply;
import 'message.dart';
import 'utils.dart';
import 'domain.dart' show RelayOptions;
import 'dns_cache.dart' as dnsCache;

// ============================================================
//  MX lookup (uses shared dns_cache)
// ============================================================

/// Username/password pair for SMTP AUTH PLAIN/LOGIN.
class SmtpAuthCredentials {
  final String user;
  final String pass;
  const SmtpAuthCredentials({required this.user, required this.pass});
}

/// MAIL FROM extension parameters (RFC 1870 SIZE, RFC 1652 8BITMIME,
/// RFC 6531 SMTPUTF8, RFC 8689 REQUIRETLS).
class MailFromParams {
  final int? size;
  final String? body; // '7BIT' | '8BITMIME' | 'BINARYMIME'
  final bool smtputf8;
  final bool requiretls;
  const MailFromParams({
    this.size,
    this.body,
    this.smtputf8 = false,
    this.requiretls = false,
  });

  Map<String, dynamic> toMap() => {
    if (size != null) 'size': size,
    if (body != null) 'body': body,
    if (smtputf8) 'smtputf8': true,
    if (requiretls) 'requiretls': true,
  };
}

/// Callback invoked by the SMTP client wrapper after a single command.
typedef SmtpResultCb = void Function(Exception? err);

/// Callback invoked after a DATA exchange completes.
typedef SmtpDataCb = void Function(Exception? err, [SmtpReply? reply]);

class SmtpClientOptions {
  final String host;
  final int port;
  final String localHostname;
  final int timeout;
  final bool ignoreTLS;
  final SmtpAuthCredentials? auth;

  const SmtpClientOptions({
    required this.host,
    this.port = 25,
    this.localHostname = 'localhost',
    this.timeout = 30000,
    this.ignoreTLS = false,
    this.auth,
  });
}

Future<List<MxRecord>> resolveMX(String domain) async {
  try {
    final records = await dnsCache.mxRecords(domain);
    if (records.isEmpty) {
      return [MxRecord(exchange: domain, priority: 10)];
    }
    final out = records
        .map((r) => MxRecord(exchange: r.exchange, priority: r.priority))
        .toList();
    out.sort((a, b) => a.priority.compareTo(b.priority));
    return out;
  } catch (err) {
    return [MxRecord(exchange: domain, priority: 10)];
  }
}

// ============================================================
//  SMTPConnection — TCP socket + SMTPSession(isServer:false)
// ============================================================

class SMTPConnectionWrapper {
  final SMTPSession session;
  final Map<String, dynamic>? capabilities;
  final bool isTLS;
  final void Function(String from, MailFromParams? params, SmtpResultCb cb)
  mailFrom;
  final void Function(String to, SmtpResultCb cb) rcptTo;
  final void Function(Object rawMessage, SmtpDataCb cb) data;
  final void Function(String user, String pass, SmtpResultCb cb) authPlain;
  final void Function() quit;
  final void Function() destroy;
  final void Function(String) sendLine;
  final void Function(void Function(SmtpReply)) readReply;

  SMTPConnectionWrapper({
    required this.session,
    required this.capabilities,
    required this.isTLS,
    required this.mailFrom,
    required this.rcptTo,
    required this.data,
    required this.authPlain,
    required this.quit,
    required this.destroy,
    required this.sendLine,
    required this.readReply,
  });
}

Future<SMTPConnectionWrapper> SMTPConnection(SmtpClientOptions options) async {
  String host = options.host;
  int port = options.port;
  String localHostname = options.localHostname;
  int timeout = options.timeout;

  Socket? socket;
  SMTPSession session;
  bool done = false;

  Completer<SMTPConnectionWrapper> completer = Completer();

  void finish(Exception? err, [SMTPConnectionWrapper? result]) {
    if (done) return;
    done = true;
    if (err != null) {
      if (socket != null) {
        try {
          socket!.destroy();
        } catch (e) {}
      }
      if (!completer.isCompleted) completer.completeError(err);
    } else {
      if (!completer.isCompleted) completer.complete(result);
    }
  }

  session = SMTPSession(
    SMTPSessionOptions(isServer: false, hostname: localHostname),
  );

  session.on('send', (String data) {
    if (socket != null) {
      try {
        socket!.add(toU8(data));
      } catch (e) {}
    }
  });

  session.on('error', (Exception err) {
    finish(err);
  });

  session.on('starttls', () async {
    try {
      SecureSocket tlsSocket = await SecureSocket.secure(
        socket!,
        host: host,
        onBadCertificate: (cert) =>
            true, // rejectUnauthorized: false equivalent
      );

      socket = tlsSocket;
      tlsSocket.listen(
        (chunk) => session.feed(chunk),
        onError: (err) =>
            finish(err is Exception ? err : Exception(err.toString())),
        onDone: () {
          if (!done) finish(Exception('Connection closed'));
        },
      );
      session.tlsUpgraded();
    } catch (err) {
      finish(err is Exception ? err : Exception(err.toString()));
    }
  });

  session.on('ready', () {
    var conn = SMTPConnectionWrapper(
      session: session,
      capabilities: session.capabilities,
      isTLS: session.isTLS,
      mailFrom: (from, params, cb) =>
          session.mailFrom(from, params?.toMap() ?? {}, cb),
      rcptTo: (to, cb) => session.rcptTo(to, cb),
      data: (rawMessage, cb) => session.data(rawMessage, cb),
      authPlain: (user, pass, cb) => session.authPlain(user, pass, cb),
      quit: () {
        session.quit();
        Timer(Duration(milliseconds: 300), () {
          if (socket != null)
            try {
              socket!.destroy();
            } catch (e) {}
        });
      },
      destroy: () {
        if (socket != null)
          try {
            socket!.destroy();
          } catch (e) {}
      },
      sendLine: (line) => session.sendLine(line),
      readReply: (cb) => session.readReply(cb),
    );

    finish(null, conn);
  });

  try {
    socket = await Socket.connect(
      host,
      port,
      timeout: Duration(milliseconds: timeout),
    );

    socket!.listen(
      (chunk) => session.feed(chunk),
      onError: (err) =>
          finish(err is Exception ? err : Exception(err.toString())),
      onDone: () {
        if (!done) finish(Exception('Connection closed'));
      },
    );

    session.greet();
  } catch (err) {
    finish(err is Exception ? err : Exception(err.toString()));
  }

  return completer.future;
}

// ============================================================
//  Typed sendMail / deliverToDomain public surface
// ============================================================

/// A single attachment for a composed outbound message.
class MailAttachment {
  final String? filename;
  final String? contentType;
  final String? contentId;
  final String? cid;
  final String? disposition; // 'attachment' | 'inline'
  final List<int>? content;
  final String? encoding; // 'base64' | '7bit' | '8bit' | 'binary'

  const MailAttachment({
    this.filename,
    this.contentType,
    this.contentId,
    this.cid,
    this.disposition,
    this.content,
    this.encoding,
  });

  Map<String, Object?> toMap() => {
    if (filename != null) 'filename': filename,
    if (contentType != null) 'contentType': contentType,
    if (contentId != null) 'contentId': contentId,
    if (cid != null) 'cid': cid,
    if (disposition != null) 'disposition': disposition,
    if (content != null) 'content': content,
    if (encoding != null) 'encoding': encoding,
  };
}

/// Outbound message specification accepted by [sendMail].
///
/// Either [raw] (a fully-formed RFC 5322 message) must be supplied, or the
/// composition fields ([from] + [to] at minimum) so that the message can
/// be built internally.
class SendMailOptions {
  final Uint8List? raw;
  final AddressObj? from;
  final List<AddressObj>? to;
  final List<AddressObj>? cc;
  final List<AddressObj>? bcc;
  final String? subject;
  final String? text;
  final String? html;
  final List<MailAttachment>? attachments;
  final Map<String, String>? headers;
  final String? messageId;
  final String? date;
  final AddressObj? replyTo;
  final String? priority; // 'high' | 'normal' | 'low'
  final RelayOptions? relay;
  final String localHostname;
  final int timeout;
  final bool ignoreTLS;

  const SendMailOptions({
    this.raw,
    this.from,
    this.to,
    this.cc,
    this.bcc,
    this.subject,
    this.text,
    this.html,
    this.attachments,
    this.headers,
    this.messageId,
    this.date,
    this.replyTo,
    this.priority,
    this.relay,
    this.localHostname = 'localhost',
    this.timeout = 30000,
    this.ignoreTLS = false,
  });

  Map<String, Object?> _addrToLegacy(AddressObj a) => {
    'name': a.name,
    'address': a.address,
  };

  List<Map<String, Object?>> _addrListToLegacy(List<AddressObj> list) =>
      list.map(_addrToLegacy).toList();

  Map<String, Object?> toLegacyMap() => {
    if (raw != null) 'raw': raw,
    if (from != null) 'from': _addrToLegacy(from!),
    if (to != null) 'to': _addrListToLegacy(to!),
    if (cc != null) 'cc': _addrListToLegacy(cc!),
    if (bcc != null) 'bcc': _addrListToLegacy(bcc!),
    if (subject != null) 'subject': subject,
    if (text != null) 'text': text,
    if (html != null) 'html': html,
    if (attachments != null)
      'attachments': attachments!.map((a) => a.toMap()).toList(),
    if (headers != null) 'headers': headers,
    if (messageId != null) 'messageId': messageId,
    if (date != null) 'date': date,
    if (replyTo != null) 'replyTo': _addrToLegacy(replyTo!),
    if (priority != null) 'priority': priority,
    if (relay != null)
      'relay': {
        'host': relay!.host,
        'port': relay!.port,
        if (relay!.username != null) 'username': relay!.username,
        if (relay!.password != null) 'password': relay!.password,
        'requireTls': relay!.requireTls,
      },
    'localHostname': localHostname,
    'timeout': timeout,
    'ignoreTLS': ignoreTLS,
  };
}

/// Result of delivering one envelope group (one MX domain).
class DeliverResult {
  final String host;
  final List<String> accepted;
  final List<String> rejected;

  const DeliverResult({
    required this.host,
    required this.accepted,
    required this.rejected,
  });
}

/// Per-recipient delivery error after all retries fail.
class DeliverError {
  final String domain;
  final Object error;
  const DeliverError({required this.domain, required this.error});
}

/// Aggregate result returned by [sendMail].
class SendMailResult {
  final String? messageId;
  final List<DeliverResult> accepted;
  final List<DeliverError> rejected;

  const SendMailResult({
    required this.messageId,
    required this.accepted,
    required this.rejected,
  });
}

/// Single MX record returned by [resolveMX].
class MxRecord {
  final String exchange;
  final int priority;
  const MxRecord({required this.exchange, this.priority = 10});
}

// ============================================================
//  sendMail
// ============================================================

/// Send a message. Type-safe: takes a [SendMailOptions], returns a typed
/// [SendMailResult]. The internal pipeline still uses untyped maps until
/// the entire composition stack is migrated.
Future<SendMailResult> sendMail(SendMailOptions options) async {
  final raw = await sendMailLegacyMap(
    options.toLegacyMap().cast<String, dynamic>(),
  );
  final accepted = <DeliverResult>[];
  for (final m in (raw['accepted'] as List? ?? const [])) {
    if (m is Map) {
      accepted.add(
        DeliverResult(
          host: (m['host'] as String?) ?? '',
          accepted:
              (m['accepted'] as List?)?.cast<String>() ?? const <String>[],
          rejected:
              (m['rejected'] as List?)?.cast<String>() ?? const <String>[],
        ),
      );
    }
  }
  final rejected = <DeliverError>[];
  for (final m in (raw['rejected'] as List? ?? const [])) {
    if (m is Map) {
      rejected.add(
        DeliverError(
          domain: (m['domain'] as String?) ?? '',
          error: m['error'] as Object? ?? Exception('unknown'),
        ),
      );
    }
  }
  return SendMailResult(
    messageId: raw['messageId'] as String?,
    accepted: accepted,
    rejected: rejected,
  );
}

/// Legacy Map-based entry point used by internal call sites in
/// `server.dart` until the surrounding pipeline is fully typed.
/// Public typed callers should use [sendMail] / [SendMailOptions].
Future<Map<String, dynamic>> sendMailLegacyMap(
  Map<String, dynamic>? options,
) async {
  options ??= {};

  ComposeResult? composed;
  Uint8List? rawMessage;

  if (options['raw'] != null) {
    rawMessage = options['raw'] is Uint8List
        ? options['raw']
        : toU8(options['raw'].toString());
  } else {
    composed = composeMessageTyped(
      ComposeMessageOptions(
        from: options['from'],
        to: options['to'],
        cc: options['cc'],
        bcc: options['bcc'],
        subject: options['subject'] as String?,
        text: options['text'] as String?,
        html: options['html'] as String?,
        attachments: options['attachments'] is List
            ? List<Map<String, dynamic>>.from(options['attachments'] as List)
            : null,
        headers: options['headers'],
        messageId: options['messageId'] as String?,
        date: options['date'] as String?,
        replyTo: options['replyTo'],
        priority: options['priority'] as String?,
      ),
    );
    rawMessage = composed.raw;
  }

  String? envFrom = extractAddress(options['from']);
  // Collect to/cc/bcc as a heterogeneous Object list — `extractAddressList`
  // accepts strings, Map address objects, and parses comma-separated lists.
  final List<Object> envToList = <Object>[];
  void appendAddrs(Object? v) {
    if (v == null) return;
    if (v is List) {
      for (final Object? item in v) {
        if (item != null) envToList.add(item);
      }
    } else {
      envToList.add(v);
    }
  }

  appendAddrs(options['to']);
  appendAddrs(options['cc']);
  appendAddrs(options['bcc']);

  List<String> envTo = extractAddressList(envToList);

  if (envFrom == null || envTo.isEmpty) throw Exception('Missing from or to');

  String? messageId = composed != null
      ? composed.messageId
      : (options['messageId'] as String?);

  if (options['relay'] != null) {
    return await sendViaRelay(
      options['relay'],
      envFrom,
      envTo,
      rawMessage!,
      messageId,
      options,
    );
  }

  Map<String, Map<String, dynamic>> byDomain = {};
  for (int i = 0; i < envTo.length; i++) {
    String raw = envTo[i];
    int at = raw.lastIndexOf('@');
    if (at < 0) continue;
    String domain = raw.substring(at + 1);
    String asciiDomain = domainToAscii(domain);
    if (!byDomain.containsKey(asciiDomain)) {
      byDomain[asciiDomain] = {'recipients': <String>[], 'needsUtf8': false};
    }
    (byDomain[asciiDomain]!['recipients'] as List<String>).add(raw);
    if (addressNeedsSmtputf8(raw)) byDomain[asciiDomain]!['needsUtf8'] = true;
  }

  bool fromNeedsUtf8 = addressNeedsSmtputf8(envFrom);

  List<String> domains = byDomain.keys.toList();
  List<dynamic> results = [];
  List<Map<String, dynamic>> errors = [];
  int pending = domains.length;

  if (pending == 0) throw Exception('No valid recipients');

  Completer<Map<String, dynamic>> completer = Completer();

  for (int i = 0; i < domains.length; i++) {
    String domain = domains[i];
    var group = byDomain[domain]!;
    bool envelopeNeedsUtf8 = group['needsUtf8'] == true || fromNeedsUtf8;

    Map<String, dynamic> opts = Map.from(options);
    opts['envelopeNeedsUtf8'] = envelopeNeedsUtf8;

    deliverToDomain(
          domain,
          envFrom,
          group['recipients'] as List<String>,
          rawMessage!,
          opts,
        )
        .then((info) {
          results.add(info);
        })
        .catchError((err) {
          errors.add({'domain': domain, 'error': err});
        })
        .whenComplete(() {
          pending--;
          if (pending == 0) {
            if (errors.isNotEmpty && results.isEmpty) {
              completer.completeError(errors[0]['error']);
            } else {
              completer.complete({
                'messageId': messageId,
                'accepted': results,
                'rejected': errors,
              });
            }
          }
        });
  }

  return completer.future;
}

// ============================================================
//  Direct delivery via MX
// ============================================================

Future<Map<String, dynamic>> deliverToDomain(
  String domain,
  String envFrom,
  List<String> recipients,
  Uint8List rawMessage,
  Map<String, dynamic> options,
) async {
  var mxRecords = await resolveMX(domain);
  int mxIndex = 0;

  Future<Map<String, dynamic>> tryNextMX() async {
    if (mxIndex >= mxRecords.length)
      throw Exception('All MX failed for $domain');
    var mx = mxRecords[mxIndex++];

    try {
      var conn = await SMTPConnection(
        SmtpClientOptions(
          host: mx.exchange,
          port: 25,
          localHostname: options['localHostname'] ?? 'localhost',
          timeout: options['timeout'] ?? 30000,
          ignoreTLS: options['ignoreTLS'] == true,
        ),
      );

      var peerCaps = conn.capabilities ?? {};
      bool peerUtf8 = peerCaps['smtputf8'] == true;
      bool wantUtf8 = options['envelopeNeedsUtf8'] == true;

      String effFrom = envFrom;
      List<String> effRecipients = List.from(recipients);

      if (wantUtf8 && !peerUtf8) {
        String? mappedFrom = addressForAsciiOnlyPeer(envFrom);
        if (mappedFrom == null) {
          conn.quit();
          throw Exception(
            'Peer ${mx.exchange} does not advertise SMTPUTF8 and sender local-part is non-ASCII',
          );
        }
        effFrom = mappedFrom;

        List<String> mappedTo = [];
        for (int r = 0; r < recipients.length; r++) {
          String? m = addressForAsciiOnlyPeer(recipients[r]);
          if (m == null) {
            conn.quit();
            throw Exception(
              'Peer ${mx.exchange} does not advertise SMTPUTF8 and recipient ${recipients[r]} has a non-ASCII local-part',
            );
          }
          mappedTo.add(m);
        }
        effRecipients = mappedTo;
        wantUtf8 = false;
      } else if (!wantUtf8 && peerUtf8) {
        effFrom = addressForAsciiOnlyPeer(envFrom) ?? envFrom;
        effRecipients = recipients
            .map((r) => addressForAsciiOnlyPeer(r) ?? r)
            .toList();
      }

      final mailParams = MailFromParams(
        size: rawMessage.length,
        smtputf8: wantUtf8 && peerUtf8,
      );

      Completer<Map<String, dynamic>> rcptCompleter = Completer();

      conn.mailFrom(effFrom, mailParams, (err) {
        if (err != null) {
          conn.destroy();
          rcptCompleter.completeError(err);
          return;
        }

        List<String> accepted = [];
        List<String> rejected = [];
        int idx = 0;

        void nextRcpt() {
          if (idx >= effRecipients.length) {
            if (accepted.isEmpty) {
              conn.quit();
              rcptCompleter.completeError(Exception('All recipients rejected'));
              return;
            }
            conn.data(rawMessage, (err, [reply]) {
              conn.quit();
              if (err != null) {
                rcptCompleter.completeError(err);
                return;
              }
              rcptCompleter.complete({
                'host': mx.exchange,
                'accepted': accepted,
                'rejected': rejected,
              });
            });
            return;
          }
          conn.rcptTo(effRecipients[idx], (err) {
            if (err != null) {
              rejected.add(recipients[idx]);
            } else {
              accepted.add(recipients[idx]);
            }
            idx++;
            nextRcpt();
          });
        }

        nextRcpt();
      });

      return await rcptCompleter.future;
    } catch (e) {
      return await tryNextMX();
    }
  }

  return await tryNextMX();
}

// ============================================================
//  Relay delivery
// ============================================================

Future<Map<String, dynamic>> sendViaRelay(
  Map<String, dynamic> relay,
  String envFrom,
  List<String> envTo,
  Uint8List rawMessage,
  String? messageId,
  Map<String, dynamic> options,
) async {
  var conn = await SMTPConnection(
    SmtpClientOptions(
      host: relay['host'],
      port: relay['port'] ?? 587,
      localHostname:
          relay['localHostname'] ?? options['localHostname'] ?? 'localhost',
      timeout: relay['timeout'] ?? 30000,
      ignoreTLS: relay['ignoreTLS'] == true,
    ),
  );

  Completer<Map<String, dynamic>> completer = Completer();

  void afterAuth() {
    conn.mailFrom(envFrom, null, (err) {
      if (err != null) {
        conn.destroy();
        completer.completeError(err);
        return;
      }

      List<String> accepted = [];
      int idx = 0;
      void nextRcpt() {
        if (idx >= envTo.length) {
          if (accepted.isEmpty) {
            conn.quit();
            completer.completeError(Exception('All recipients rejected'));
            return;
          }
          conn.data(rawMessage, (err, [reply]) {
            conn.quit();
            if (err != null) {
              completer.completeError(err);
              return;
            }
            completer.complete({
              'messageId': messageId,
              'host': relay['host'],
              'accepted': accepted,
            });
          });
          return;
        }
        conn.rcptTo(envTo[idx], (err) {
          if (err == null) accepted.add(envTo[idx]);
          idx++;
          nextRcpt();
        });
      }

      nextRcpt();
    });
  }

  if (relay['auth'] != null &&
      relay['auth']['user'] != null &&
      relay['auth']['pass'] != null) {
    conn.authPlain(relay['auth']['user'], relay['auth']['pass'], (err) {
      if (err != null) {
        conn.destroy();
        completer.completeError(err);
        return;
      }
      afterAuth();
    });
  } else {
    afterAuth();
  }

  return completer.future;
}
