import 'dart:async';
import 'dart:typed_data';
import 'smtp_client.dart';
import 'dns_cache.dart' as dns_cache;

class PoolOptions {
  final int maxPerDomain;
  final int maxMessagesPerConn;
  final int idleTimeout;
  final int rateLimitPerMinute;
  final int reconnectDelay;
  final int mxCacheTTL;
  final List<int> retryDelays;
  final String localHostname;
  final bool ignoreTLS;
  final int timeout;

  PoolOptions({
    this.maxPerDomain = 3,
    this.maxMessagesPerConn = 100,
    this.idleTimeout = 30000,
    this.rateLimitPerMinute = 60,
    this.reconnectDelay = 1000,
    this.mxCacheTTL = 300000,
    this.retryDelays = const [60000, 300000, 1800000, 7200000, 14400000],
    this.localHostname = 'localhost',
    this.ignoreTLS = false,
    this.timeout = 30000,
  });
}

typedef EvCallback = void Function(Map<String, dynamic> event);

class _EventEmitter {
  final Map<String, List<EvCallback>> _listeners = {};

  void on(String event, EvCallback cb) {
    _listeners.putIfAbsent(event, () => []).add(cb);
  }

  void off(String event, EvCallback cb) {
    _listeners[event]?.remove(cb);
  }

  void emit(String event, Map<String, dynamic> data) {
    if (_listeners.containsKey(event)) {
      for (var cb in _listeners[event]!) {
        cb(data);
      }
    }
  }
}

class PoolEntry {
  SMTPConnectionWrapper? conn;
  bool busy;
  int messageCount;
  Timer? idleTimer;
  bool alive;
  String mx;

  PoolEntry({
    required this.conn,
    this.busy = false,
    this.messageCount = 0,
    this.idleTimer,
    this.alive = true,
    required this.mx,
  });
}

/// Outcome reported to a [PoolMessage] callback on success.
class PoolDeliveryInfo {
  final String? messageId;
  final List<String> accepted;
  final List<String> rejected;
  final String mx;
  const PoolDeliveryInfo({
    required this.messageId,
    required this.accepted,
    required this.rejected,
    required this.mx,
  });
}

/// Callback signature for completed pool deliveries.
typedef PoolMessageCallback =
    void Function(Object? error, [PoolDeliveryInfo? info]);

class PoolMessage {
  int id;
  String envFrom;
  List<String> envTo;
  Uint8List raw;
  String? messageId;
  PoolMessageCallback? cb;
  int attempts;
  int nextRetry;

  PoolMessage({
    required this.id,
    required this.envFrom,
    required this.envTo,
    required this.raw,
    this.messageId,
    this.cb,
    this.attempts = 0,
    this.nextRetry = 0,
  });
}

class PoolStats {
  int lastConnectTime = 0;
  int lastDisconnectTime = 0;
  int activeConnections = 0;
  int sentThisMinute = 0;
  int minuteStart = DateTime.now().millisecondsSinceEpoch;
  int backoffUntil = 0;
}

class DomainPool {
  String domain;
  List<PoolEntry> connections = [];
  List<PoolMessage> pending = [];
  PoolStats stats = PoolStats();

  DomainPool({required this.domain});
}

class OutboundPool {
  final PoolOptions settings;
  final Map<String, DomainPool> _pools = {};
  Timer? _schedulerTimer;
  bool _running = false;
  final _EventEmitter _ev = _EventEmitter();
  int _messageIdCounter = 0;

  OutboundPool([PoolOptions? options]) : settings = options ?? PoolOptions();

  void on(String name, EvCallback fn) => _ev.on(name, fn);
  void off(String name, EvCallback fn) => _ev.off(name, fn);

  int get poolCount => _pools.length;

  Future<List<dns_cache.MxDnsRecord>> _getMX(String domain) async {
    try {
      var records = await dns_cache.mxRecords(domain);
      if (records.isEmpty) {
        return [dns_cache.MxDnsRecord(exchange: domain, priority: 10)];
      }
      final sorted = List<dns_cache.MxDnsRecord>.from(records)
        ..sort((a, b) => a.priority.compareTo(b.priority));
      return sorted;
    } catch (_) {
      return [dns_cache.MxDnsRecord(exchange: domain, priority: 10)];
    }
  }

  DomainPool _getPool(String domain) {
    return _pools.putIfAbsent(domain, () => DomainPool(domain: domain));
  }

