<?php

namespace App\Livewire\Admin;

use App\Models\Group;
use App\Models\User;
use Livewire\Attributes\Layout;
use Livewire\Component;

#[Layout('components.layout')]
class Groups extends Component
{
    // Create-form state.
    public string $newName        = '';
    public string $newSlug        = '';
    public string $newEmail       = '';
    public string $newDescription = '';

    public ?int   $editingGroupId    = null;
    public string $memberEmailToAdd  = '';
    public ?string $statusMessage    = null;

    protected function rules(): array
    {
        return [
            'newName'        => ['required', 'string', 'max:120'],
            'newSlug'        => ['nullable', 'string', 'max:80', 'alpha_dash'],
            'newEmail'       => ['nullable', 'email'],
            'newDescription' => ['nullable', 'string', 'max:255'],
        ];
    }

    public function createGroup(): void
    {
        $data = $this->validate();

        Group::create([
            'name'        => $data['newName'],
            'slug'        => $data['newSlug'] ?: null,
            'email'       => $data['newEmail'] ?: null,
            'description' => $data['newDescription'] ?: null,
        ]);

        $this->reset(['newName', 'newSlug', 'newEmail', 'newDescription']);
        $this->statusMessage = 'Group created.';
    }

    public function deleteGroup(int $groupId): void
    {
        Group::findOrFail($groupId)->delete();
        if ($this->editingGroupId === $groupId) {
            $this->editingGroupId = null;
        }
        $this->statusMessage = 'Group deleted.';
    }

    public function manageMembers(int $groupId): void
    {
        $this->editingGroupId   = $groupId;
        $this->memberEmailToAdd = '';
    }

    public function closeMembers(): void
    {
        $this->editingGroupId = null;
    }

    public function addMember(): void
    {
        if (! $this->editingGroupId) { return; }
        $email = trim($this->memberEmailToAdd);
        if ($email === '') { return; }

        $user = User::firstWhere('email', $email);
        if (! $user) {
            $this->addError('memberEmailToAdd', "No user with email {$email}.");
            return;
        }

        Group::findOrFail($this->editingGroupId)->members()->syncWithoutDetaching([$user->id]);
        $this->memberEmailToAdd = '';
        $this->statusMessage    = "Added {$email} to group.";
    }

    public function removeMember(int $userId): void
    {
        if (! $this->editingGroupId) { return; }
        Group::findOrFail($this->editingGroupId)->members()->detach($userId);
        $this->statusMessage = 'Member removed.';
    }

    public function render()
    {
        $groups = Group::withCount('members')->orderBy('name')->get();
        $editing = $this->editingGroupId
            ? Group::with('members')->find($this->editingGroupId)
            : null;

        return view('livewire.admin.groups', compact('groups', 'editing'))
            ->title('Admin · Groups');
    }
}
