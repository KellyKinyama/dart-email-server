<div>
  <div class="toolbar">
    <h1>Admin · Groups</h1>
    <span class="right">{{ $groups->count() }} {{ \Illuminate\Support\Str::plural('group', $groups->count()) }}</span>
  </div>

  @if ($statusMessage)
    <div class="flash">{{ $statusMessage }}</div>
  @endif

  <div style="padding: 16px 20px; display: grid; gap: 24px; grid-template-columns: 1fr 1fr;">
    {{-- ─── Create form ─────────────────────────────────────────────── --}}
    <div>
      <h2 style="font: 500 16px/1.3 'Google Sans','Inter',sans-serif; margin: 0 0 12px;">Create group</h2>
      <form wire:submit="createGroup">
        <label>Name</label>
        <input wire:model="newName" required>
        @error('newName') <div class="err">{{ $message }}</div> @enderror

        <label>Slug <span class="hint">(optional, auto-derived)</span></label>
        <input wire:model="newSlug" placeholder="sales-team">
        @error('newSlug') <div class="err">{{ $message }}</div> @enderror

        <label>Group email <span class="hint">(optional alias)</span></label>
        <input wire:model="newEmail" type="email" placeholder="sales@dartmail.local">
        @error('newEmail') <div class="err">{{ $message }}</div> @enderror

        <label>Description</label>
        <input wire:model="newDescription" placeholder="What this list is for">
        @error('newDescription') <div class="err">{{ $message }}</div> @enderror

        <div style="margin-top: 16px;">
          <button class="btn" type="submit">Create group</button>
        </div>
      </form>
    </div>

    {{-- ─── Group list / member editor ─────────────────────────────── --}}
    <div>
      <h2 style="font: 500 16px/1.3 'Google Sans','Inter',sans-serif; margin: 0 0 12px;">All groups</h2>

      @forelse ($groups as $g)
        <div style="border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin-bottom:10px;background:var(--surface);">
          <div style="display:flex;align-items:center;gap:8px;">
            <strong>{{ $g->name }}</strong>
            <span class="badge none">{{ $g->slug }}</span>
            @if ($g->email)
              <span class="badge none">{{ $g->email }}</span>
            @endif
            <span class="badge {{ $g->members_count ? 'pass' : 'none' }}" style="margin-left:auto;">
              {{ $g->members_count }} {{ \Illuminate\Support\Str::plural('member', $g->members_count) }}
            </span>
          </div>
          @if ($g->description)
            <div style="font-size:12px;color:var(--text-2);margin-top:4px;">{{ $g->description }}</div>
          @endif
          <div style="margin-top:10px;display:flex;gap:8px;">
            <button wire:click="manageMembers({{ $g->id }})" class="btn ghost" type="button" style="padding:4px 10px;font-size:12px;">
              {{ $editingGroupId === $g->id ? 'Editing…' : 'Manage members' }}
            </button>
            <button wire:click="deleteGroup({{ $g->id }})" wire:confirm="Delete group {{ $g->name }}?"
                    class="btn ghost" type="button"
                    style="padding:4px 10px;font-size:12px;color:var(--accent);">Delete</button>
          </div>
        </div>
      @empty
        <p style="color:var(--text-2);">No groups yet.</p>
      @endforelse
    </div>
  </div>

  @if ($editing)
    <div style="margin: 0 20px 24px; border:1px solid var(--line); border-radius:12px; padding:16px 20px; background:var(--surface-2);">
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:12px;">
        <h2 style="font: 500 16px/1.3 'Google Sans','Inter',sans-serif; margin:0;">Members of {{ $editing->name }}</h2>
        <button wire:click="closeMembers" class="btn ghost" type="button"
                style="margin-left:auto;padding:4px 10px;font-size:12px;">Close</button>
      </div>

      <form wire:submit.prevent="addMember" style="display:flex;gap:8px;align-items:flex-end;">
        <div style="flex:1;">
          <label>Add member by email</label>
          <input wire:model="memberEmailToAdd" type="email" placeholder="someone@example.com">
          @error('memberEmailToAdd') <div class="err">{{ $message }}</div> @enderror
        </div>
        <button class="btn" type="submit">Add</button>
      </form>

      <ul style="list-style:none;padding:0;margin:16px 0 0;display:flex;flex-direction:column;gap:6px;">
        @forelse ($editing->members as $m)
          <li style="display:flex;align-items:center;gap:10px;padding:8px 12px;background:var(--surface);border:1px solid var(--line);border-radius:8px;">
            <span style="flex:1;">{{ $m->name }} &lt;{{ $m->email }}&gt;</span>
            <button wire:click="removeMember({{ $m->id }})" class="btn ghost" type="button"
                    style="padding:2px 10px;font-size:12px;color:var(--accent);">Remove</button>
          </li>
        @empty
          <li style="color:var(--text-2);">No members yet.</li>
        @endforelse
      </ul>
    </div>
  @endif
</div>
