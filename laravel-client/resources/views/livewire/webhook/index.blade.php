<div>
  <div class="toolbar">
    <h1>Webhook log</h1>
    <span class="right">{{ count($messages) }} {{ \Illuminate\Support\Str::plural('event', count($messages)) }}</span>
  </div>

  <p style="padding: 0 24px; color: var(--text-2); font-size: 12px; margin: 12px 0 0;">
    Mail pushed by <code>dart_email_server</code> to <code>POST /api/incoming-mail</code>.
  </p>

  <ul class="mlist" style="margin-top: 12px;">
    @forelse ($messages as $m)
      <li onclick="window.location='{{ route('webhook.show', $m) }}'">
        <div class="from">{{ $m->envelope_from ?: '(unknown)' }}</div>
        <div class="subj">
          {{ $m->subject ?: '(no subject)' }}
          <span class="snippet">to {{ implode(', ', $m->envelope_to ?? []) }}</span>
        </div>
        <div class="date">{{ optional($m->received_at)->format('M j, H:i') }}</div>
      </li>
    @empty
      <li class="empty" style="cursor:default;display:block;border:0;height:auto;">
        <div class="big">🔔</div>
        <div>No webhook events yet.</div>
        <div style="margin-top:6px;font-size:12px;">
          Send mail to the dart_email_server SMTP listener and it will appear here.
        </div>
      </li>
    @endforelse
  </ul>
</div>
