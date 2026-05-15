import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'smtp_session.dart';
import 'imap_session.dart';
import 'pop3_session.dart';
import 'smtp_client.dart';
import 'pool.dart';
import 'rate_limit.dart';
import 'dsn.dart';
import 'message.dart';
import 'domain.dart';
import 'dkim.dart' as dkim;
import 'spf.dart';
import 'dmarc.dart';
import 'rdns.dart';
import 'utils.dart';

// -----------------------------------------------------------
//  Typed server option / context types
// -----------------------------------------------------------

typedef SniCallback =
    void Function(
      String? servername,
      void Function(Exception? error, SecurityContext? context) cb,
    );

typedef DkimCallback =
    void Function(
      String domain,
      void Function(Exception? error, dkim.DkimSignOptions? options) cb,
    );

typedef OnSecureCallback = void Function();

/// Per-protocol port assignments. `null` disables a protocol.
class ServerPorts {
  final int? inbound; // SMTP   (cleartext, port 25)
  final int? submission; // SMTP submission (587)
  final int? secure; // SMTPS  (implicit TLS, 465)
  final int? imap; // IMAP   (143)
  final int? imaps; // IMAPS  (993)
  final int? pop3; // POP3   (110)
  final int? pop3s; // POP3S  (995)

  const ServerPorts({
    this.inbound = 25,
    this.submission,
    this.secure,
    this.imap,
    this.imaps,
    this.pop3,
    this.pop3s,
  });
}

/// Outbound relay smarthost configuration.
/// (Defined in `domain.dart` and re-exported via `index.dart`.)
// class RelayOptions { ... }

class ServerOptions {
  final String hostname;
  final ServerPorts ports;
  final int maxSize;
  final int maxRecipients;
  final int acceptTimeout;
  final RateLimiterConfig? rateLimit;
  final int closeTimeout;
  final bool useProxy;
  final RelayOptions? relay;
  final SniCallback? sniCallback;
  final DkimCallback? dkimCallback;
  final OnSecureCallback? onSecure;
  final PoolOptions? pool;

  const ServerOptions({
    this.hostname = 'localhost',
    this.ports = const ServerPorts(),
    this.maxSize = 25 * 1024 * 1024,
    this.maxRecipients = 100,
    this.acceptTimeout = 30000,
    this.rateLimit,
    this.closeTimeout = 30000,
    this.useProxy = false,
    this.relay,
    this.sniCallback,
    this.dkimCallback,
    this.onSecure,
    this.pool,
  });
}

/// Tracks an active socket-level connection.
class ConnectionRecord {
  final String id;
  final String protocol; // smtp | imap | pop3
  final String? remoteAddress;

  const ConnectionRecord({
    required this.id,
    required this.protocol,
    required this.remoteAddress,
  });
}

/// Payload emitted on the `'connection'` event. Listeners may call
/// [reject] to refuse the connection.
class ConnectionInfo {
  final String id;
  final String protocol; // smtp | imap | pop3
  final String? remoteAddress;
  bool _rejected = false;

  ConnectionInfo({
    required this.id,
    required this.protocol,
    required this.remoteAddress,
  });

  bool get rejected => _rejected;

  void reject() {
    _rejected = true;
  }
}

/// Payload emitted on the `'auth'` event. Listeners must call either
/// [accept] or [reject] to settle the authentication attempt.
class AuthInfo {
  final String protocol; // smtp | imap | pop3
  final String? username;
  final String? password;
  final String? authMethod;
  final String? remoteAddress;
  final bool isTLS;
  final void Function() accept;
  final void Function([String? msg]) reject;

  const AuthInfo({
    required this.protocol,
    required this.username,
    required this.password,
    required this.authMethod,
    required this.remoteAddress,
    required this.isTLS,
    required this.accept,
    required this.reject,
  });
}

/// Payload emitted on the `'rateLimit'` event.
class RateLimitNotice {
  final String protocol; // smtp | imap | pop3
  final String? remoteAddress;
  final String? reason;
  final int? bannedUntil;

  const RateLimitNotice({
    required this.protocol,
    required this.remoteAddress,
    required this.reason,
    this.bannedUntil,
  });
}

/// State payload paired with a session facade for the `'smtpSession'` event.
class SmtpFacadeState {
  static const String protocol = 'smtp';
  final bool isSubmission;
  String? username;
  final String? remoteAddress;
  bool isTLS;

  SmtpFacadeState({
    required this.isSubmission,
    this.username,
    required this.remoteAddress,
    required this.isTLS,
  });
}

