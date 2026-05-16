@props(['title' => 'DartMail'])

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
      --line:      #e0e3e9;
      --text:      #202124;
      --text-2:    #5f6368;
      --text-3:    #80868b;
      --primary:   #1a73e8;
      --primary-2: #c2e7ff;
      --primary-text: #001d35;
      --accent:    #d93025;
      --shadow:    0 1px 2px rgba(60,64,67,.08), 0 1px 3px rgba(60,64,67,.12);
      --shadow-2:  0 1px 3px rgba(60,64,67,.16), 0 4px 8px rgba(60,64,67,.1);
      --radius:    16px;
      --radius-sm: 8px;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        color-scheme: dark;
        --bg:        #131314; --surface:   #1e1f20; --surface-2: #28292c;
        --line:      #3c4043; --text:      #e8eaed; --text-2:    #9aa0a6;
        --text-3:    #80868b; --primary:   #8ab4f8; --primary-2: #003b73;
        --primary-text: #c2e7ff; --accent:    #f28b82;
      }
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; }
    body {
      font: 14px/1.5 'Inter', system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
      color: var(--text);
      background: var(--bg);
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 24px;
    }
    a { color: var(--primary); text-decoration: none; }
    a:hover { text-decoration: underline; }
    .auth-card {
      background: var(--surface);
      border-radius: var(--radius);
      box-shadow: var(--shadow-2);
      padding: 36px 40px;
      width: 100%;
      max-width: 440px;
    }
    .auth-brand {
      display: flex; align-items: center; gap: 10px;
      font: 500 22px/1.2 'Google Sans','Inter',sans-serif;
      margin-bottom: 4px;
    }
    .auth-brand-dot {
      width: 28px; height: 28px; border-radius: 8px;
      background: linear-gradient(135deg, #4285f4 0%, #34a853 50%, #fbbc04 75%, #ea4335 100%);
    }
    h1 {
      margin: 16px 0 4px;
      font: 500 24px/1.3 'Google Sans','Inter',sans-serif;
    }
    .sub { color: var(--text-2); font-size: 14px; margin-bottom: 24px; }
    label {
      display: block; font-size: 12px; font-weight: 600; color: var(--text-2);
      margin: 16px 0 6px; text-transform: uppercase; letter-spacing: .4px;
    }
    input[type=text], input[type=email], input[type=password] {
      width: 100%; padding: 10px 12px;
      border: 1px solid var(--line); border-radius: var(--radius-sm);
      background: var(--surface); color: var(--text); font: inherit;
      transition: border-color .15s, box-shadow .15s;
    }
    input:focus {
      border-color: var(--primary); outline: 0;
      box-shadow: 0 0 0 3px color-mix(in srgb, var(--primary) 25%, transparent);
    }
    .row-check { display: flex; align-items: center; gap: 8px; margin: 16px 0 0; font-size: 13px; color: var(--text-2); }
    .btn {
      display: inline-block; padding: 10px 20px;
      background: var(--primary); color: white; border: 0; border-radius: 999px;
      font: 500 14px/1 'Google Sans','Inter',sans-serif; cursor: pointer;
      box-shadow: var(--shadow);
    }
    .btn:hover { box-shadow: var(--shadow-2); }
    .btn-row { display: flex; align-items: center; justify-content: space-between; margin-top: 24px; gap: 16px; flex-wrap: wrap; }
    .err { color: var(--accent); font-size: 12px; margin-top: 4px; }
    .flash {
      background: #e6f4ea; color: #137333; border: 1px solid #b7dfb9;
      padding: 10px 14px; border-radius: var(--radius-sm); font-size: 13px; margin-bottom: 16px;
    }
    @media (prefers-color-scheme: dark) {
      .flash { background: #0d3a1f; color: #a8dab5; border-color: #185b30; }
    }
    .alt { font-size: 13px; color: var(--text-2); }
  </style>
</head>
<body>
  <div class="auth-card">
    <div class="auth-brand"><span class="auth-brand-dot"></span><span>DartMail</span></div>
    {{ $slot }}
  </div>
</body>
</html>
