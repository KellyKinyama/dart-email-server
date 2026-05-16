<div>
  <div class="toolbar">
    <h1>{{ $folder }}</h1>
    <span class="right">{{ count($messages) }} {{ \Illuminate\Support\Str::plural('message', count($messages)) }}</span>
  </div>

  @if ($error)
    <div class="err">IMAP error: {{ $error }}</div>
  @endif

  @php
    $palette = ['#1a73e8','#34a853','#fbbc04','#ea4335','#a142f4','#16a2d7','#ff6d00','#0b8043'];
    $colorFor = function (?string $email) use ($palette) {
      if (! $email) return $palette[0];
      $hash = 0;
      foreach (str_split($email) as $ch) { $hash = ($hash * 31 + ord($ch)) & 0xffffffff; }
      return $palette[$hash % count($palette)];
    };
    $initialOf = function (?string $name, ?string $email) {
      $base = trim((string) $name) !== '' ? $name : (string) $email;
      return strtoupper(substr($base, 0, 1) ?: '?');
    };
  @endphp

  <ul class="mlist">
    @forelse ($messages as $m)
      @php
        $url = route('inbox.show', ['folder' => $folder, 'uid' => $m['uid']]);
        $who = $m['fromName'] ?: $m['from'] ?: '(unknown)';
      @endphp
      <li class="{{ $m['seen'] ? 'read' : '' }}" wire:navigate.hover onclick="window.location='{{ $url }}'">
        <div class="from" style="display:flex;align-items:center;gap:10px;">
          <span class="avatar" style="width:28px;height:28px;font-size:12px;background:{{ $colorFor($m['from']) }}">
            {{ $initialOf($m['fromName'], $m['from']) }}
          </span>
          <span style="overflow:hidden;text-overflow:ellipsis;">{{ $who }}</span>
        </div>
        <div class="subj">
          {{ $m['subject'] ?: '(no subject)' }}
          @if (! empty($m['hasAttach']))
            <span title="Has attachment" style="color:var(--text-3);margin-left:6px;">📎</span>
          @endif
        </div>
        <div class="date">{{ $m['date'] }}</div>
      </li>
    @empty
      <li class="empty" style="cursor:default;display:block;border:0;height:auto;">
        <div class="big">📭</div>
        <div>Nothing in <strong>{{ $folder }}</strong>.</div>
        <div style="margin-top:6px;font-size:12px;">
          @if (strcasecmp($folder, 'INBOX') === 0)
            New mail will appear here as it arrives.
          @else
            Move or copy messages here from another folder.
          @endif
        </div>
      </li>
    @endforelse
  </ul>
</div>