/// Payload emitted on the `'mailboxSession'` event for IMAP/POP3
/// authenticated sessions. Provides typed event hookup and notification
/// methods.
class MailboxFacade {
  final String protocol; // imap | pop3
  final String? username;
  final String? remoteAddress;
  final bool isTLS;
  final void Function(String, Function) on;
  final void Function(String, Function) off;
  final void Function(int total) notifyExists;
  final void Function(int count) notifyRecent;
  final void Function(int seq, int? uid) notifyExpunge;
  final void Function(VanishedSet arg) notifyVanished;
  final void Function(int seq, int? uid, List<String>? flags) notifyFlags;

  const MailboxFacade({
    required this.protocol,
    required this.username,
    required this.remoteAddress,
    required this.isTLS,
    required this.on,
    required this.off,
    required this.notifyExists,
    required this.notifyRecent,
    required this.notifyExpunge,
    required this.notifyVanished,
    required this.notifyFlags,
  });
}

class ServerContext {
  String hostname = 'localhost';
  ServerPorts ports = const ServerPorts();
  int maxSize = 25 * 1024 * 1024;
  int maxRecipients = 100;
  int acceptTimeout = 30000;
  RateLimiterConfig? rateLimit;
  int closeTimeout = 30000;

  bool useProxy = false;
  RelayOptions? relay;

  SniCallback? sniCallback;
  DkimCallback? dkimCallback;
  OnSecureCallback? onSecure;

  Map<String, DomainMaterial> domains = {};
  Map<String, SecurityContext> secureContexts = {};

  List<Object> servers = [];
  Map<Socket, ConnectionRecord> connections = {};

  int connectionCounter = 0;
  bool listening = false;

  OutboundPool? pool;
  RateLimiter? limiter;
}

class Server {
  final EventEmitter _ev = EventEmitter();
  final ServerContext context = ServerContext();

  Server([ServerOptions opts = const ServerOptions()]) {
    context.hostname = opts.hostname;
    context.ports = opts.ports;
    context.maxSize = opts.maxSize;
    context.maxRecipients = opts.maxRecipients;
    context.acceptTimeout = opts.acceptTimeout;
    context.rateLimit = opts.rateLimit;
    context.closeTimeout = opts.closeTimeout;

    context.useProxy = opts.useProxy;
    context.relay = opts.relay;

    context.sniCallback = opts.sniCallback;
    context.dkimCallback = opts.dkimCallback;
    context.onSecure = opts.onSecure;

    if (context.rateLimit != null) {
      context.limiter = RateLimiter(context.rateLimit!);
    }

    final basePool = opts.pool ?? PoolOptions();
    final poolOpts = PoolOptions(
      maxPerDomain: basePool.maxPerDomain,
      maxMessagesPerConn: basePool.maxMessagesPerConn,
      idleTimeout: basePool.idleTimeout,
      rateLimitPerMinute: basePool.rateLimitPerMinute,
      reconnectDelay: basePool.reconnectDelay,
      mxCacheTTL: basePool.mxCacheTTL,
      retryDelays: basePool.retryDelays,
      localHostname: context.hostname,
      ignoreTLS: basePool.ignoreTLS,
      timeout: basePool.timeout,
    );
    context.pool = OutboundPool(poolOpts);

    context.pool!.on('sent', (info) {
      _ev.emit('sent', info);
    });
    context.pool!.on('bounce', (info) {
      _ev.emit('bounce', info);
    });
    context.pool!.on('retry', (info) {
      _ev.emit('retry', info);
    });
  }

  void on(String name, Function fn) => _ev.on(name, fn);
  void off(String name, Function fn) => _ev.off(name, fn);

  bool get listening => context.listening;
  List<String> get domains => context.domains.keys.toList();

  void addDomain(DomainMaterial mat) {
    final domain = mat.domain;
    if (domain.isEmpty) throw ArgumentError('Invalid domain material');
    context.domains[domain] = mat;
    _ev.emit('domainAdded', domain);

    mat
        .verifyDNS()
        .then((results) {
          final warnings = <String>[];
          if (!results.dkim) warnings.add('DKIM record missing for $domain');
          if (!results.spf) warnings.add('SPF record missing for $domain');
          if (!results.dmarc) warnings.add('DMARC record missing for $domain');
          if (!results.mx) warnings.add('MX record missing for $domain');
          for (final w in warnings) {
            _ev.emit('dnsWarning', DnsWarning(domain: domain, message: w));
          }
        })
        .catchError((Object _) {});
  }

