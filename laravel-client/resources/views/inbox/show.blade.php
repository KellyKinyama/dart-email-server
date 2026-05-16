<x-layout :title="$message['subject'] ?: '(no subject)'" activeNav="inbox" :activeFolder="$folder">
  @php
    $palette = ['#1a73e8','#34a853','#fbbc04','#ea4335','#a142f4','#16a2d7','#ff6d00','#0b8043'];
    $hash = 0;
    foreach (str_split((string) ($message['from'] ?? '?')) as $ch) { $hash = ($hash * 31 + ord($ch)) & 0xffffffff; }
    $color = $palette[$hash % count($palette)];
    $initial = strtoupper(substr((string) ($message['fromName'] ?: $message['from'] ?: '?'), 0, 1));
  @endphp

  <div class="toolbar">
    <a href="{{ route('inbox.index', ['folder' => $folder]) }}" class="icon-btn" title="Back to {{ $folder }}">←</a>
    <h1>{{ $message['subject'] ?: '(no subject)' }}</h1>
    <span class="right">{{ number_format($message['size']) }} B</span>
  </div>

  <div class="msg-card">
    <div class="msg-meta">
      <span class="avatar lg" style="background:{{ $color }}">{{ $initial }}</span>
      <div>
        <div class="who">
          <span class="name">{{ $message['fromName'] ?: $message['from'] }}</span>
          <span class="addr">&lt;{{ $message['from'] }}&gt;</span>
          <span class="when">{{ $message['date'] }}</span>
        </div>
        <div class="row2">to {{ implode(', ', $message['to'] ?: [config('dart_email.imap.username')]) }}</div>
        @if (! empty($message['cc']))
          <div class="row2">cc {{ implode(', ', $message['cc']) }}</div>
        @endif
        @if (! empty($message['bcc']))
          <div class="row2">bcc {{ implode(', ', $message['bcc']) }}</div>
        @endif
        @if (! empty($message['replyTo']))
          <div class="row2">reply-to {{ implode(', ', $message['replyTo']) }}</div>
        @endif
      </div>
    </div>

    @if (! empty($message['attachments']))
      @php
        $fmtSize = function (int $n) {
          if ($n < 1024) return $n . ' B';
          if ($n < 1048576) return number_format($n / 1024, 1) . ' KB';
          return number_format($n / 1048576, 1) . ' MB';
        };
        $iconFor = function (string $mime) {
          if (str_starts_with($mime, 'image/')) return '🖼️';
          if (str_starts_with($mime, 'video/')) return '🎞️';
          if (str_starts_with($mime, 'audio/')) return '🎵';
          if (str_contains($mime, 'pdf'))       return '📕';
          if (str_contains($mime, 'zip') || str_contains($mime, 'compressed')) return '🗜️';
          if (str_contains($mime, 'word') || str_contains($mime, 'document')) return '📝';
          if (str_contains($mime, 'sheet') || str_contains($mime, 'excel'))   return '📊';
          return '📎';
        };
      @endphp
      <div class="att-strip">
        <div class="att-strip-label">{{ count($message['attachments']) }} {{ \Illuminate\Support\Str::plural('attachment', count($message['attachments'])) }}</div>
        <div class="att-chips">
          @foreach ($message['attachments'] as $a)
            <a class="att-chip" href="{{ route('inbox.attachment', ['folder' => $folder, 'uid' => $message['uid'], 'index' => $a['index']]) }}">
              <span class="att-chip-ico">{{ $iconFor($a['mime']) }}</span>
              <span class="att-chip-meta">
                <span class="att-chip-name">{{ $a['name'] }}</span>
                <span class="att-chip-size">{{ $fmtSize($a['size']) }} · {{ $a['mime'] }}</span>
              </span>
              <span class="att-chip-dl">⬇</span>
            </a>
          @endforeach
        </div>
      </div>
      <style>
        .att-strip { padding: 0 24px 16px; }
        .att-strip-label { font-size: 11px; color: var(--text-3); text-transform: uppercase; letter-spacing: .5px; margin-bottom: 8px; }
        .att-chips { display: flex; flex-wrap: wrap; gap: 10px; }
        .att-chip { display: flex; align-items: center; gap: 10px; padding: 10px 14px; border: 1px solid var(--border); border-radius: 12px; background: var(--surface-2); text-decoration: none; color: var(--text-1); min-width: 220px; max-width: 320px; transition: background .15s, border-color .15s; }
        .att-chip:hover { background: var(--surface); border-color: var(--accent); }
        .att-chip-ico { font-size: 22px; }
        .att-chip-meta { display: flex; flex-direction: column; flex: 1; overflow: hidden; }
        .att-chip-name { font-size: 13px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .att-chip-size { font-size: 11px; color: var(--text-3); }
        .att-chip-dl { color: var(--text-3); font-size: 14px; }
      </style>
    @endif

    <div class="msg-body">
      @if (! empty($message['html']))
        <iframe sandbox srcdoc="{{ $message['html'] }}"></iframe>
      @elseif (! empty($message['text']))
        <pre>{{ $message['text'] }}</pre>
      @else
        <p style="color: var(--text-2);">(empty body)</p>
      @endif
    </div>

    <details class="headers">
      <summary>Show original headers</summary>
      <pre>{{ $message['headers'] }}</pre>
    </details>
  </div>
</x-layout>
