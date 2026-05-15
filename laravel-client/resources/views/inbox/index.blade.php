<x-layout title="Inbox">
  @if ($error)
    <div class="err">IMAP error: {{ $error }}</div>
  @endif

  <p class="small">
    Folder:
    <select onchange="window.location='{{ route('inbox.index') }}?folder=' + encodeURIComponent(this.value)">
      @foreach ($folders as $name => $path)
        <option value="{{ $name }}" @selected($name === $folder)>{{ $name }}</option>
      @endforeach
      @if (! count($folders))
        <option>{{ $folder }}</option>
      @endif
    </select>
    &middot; {{ count($messages) }} message(s)
  </p>

  <table>
    <thead><tr><th>From</th><th>Subject</th><th>Date</th><th>Size</th></tr></thead>
    <tbody>
      @forelse ($messages as $m)
        <tr onclick="window.location='{{ route('inbox.show', [$folder, $m['uid']]) }}'" style="cursor:pointer">
          <td>{{ $m['fromName'] ?: $m['from'] }}<br><span class="small">{{ $m['from'] }}</span></td>
          <td>{!! $m['seen'] ? '' : '<strong>' !!}{{ $m['subject'] ?: '(no subject)' }}{!! $m['seen'] ? '' : '</strong>' !!}</td>
          <td class="small">{{ $m['date'] }}</td>
          <td class="small">{{ number_format($m['size']) }} B</td>
        </tr>
      @empty
        <tr><td colspan="4" style="text-align:center" class="small">No messages.</td></tr>
      @endforelse
    </tbody>
  </table>
</x-layout>