  bool removeDomain(String domain) {
    return context.domains.remove(domain) != null;
  }

  DomainMaterial? getDomainMaterial(String domain) {
    return context.domains[domain];
  }

  bool isDomainRegistered(String domain) {
    return context.domains.containsKey(domain);
  }

  Future<SecurityContext?> resolveTlsContext(String? servername) async {
    String key = (servername ?? '').toLowerCase();

    if (context.secureContexts.containsKey(key)) {
      return context.secureContexts[key];
    }

    final mat = getDomainMaterial(key);
    final tls = mat?.tls;
    if (tls != null && tls.key != null && tls.cert != null) {
      try {
        final ctx = SecurityContext();
        ctx.usePrivateKeyBytes(utf8.encode(tls.key!));
        ctx.useCertificateChainBytes(utf8.encode(tls.cert!));
        context.secureContexts[key] = ctx;
        return ctx;
      } catch (e) {
        return null;
      }
    }

    if (context.sniCallback != null) {
      Completer<SecurityContext?> completer = Completer();
      context.sniCallback!(servername, (err, ctx) {
        if (err != null)
          completer.completeError(err);
        else
          completer.complete(ctx);
      });
      return completer.future;
    }

    return null;
  }

  Future<dkim.DkimSignOptions?> resolveDkim(String domain) async {
    final mat = getDomainMaterial(domain);
    final dkimMat = mat?.dkim;
    if (dkimMat != null && dkimMat.privateKey != null) {
      return dkim.DkimSignOptions(
        domain: domain,
        selector: dkimMat.selector,
        algo: dkimMat.algo,
        privateKey: dkimMat.privateKey!,
      );
    }

    if (context.dkimCallback != null) {
      Completer<dkim.DkimSignOptions?> completer = Completer();
      context.dkimCallback!(domain, (err, opts) {
        if (err != null) {
          completer.completeError(err);
        } else {
          completer.complete(opts);
        }
      });
      return completer.future;
    }

    return null;
  }

