<x-layout :title="$message->subject ?: '(no subject)'">
  <p><a href="{{ route('webhook.index') }}">&larr; back to webhook log</a></p>
  <h2 style="margin-bottom:4px">{{ $message->subject ?: '(no subject)' }}</h2>
  <p class="small">
    Envelope from: {{ $message->envelope_from }} &middot;
    To: {{ implode(', ', $message->envelope_to ?? []) }} &middot;
    {{ optional($message->received_at)->format('Y-m-d H:i:s') }} &middot;
    {{ number_format($message->size) }} B
  </p>
  <p>
    @foreach (['spf','dkim','dmarc','rdns'] as $k)
      <span class="badge {{ $message->{$k} ?: 'none' }}">{{ strtoupper($k) }}: {{ $message->{$k} ?: '—' }}</span>
    @endforeach
  </p>

  @if ($message->html_body)
    <iframe srcdoc="{{ e($message->html_body) }}" style="width:100%;min-height:400px;border:1px solid #8884;border-radius:6px;background:white"></iframe>
  @elseif ($message->text_body)
    <pre>{{ $message->text_body }}</pre>
  @endif

  @if ($message->raw)
    <details style="margin-top:24px">
      <summary class="small">Raw RFC 5322 bytes</summary>
      <pre>{{ $message->raw }}</pre>
    </details>
  @endif
</x-layout>
