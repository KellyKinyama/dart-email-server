import 'dart:async';

class RateLimiterConfig {
  final int maxConnectionsPerIp;
  final int maxAuthFailuresPerIp;
  final int authFailureWindow;
  final int banDuration;
  final int maxMessagesPerHourPerIp;
  final List<String> exemptIps;

  RateLimiterConfig({
    this.maxConnectionsPerIp = 0,
    this.maxAuthFailuresPerIp = 0,
    this.authFailureWindow = 300000,
    this.banDuration = 3600000,
    this.maxMessagesPerHourPerIp = 0,
    this.exemptIps = const [],
  });
}

class ConnectResult {
  final bool ok;
  final String? reason;
  final int? retryAfter;

  ConnectResult(this.ok, {this.reason, this.retryAfter});
}

class AuthFailureResult {
  final bool banned;
  final int? bannedUntil;
  final int? failuresInWindow;

  AuthFailureResult(this.banned, {this.bannedUntil, this.failuresInWindow});
}

class MessageResult {
  final bool ok;
  final String? reason;

  MessageResult(this.ok, {this.reason});
}

class SnapshotResult {
  final int connections;
  final int failuresInWindow;
  final int messagesInHour;
  final int bannedUntil;

  SnapshotResult(this.connections, this.failuresInWindow, this.messagesInHour, this.bannedUntil);
}

class _RateState {
  int connections = 0;
  List<int> failures = [];
  List<int> messages = [];
  int bannedUntil = 0;
}

class RateLimiter {
  final int maxConn;
  final int maxAuthFail;
  final int authWindow;
  final int banDuration;
  final int maxMsgPerHour;
  final int hourWindow = 60 * 60 * 1000;
  final Set<String> exemptSet;

  final Map<String, _RateState> _state = {};
  Timer? _gcTimer;

  RateLimiter(RateLimiterConfig config)
      : maxConn = config.maxConnectionsPerIp,
        maxAuthFail = config.maxAuthFailuresPerIp,
        authWindow = config.authFailureWindow,
        banDuration = config.banDuration,
        maxMsgPerHour = config.maxMessagesPerHourPerIp,
        exemptSet = Set.from(config.exemptIps) {
    int gcInterval = authWindow;
    if (hourWindow < gcInterval) gcInterval = hourWindow;
    gcInterval ~/= 2;
    if (gcInterval <= 0) gcInterval = 1000;
    _gcTimer = Timer.periodic(Duration(milliseconds: gcInterval), (_) => _gc());
  }

  _RateState _getEntry(String ip) {
    return _state.putIfAbsent(ip, () => _RateState());
  }

  void _maybeEvict(String ip, _RateState e) {
    if (e.connections > 0) return;
    if (e.failures.isNotEmpty) return;
    if (e.messages.isNotEmpty) return;
    if (e.bannedUntil > DateTime.now().millisecondsSinceEpoch) return;
    _state.remove(ip);
  }

  void _prune(_RateState e, int now) {
    if (e.failures.isNotEmpty) {
      int cutoff = now - authWindow;
      e.failures.removeWhere((t) => t < cutoff);
    }
    if (e.messages.isNotEmpty) {
      int cutoff = now - hourWindow;
      e.messages.removeWhere((t) => t < cutoff);
    }
  }

  bool _isExempt(String? ip) {
    return ip == null || exemptSet.contains(ip);
  }

  ConnectResult canConnect(String? ip) {
    if (_isExempt(ip)) return ConnectResult(true);
    var e = _state[ip!];
    int now = DateTime.now().millisecondsSinceEpoch;

    if (e != null && e.bannedUntil > now) {
      return ConnectResult(false, reason: 'banned', retryAfter: ((e.bannedUntil - now) / 1000).ceil());
    }
    if (maxConn > 0 && e != null && e.connections >= maxConn) {
      return ConnectResult(false, reason: 'too_many_connections');
    }
    return ConnectResult(true);
  }

  void recordConnection(String? ip) {
    if (_isExempt(ip)) return;
    _getEntry(ip!).connections++;
  }