  SMTPSession createSession(
    Socket socket,
    bool isSubmission,
    String? remoteAddress,
    String connId,
  ) {
    final hasTls =
        context.domains.values.any((d) => d.tls?.key != null) ||
        context.sniCallback != null;

    SMTPSession session = SMTPSession(
      SMTPSessionOptions(
        hostname: context.hostname,
        isSubmission: isSubmission,
        maxSize: context.maxSize,
        maxRecipients: context.maxRecipients,
        acceptTimeout: context.acceptTimeout,
        remoteAddress: remoteAddress,
        localAddress: socket.address.address,
        isTLS: false,
        tlsOptions: hasTls ? const {} : null,
        authMethods: const ['PLAIN', 'LOGIN', 'XOAUTH2'],
      ),
    );

    session.setParseMessage((raw) {
      return parseMessage(raw);
    });

    EventEmitter sessionFacade = EventEmitter();
    final facadeState = SmtpFacadeState(
      isSubmission: isSubmission,
      remoteAddress: remoteAddress,
      isTLS: session.isTLS,
    );

    session.on('send', (String data) {
      try {
        socket.add(toU8(data));
      } catch (e) {}
    });

    session.on('ehlo', (host) {});

    session.on('auth', (SmtpAuthRequest req) {
      late AuthInfo authInfo;
      authInfo = AuthInfo(
        protocol: 'smtp',
        username: req.username,
        password: req.password,
        authMethod: req.authMethod,
        remoteAddress: remoteAddress,
        isTLS: session.isTLS,
        accept: () {
          if (context.limiter != null && remoteAddress != null)
            context.limiter!.recordAuthSuccess(remoteAddress);
          facadeState.username = authInfo.username;
          _ev.emit('smtpSession', sessionFacade, facadeState);
          req.accept();
        },
        reject: ([String? msg]) {
          if (context.limiter != null && remoteAddress != null) {
            var r = context.limiter!.recordAuthFailure(remoteAddress);
            if (r.banned)
              _ev.emit(
                'rateLimit',
                RateLimitNotice(
                  protocol: 'smtp',
                  remoteAddress: remoteAddress,
                  reason: 'banned',
                  bannedUntil: r.bannedUntil,
                ),
              );
          }
          req.reject();
        },
      );

      _ev.emit('auth', authInfo);
    });

    session.on('message', (MailObject mail) {
      if (isSubmission) {
        sessionFacade.emit('mail', mail);
        Timer.run(() {
          mail.emitBody();
        });
      } else {
        bool dkimDone = false, spfDone = false, rdnsDone = false;

        void afterAllAuth() {
          if (!dkimDone || !spfDone || !rdnsDone) return;

          String fromDomain = '';
          if (mail.headerFrom != null) {
            Match? m = RegExp(r'@([^>,\s]+)').firstMatch(mail.headerFrom!);
            if (m != null) fromDomain = m.group(1)!.trim();
          }

          String spfDomain = '';
          if (mail.from != null) {
            var parts = mail.from!.split('@');
            if (parts.length > 1) spfDomain = parts[1];
          }

          checkDMARC(
                DmarcOptions(
                  fromDomain: fromDomain,
                  dkimResult: mail.auth.dkim,
                  dkimDomain: mail.auth.dkimDomain,
                  spfResult: mail.auth.spf,
                  spfDomain: spfDomain,
                ),
              )
              .then((dmarcResult) {
                mail.auth.dmarc = dmarcResult.result;
                mail.auth.dmarcPolicy = dmarcResult.policy;
                sessionFacade.emit('mail', mail);
                Timer.run(() {
                  mail.emitBody();
                });
              })
              .catchError((err) {
                mail.auth.dmarc = 'none';
                sessionFacade.emit('mail', mail);
                Timer.run(() {
                  mail.emitBody();
                });
              });
        }

        dkim
            .verify(mail.raw)
            .then((result) {
              mail.auth.dkim = result.result;
              mail.auth.dkimDomain = result.domain;
              dkimDone = true;
              afterAllAuth();
            })
            .catchError((err) {
              mail.auth.dkim = 'none';
              dkimDone = true;
              afterAllAuth();
            });

        String envelopeDomain = '';
        if (mail.from != null) {
          var parts = mail.from!.split('@');
          if (parts.length > 1) envelopeDomain = parts[1];
        }

        checkSPF(remoteAddress ?? '', envelopeDomain)
            .then((result) {
              mail.auth.spf = result.result;
              spfDone = true;
              afterAllAuth();
            })
            .catchError((err) {
              mail.auth.spf = 'none';
              spfDone = true;
              afterAllAuth();
            });

        checkFCrDNS(remoteAddress ?? '')
            .then((result) {
              mail.auth.rdns = result.result;
              mail.auth.rdnsHostname = result.hostname;
              rdnsDone = true;
              afterAllAuth();
            })
            .catchError((err) {
              mail.auth.rdns = 'none';
              rdnsDone = true;
              afterAllAuth();
            });
      }
    });

    session.on('starttls', () async {
      try {
        var defaultCtx = await resolveTlsContext(null);

        SecureSocket tlsSocket = await SecureSocket.secureServer(
          socket,
          defaultCtx!,
        );

        session.tlsUpgraded();
        facadeState.isTLS = true;

        tlsSocket.listen(
          (chunk) {
            session.feed(chunk);
          },
          onError: (err) {
            _ev.emit('tlsError', Exception('TLS handshake failed'));
            try {
              socket.destroy();
            } catch (e) {}
          },
        );
      } catch (err) {
        _ev.emit('tlsError', Exception('TLS handshake failed'));
        try {
          socket.destroy();
        } catch (e) {}
      }
    });

    session.on('close', () {
      try {
        socket.destroy();
      } catch (e) {}
      sessionFacade.emit('close');
    });

    if (!isSubmission) {
      _ev.emit('smtpSession', sessionFacade, facadeState);
    }

    return session;
  }

  void handleConnection(Socket socket, bool isSubmission) {
    String connId = '${(++context.connectionCounter).toRadixString(36)}-conn';
    String? remoteAddress = socket.remoteAddress.address;

    void startSession(String? finalRemoteAddress) {
      if (context.limiter != null && finalRemoteAddress != null) {
        var check = context.limiter!.canConnect(finalRemoteAddress);
        if (check.ok != true) {
          try {
            socket.add(toU8('421 4.7.0 Too many connections or banned\r\n'));
          } catch (e) {}
          try {
            socket.destroy();
          } catch (e) {}
          _ev.emit(
            'rateLimit',
            RateLimitNotice(
              protocol: 'smtp',
              remoteAddress: finalRemoteAddress,
              reason: check.reason,
            ),
          );
          return;
        }
        context.limiter!.recordConnection(finalRemoteAddress);
      }

      context.connections[socket] = ConnectionRecord(
        id: connId,
        protocol: 'smtp',
        remoteAddress: finalRemoteAddress,
      );

      final connInfo = ConnectionInfo(
        id: connId,
        protocol: 'smtp',
        remoteAddress: finalRemoteAddress,
      );

      _ev.emit('connection', connInfo);
      if (connInfo.rejected) {
        socket.destroy();
        context.connections.remove(socket);
        if (context.limiter != null && finalRemoteAddress != null)
          context.limiter!.releaseConnection(finalRemoteAddress);
        return;
      }

      var session = createSession(
        socket,
        isSubmission,
        finalRemoteAddress,
        connId,
      );

      socket.listen(
        (chunk) {
          session.feed(chunk);
        },
        onError: (e) {
          session.close();
        },
        onDone: () {
          session.close();
          context.connections.remove(socket);
          if (context.limiter != null && finalRemoteAddress != null)
            context.limiter!.releaseConnection(finalRemoteAddress);
        },
      );

      session.greet();
    }

    if (context.useProxy) {
      startSession(remoteAddress);
    } else {
      startSession(remoteAddress);
    }
  }

