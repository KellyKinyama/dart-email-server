<?php

namespace Tests\Feature;

use App\Models\User;
use App\Services\ImapMailboxService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Mockery;
use Tests\TestCase;

class InboxControllerTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();
        $this->actingAs(User::factory()->create());
    }

    protected function tearDown(): void
    {
        Mockery::close();
        parent::tearDown();
    }

    /**
     * Bind a mocked ImapMailboxService into the container so we never
     * touch a real IMAP server.
     */
    protected function fakeImap(array $expectations = []): \Mockery\MockInterface
    {
        $mock = Mockery::mock(ImapMailboxService::class);
        foreach ($expectations as $method => $returns) {
            $mock->shouldReceive($method)->andReturn($returns);
        }
        $this->app->instance(ImapMailboxService::class, $mock);
        return $mock;
    }

    public function test_index_lists_messages(): void
    {
        $this->fakeImap([
            'folders'      => ['INBOX' => 'INBOX', 'Sent' => 'Sent'],
            'listMessages' => [
                [
                    'uid'       => 7,
                    'subject'   => 'hello world',
                    'from'      => 'a@b.com',
                    'fromName'  => 'A',
                    'date'      => '2026-05-16 10:00',
                    'seen'      => false,
                    'size'      => 42,
                    'hasAttach' => true,
                ],
            ],
        ]);

        $this->get('/inbox')
            ->assertStatus(200)
            ->assertSee('hello world');
    }

    public function test_index_renders_gracefully_when_imap_throws(): void
    {
        $mock = Mockery::mock(ImapMailboxService::class);
        $mock->shouldReceive('folders')->andThrow(new \RuntimeException('IMAP down'));
        $this->app->instance(ImapMailboxService::class, $mock);

        $this->get('/inbox')
            ->assertStatus(200)
            ->assertSee('IMAP down');
    }

    public function test_show_returns_404_when_message_missing(): void
    {
        $mock = Mockery::mock(ImapMailboxService::class);
        $mock->shouldReceive('getMessage')->with('INBOX', 99)->andReturn(null);
        $this->app->instance(ImapMailboxService::class, $mock);

        $this->get('/inbox/INBOX/99')->assertStatus(404);
    }

    public function test_show_renders_message_with_cc_bcc_attachments(): void
    {
        $mock = Mockery::mock(ImapMailboxService::class);
        $mock->shouldReceive('getMessage')
            ->with('INBOX', 7)
            ->andReturn([
                'uid'         => 7,
                'subject'     => 'shown',
                'from'        => 'a@b.com',
                'fromName'    => 'A',
                'to'          => ['me@example.com'],
                'cc'          => ['cc@example.com'],
                'bcc'         => ['bcc@example.com'],
                'replyTo'     => ['reply@example.com'],
                'date'        => '2026-05-16 10:00:00',
                'text'        => 'plain body text',
                'html'        => '<p>html body</p>',
                'headers'     => '',
                'size'        => 100,
                'attachments' => [[
                    'index' => 0,
                    'name'  => 'report.pdf',
                    'size'  => 12,
                    'mime'  => 'application/pdf',
                ]],
            ]);
        $this->app->instance(ImapMailboxService::class, $mock);

        $this->get('/inbox/INBOX/7')
            ->assertStatus(200)
            ->assertSee('shown')
            ->assertSee('cc@example.com')
            ->assertSee('bcc@example.com')
            ->assertSee('reply@example.com')
            ->assertSee('report.pdf');
    }

    public function test_attachment_streams_bytes_with_filename_header(): void
    {
        $bytes = "%PDF-fake-bytes";
        $mock = Mockery::mock(ImapMailboxService::class);
        $mock->shouldReceive('getAttachment')
            ->with('INBOX', 7, 0)
            ->andReturn([
                'name'    => 'report.pdf',
                'mime'    => 'application/pdf',
                'content' => $bytes,
            ]);
        $this->app->instance(ImapMailboxService::class, $mock);

        $resp = $this->get('/inbox/INBOX/7/attachment/0');
        $resp->assertStatus(200);
        $resp->assertHeader('Content-Type', 'application/pdf');
        $this->assertStringContainsString(
            'attachment; filename="report.pdf"',
            $resp->headers->get('Content-Disposition')
        );
        $this->assertSame($bytes, $resp->getContent());
    }

    public function test_attachment_returns_404_when_missing(): void
    {
        $mock = Mockery::mock(ImapMailboxService::class);
        $mock->shouldReceive('getAttachment')->andReturn(null);
        $this->app->instance(ImapMailboxService::class, $mock);

        $this->get('/inbox/INBOX/7/attachment/99')->assertStatus(404);
    }
}
