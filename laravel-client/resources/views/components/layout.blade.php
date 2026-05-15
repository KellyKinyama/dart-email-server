@props(['title' => 'dart_email_server client'])
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{ $title }}</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { font: 14px/1.5 system-ui, sans-serif; margin: 0; }
  header { padding: 12px 20px; border-bottom: 1px solid #8884; display: flex; gap: 16px; align-items: center; }
  header a { text-decoration: none; color: inherit; padding: 6px 10px; border-radius: 6px; }
  header a:hover { background: #8881; }
  header .brand { font-weight: 700; }
  main { max-width: 1100px; margin: 24px auto; padding: 0 20px; }
  table { width: 100%; border-collapse: collapse; }
  th, td { padding: 8px 10px; border-bottom: 1px solid #8883; text-align: left; vertical-align: top; }
  th { background: #8881; }
  tr:hover td { background: #8881; }
  pre { background: #8881; padding: 12px; overflow-x: auto; border-radius: 6px; white-space: pre-wrap; }
  .badge { display: inline-block; padding: 1px 8px; border-radius: 999px; font-size: 11px; }
  .badge.pass { background: #16a34a33; color: #16a34a; }
  .badge.fail { background: #dc262633; color: #dc2626; }
  .badge.none { background: #8884; }
  form label { display: block; margin: 12px 0 4px; font-weight: 600; }
  form input, form textarea, form select {
    width: 100%; padding: 8px 10px; border: 1px solid #8884; border-radius: 6px; background: transparent; color: inherit; font: inherit;
  }
  form textarea { min-height: 140px; resize: vertical; }
  form button { margin-top: 16px; padding: 10px 18px; border: 0; background: #2563eb; color: white; border-radius: 6px; font-weight: 600; cursor: pointer; }
  form button:hover { background: #1d4ed8; }
  .flash { padding: 10px 14px; background: #16a34a22; border: 1px solid #16a34a55; border-radius: 6px; margin-bottom: 16px; }
  .err { padding: 10px 14px; background: #dc262622; border: 1px solid #dc262655; border-radius: 6px; margin-bottom: 16px; }
  .small { color: #888; font-size: 12px; }
</style>
</head>
<body>
<header>
  <span class="brand">dart_email_server client</span>
  <a href="{{ route('inbox.index') }}">Inbox (IMAP)</a>
  <a href="{{ route('webhook.index') }}">Webhook log</a>
  <a href="{{ route('compose.create') }}">Compose</a>
  <span class="small" style="margin-left:auto">SMTP {{ config('dart_email.smtp.host') }}:{{ config('dart_email.smtp.port') }} &middot; IMAP {{ config('dart_email.imap.host') }}:{{ config('dart_email.imap.port') }}</span>
</header>
<main>
  @if (session('status'))
    <div class="flash">{{ session('status') }}</div>
  @endif
  @if ($errors->any())
    <div class="err">
      <ul style="margin:0;padding-left:18px">
        @foreach ($errors->all() as $e) <li>{{ $e }}</li> @endforeach
      </ul>
    </div>
  @endif
  {{ $slot }}
</main>
</body>
</html>