  void handleImapConnection(
    Socket socket,
    String? remoteAddress,
    String connId,
  ) {
    if (context.limiter != null && remoteAddress != null) {
      var check = context.limiter!.canConnect(remoteAddress);
      if (check.ok != true) {
        try {
          socket.add(toU8('* BYE Too many connections or banned\r\n'));
        } catch (e) {}
        try {
          socket.destroy();
        } catch (e) {}
        _ev.emit(
          'rateLimit',
          RateLimitNotice(
            protocol: 'imap',
            remoteAddress: remoteAddress,
            reason: check.reason,
          ),
        );
        return;
      }
      context.limiter!.recordConnection(remoteAddress);
    }

    final connInfo = ConnectionInfo(
      id: connId,
      protocol: 'imap',
      remoteAddress: remoteAddress,
    );
    _ev.emit('connection', connInfo);
    if (connInfo.rejected) {
      try {
        socket.destroy();
      } catch (e) {}
      if (context.limiter != null && remoteAddress != null)
        context.limiter!.releaseConnection(remoteAddress);
      return;
    }
    context.connections[socket] = ConnectionRecord(
      id: connId,
      protocol: 'imap',
      remoteAddress: remoteAddress,
    );

    final hasTls =
        context.domains.values.any((d) => d.tls?.key != null) ||
        context.sniCallback != null;

    IMAPSession imapSession = IMAPSession(
      IMAPSessionOptions(
        hostname: context.hostname,
        remoteAddress: remoteAddress,
        isTLS: false,
        tlsOptions: hasTls ? const {} : null,
      ),
    );

    imapSession.on('send', (dynamic data) {
      try {
        socket.add(toU8(data));
      } catch (e) {}
    });

    imapSession.on('imapAuth', (ImapAuthRequest authCtx) {
      late AuthInfo authInfo;
      authInfo = AuthInfo(
        protocol: 'imap',
        username: authCtx.username,
        password: authCtx.password,
        authMethod: authCtx.authMethod,
        remoteAddress: remoteAddress,
        isTLS: imapSession.isTLS,
        accept: () {
          if (context.limiter != null && remoteAddress != null)
            context.limiter!.recordAuthSuccess(remoteAddress);
          authCtx.accept();
          final mailbox = MailboxFacade(
            protocol: 'imap',
            username: authCtx.username,
            remoteAddress: remoteAddress,
            isTLS: imapSession.isTLS,
            on: authCtx.on,
            off: authCtx.off,
            notifyExists: imapSession.notifyExists,
            notifyRecent: imapSession.notifyRecent,
            notifyExpunge: imapSession.notifyExpunge,
            notifyVanished: imapSession.notifyVanished,
            notifyFlags: imapSession.notifyFlags,
          );
          _ev.emit('mailboxSession', mailbox);
        },
        reject: ([String? msg]) {
          if (context.limiter != null && remoteAddress != null) {
            var r = context.limiter!.recordAuthFailure(remoteAddress);
            if (r.banned)
              _ev.emit(
                'rateLimit',
                RateLimitNotice(
                  protocol: 'imap',
                  remoteAddress: remoteAddress,
                  reason: 'banned',
                  bannedUntil: r.bannedUntil,
                ),
              );
          }
          authCtx.reject(msg);
        },
      );

      _ev.emit('auth', authInfo);
    });

    imapSession.on('starttls', () async {
      try {
        var defaultCtx = await resolveTlsContext(null);
        SecureSocket tlsSocket = await SecureSocket.secureServer(
          socket,
          defaultCtx!,
        );
        imapSession.tlsUpgraded();
        tlsSocket.listen(
          (chunk) {
            imapSession.feed(chunk);
          },
          onError: (err) {
            _ev.emit('tlsError', Exception('TLS handshake failed'));
            try {
              socket.destroy();
            } catch (e) {}
          },
        );
      } catch (err) {
        _ev.emit('tlsError', Exception('TLS handshake failed'));
        try {
          socket.destroy();
        } catch (e) {}
      }
    });

    imapSession.on('close', () {
      // Use socket.close() (graceful TCP shutdown that flushes pending
      // writes) instead of destroy(), so the tagged BYE/OK bytes from
      // LOGOUT actually reach the client before EOF.
      try {
        socket.close();
      } catch (e) {}
    });

    socket.listen(
      (chunk) {
        imapSession.feed(chunk);
      },
      onError: (e) {
        imapSession.close();
      },
      onDone: () {
        imapSession.close();
        context.connections.remove(socket);
        if (context.limiter != null && remoteAddress != null)
          context.limiter!.releaseConnection(remoteAddress);
      },
    );

    imapSession.greet();
  }

