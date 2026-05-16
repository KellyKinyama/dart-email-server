<?php

namespace App\Livewire\Admin;

use App\Models\User;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;
use Livewire\Attributes\Layout;
use Livewire\Component;
use Livewire\WithPagination;
use Spatie\Permission\Models\Role;

#[Layout('components.layout')]
class Users extends Component
{
    use WithPagination;

    public string $search = '';
    public ?string $statusMessage = null;

    public function updatingSearch(): void
    {
        $this->resetPage();
    }

    public function toggleAdmin(int $userId): void
    {
        $user = User::findOrFail($userId);
        if ($user->id === auth()->id()) {
            $this->statusMessage = "You can't change your own admin role.";
            return;
        }
        if ($user->hasRole('admin')) {
            $user->removeRole('admin');
            $user->assignRole('user');
            $this->statusMessage = "Removed admin from {$user->email}.";
        } else {
            $user->assignRole('admin');
            $this->statusMessage = "Granted admin to {$user->email}.";
        }
    }

    public function resetPassword(int $userId): void
    {
        $user = User::findOrFail($userId);
        $temp = Str::random(14);
        $user->forceFill(['password' => Hash::make($temp)])->save();
        // Surfaced once so the admin can hand it to the user out-of-band.
        $this->statusMessage = "Temporary password for {$user->email}: {$temp}";
    }

    public function deleteUser(int $userId): void
    {
        $user = User::findOrFail($userId);
        if ($user->id === auth()->id()) {
            $this->statusMessage = "You can't delete your own account here.";
            return;
        }
        $email = $user->email;
        $user->delete();
        $this->statusMessage = "Deleted {$email}.";
    }

    public function render()
    {
        $users = User::query()
            ->when($this->search !== '', fn ($q) => $q
                ->where('email', 'like', "%{$this->search}%")
                ->orWhere('name', 'like', "%{$this->search}%"))
            ->orderBy('id')
            ->paginate(20);

        return view('livewire.admin.users', [
            'users' => $users,
            'roles' => Role::pluck('name'),
        ])->title('Admin · Users');
    }
}
