import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

// ============================================================================
//  dsn.dart — Delivery Status Notifications (RFC 3461 / 3464)
// ============================================================================

final Random _rnd = Random.secure();

String _randomHex(int length) {
  var bytes = Uint8List(length);
  for (int i = 0; i < length; i++) {
    bytes[i] = _rnd.nextInt(256);
  }
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

class DsnRecipient {
  final String finalRecipient;
  final String? originalRecipient;
  final String? action;
  final String? status;
  final String? diagnostic;
  final String? remoteMta;
  final DateTime? lastAttempt;
  final DateTime? willRetryUntil;

  DsnRecipient({
    required this.finalRecipient,
    this.originalRecipient,
    this.action,
    this.status,
    this.diagnostic,
    this.remoteMta,
    this.lastAttempt,
    this.willRetryUntil,
  });
}

class DsnOptions {
  final String? reportingMta;
  final String? originalEnvelopeId;
  final DateTime? arrivalDate;
  final Uint8List? originalMessage;
  final String? returnContent;
  final List<DsnRecipient>? recipients;
  final String? from;
  final String? to;

  DsnOptions({
    this.reportingMta,
    this.originalEnvelopeId,
    this.arrivalDate,
    this.originalMessage,
    this.returnContent,
    this.recipients,
    this.from,
    this.to,
  });
}

Uint8List buildDsn(DsnOptions options) {
  String reportingMta = options.reportingMta ?? 'localhost';
  String from = options.from ?? 'postmaster@$reportingMta';
  String to = options.to ?? '';
  String arrival = options.arrivalDate != null
      ? formatDate(options.arrivalDate!)
      : formatDate(DateTime.now());
  Uint8List originalMsg = options.originalMessage ?? Uint8List(0);
  String returnContent = (options.returnContent ?? 'headers').toLowerCase();
  List<DsnRecipient> recipients = options.recipients ?? [];

  String overall = 'delivered';
  for (var r in recipients) {
    if (r.action == 'failed') {
      overall = 'failed';
      break;
    }
    if (r.action == 'delayed') overall = 'delayed';
  }

  String subject = overall == 'failed'
      ? 'Undelivered Mail Returned to Sender'
      : overall == 'delayed'
      ? 'Delivery Status Notification (Delay)'
      : 'Delivery Status Notification';

  String boundary = '=_dsn_${_randomHex(12)}';

  StringBuffer outBuf = StringBuffer();
  outBuf.write('From: $from\r\n');
  outBuf.write('To: $to\r\n');
  outBuf.write('Subject: $subject\r\n');
  outBuf.write('Date: ${formatDate(DateTime.now())}\r\n');
  outBuf.write('Message-ID: <dsn-${_randomHex(8)}@$reportingMta>\r\n');
  outBuf.write('MIME-Version: 1.0\r\n');
  outBuf.write(
    'Content-Type: multipart/report; report-type=delivery-status;\r\n',
  );
  outBuf.write(' boundary="$boundary"\r\n');
  outBuf.write('Auto-Submitted: auto-replied\r\n');
  outBuf.write('\r\n');
  outBuf.write('This is a MIME-formatted delivery status notification.\r\n');

  outBuf.write('\r\n--$boundary\r\n');
  outBuf.write('Content-Type: text/plain; charset=utf-8\r\n');
  outBuf.write('Content-Transfer-Encoding: 8bit\r\n');
  outBuf.write('\r\n');
  outBuf.write(_humanReadable(recipients, overall, reportingMta));

  outBuf.write('\r\n--$boundary\r\n');
  outBuf.write('Content-Type: message/delivery-status\r\n');
  outBuf.write('\r\n');
  outBuf.write(
    _deliveryStatusBlock(
      reportingMta,
      options.originalEnvelopeId,
      arrival,
      recipients,
    ),
  );

  outBuf.write('\r\n--$boundary\r\n');
  if (returnContent == 'full') {
    outBuf.write('Content-Type: message/rfc822\r\n');
    outBuf.write('\r\n');
    var hdr = utf8.encode(outBuf.toString());
    var footer = utf8.encode('\r\n--$boundary--\r\n');
    var b = BytesBuilder();
    b.add(hdr);
    b.add(originalMsg);
    b.add(footer);
    return b.toBytes();
  } else {
    outBuf.write('Content-Type: message/rfc822-headers\r\n');
    outBuf.write('\r\n');
    outBuf.write(_extractHeaders(originalMsg));
    outBuf.write('\r\n--$boundary--\r\n');
    return Uint8List.fromList(utf8.encode(outBuf.toString()));
  }
}

String _humanReadable(
  List<DsnRecipient> recipients,
  String overall,
  String mta,
) {
  StringBuffer s = StringBuffer();
  if (overall == 'failed') {
    s.write('This message was not delivered.\r\n\r\n');
  } else if (overall == 'delayed') {
    s.write('This message has been delayed.\r\n');
    s.write('The server will continue trying to deliver it.\r\n\r\n');
  } else {
    s.write('This is a delivery status notification.\r\n\r\n');
  }
  s.write('Reporting-MTA: $mta\r\n\r\n');

  for (var r in recipients) {
    s.write('-- Recipient: ${r.finalRecipient}\r\n');
    s.write('   Action:   ${r.action ?? 'failed'}\r\n');
    if (r.status != null) s.write('   Status:   ${r.status}\r\n');
    if (r.diagnostic != null) s.write('   Reason:   ${r.diagnostic}\r\n');
    if (r.remoteMta != null) s.write('   Remote:   ${r.remoteMta}\r\n');
    if (r.willRetryUntil != null)
      s.write('   Retry until: ${formatDate(r.willRetryUntil!)}\r\n');
    s.write('\r\n');
  }
  return s.toString();
}

String _deliveryStatusBlock(
  String mta,
  String? envid,
  String? arrival,
  List<DsnRecipient> recipients,
) {
  StringBuffer s = StringBuffer();
  s.write('Reporting-MTA: dns; $mta\r\n');
  if (envid != null) s.write('Original-Envelope-Id: $envid\r\n');
  if (arrival != null) s.write('Arrival-Date: $arrival\r\n');

  if (recipients.isEmpty) {
    s.write(
      '\r\nFinal-Recipient: rfc822; unknown\r\nAction: failed\r\nStatus: 5.0.0\r\n',
    );
    return s.toString();
  }

  for (var r in recipients) {
    s.write('\r\n');
    if (r.originalRecipient != null) {
      s.write('Original-Recipient: rfc822; ${r.originalRecipient}\r\n');
    }
    s.write(
      'Final-Recipient: rfc822; ${r.finalRecipient.isEmpty ? 'unknown' : r.finalRecipient}\r\n',
    );
    s.write('Action: ${r.action ?? 'failed'}\r\n');
    s.write('Status: ${r.status ?? '5.0.0'}\r\n');
    if (r.remoteMta != null) s.write('Remote-MTA: dns; ${r.remoteMta}\r\n');
    if (r.diagnostic != null)
      s.write('Diagnostic-Code: smtp; ${r.diagnostic}\r\n');
    if (r.lastAttempt != null)
      s.write('Last-Attempt-Date: ${formatDate(r.lastAttempt!)}\r\n');
    if (r.willRetryUntil != null)
      s.write('Will-Retry-Until: ${formatDate(r.willRetryUntil!)}\r\n');
  }
  return s.toString();
}

String _extractHeaders(Uint8List? raw) {
  if (raw == null || raw.isEmpty) return '';
  String s;
  try {
    s = utf8.decode(raw);
  } catch (_) {
    s = String.fromCharCodes(raw);
  }
  int end = s.indexOf('\r\n\r\n');
  if (end < 0) return s;
  return s.substring(0, end + 2);
}

// RFC 5322 date formatting for Dart
String formatDate(DateTime d) {
  DateTime dt = d.toUtc();

  // Example: Wed, 22 Apr 2026 15:00:00 +0000
  const List<String> days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const List<String> months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  String day = days[dt.weekday - 1];
  String date = dt.day.toString().padLeft(2, '0');
  String month = months[dt.month - 1];
  String year = dt.year.toString();
  String hour = dt.hour.toString().padLeft(2, '0');
  String min = dt.minute.toString().padLeft(2, '0');
  String sec = dt.second.toString().padLeft(2, '0');

  return '$day, $date $month $year $hour:$min:$sec +0000';
}