  void handlePop3Connection(
    Socket socket,
    String? remoteAddress,
    String connId,
  ) {
    final connInfo = ConnectionInfo(
      id: connId,
      protocol: 'pop3',
      remoteAddress: remoteAddress,
    );
    _ev.emit('connection', connInfo);
    if (connInfo.rejected) {
      try {
        socket.destroy();
      } catch (e) {}
      return;
    }
    context.connections[socket] = ConnectionRecord(
      id: connId,
      protocol: 'pop3',
      remoteAddress: remoteAddress,
    );

    final hasTls =
        context.domains.values.any((d) => d.tls?.key != null) ||
        context.sniCallback != null;

    POP3Session pop3Session = POP3Session(
      POP3SessionOptions(
        hostname: context.hostname,
        remoteAddress: remoteAddress,
        isTLS: false,
        tlsOptions: hasTls ? const {} : null,
      ),
    );

    pop3Session.on('send', (dynamic data) {
      try {
        socket.add(toU8(data));
      } catch (e) {}
    });

    pop3Session.on('pop3Auth', (Pop3AuthRequest authCtx) {
      late AuthInfo authInfo;
      authInfo = AuthInfo(
        protocol: 'pop3',
        username: authCtx.username,
        password: authCtx.password,
        authMethod: authCtx.authMethod,
        remoteAddress: remoteAddress,
        isTLS: pop3Session.isTLS,
        accept: () {
          final mailbox = MailboxFacade(
            protocol: 'pop3',
            username: authCtx.username,
            remoteAddress: remoteAddress,
            isTLS: pop3Session.isTLS,
            on: authCtx.on,
            off: authCtx.off,
            notifyExists: (_) {},
            notifyRecent: (_) {},
            notifyExpunge: (_, __) {},
            notifyVanished: (_) {},
            notifyFlags: (_, __, ___) {},
          );
          _ev.emit('mailboxSession', mailbox);
          authCtx.accept();
        },
        reject: ([String? msg]) {
          authCtx.reject(msg);
        },
      );
      _ev.emit('auth', authInfo);
    });

    pop3Session.on('starttls', () async {
      try {
        var defaultCtx = await resolveTlsContext(null);
        SecureSocket tlsSocket = await SecureSocket.secureServer(
          socket,
          defaultCtx!,
        );
        pop3Session.tlsUpgraded();
        tlsSocket.listen(
          (chunk) {
            pop3Session.feed(chunk);
          },
          onError: (err) {
            _ev.emit('tlsError', Exception('TLS handshake failed'));
            try {
              socket.destroy();
            } catch (e) {}
          },
        );
      } catch (err) {
        _ev.emit('tlsError', Exception('TLS handshake failed'));
        try {
          socket.destroy();
        } catch (e) {}
      }
    });

    pop3Session.on('close', () {
      // Graceful close — flush pending writes (e.g. final +OK on QUIT).
      try {
        socket.close();
      } catch (e) {}
    });

    socket.listen(
      (chunk) {
        pop3Session.feed(chunk);
      },
      onError: (e) {
        pop3Session.close();
      },
      onDone: () {
        pop3Session.close();
        context.connections.remove(socket);
      },
    );

    pop3Session.greet();
  }

