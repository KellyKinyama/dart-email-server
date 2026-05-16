<?php

namespace Tests\Unit;

use App\Models\OutboundMessage;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Tests\TestCase;

class OutboundMessageTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();
        Storage::fake('public');
    }

    public function test_default_media_collection_is_attachments(): void
    {
        $msg = new OutboundMessage();
        $msg->registerMediaCollections();
        $collections = collect($msg->mediaCollections)->pluck('name')->all();
        $this->assertContains('attachments', $collections);
    }

    public function test_attachment_specs_translates_media_to_array_shape(): void
    {
        $msg = OutboundMessage::create([
            'subject'      => 't',
            'to_addresses' => ['x@example.com'],
        ]);

        $upload = UploadedFile::fake()->create('plan.txt', 1, 'text/plain');
        $msg->addMedia($upload->getRealPath())
            ->usingName('plan.txt')
            ->usingFileName('plan.txt')
            ->withCustomProperties(['mime' => 'text/plain'])
            ->toMediaCollection('attachments');

        $specs = $msg->fresh()->attachmentSpecs();
        $this->assertCount(1, $specs);
        $this->assertSame('plan.txt',   $specs[0]['as']);
        $this->assertSame('text/plain', $specs[0]['mime']);
        $this->assertIsString($specs[0]['path']);
        $this->assertNotSame('', $specs[0]['path']);
    }

    public function test_address_columns_round_trip_as_arrays(): void
    {
        $msg = OutboundMessage::create([
            'subject'       => 'cast',
            'to_addresses'  => ['a@e.com', 'b@e.com'],
            'cc_addresses'  => ['c@e.com'],
            'bcc_addresses' => null,
        ]);
        $reloaded = $msg->fresh();
        $this->assertSame(['a@e.com', 'b@e.com'], $reloaded->to_addresses);
        $this->assertSame(['c@e.com'],            $reloaded->cc_addresses);
        $this->assertNull($reloaded->bcc_addresses);
    }
}
