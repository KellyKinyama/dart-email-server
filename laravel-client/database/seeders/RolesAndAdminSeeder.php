<?php

namespace Database\Seeders;

use App\Models\User;
use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\Hash;
use Spatie\Permission\Models\Permission;
use Spatie\Permission\Models\Role;
use Spatie\Permission\PermissionRegistrar;

class RolesAndAdminSeeder extends Seeder
{
    /**
     * Provision the canonical roles + permissions and bootstrap an
     * initial admin account if one does not already exist.
     *
     * Admin credentials may be overridden by environment variables so
     * production deployments don't bake the default password into the
     * source tree:
     *   ADMIN_EMAIL    (default: admin@dartmail.local)
     *   ADMIN_PASSWORD (default: ChangeMe!2026)
     *   ADMIN_NAME     (default: Administrator)
     */
    public function run(): void
    {
        // Make sure the registrar reads fresh role/permission data.
        app(PermissionRegistrar::class)->forgetCachedPermissions();

        $permissions = [
            'manage users',
            'manage roles',
            'view admin panel',
        ];
        foreach ($permissions as $name) {
            Permission::findOrCreate($name, 'web');
        }

        $admin = Role::findOrCreate('admin', 'web');
        $user  = Role::findOrCreate('user',  'web');

        $admin->syncPermissions($permissions);

        $email = env('ADMIN_EMAIL',    'admin@dartmail.local');
        $name  = env('ADMIN_NAME',     'Administrator');
        $pass  = env('ADMIN_PASSWORD', 'ChangeMe!2026');

        $adminUser = User::firstOrCreate(
            ['email' => $email],
            ['name' => $name, 'password' => Hash::make($pass)],
        );
        $adminUser->assignRole($admin);

        $this->command?->info("Admin role + permissions provisioned. Admin user: {$email}");
    }
}
