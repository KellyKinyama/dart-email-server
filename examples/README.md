# Dart Email Server — Examples

Self-contained scripts demonstrating the public API. Run any of them with
`dart run examples/<file>.dart` from the project root.

> **Heads up:** several examples open real network sockets (port 25 for
> direct MX delivery, ports 25/587 for the SMTP server, etc.). Use a
> non-privileged port (`>1024`) on Windows or run with administrator
> privileges if you need the standard ports.

| File | What it shows |
|------|---------------|
| `compose_message.dart` | Build an RFC 5322 message in memory using `composeMessageTyped`, no networking. |
| `parse_smtp_reply.dart` | Use `parseReplyBlockTyped` to decode a multi-line EHLO response. |
| `build_dsn.dart` | Generate an RFC 3464 multipart/report Delivery Status Notification. |
| `build_domain_material.dart` | Generate the publishable MTA-STS policy and TLS-RPT DNS record for a domain. |
| `client_send_relay.dart` | Send a message through an authenticated SMTP relay (e.g. submission on 587). |
| `client_send_direct_mx.dart` | Direct-MX delivery: look up the recipient's MX and deliver without a relay. |
| `smtp_server.dart` | Run an inbound SMTP server on `localhost:2525`, log every incoming message. |
| `smtp_submission_server.dart` | Submission server that authenticates users and prints the message body. |
| `imap_server.dart` | Minimal IMAP server with a single in-memory mailbox. |
