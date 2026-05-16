<?php

namespace Tests\Feature;

use App\Livewire\Admin\Users as AdminUsers;
use App\Models\User;
use Database\Seeders\RolesAndAdminSeeder;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;
use Spatie\Permission\Models\Role;
use Tests\TestCase;

class AdminTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();
        $this->seed(RolesAndAdminSeeder::class);
    }

    private function admin(): User
    {
        $u = User::factory()->create();
        $u->assignRole('admin');
        return $u;
    }

    private function regular(): User
    {
        $u = User::factory()->create();
        $u->assignRole('user');
        return $u;
    }

    public function test_seeder_creates_admin_role_and_default_admin_user(): void
    {
        $this->assertTrue(Role::where('name', 'admin')->exists());
        $this->assertTrue(Role::where('name', 'user')->exists());
        $admin = User::where('email', 'admin@dartmail.local')->first();
        $this->assertNotNull($admin);
        $this->assertTrue($admin->hasRole('admin'));
    }

    public function test_non_admin_cannot_access_admin_users(): void
    {
        $this->actingAs($this->regular())
            ->get('/admin/users')
            ->assertStatus(403);
    }

    public function test_unauthenticated_admin_users_redirects_to_login(): void
    {
        $this->get('/admin/users')->assertRedirect('/login');
    }

    public function test_admin_can_access_admin_users(): void
    {
        $this->actingAs($this->admin())
            ->get('/admin/users')
            ->assertStatus(200)
            ->assertSee('Admin · Users', false);
    }

    public function test_admin_can_grant_and_revoke_admin_role(): void
    {
        $this->actingAs($this->admin());
        $target = $this->regular();

        Livewire::test(AdminUsers::class)->call('toggleAdmin', $target->id);
        $this->assertTrue($target->fresh()->hasRole('admin'));

        Livewire::test(AdminUsers::class)->call('toggleAdmin', $target->id);
        $this->assertFalse($target->fresh()->hasRole('admin'));
    }

    public function test_admin_cannot_change_own_admin_role(): void
    {
        $admin = $this->admin();
        $this->actingAs($admin);

        Livewire::test(AdminUsers::class)
            ->call('toggleAdmin', $admin->id)
            ->assertSet('statusMessage', "You can't change your own admin role.");

        $this->assertTrue($admin->fresh()->hasRole('admin'));
    }

    public function test_admin_can_reset_user_password(): void
    {
        $this->actingAs($this->admin());
        $target  = $this->regular();
        $oldHash = $target->password;

        Livewire::test(AdminUsers::class)->call('resetPassword', $target->id);

        $this->assertNotSame($oldHash, $target->fresh()->password);
    }

    public function test_admin_can_delete_user(): void
    {
        $this->actingAs($this->admin());
        $target = $this->regular();

        Livewire::test(AdminUsers::class)->call('deleteUser', $target->id);

        $this->assertDatabaseMissing('users', ['id' => $target->id]);
    }

    public function test_newly_registered_user_gets_user_role(): void
    {
        $this->post('/register', [
            'name'                  => 'Joe',
            'email'                 => 'joe@example.com',
            'password'              => 'password1234',
            'password_confirmation' => 'password1234',
        ])->assertRedirect();

        $u = User::firstWhere('email', 'joe@example.com');
        $this->assertNotNull($u);
        $this->assertTrue($u->hasRole('user'));
        $this->assertFalse($u->hasRole('admin'));
    }
}
