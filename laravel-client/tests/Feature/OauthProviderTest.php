<?php

namespace Tests\Feature;

use App\Models\User;
use Database\Seeders\RolesAndAdminSeeder;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Passport\Client;
use Laravel\Passport\ClientRepository;
use Tests\TestCase;

class OauthProviderTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();
        $this->seed(RolesAndAdminSeeder::class);
        // Generate Passport encryption keys for the in-memory test DB run.
        $this->artisan('passport:keys', ['--force' => true])->run();
    }

    public function test_oauth_authorize_endpoint_is_registered(): void
    {
        $routes = collect(app('router')->getRoutes())
            ->map(fn ($r) => $r->uri())
            ->all();

        $this->assertContains('oauth/authorize', $routes);
        $this->assertContains('oauth/token',     $routes);
    }

    public function test_personal_access_token_authenticates_api_user(): void
    {
        $u = User::factory()->create();
        $u->assignRole('user');

        // Personal access client must exist for createToken() to work.
        app(ClientRepository::class)->createPersonalAccessGrantClient('PAT');

        $token = $u->createToken('test-token')->accessToken;

        $this->withHeader('Authorization', "Bearer {$token}")
            ->getJson('/api/user')
            ->assertOk()
            ->assertJsonPath('email', $u->email);
    }

    public function test_admin_can_create_oauth_client_via_repository(): void
    {
        $admin = User::factory()->create();
        $admin->assignRole('admin');

        $client = app(ClientRepository::class)->createAuthorizationCodeGrantClient(
            name: 'Third party',
            redirectUris: ['https://example.com/cb'],
            confidential: true,
            user: $admin,
        );

        $this->assertInstanceOf(Client::class, $client);
        $this->assertNotNull($client->plainSecret);
        $this->assertDatabaseHas('oauth_clients', ['name' => 'Third party']);
    }

    public function test_admin_panel_is_admin_only(): void
    {
        $u = User::factory()->create();
        $u->assignRole('user');
        $this->actingAs($u)->get('/admin/oauth-clients')->assertStatus(403);
    }
}
