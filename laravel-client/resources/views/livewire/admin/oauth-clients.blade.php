<div>
  <div class="toolbar">
    <h1>Admin · OAuth Clients</h1>
    <span class="right">{{ $clients->count() }} {{ \Illuminate\Support\Str::plural('client', $clients->count()) }}</span>
  </div>

  @if ($statusMessage)
    <div class="flash">{{ $statusMessage }}</div>
  @endif

  @if ($revealedSecret)
    <div style="margin: 12px 20px; padding: 14px 16px; border:1px solid var(--accent); border-radius:10px; background:var(--surface-2);">
      <strong>New OAuth client credentials</strong>
      <div style="margin-top:8px; font-family: ui-monospace, Menlo, Consolas, monospace; font-size:13px;">
        <div><strong>client_id:</strong> {{ $revealedClientId }}</div>
        <div><strong>client_secret:</strong> {{ $revealedSecret }}</div>
      </div>
      <p style="margin: 8px 0 0; font-size: 12px; color: var(--text-2);">
        Save these now — the secret is hashed in the database and cannot be retrieved later.
      </p>
    </div>
  @endif

  <div style="padding: 16px 20px; display: grid; gap: 24px; grid-template-columns: 1fr 1fr;">
    <div>
      <h2 style="font: 500 16px/1.3 'Google Sans','Inter',sans-serif; margin: 0 0 12px;">Register new client</h2>
      <form wire:submit="createClient">
        <label>App name</label>
        <input wire:model="newName" required placeholder="My third-party app">
        @error('newName') <div class="err">{{ $message }}</div> @enderror

        <label>Redirect URI</label>
        <input wire:model="newRedirect" required placeholder="https://example.com/oauth/callback">
        @error('newRedirect') <div class="err">{{ $message }}</div> @enderror

        <label class="row-check" style="display:flex;align-items:center;gap:8px;margin-top:10px;">
          <input type="checkbox" wire:model="newConfidential">
          Confidential client (server-to-server; uncheck for public SPA / mobile)
        </label>

        <div style="margin-top: 16px;">
          <button class="btn" type="submit">Create client</button>
        </div>
      </form>

      <div style="margin-top:24px; font-size:12px; color:var(--text-2); line-height:1.55;">
        <strong>Discovery / endpoints:</strong><br>
        Authorize: <code>{{ url('/oauth/authorize') }}</code><br>
        Token: <code>{{ url('/oauth/token') }}</code><br>
        User info (with bearer): <code>{{ url('/api/user') }}</code>
      </div>
    </div>

    <div>
      <h2 style="font: 500 16px/1.3 'Google Sans','Inter',sans-serif; margin: 0 0 12px;">Registered clients</h2>

      @forelse ($clients as $c)
        <div style="border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin-bottom:10px;background:var(--surface);">
          <div style="display:flex;align-items:center;gap:8px;">
            <strong>{{ $c->name }}</strong>
            @if ($c->revoked)
              <span class="badge none" style="color:var(--accent);">revoked</span>
            @else
              <span class="badge pass">active</span>
            @endif
            <span class="badge none">{{ $c->confidential() ? 'confidential' : 'public' }}</span>
          </div>
          <div style="font-family: ui-monospace,Menlo,Consolas,monospace; font-size:12px; color:var(--text-2); margin-top:4px;">
            id: {{ $c->getKey() }}
          </div>
          <div style="font-size:12px; color:var(--text-2); margin-top:2px;">
            redirect: {{ is_array($c->redirect_uris) ? implode(', ', $c->redirect_uris) : ($c->redirect ?? '—') }}
          </div>

          <div style="margin-top:10px;display:flex;gap:8px;">
            @if ($c->revoked)
              <button wire:click="unrevokeClient('{{ $c->getKey() }}')" class="btn ghost" type="button"
                      style="padding:4px 10px;font-size:12px;">Re-enable</button>
            @else
              <button wire:click="revokeClient('{{ $c->getKey() }}')" class="btn ghost" type="button"
                      style="padding:4px 10px;font-size:12px;color:var(--accent);">Revoke</button>
            @endif
            <button wire:click="deleteClient('{{ $c->getKey() }}')"
                    wire:confirm="Delete client {{ $c->name }} permanently?"
                    class="btn ghost" type="button"
                    style="padding:4px 10px;font-size:12px;color:var(--accent);">Delete</button>
          </div>
        </div>
      @empty
        <p style="color:var(--text-2);">No OAuth clients yet.</p>
      @endforelse
    </div>
  </div>
</div>