  void releaseConnection(String? ip) {
    if (_isExempt(ip)) return;
    var e = _state[ip!];
    if (e == null) return;
    if (e.connections > 0) e.connections--;
    _maybeEvict(ip, e);
  }

  AuthFailureResult recordAuthFailure(String? ip) {
    if (_isExempt(ip)) return AuthFailureResult(false);
    if (maxAuthFail == 0) return AuthFailureResult(false);

    var e = _getEntry(ip!);
    int now = DateTime.now().millisecondsSinceEpoch;
    _prune(e, now);
    e.failures.add(now);

    if (e.failures.length >= maxAuthFail) {
      e.bannedUntil = now + banDuration;
      e.failures.clear(); // fresh ban resets counter
      return AuthFailureResult(true, bannedUntil: e.bannedUntil);
    }
    return AuthFailureResult(false, failuresInWindow: e.failures.length);
  }

  void recordAuthSuccess(String? ip) {
    if (_isExempt(ip)) return;
    var e = _state[ip!];
    if (e == null) return;
    if (e.failures.isNotEmpty) e.failures.clear();
    _maybeEvict(ip, e);
  }

  MessageResult canAcceptMessage(String? ip) {
    if (_isExempt(ip)) return MessageResult(true);
    if (maxMsgPerHour == 0) return MessageResult(true);
    var e = _state[ip!];
    if (e == null) return MessageResult(true);
    int now = DateTime.now().millisecondsSinceEpoch;
    _prune(e, now);
    if (e.messages.length >= maxMsgPerHour) {
      return MessageResult(false, reason: 'hourly_message_cap');
    }
    return MessageResult(true);
  }

  void recordMessage(String? ip) {
    if (_isExempt(ip)) return;
    if (maxMsgPerHour == 0) return;
    var e = _getEntry(ip!);
    int now = DateTime.now().millisecondsSinceEpoch;
    _prune(e, now);
    e.messages.add(now);
  }

  void ban(String? ip, [int? durationMs]) {
    if (ip == null) return;
    var e = _getEntry(ip);
    int now = DateTime.now().millisecondsSinceEpoch;
    e.bannedUntil = now + (durationMs ?? banDuration);
  }

  void unban(String? ip) {
    if (ip == null) return;
    var e = _state[ip];
    if (e == null) return;
    e.bannedUntil = 0;
    e.failures.clear();
    _maybeEvict(ip, e);
  }

  void _gc() {
    int now = DateTime.now().millisecondsSinceEpoch;
    List<String> dead = [];
    _state.forEach((ip, e) {
      _prune(e, now);
      if (e.bannedUntil != 0 && e.bannedUntil <= now) e.bannedUntil = 0;
      if (e.connections == 0 && e.failures.isEmpty && e.messages.isEmpty && e.bannedUntil == 0) {
        dead.add(ip);
      }
    });
    for (var ip in dead) {
      _state.remove(ip);
    }
  }

  void close() {
    _gcTimer?.cancel();
    _gcTimer = null;
    _state.clear();
  }

  SnapshotResult? snapshot(String? ip) {
    if (ip == null) return null;
    var e = _state[ip];
    if (e == null) return null;
    return SnapshotResult(
      e.connections,
      e.failures.length,
      e.messages.length,
      e.bannedUntil > DateTime.now().millisecondsSinceEpoch ? e.bannedUntil : 0
    );
  }
}

RateLimiter createRateLimiter([Map<String, dynamic>? config]) {
  config ??= {};
  return RateLimiter(RateLimiterConfig(
    maxConnectionsPerIp: config['maxConnectionsPerIp'] ?? 0,
    maxAuthFailuresPerIp: config['maxAuthFailuresPerIp'] ?? 0,
    authFailureWindow: config['authFailureWindow'] ?? 300000,
    banDuration: config['banDuration'] ?? 3600000,
    maxMessagesPerHourPerIp: config['maxMessagesPerHourPerIp'] ?? 0,
    exemptIps: (config['exemptIps'] as List<dynamic>?)?.cast<String>() ?? const [],
  ));
}
