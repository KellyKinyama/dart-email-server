@props([
  'title'        => 'DartMail',
  'activeNav'    => null,
  'activeFolder' => null,
])

@inject('imap', 'App\\Services\\ImapMailboxService')

@php
  $sidebarFolders = [];
  $sidebarError   = null;
  try {
    $sidebarFolders = $imap->folders();
  } catch (\Throwable $e) {
    $sidebarError = $e->getMessage();
  }

  $iconMap = [
    'inbox'   => '📥',
    'sent'    => '📤',
    'drafts'  => '📝',
    'trash'   => '🗑',
    'junk'    => '⚠',
    'spam'    => '⚠',
    'archive' => '🗄',
  ];
  $orderHint = ['inbox' => 0, 'sent' => 1, 'drafts' => 2, 'trash' => 3, 'junk' => 4, 'spam' => 4, 'archive' => 5];
  $orderedFolders = array_keys($sidebarFolders);
  usort($orderedFolders, function ($a, $b) use ($orderHint) {
    $ka = $orderHint[strtolower($a)] ?? 99;
    $kb = $orderHint[strtolower($b)] ?? 99;
    if ($ka === $kb) return strcasecmp($a, $b);
    return $ka <=> $kb;
  });
@endphp

<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>{{ $title }} · DartMail</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Google+Sans:wght@400;500;700&display=swap" rel="stylesheet">
  <style>
    :root {
      color-scheme: light;
      --bg:        #f6f8fc;
      --surface:   #ffffff;
      --surface-2: #f1f3f4;
      --hover:     #eaeef6;
      --line:      #e0e3e9;
      --text:      #202124;
      --text-2:    #5f6368;
      --text-3:    #80868b;
      --primary:   #1a73e8;
      --primary-2: #c2e7ff;
      --primary-text: #001d35;
      --accent:    #d93025;
      --unread-bg: #ffffff;
      --read-bg:   #f6f8fc;
      --shadow:    0 1px 2px rgba(60,64,67,.08), 0 1px 3px rgba(60,64,67,.12);
      --shadow-2:  0 1px 3px rgba(60,64,67,.16), 0 4px 8px rgba(60,64,67,.1);
      --radius:    16px;
      --radius-sm: 8px;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        color-scheme: dark;
        --bg:        #131314;
        --surface:   #1e1f20;
        --surface-2: #28292c;
        --hover:     #35363a;
        --line:      #3c4043;
        --text:      #e8eaed;
        --text-2:    #9aa0a6;
        --text-3:    #80868b;
        --primary:   #8ab4f8;
        --primary-2: #003b73;
        --primary-text: #c2e7ff;
        --accent:    #f28b82;
        --unread-bg: #1e1f20;
        --read-bg:   #131314;
        --shadow:    0 1px 2px rgba(0,0,0,.4);
        --shadow-2:  0 1px 3px rgba(0,0,0,.4), 0 4px 8px rgba(0,0,0,.3);
      }
    }

    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; }
    body {
      font: 14px/1.5 'Inter', system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
      color: var(--text);
      background: var(--bg);
      min-height: 100vh;
    }
    a { color: var(--primary); text-decoration: none; }
    a:hover { text-decoration: underline; }

    .app {
      display: grid;
      grid-template-columns: 256px 1fr;
      grid-template-rows: 64px 1fr;
      grid-template-areas:
        "header  header"
        "sidebar main";
      min-height: 100vh;
    }

    .topbar {
      grid-area: header;
      display: flex;
      align-items: center;
      gap: 16px;
      padding: 0 24px;
      background: var(--bg);
      border-bottom: 1px solid var(--line);
      position: sticky;
      top: 0;
      z-index: 5;
    }
    .brand {
      font-family: 'Google Sans', 'Inter', sans-serif;
      font-weight: 500;
      font-size: 22px;
      color: var(--text);
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .brand-dot {
      width: 28px; height: 28px;
      border-radius: 8px;
      background: linear-gradient(135deg, #4285f4 0%, #34a853 50%, #fbbc04 75%, #ea4335 100%);
    }
    .search {
      flex: 1;
      max-width: 720px;
      display: flex;
      align-items: center;
      gap: 8px;
      background: var(--surface-2);
      border-radius: 999px;
      padding: 8px 18px;
      transition: background .15s;
    }
    .search:focus-within { background: var(--surface); box-shadow: var(--shadow); }
    .search input {
      flex: 1;
      border: 0;
      outline: 0;
      background: transparent;
      color: inherit;
      font: inherit;
    }
    .topbar .meta {
      font-size: 12px;
      color: var(--text-3);
      margin-left: auto;
    }
    .avatar {
      width: 36px; height: 36px; border-radius: 50%;
      background: linear-gradient(135deg, #1a73e8, #34a853);
      color: white;
      display: grid; place-items: center;
      font-weight: 600;
      flex-shrink: 0;
    }
    .avatar.lg { width: 44px; height: 44px; font-size: 16px; }

    .sidebar {
      grid-area: sidebar;
      padding: 8px 8px 24px;
      overflow-y: auto;
    }
    .compose-btn {
      display: inline-flex;
      align-items: center;
      gap: 12px;
      padding: 14px 24px 14px 16px;
      background: var(--primary-2);
      color: var(--primary-text);
      font-family: 'Google Sans', 'Inter', sans-serif;
      font-weight: 500;
      font-size: 14px;
      border-radius: 16px;
      box-shadow: var(--shadow);
      transition: box-shadow .15s, background .15s;
      margin: 8px 8px 16px;
    }
    .compose-btn:hover { box-shadow: var(--shadow-2); text-decoration: none; }
    .compose-btn .plus { font-size: 22px; line-height: 1; font-weight: 400; }

    .nav-list { list-style: none; margin: 0; padding: 0; }
    .nav-list li a {
      display: flex;
      align-items: center;
      gap: 14px;
      padding: 0 24px 0 26px;
      height: 32px;
      border-radius: 0 999px 999px 0;
      color: var(--text);
      font-weight: 500;
      font-size: 14px;
      margin-right: 12px;
    }
    .nav-list li a:hover { background: var(--hover); text-decoration: none; }
    .nav-list li a.active {
      background: var(--primary-2);
      color: var(--primary-text);
      font-weight: 700;
    }
    .nav-list li a .glyph { width: 20px; text-align: center; font-size: 16px; }
    .nav-divider { height: 1px; background: var(--line); margin: 12px 16px; }

    .main {
      grid-area: main;
      padding: 0 16px 16px 0;
      min-width: 0;
    }
    .panel {
      background: var(--surface);
      border-radius: var(--radius);
      box-shadow: var(--shadow);
      overflow: hidden;
      min-height: calc(100vh - 96px);
    }

    .toolbar {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 8px 16px;
      border-bottom: 1px solid var(--line);
      min-height: 48px;
    }
    .toolbar h1 {
      margin: 0;
      font: 600 16px/1.4 'Google Sans','Inter',sans-serif;
      color: var(--text);
    }
    .toolbar .right { margin-left: auto; color: var(--text-2); font-size: 12px; }
    .icon-btn {
      width: 36px; height: 36px;
      display: grid; place-items: center;
      border-radius: 50%;
      background: transparent;
      color: var(--text-2);
      border: 0;
      cursor: pointer;
      font-size: 16px;
      text-decoration: none;
    }
    .icon-btn:hover { background: var(--hover); color: var(--text); text-decoration: none; }

    .flash, .err {
      margin: 12px 16px;
      padding: 10px 14px;
      border-radius: var(--radius-sm);
      font-size: 13px;
    }
    .flash { background: #e6f4ea; color: #137333; border: 1px solid #b7dfb9; }
    .err   { background: #fce8e6; color: #c5221f; border: 1px solid #f5b5b1; }
    @media (prefers-color-scheme: dark) {
      .flash { background: #0d3a1f; color: #a8dab5; border-color: #185b30; }
      .err   { background: #3b1d1c; color: #f5b5b1; border-color: #5b2422; }
    }

    .form-card { padding: 24px 28px; max-width: 760px; }
    .form-card label {
      display: block;
      font-size: 12px;
      font-weight: 600;
      color: var(--text-2);
      margin: 16px 0 6px;
      text-transform: uppercase;
      letter-spacing: .4px;
    }
    .form-card input,
    .form-card textarea,
    .form-card select {
      width: 100%;
      padding: 10px 12px;
      border: 1px solid var(--line);
      border-radius: var(--radius-sm);
      background: var(--surface);
      color: var(--text);
      font: inherit;
      transition: border-color .15s, box-shadow .15s;
    }
    .form-card input:focus,
    .form-card textarea:focus,
    .form-card select:focus {
      border-color: var(--primary);
      outline: 0;
      box-shadow: 0 0 0 3px color-mix(in srgb, var(--primary) 25%, transparent);
    }
    .form-card textarea { min-height: 220px; resize: vertical; font-family: 'Inter', system-ui, sans-serif; }
    .btn {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 10px 24px;
      background: var(--primary);
      color: #fff;
      border: 0;
      border-radius: 999px;
      font: 500 14px/1 'Google Sans','Inter',sans-serif;
      cursor: pointer;
      box-shadow: var(--shadow);
      transition: box-shadow .15s, transform .05s;
    }
    .btn:hover { box-shadow: var(--shadow-2); text-decoration: none; }
    .btn:active { transform: translateY(1px); }
    .btn.ghost { background: transparent; color: var(--text-2); box-shadow: none; }
    .btn.ghost:hover { background: var(--hover); color: var(--text); }
    .btn-row { margin-top: 24px; display: flex; gap: 10px; align-items: center; }

    .mlist { list-style: none; margin: 0; padding: 0; }
    .mlist li {
      display: grid;
      grid-template-columns: 220px 1fr 120px;
      align-items: center;
      gap: 12px;
      padding: 0 16px;
      height: 44px;
      border-bottom: 1px solid var(--line);
      cursor: pointer;
      background: var(--unread-bg);
      transition: background .12s, box-shadow .12s;
    }
    .mlist li:hover { background: var(--surface); box-shadow: inset 0 0 0 1px var(--line), var(--shadow); z-index: 1; position: relative; }
    .mlist li.read { background: var(--read-bg); }
    .mlist li.read .from, .mlist li.read .subj { font-weight: 400; color: var(--text-2); }
    .mlist .from { font-weight: 600; color: var(--text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .mlist .subj { font-weight: 600; color: var(--text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .mlist .subj .snippet { color: var(--text-2); font-weight: 400; margin-left: 6px; }
    .mlist .date { text-align: right; color: var(--text-2); font-size: 12px; white-space: nowrap; }
    .empty {
      display: block;
      padding: 64px 24px;
      text-align: center;
      color: var(--text-2);
    }
    .empty .big { font-size: 64px; line-height: 1; opacity: .6; margin-bottom: 8px; }

    .msg-card { padding: 16px 24px 32px; }
    .msg-card h1 {
      margin: 0 0 16px;
      font: 600 22px/1.3 'Google Sans','Inter',sans-serif;
    }
    .msg-meta {
      display: grid;
      grid-template-columns: 44px 1fr;
      gap: 14px;
      align-items: flex-start;
      margin-bottom: 20px;
    }
    .msg-meta .who { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
    .msg-meta .name { font-weight: 600; color: var(--text); }
    .msg-meta .addr { color: var(--text-2); font-size: 12px; }
    .msg-meta .when { color: var(--text-2); font-size: 12px; margin-left: auto; }
    .msg-meta .row2 { color: var(--text-2); font-size: 12px; margin-top: 2px; }
    .msg-body {
      margin-top: 8px;
      font-size: 14px;
      line-height: 1.65;
      color: var(--text);
    }
    .msg-body iframe {
      width: 100%;
      min-height: 480px;
      border: 0;
      background: white;
      border-radius: var(--radius-sm);
    }
    .msg-body pre {
      white-space: pre-wrap;
      word-break: break-word;
      font: inherit;
      background: transparent;
      padding: 0;
      margin: 0;
    }
    details.headers { margin-top: 32px; padding: 12px 16px; background: var(--surface-2); border-radius: var(--radius-sm); }
    details.headers summary { cursor: pointer; color: var(--text-2); font-size: 12px; }
    details.headers pre {
      font: 12px/1.5 ui-monospace, SFMono-Regular, 'Cascadia Mono', Menlo, monospace;
      color: var(--text-2);
      white-space: pre-wrap;
      margin: 12px 0 0;
    }

    .badge { display: inline-block; padding: 1px 8px; border-radius: 999px; font-size: 11px; font-weight: 500; }
    .badge.pass { background: #e6f4ea; color: #137333; }
    .badge.fail { background: #fce8e6; color: #c5221f; }
    .badge.none { background: var(--surface-2); color: var(--text-2); }

    @media (max-width: 900px) {
      .app { grid-template-columns: 72px 1fr; }
      .compose-btn { padding: 14px; }
      .compose-btn .label { display: none; }
      .nav-list li a { padding: 0 0 0 24px; }
      .nav-list li a span:not(.glyph) { display: none; }
      .topbar .meta { display: none; }
    }
  </style>
  @livewireStyles
</head>
<body>
<div class="app">
  <header class="topbar">
    <div class="brand">
      <span class="brand-dot"></span>
      <span>DartMail</span>
    </div>
    <form class="search" method="get" action="{{ route('inbox.index') }}">
      <span aria-hidden="true">🔍</span>
      <input type="search" name="q" placeholder="Search mail" value="{{ request('q') }}">
    </form>
    <div class="meta">
      SMTP {{ config('dart_email.smtp.host') }}:{{ config('dart_email.smtp.port') }}
      &middot; IMAP {{ config('dart_email.imap.host') }}:{{ config('dart_email.imap.port') }}
    </div>
    <div class="avatar" title="{{ auth()->user()?->email ?: config('dart_email.imap.username') }}">
      {{ strtoupper(substr(auth()->user()?->name ?: auth()->user()?->email ?: config('dart_email.imap.username'), 0, 1)) }}
    </div>
    @auth
      <form method="post" action="{{ url('/logout') }}" style="margin:0;">
        @csrf
        <button type="submit" class="icon-btn" title="Sign out" style="background:transparent;border:0;cursor:pointer;">↩</button>
      </form>
    @endauth
  </header>

  <aside class="sidebar">
    <a class="compose-btn" href="{{ route('compose.create') }}">
      <span class="plus">＋</span><span class="label">Compose</span>
    </a>

    <ul class="nav-list">
      @forelse ($orderedFolders as $folderName)
        @php
          $key = strtolower($folderName);
          $glyph = $iconMap[$key] ?? '📁';
          $isActive = $activeNav === 'inbox' && strcasecmp($folderName, $activeFolder ?? 'INBOX') === 0;
          $url = route('inbox.index', ['folder' => $folderName]);
        @endphp
        <li>
          <a href="{{ $url }}" class="{{ $isActive ? 'active' : '' }}">
            <span class="glyph">{{ $glyph }}</span>
            <span>{{ $folderName }}</span>
          </a>
        </li>
      @empty
        <li>
          <a href="{{ route('inbox.index') }}" class="{{ $activeNav === 'inbox' ? 'active' : '' }}">
            <span class="glyph">📥</span><span>Inbox</span>
          </a>
        </li>
      @endforelse
    </ul>

    <div class="nav-divider"></div>

    <ul class="nav-list">
      <li>
        <a href="{{ route('webhook.index') }}" class="{{ $activeNav === 'webhook' ? 'active' : '' }}">
          <span class="glyph">🔔</span><span>Webhook log</span>
        </a>
      </li>
      @if (auth()->user()?->hasRole('admin'))
        <li>
          <a href="{{ route('admin.users') }}" class="{{ $activeNav === 'admin' ? 'active' : '' }}">
            <span class="glyph">🛡️</span><span>Admin</span>
          </a>
        </li>
      @endif
    </ul>

    @if ($sidebarError)
      <div class="err" style="margin: 12px 12px 0; font-size: 12px;">
        IMAP unavailable: {{ \Illuminate\Support\Str::limit($sidebarError, 80) }}
      </div>
    @endif
  </aside>

  <main class="main">
    <div class="panel">
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
    </div>
  </main>
</div>
@livewireScripts
</body>
</html>
