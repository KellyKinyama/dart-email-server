<?php

namespace Tests\Feature;

use App\Models\User;
use App\Notifications\NewMailNotification;
use Database\Seeders\RolesAndAdminSeeder;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\Notification;
use Tests\TestCase;

class PushNotificationTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();
        $this->seed(RolesAndAdminSeeder::class);
        Config::set('dart_email.webhook.secret', 'test-secret');
    }

    public function test_authenticated_user_can_store_a_push_subscription(): void
    {
        $u = User::factory()->create();
        $u->assignRole('user');

        $this->actingAs($u)
            ->postJson('/push/subscribe', [
                'endpoint' => 'https://fcm.googleapis.com/fcm/send/abc123',
                'keys' => [
                    'p256dh' => str_repeat('A', 87) . '=',
                    'auth'   => str_repeat('B', 22),
                ],
            ])
            ->assertOk();

        $this->assertSame(1, $u->pushSubscriptions()->count());
    }

    public function test_user_can_unsubscribe(): void
    {
        $u = User::factory()->create();
        $u->assignRole('user');
        $u->updatePushSubscription(
            'https://fcm.googleapis.com/fcm/send/zzz',
            str_repeat('C', 87),
            str_repeat('D', 22),
        );

        $this->actingAs($u)
            ->postJson('/push/unsubscribe', [
                'endpoint' => 'https://fcm.googleapis.com/fcm/send/zzz',
            ])
            ->assertOk();

        $this->assertSame(0, $u->fresh()->pushSubscriptions()->count());
    }

    public function test_unauthenticated_subscribe_is_rejected(): void
    {
        $this->postJson('/push/subscribe', [
            'endpoint' => 'https://fcm.googleapis.com/fcm/send/no-auth',
            'keys' => ['p256dh' => str_repeat('E', 87), 'auth' => str_repeat('F', 22)],
        ])->assertUnauthorized();
    }

    public function test_incoming_webhook_fans_out_push_to_subscribed_recipients(): void
    {
        Notification::fake();

        $alice = User::factory()->create(['email' => 'alice@example.com']);
        $alice->assignRole('user');
        $alice->updatePushSubscription(
            'https://fcm.googleapis.com/fcm/send/alice',
            str_repeat('G', 87),
            str_repeat('H', 22),
        );

        $bob = User::factory()->create(['email' => 'bob@example.com']);
        $bob->assignRole('user'); // bob has NO push subscription.

        $this->withHeader('Authorization', 'Bearer test-secret')
            ->postJson('/api/incoming-mail', [
                'envelopeFrom' => 'sender@external.test',
                'envelopeTo'   => ['alice@example.com', 'bob@example.com', 'nobody@example.com'],
                'subject'      => 'Hi there',
                'text'         => 'body',
            ])
            ->assertOk();

        Notification::assertSentTo($alice, NewMailNotification::class);
        Notification::assertNotSentTo($bob,  NewMailNotification::class);
    }
}
