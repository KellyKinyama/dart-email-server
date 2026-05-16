<div>
  @php
    $palette = ['#1a73e8','#34a853','#fbbc04','#ea4335','#a142f4','#16a2d7','#ff6d00','#0b8043'];
    $hash = 0;
    foreach (str_split((string) ($message->envelope_from ?? '?')) as $ch) { $hash = ($hash * 31 + ord($ch)) & 0xffffffff; }
    $color = $palette[$hash % count($palette)];
    $initial = strtoupper(substr((string) ($message->envelope_from ?: '?'), 0, 1));
  @endphp

  <div class="toolbar">
    <a href="{{ route('webhook.index') }}" class="icon-btn" title="Back to log">←</a>
    <h1>{{ $message->subject ?: '(no subject)' }}</h1>
    <span class="right">{{ number_format($message->size) }} B</span>
  </div>

  <div class="msg-card">
    <div class="msg-meta">
      <span class="avatar lg" style="background:{{ $color }}">{{ $initial }}</span>
      <div>
        <div class="who">
          <span class="name">{{ $message->envelope_from }}</span>
          <span class="when">{{ optional($message->received_at)->format('M j, Y H:i:s') }}</span>
        </div>
        <div class="row2">to {{ implode(', ', $message->envelope_to ?? []) }}</div>
        <div class="row2" style="margin-top: 8px; display: flex; gap: 6px; flex-wrap: wrap;">
          @foreach (['spf','dkim','dmarc','rdns'] as $k)
            <span class="badge {{ $message->{$k} ?: 'none' }}">{{ strtoupper($k) }}: {{ $message->{$k} ?: '—' }}</span>
          @endforeach
        </div>
      </div>
    </div>

    <div class="msg-body">
      @if ($message->html_body)
        <iframe sandbox srcdoc="{{ $message->html_body }}"></iframe>
      @elseif ($message->text_body)
        <pre>{{ $message->text_body }}</pre>
      @else
        <p style="color: var(--text-2);">(empty body)</p>
      @endif
    </div>

    @if ($message->raw)
      <details class="headers">
        <summary>Raw RFC 5322 bytes</summary>
        <pre>{{ $message->raw }}</pre>
      </details>
    @endif
  </div>
</div>
