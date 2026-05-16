<div>
  <div class="toolbar">
    <h1>Admin · Users</h1>
    <span class="right">{{ $users->total() }} {{ \Illuminate\Support\Str::plural('account', $users->total()) }}</span>
  </div>

  @if ($statusMessage)
    <div class="flash">{{ $statusMessage }}</div>
  @endif

  <div style="padding: 12px 16px;">
    <input wire:model.live.debounce.300ms="search" type="search" placeholder="Search by name or email"
           style="width:100%;max-width:420px;padding:8px 12px;border:1px solid var(--line);border-radius:8px;background:var(--surface);color:var(--text);font:inherit;">
  </div>

  <table style="width:100%;border-collapse:collapse;font-size:14px;">
    <thead>
      <tr style="text-align:left;color:var(--text-2);font-size:11px;text-transform:uppercase;letter-spacing:.4px;">
        <th style="padding:8px 16px;border-bottom:1px solid var(--line);">User</th>
        <th style="padding:8px 16px;border-bottom:1px solid var(--line);">Email</th>
        <th style="padding:8px 16px;border-bottom:1px solid var(--line);">Roles</th>
        <th style="padding:8px 16px;border-bottom:1px solid var(--line);">Created</th>
        <th style="padding:8px 16px;border-bottom:1px solid var(--line);text-align:right;">Actions</th>
      </tr>
    </thead>
    <tbody>
      @forelse ($users as $u)
        <tr>
          <td style="padding:10px 16px;border-bottom:1px solid var(--line);">{{ $u->name }}</td>
          <td style="padding:10px 16px;border-bottom:1px solid var(--line);">{{ $u->email }}</td>
          <td style="padding:10px 16px;border-bottom:1px solid var(--line);">
            @foreach ($u->getRoleNames() as $r)
              <span class="badge {{ $r === 'admin' ? 'pass' : 'none' }}">{{ $r }}</span>
            @endforeach
          </td>
          <td style="padding:10px 16px;border-bottom:1px solid var(--line);color:var(--text-2);">
            {{ optional($u->created_at)->format('M j, Y') }}
          </td>
          <td style="padding:10px 16px;border-bottom:1px solid var(--line);text-align:right;">
            <button wire:click="toggleAdmin({{ $u->id }})" class="btn ghost" type="button"
                    style="padding:4px 10px;font-size:12px;">
              {{ $u->hasRole('admin') ? 'Revoke admin' : 'Make admin' }}
            </button>
            <button wire:click="resetPassword({{ $u->id }})" class="btn ghost" type="button"
                    style="padding:4px 10px;font-size:12px;">Reset password</button>
            <button wire:click="deleteUser({{ $u->id }})" wire:confirm="Delete {{ $u->email }}?"
                    class="btn ghost" type="button"
                    style="padding:4px 10px;font-size:12px;color:var(--accent);">Delete</button>
          </td>
        </tr>
      @empty
        <tr><td colspan="5" style="padding:32px;text-align:center;color:var(--text-2);">No users.</td></tr>
      @endforelse
    </tbody>
  </table>

  <div style="padding:12px 16px;">{{ $users->links() }}</div>
</div>
