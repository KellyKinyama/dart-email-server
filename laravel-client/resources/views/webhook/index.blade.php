<x-layout title="Webhook log">
  <p class="small">Mail pushed by dart_email_server to <code>POST /api/incoming-mail</code>.</p>
  <table>
    <thead><tr><th>Received</th><th>From</th><th>To</th><th>Subject</th><th>SPF</th><th>DKIM</th><th>DMARC</th><th>rDNS</th></tr></thead>
    <tbody>
    @forelse ($messages as $m)
      <tr onclick="window.location='{{ route('webhook.show', $m) }}'" style="cursor:pointer">
        <td class="small">{{ optional($m->received_at)->format('Y-m-d H:i') }}</td>
        <td>{{ $m->envelope_from }}</td>
        <td class="small">{{ implode(', ', $m->envelope_to ?? []) }}</td>
        <td>{{ $m->subject ?: '(no subject)' }}</td>
        @foreach (['spf','dkim','dmarc','rdns'] as $k)
          <td><span class="badge {{ $m->{$k} ?: 'none' }}">{{ $m->{$k} ?: '—' }}</span></td>
        @endforeach
      </tr>
    @empty
      <tr><td colspan="8" style="text-align:center" class="small">Nothing received yet.</td></tr>
    @endforelse
    </tbody>
  </table>
</x-layout>