  Future<void> listen() async {
    final ports = context.ports;
    final tcpJobs = <int, void Function(Socket)>{};
    if (ports.inbound != null) {
      tcpJobs[ports.inbound!] = (s) => handleConnection(s, false);
    }
    if (ports.submission != null) {
      tcpJobs[ports.submission!] = (s) => handleConnection(s, true);
    }
    if (ports.imap != null) {
      tcpJobs[ports.imap!] = (s) {
        final connId =
            '${(++context.connectionCounter).toRadixString(36)}-conn';
        handleImapConnection(s, s.remoteAddress.address, connId);
      };
    }
    if (ports.pop3 != null) {
      tcpJobs[ports.pop3!] = (s) {
        final connId =
            '${(++context.connectionCounter).toRadixString(36)}-conn';
        handlePop3Connection(s, s.remoteAddress.address, connId);
      };
    }

    for (final entry in tcpJobs.entries) {
      try {
        final server = await ServerSocket.bind(
          InternetAddress.anyIPv4,
          entry.key,
        );
        context.servers.add(server);
        server.listen(entry.value);
      } catch (e) {
        _ev.emit('error', e);
      }
    }

    final tlsJobs = <int, void Function(SecureSocket)>{};
    if (ports.secure != null) {
      tlsJobs[ports.secure!] = (s) => handleConnection(s, true);
    }
    if (ports.imaps != null) {
      tlsJobs[ports.imaps!] = (s) {
        final connId =
            '${(++context.connectionCounter).toRadixString(36)}-conn';
        handleImapConnection(s, s.remoteAddress.address, connId);
      };
    }
    if (ports.pop3s != null) {
      tlsJobs[ports.pop3s!] = (s) {
        final connId =
            '${(++context.connectionCounter).toRadixString(36)}-conn';
        handlePop3Connection(s, s.remoteAddress.address, connId);
      };
    }

    if (tlsJobs.isNotEmpty) {
      final defaultCtx = await resolveTlsContext(null);
      if (defaultCtx != null) {
        for (final entry in tlsJobs.entries) {
          try {
            final tlsServer = await SecureServerSocket.bind(
              InternetAddress.anyIPv4,
              entry.key,
              defaultCtx,
            );
            context.servers.add(tlsServer);
            tlsServer.listen(entry.value);
          } catch (e) {
            _ev.emit('error', e);
          }
        }
      }
    }

    context.listening = true;
    _ev.emit('ready');
  }

  void close([Function? cb]) {
    if (context.pool != null) {
      context.pool!.closeAll();
    }

    if (context.servers.isEmpty && context.connections.isEmpty) {
      context.listening = false;
      if (cb != null) cb();
      return;
    }

    for (final server in context.servers) {
      try {
        if (server is ServerSocket) {
          server.close();
        } else if (server is SecureServerSocket) {
          server.close();
        }
      } catch (e) {}
    }
    context.servers.clear();

    context.connections.keys.forEach((socket) {
      try {
        socket.add(toU8('421 ${context.hostname} Server shutting down\r\n'));
      } catch (e) {}
    });

    Timer(Duration(milliseconds: context.closeTimeout), () {
      context.connections.keys.forEach((socket) {
        try {
          socket.destroy();
        } catch (e) {}
      });
      context.connections.clear();
      context.listening = false;
      if (cb != null) cb();
    });
  }

  /// Typed entry point. Prefer this over [send].
  void sendTyped(SendMailOptions options, [Function? cb]) {
    send(options.toLegacyMap().cast<String, dynamic>(), cb);
  }

  void send(Map<String, dynamic> options, [Function? cb]) {
    _ev.emit('sending', options);

    Map<String, dynamic>? useRelay = options['relay'] ?? context.relay;

    void composeAndSignWrapper(
      Function(Exception?, Uint8List?, String?) callback,
    ) {
      var composed = composeMessageTyped(
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
          replyTo: options['replyTo'],
          priority: options['priority'] as String?,
        ),
      );

      String fromDomain = '';
      String? fromAddr = extractAddress(options['from']);
      if (fromAddr != null) {
        var parts = fromAddr.split('@');
        if (parts.length > 1) fromDomain = parts[1];
      }

      if (fromDomain.isEmpty) {
        callback(null, composed.raw, composed.messageId);
        return;
      }

      resolveDkim(fromDomain)
          .then((dkimOptions) {
            if (dkimOptions == null) {
              callback(null, composed.raw, composed.messageId);
              return;
            }
            try {
              var signed = dkim.sign(composed.raw, dkimOptions);
              callback(null, signed.message, composed.messageId);
            } catch (e) {
              callback(null, composed.raw, composed.messageId);
            }
          })
          .catchError((err) {
            callback(null, composed.raw, composed.messageId);
          });
    }

