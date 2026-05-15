<?php

/*
|--------------------------------------------------------------------------
| dart_email_server connection settings
|--------------------------------------------------------------------------
|
| Used by app/Services/* and app/Http/Controllers/* to talk to a running
| dart_email_server instance. Override any value via the matching
| DART_MAIL_* env variable.
|
*/

return [

    // SMTP submission (587) — outbound relay through dart_email_server.
    // Laravel's MAIL_* env vars control the actual transport; this block
    // mirrors them so the UI can show what it is using.
    'smtp' => [
        'host'       => env('DART_MAIL_SMTP_HOST', env('MAIL_HOST', '127.0.0.1')),
        'port'       => (int) env('DART_MAIL_SMTP_PORT', env('MAIL_PORT', 587)),
        'username'   => env('DART_MAIL_SMTP_USER', env('MAIL_USERNAME')),
        'password'   => env('DART_MAIL_SMTP_PASS', env('MAIL_PASSWORD')),
        'encryption' => env('DART_MAIL_SMTP_ENC', env('MAIL_ENCRYPTION', 'tls')),
        'from'       => [
            'address' => env('MAIL_FROM_ADDRESS', 'demo@example.com'),
            'name'    => env('MAIL_FROM_NAME', 'Demo'),
        ],
    ],

    // IMAP retrieval. Defaults match examples/imap_server.dart.
    'imap' => [
        'host'           => env('DART_MAIL_IMAP_HOST', '127.0.0.1'),
        'port'           => (int) env('DART_MAIL_IMAP_PORT', 2143),
        'encryption'     => env('DART_MAIL_IMAP_ENC', false),  // false | 'ssl' | 'tls'
        'validate_cert'  => (bool) env('DART_MAIL_IMAP_VALIDATE_CERT', false),
        'username'       => env('DART_MAIL_IMAP_USER', 'demo@example.com'),
        'password'       => env('DART_MAIL_IMAP_PASS', 'demo'),
        'protocol'       => 'imap',
    ],

    // POP3 retrieval (alternative to IMAP).
    'pop3' => [
        'host'           => env('DART_MAIL_POP3_HOST', '127.0.0.1'),
        'port'           => (int) env('DART_MAIL_POP3_PORT', 2110),
        'encryption'     => env('DART_MAIL_POP3_ENC', false),
        'validate_cert'  => (bool) env('DART_MAIL_POP3_VALIDATE_CERT', false),
        'username'       => env('DART_MAIL_POP3_USER', 'demo@example.com'),
        'password'       => env('DART_MAIL_POP3_PASS', 'demo'),
    ],

    // Webhook receiver — dart_email_server POSTs accepted inbound mail
    // to /api/incoming-mail. Validate this shared secret in the Bearer
    // header to prevent forgeries.
    'webhook' => [
        'secret' => env('DART_MAIL_WEBHOOK_SECRET', 'change-me'),
    ],

];
