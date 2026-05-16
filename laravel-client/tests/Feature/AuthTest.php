<?php

namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Hash;
use Tests\TestCase;

class AuthTest extends TestCase
{
    use RefreshDatabase;

    public function test_login_view_renders(): void
    {
        $this->get('/login')->assertStatus(200)->assertSee('Sign in');
    }

    public function test_register_view_renders(): void
    {
        $this->get('/register')->assertStatus(200)->assertSee('Create your account');
    }

    public function test_unauthenticated_inbox_redirects_to_login(): void
    {
        $this->get('/inbox')->assertRedirect('/login');
    }

    public function test_user_can_register(): void
    {
        $this->post('/register', [
            'name'                  => 'Test User',
            'email'                 => 'newuser@example.com',
            'password'              => 'password1234',
            'password_confirmation' => 'password1234',
        ])->assertRedirect(); // Fortify redirects to fortify.home on success.

        $this->assertDatabaseHas('users', ['email' => 'newuser@example.com']);
        $this->assertAuthenticated();
    }

    public function test_user_can_log_in(): void
    {
        User::factory()->create([
            'email'    => 'me@example.com',
            'password' => Hash::make('secret-pass'),
        ]);

        $this->post('/login', [
            'email'    => 'me@example.com',
            'password' => 'secret-pass',
        ])->assertRedirect();

        $this->assertAuthenticated();
    }

    public function test_user_can_log_out(): void
    {
        $this->actingAs(User::factory()->create());
        $this->post('/logout')->assertRedirect();
        $this->assertGuest();
    }

    public function test_login_fails_with_wrong_password(): void
    {
        User::factory()->create([
            'email'    => 'me@example.com',
            'password' => Hash::make('secret-pass'),
        ]);

        $this->from('/login')->post('/login', [
            'email'    => 'me@example.com',
            'password' => 'wrong-password',
        ])->assertRedirect('/login')
          ->assertSessionHasErrors('email');

        $this->assertGuest();
    }
}