  void _cleanPool(String domain) {
    var pool = _pools[domain];
    if (pool == null) return;
    if (pool.connections.isEmpty && pool.pending.isEmpty) {
      _pools.remove(domain);
      dns_cache.removeFromCache(domain);
    }
  }

  bool _canSendNow(DomainPool pool) {
    var stats = pool.stats;
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now < stats.backoffUntil) return false;
    if (now - stats.minuteStart > 60000) {
      stats.sentThisMinute = 0;
      stats.minuteStart = now;
    }
    if (stats.sentThisMinute >= settings.rateLimitPerMinute) return false;
    return true;
  }

  bool _canOpenConnection(DomainPool pool) {
    var stats = pool.stats;
    int now = DateTime.now().millisecondsSinceEpoch;
    if (stats.activeConnections >= settings.maxPerDomain) return false;
    if (stats.lastDisconnectTime > 0 &&
        now - stats.lastDisconnectTime < settings.reconnectDelay)
      return false;
    if (now < stats.backoffUntil) return false;
    return true;
  }

  void _openConnection(
    DomainPool pool,
    void Function(Exception?, PoolEntry?) cb,
  ) {
    String domain = pool.domain;
    pool.stats.lastConnectTime = DateTime.now().millisecondsSinceEpoch;
    pool.stats.activeConnections++;

    _getMX(domain).then((mxRecords) {
      int mxIndex = 0;

      void tryNextMX() {
        if (mxIndex >= mxRecords.length) {
          pool.stats.activeConnections--;
          cb(Exception('All MX failed for $domain'), null);
          return;
        }

        var mx = mxRecords[mxIndex++];

        SMTPConnection(
              SmtpClientOptions(
                host: mx.exchange,
                port: 25,
                localHostname: settings.localHostname,
                timeout: settings.timeout,
                ignoreTLS: settings.ignoreTLS,
              ),
            )
            .then((conn) {
              var entry = PoolEntry(
                conn: conn,
                busy: false,
                messageCount: 0,
                mx: mx.exchange,
              );
              pool.connections.add(entry);
              cb(null, entry);
            })
            .catchError((err) {
              tryNextMX();
            });
      }

      tryNextMX();
    });
  }

  void _closeConnection(DomainPool pool, PoolEntry entry) {
    entry.alive = false;
    if (entry.idleTimer != null) {
      entry.idleTimer!.cancel();
      entry.idleTimer = null;
    }
    try {
      entry.conn?.quit();
    } catch (_) {}
    pool.connections.remove(entry);
    pool.stats.activeConnections--;
    pool.stats.lastDisconnectTime = DateTime.now().millisecondsSinceEpoch;
    _cleanPool(pool.domain);
  }

  void _startIdleTimer(DomainPool pool, PoolEntry entry) {
    if (entry.idleTimer != null) entry.idleTimer!.cancel();
    entry.idleTimer = Timer(Duration(milliseconds: settings.idleTimeout), () {
      _closeConnection(pool, entry);
    });
  }

  void _checkConnectionHealth(PoolEntry entry, void Function(bool) cb) {
    try {
      entry.conn!.sendLine('NOOP');
      entry.conn!.readReply((reply) {
        cb(reply.code == 250);
      });
    } catch (_) {
      cb(false);
    }
  }

  void _sendMessage(DomainPool pool, PoolEntry entry, PoolMessage msg) {
    entry.busy = true;
    if (entry.idleTimer != null) {
      entry.idleTimer!.cancel();
      entry.idleTimer = null;
    }

    entry.conn!.mailFrom(msg.envFrom, MailFromParams(size: msg.raw.length), (
      err,
    ) {
      if (err != null) {
        entry.busy = false;
        _handleSendError(pool, entry, msg, err);
        return;
      }

      List<String> accepted = [];
      List<String> rejected = [];
      int rcptIdx = 0;

      void nextRcpt() {
        if (rcptIdx >= msg.envTo.length) {
          if (accepted.isEmpty) {
            entry.busy = false;
            var error = Exception('All recipients rejected');
            _finishMessage(pool, entry, msg, error, null, permanent: true);
            return;
          }

          entry.conn!.data(msg.raw, (err, [reply]) {
            entry.busy = false;
            entry.messageCount++;
            pool.stats.sentThisMinute++;

            if (err != null) {
              _handleSendError(pool, entry, msg, err);
            } else {
              _finishMessage(
                pool,
                entry,
                msg,
                null,
                PoolDeliveryInfo(
                  messageId: msg.messageId,
                  accepted: accepted,
                  rejected: rejected,
                  mx: entry.mx,
                ),
              );
            }
          });
          return;
        }

        entry.conn!.rcptTo(msg.envTo[rcptIdx], (err) {
          if (err != null)
            rejected.add(msg.envTo[rcptIdx]);
          else
            accepted.add(msg.envTo[rcptIdx]);
          rcptIdx++;
          nextRcpt();
        });
      }

      nextRcpt();
    });
  }

  void _finishMessage(
    DomainPool pool,
    PoolEntry entry,
    PoolMessage msg,
    Exception? err,
    PoolDeliveryInfo? info, {
    bool permanent = false,
  }) {
    if (err != null) {
      List<int> retryDelays = settings.retryDelays;
      bool retryable = !permanent && msg.attempts < retryDelays.length;

      if (retryable) {
        msg.attempts++;
        msg.nextRetry =
            DateTime.now().millisecondsSinceEpoch +
            retryDelays[msg.attempts - 1];
        pool.pending.add(msg);
        _ev.emit('retry', {
          'id': msg.id,
          'attempts': msg.attempts,
          'error': err.toString(),
          'nextRetry': msg.nextRetry,
        });
      } else {
        if (msg.cb != null) msg.cb!(err);
        _ev.emit('bounce', {
          'id': msg.id,
          'from': msg.envFrom,
          'to': msg.envTo,
          'error': err.toString(),
        });
      }
    } else {
      if (msg.cb != null) msg.cb!(null, info);
      _ev.emit('sent', {
        'id': msg.id,
        'messageId': msg.messageId,
        'accepted': info!.accepted,
        'mx': info.mx,
      });
    }

    _afterMessageSent(pool, entry);
  }

  void _handleSendError(
    DomainPool pool,
    PoolEntry entry,
    PoolMessage msg,
    dynamic err,
  ) {
    int code = 0;
    var m = RegExp(r'(\d{3})').firstMatch(err.toString());
    if (m != null) code = int.parse(m.group(1)!);

    if (code == 421) {
      pool.stats.backoffUntil =
          DateTime.now().millisecondsSinceEpoch + settings.reconnectDelay * 10;
      _closeConnection(pool, entry);
      _finishMessage(pool, entry, msg, err, null, permanent: false);
      return;
    }

    if (code >= 500 && code < 600) {
      _finishMessage(pool, entry, msg, err, null, permanent: true);
      _afterMessageSent(pool, entry);
      return;
    }

    _finishMessage(pool, entry, msg, err, null, permanent: false);
    _afterMessageSent(pool, entry);
  }

  void _afterMessageSent(DomainPool pool, PoolEntry entry) {
    if (!entry.alive) return;

    if (entry.messageCount >= settings.maxMessagesPerConn) {
      _closeConnection(pool, entry);
      return;
    }

    var next = _pickNextMessage(pool);
    if (next != null) {
      try {
        entry.conn!.sendLine('RSET');
        entry.conn!.readReply((reply) {
          if (reply.code == 250) {
            _sendMessage(pool, entry, next);
          } else {
            _closeConnection(pool, entry);
            pool.pending.insert(0, next);
          }
        });
      } catch (_) {
        _closeConnection(pool, entry);
        pool.pending.insert(0, next);
      }
    } else {
      entry.busy = false;
      _startIdleTimer(pool, entry);
    }
  }

  PoolMessage? _pickNextMessage(DomainPool pool) {
    int now = DateTime.now().millisecondsSinceEpoch;
    for (int i = 0; i < pool.pending.length; i++) {
      if (pool.pending[i].nextRetry <= now) {
        return pool.pending.removeAt(i);
      }
    }
    return null;
  }

  void schedule() {
    bool hasPending = false;
    for (var pool in _pools.values) {
      if (pool.pending.isEmpty) continue;
      hasPending = true;
      if (!_canSendNow(pool)) continue;

      PoolEntry? idleEntry;
      for (var conn in pool.connections) {
        if (!conn.busy && conn.alive) {
          idleEntry = conn;
          break;
        }
      }

      var msg = _pickNextMessage(pool);
      if (msg == null) continue;

      if (idleEntry != null) {
        if (idleEntry.idleTimer != null) {
          idleEntry.idleTimer!.cancel();
          idleEntry.idleTimer = null;
        }

        _checkConnectionHealth(idleEntry, (alive) {
          if (alive) {
            try {
              idleEntry!.conn!.sendLine('RSET');
              idleEntry.conn!.readReply((reply) {
                if (reply.code == 250) {
                  _sendMessage(pool, idleEntry!, msg);
                } else {
                  _closeConnection(pool, idleEntry!);
                  pool.pending.insert(0, msg);
                }
              });
            } catch (_) {
              _closeConnection(pool, idleEntry!);
              pool.pending.insert(0, msg);
            }
          } else {
            _closeConnection(pool, idleEntry!);
            pool.pending.insert(0, msg);
          }
        });
      } else if (_canOpenConnection(pool)) {
        _openConnection(pool, (err, entry) {
          if (err != null) {
            pool.pending.insert(0, msg);
            return;
          }
          _sendMessage(pool, entry!, msg);
        });
      } else {
        pool.pending.insert(0, msg);
      }
    }

    if (!hasPending && _schedulerTimer != null) {
      stopScheduler();
    }
  }

  void startScheduler() {
    if (_schedulerTimer != null) return;
    _running = true;
    _schedulerTimer = Timer.periodic(
      Duration(milliseconds: 1000),
      (_) => schedule(),
    );
  }

  void stopScheduler() {
    _running = false;
    _schedulerTimer?.cancel();
    _schedulerTimer = null;
  }

  /// Typed enqueue. Prefer this over [enqueue].
  int enqueueTyped({
    required String envFrom,
    required List<String> envTo,
    required Uint8List raw,
    String? messageId,
    PoolMessageCallback? cb,
  }) {
    String domain = '';
    if (envTo.isNotEmpty) {
      var parts = envTo[0].split('@');
      if (parts.length > 1) domain = parts[1];
    }

    var pool = _getPool(domain);
    var entry = PoolMessage(
      id: ++_messageIdCounter,
      envFrom: envFrom,
      envTo: envTo,
      raw: raw,
      messageId: messageId,
      cb: cb,
      attempts: 0,
      nextRetry: 0,
    );

    pool.pending.add(entry);

    if (!_running) startScheduler();
    schedule();

    return entry.id;
  }

  int enqueue(Map<String, dynamic> msg) {
    final raw = msg['raw'];
    final Uint8List rawU8 = raw is Uint8List
        ? raw
        : (raw is List<int>
              ? Uint8List.fromList(raw)
              : Uint8List.fromList(raw.toString().codeUnits));
    final rawCb = msg['cb'];
    PoolMessageCallback? typedCb;
    if (rawCb is PoolMessageCallback) {
      typedCb = rawCb;
    } else if (rawCb is Function) {
      typedCb = (Object? error, [PoolDeliveryInfo? info]) {
        if (error != null) {
          Function.apply(rawCb, [error]);
        } else {
          Function.apply(rawCb, [
            null,
            {
              'messageId': info?.messageId,
              'accepted': info?.accepted,
              'rejected': info?.rejected,
              'mx': info?.mx,
            },
          ]);
        }
      };
    }
    return enqueueTyped(
      envFrom: (msg['envFrom'] as String?) ?? '',
      envTo: (msg['envTo'] as List).cast<String>(),
      raw: rawU8,
      messageId: msg['messageId'] as String?,
      cb: typedCb,
    );
  }

  void closeAll([void Function()? cb]) {
    stopScheduler();

    for (var pool in _pools.values) {
      for (var msg in pool.pending) {
        if (msg.cb != null) msg.cb!(Exception('Pool shutting down'));
      }
      pool.pending.clear();

      for (var conn in List.from(pool.connections)) {
        _closeConnection(pool, conn);
      }
    }

    _pools.clear();
    if (cb != null) cb();
  }

  Map<String, dynamic> getStats() {
    var stats = <String, dynamic>{};
    for (var pool in _pools.values) {
      stats[pool.domain] = {
        'connections': pool.connections.length,
        'busy': pool.connections.where((c) => c.busy).length,
        'pending': pool.pending.length,
        'sentThisMinute': pool.stats.sentThisMinute,
        'backoffUntil':
            pool.stats.backoffUntil > DateTime.now().millisecondsSinceEpoch
            ? pool.stats.backoffUntil
            : null,
      };
    }
    return stats;
  }
}
