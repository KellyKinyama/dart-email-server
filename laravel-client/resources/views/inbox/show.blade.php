<x-layout :title="$message['subject'] ?: '(no subject)'">
  <p><a href="{{ route('inbox.index', ['folder' => $folder]) }}">&larr; back to {{ $folder }}</a></p>

  <h2 style="margin-bottom:4px">{{ $message['subject'] ?: '(no subject)' }}</h2>
  <p class="small">
    From: {{ $message['fromName'] ?: $message['from'] }} &lt;{{ $message['from'] }}&gt; &middot;
    To: {{ implode(', ', $message['to']) }} &middot;
    {{ $message['date'] }}
  </p>

  @if ($message['html'])
    <iframe srcdoc="{{ e($message['html']) }}" style="width:100%;min-height:400px;border:1px solid #8884;border-radius:6px;background:white"></iframe>
  @elseif ($message['text'])
    <pre>{{ $message['text'] }}</pre>
  @else
    <p class="small">(empty body)</p>
  @endif

  <details style="margin-top:24px">
    <summary class="small">Raw headers ({{ number_format($message['size']) }} B)</summary>
    <pre>{{ $message['headers'] }}</pre>
  </details>
</x-layout>