    if (useRelay != null) {
      Map<String, dynamic> sendOptions = Map.from(options);
      sendOptions['relay'] = useRelay;
      sendOptions['localHostname'] = context.hostname;

      composeAndSignWrapper((err, raw, messageId) {
        if (err != null) {
          _ev.emit('sendError', err, options);
          if (cb != null) cb(err);
          return;
        }
        sendOptions['raw'] = raw;
        sendOptions['messageId'] = messageId;
        sendMailLegacyMap(sendOptions)
            .then((info) {
              _ev.emit('sent', info);
              if (cb != null) cb(null, info);
            })
            .catchError((e) {
              _ev.emit('sendError', e, options);
              if (cb != null) cb(e);
            });
      });
    } else {
      composeAndSignWrapper((err, raw, messageId) {
        if (err != null) {
          _ev.emit('sendError', err, options);
          if (cb != null) cb(err);
          return;
        }

        String? envFrom = extractAddress(options['from']);
        List<String> envToList = [];
        if (options['to'] != null)
          envToList.addAll(
            options['to'] is List
                ? List<String>.from(options['to'])
                : [options['to']],
          );
        if (options['cc'] != null)
          envToList.addAll(
            options['cc'] is List
                ? List<String>.from(options['cc'])
                : [options['cc']],
          );
        if (options['bcc'] != null)
          envToList.addAll(
            options['bcc'] is List
                ? List<String>.from(options['bcc'])
                : [options['bcc']],
          );

        List<String> envTo = extractAddressList(envToList);

        if (envFrom == null || envTo.isEmpty) {
          var e = Exception('Missing from or to');
          _ev.emit('sendError', e, options);
          if (cb != null) cb(e);
          return;
        }

        Map<String, List<String>> byDomain = {};
        for (int i = 0; i < envTo.length; i++) {
          var parts = envTo[i].split('@');
          String domain = parts.length > 1 ? parts[1] : '';
          if (byDomain[domain] == null) byDomain[domain] = [];
          byDomain[domain]!.add(envTo[i]);
        }

        List<String> doms = byDomain.keys.toList();
        for (int i = 0; i < doms.length; i++) {
          context.pool!.enqueue({
            'envFrom': envFrom,
            'envTo': byDomain[doms[i]]!,
            'raw': raw,
            'messageId': messageId,
            'cb': (i == doms.length - 1) ? cb : null,
          });
        }
      });
    }
  }

  /// Typed DSN sender. Prefer this over [sendDsn].
  void sendDsnTyped(DsnOptions dsn, [Function? cb]) {
    final raw = buildDsn(
      DsnOptions(
        reportingMta: dsn.reportingMta ?? context.hostname,
        to: dsn.to,
        from: dsn.from,
        originalEnvelopeId: dsn.originalEnvelopeId,
        originalMessage: dsn.originalMessage,
        recipients: dsn.recipients,
      ),
    );
    sendMailLegacyMap({
          'raw': raw,
          'from': '',
          'to': dsn.to,
          'pool': context.pool,
          'localHostname': context.hostname,
        })
        .then((info) {
          if (cb != null) cb(null, info);
        })
        .catchError((err) {
          if (cb != null) cb(err);
        });
  }

  void sendDsn(Map<String, dynamic> options, [Function? cb]) {
    options['reportingMta'] = context.hostname;
    Uint8List raw = buildDsn(
      DsnOptions(
        reportingMta: options['reportingMta']?.toString(),
        to: options['to']?.toString(),
        from: options['from']?.toString(),
        originalEnvelopeId: options['originalEnvelopeId']?.toString(),
        originalMessage: options['originalMessage'] is Uint8List
            ? options['originalMessage']
            : null,
        recipients: options['recipients'] is List<DsnRecipient>
            ? options['recipients'] as List<DsnRecipient>
            : null,
      ),
    );
    sendMailLegacyMap({
          'raw': raw,
          'from': '',
          'to': options['to'],
          'pool': context.pool,
          'localHostname': context.hostname,
        })
        .then((info) {
          if (cb != null) cb(null, info);
        })
        .catchError((err) {
          if (cb != null) cb(err);
        });
  }

  void clearTlsCache([String? servername]) {
    if (servername != null) {
      context.secureContexts.remove(servername.toLowerCase());
    } else {
      context.secureContexts.clear();
    }
  }
}

Server createServer([ServerOptions options = const ServerOptions()]) {
  return Server(options);
}
