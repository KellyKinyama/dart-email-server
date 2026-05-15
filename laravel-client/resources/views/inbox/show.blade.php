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
      </div>
    </div>

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
