<div>
  <div class="toolbar">
    <h1>New message</h1>
  </div>

  @if (session('status'))
    <div class="flash">{{ session('status') }}</div>
  @endif

  <form wire:submit="send" class="form-card">
    <label>From</label>
    <input wire:model="from" type="email">
    @error('from') <div class="err">{{ $message }}</div> @enderror

    <label>From name</label>
    <input wire:model="fromName" placeholder="Optional display name">
    @error('fromName') <div class="err">{{ $message }}</div> @enderror

    <label>To <span class="hint">(comma-separated; use <code>group:slug</code> or a group's email to expand a list)</span></label>
    <input wire:model="to" required placeholder="someone@example.com, group:sales-team">
    @error('to') <div class="err">{{ $message }}</div> @enderror

    <div class="addr-toggles" style="display:flex;gap:12px;margin:-8px 0 4px;">
      <a href="#" wire:click.prevent="toggleCc"  style="font-size:12px;color:var(--accent);text-decoration:none;">{{ $showCc  ? '− Cc'  : '+ Cc'  }}</a>
      <a href="#" wire:click.prevent="toggleBcc" style="font-size:12px;color:var(--accent);text-decoration:none;">{{ $showBcc ? '− Bcc' : '+ Bcc' }}</a>
    </div>

    @if ($showCc)
      <div>
        <label>Cc <span class="hint">(comma-separated)</span></label>
        <input wire:model="cc" placeholder="cc@example.com">
        @error('cc') <div class="err">{{ $message }}</div> @enderror
      </div>
    @endif

    @if ($showBcc)
      <div>
        <label>Bcc <span class="hint">(comma-separated)</span></label>
        <input wire:model="bcc" placeholder="bcc@example.com">
        @error('bcc') <div class="err">{{ $message }}</div> @enderror
      </div>
    @endif

    <label>Subject</label>
    <input wire:model="subject" required>
    @error('subject') <div class="err">{{ $message }}</div> @enderror

    <label>Message</label>
    <textarea wire:model="text" placeholder="Write your message…"></textarea>
    @error('text') <div class="err">{{ $message }}</div> @enderror

    <label>HTML body <span class="hint">(optional, takes precedence)</span></label>
    <textarea wire:model="html" placeholder="&lt;p&gt;…&lt;/p&gt;"></textarea>
    @error('html') <div class="err">{{ $message }}</div> @enderror

    <label>Attachments <span class="hint">(up to 25 MB each)</span></label>
    <input type="file" wire:model="attachments" multiple>
    @error('attachments.*') <div class="err">{{ $message }}</div> @enderror

    <div wire:loading wire:target="attachments" class="hint" style="margin-top:6px;">Uploading…</div>

    @if (! empty($attachments))
      <ul class="att-list" style="list-style:none;padding:0;margin:12px 0 0;display:flex;flex-direction:column;gap:6px;">
        @foreach ($attachments as $i => $upload)
          <li style="display:flex;align-items:center;gap:10px;padding:8px 12px;background:var(--surface);border:1px solid var(--border);border-radius:10px;font-size:13px;">
            <span>📄</span>
            <span style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">{{ $upload->getClientOriginalName() }}</span>
            <span style="color:var(--text-3);font-size:11px;">{{ number_format($upload->getSize() / 1024, 1) }} KB</span>
          </li>
        @endforeach
      </ul>
    @endif

    <div class="btn-row" style="margin-top:16px;">
      <button class="btn" type="submit" wire:loading.attr="disabled" wire:target="send">
        <span wire:loading.remove wire:target="send">Send</span>
        <span wire:loading wire:target="send">Sending…</span>
      </button>
      <a class="btn ghost" href="{{ route('inbox.index') }}">Cancel</a>
    </div>
  </form>
</div>
