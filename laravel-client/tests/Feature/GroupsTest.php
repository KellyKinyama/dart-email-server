<?php

namespace Tests\Feature;

use App\Livewire\Admin\Groups as AdminGroups;
use App\Livewire\Compose\Form as ComposeForm;
use App\Mail\GenericOutboundMail;
use App\Models\Group;
use App\Models\User;
use Database\Seeders\RolesAndAdminSeeder;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;
use Tests\TestCase;

class GroupsTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();
        $this->seed(RolesAndAdminSeeder::class);
        Mail::fake();
        Storage::fake('public');
    }

    private function admin(): User
    {
        $u = User::factory()->create();
        $u->assignRole('admin');
        return $u;
    }

    public function test_group_slug_is_auto_derived(): void
    {
        $g = Group::create(['name' => 'Sales Team']);
        $this->assertSame('sales-team', $g->slug);
    }

    public function test_member_emails_pulls_from_users(): void
    {
        $g = Group::create(['name' => 'Eng']);
        $a = User::factory()->create(['email' => 'a@example.com']);
        $b = User::factory()->create(['email' => 'b@example.com']);
        $g->members()->attach([$a->id, $b->id]);

        $this->assertEqualsCanonicalizing(
            ['a@example.com', 'b@example.com'],
            $g->memberEmails(),
        );
    }

    public function test_admin_can_create_group(): void
    {
        $this->actingAs($this->admin());

        Livewire::test(AdminGroups::class)
            ->set('newName', 'Marketing')
            ->set('newEmail', 'marketing@dartmail.local')
            ->call('createGroup')
            ->assertHasNoErrors();

        $this->assertDatabaseHas('groups', [
            'name'  => 'Marketing',
            'slug'  => 'marketing',
            'email' => 'marketing@dartmail.local',
        ]);
    }

    public function test_admin_can_add_and_remove_members(): void
    {
        $this->actingAs($this->admin());
        $group = Group::create(['name' => 'Crew']);
        $user  = User::factory()->create(['email' => 'crew1@example.com']);

        Livewire::test(AdminGroups::class)
            ->call('manageMembers', $group->id)
            ->set('memberEmailToAdd', 'crew1@example.com')
            ->call('addMember')
            ->assertHasNoErrors();

        $this->assertTrue($group->fresh()->members->contains($user));

        Livewire::test(AdminGroups::class)
            ->call('manageMembers', $group->id)
            ->call('removeMember', $user->id);

        $this->assertFalse($group->fresh()->members->contains($user));
    }

    public function test_add_unknown_email_errors(): void
    {
        $this->actingAs($this->admin());
        $group = Group::create(['name' => 'Ops']);

        Livewire::test(AdminGroups::class)
            ->call('manageMembers', $group->id)
            ->set('memberEmailToAdd', 'nobody@example.com')
            ->call('addMember')
            ->assertHasErrors('memberEmailToAdd');
    }

    public function test_non_admin_cannot_access_groups_panel(): void
    {
        $u = User::factory()->create();
        $u->assignRole('user');
        $this->actingAs($u)->get('/admin/groups')->assertStatus(403);
    }

    public function test_compose_expands_group_slug_into_member_emails(): void
    {
        $sender = User::factory()->create();
        $sender->assignRole('user');
        $this->actingAs($sender);

        $g = Group::create(['name' => 'List', 'slug' => 'list']);
        $g->members()->attach([
            User::factory()->create(['email' => 'm1@example.com'])->id,
            User::factory()->create(['email' => 'm2@example.com'])->id,
        ]);

        Livewire::test(ComposeForm::class)
            ->set('to', 'group:list')
            ->set('subject', 'hello list')
            ->set('text', 'hi')
            ->call('send')
            ->assertHasNoErrors();

        Mail::assertSent(GenericOutboundMail::class, function ($mail) {
            return $mail->hasTo('m1@example.com') && $mail->hasTo('m2@example.com');
        });
    }

    public function test_compose_expands_group_email_alias(): void
    {
        $sender = User::factory()->create();
        $sender->assignRole('user');
        $this->actingAs($sender);

        $g = Group::create(['name' => 'Sales', 'email' => 'sales@dartmail.local']);
        $g->members()->attach(
            User::factory()->create(['email' => 'rep@example.com'])->id
        );

        Livewire::test(ComposeForm::class)
            ->set('to', 'sales@dartmail.local')
            ->set('subject', 'hi sales')
            ->set('text', 'hi')
            ->call('send')
            ->assertHasNoErrors();

        Mail::assertSent(GenericOutboundMail::class, fn ($m) => $m->hasTo('rep@example.com'));
    }

    public function test_expand_recipients_drops_duplicates(): void
    {
        $g = Group::create(['name' => 'Dup', 'slug' => 'dup']);
        $g->members()->attach([
            User::factory()->create(['email' => 'x@example.com'])->id,
            User::factory()->create(['email' => 'y@example.com'])->id,
        ]);

        $expanded = ComposeForm::expandRecipients('x@example.com, group:dup');
        $this->assertSame(['x@example.com', 'y@example.com'], $expanded);
    }
}
