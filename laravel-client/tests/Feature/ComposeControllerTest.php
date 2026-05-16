<?php

namespace Tests\Feature;

use App\Livewire\Compose\Form;
use App\Mail\GenericOutboundMail;
use App\Models\OutboundMessage;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;
use Tests\TestCase;

/**
 * Exercises App\Livewire\Compose\Form (the former ComposeController).
 */
class ComposeControllerTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();
        Mail::fake();
        Storage::fake('public');
        Storage::fake('local');
        $this->actingAs(\App\Models\User::factory()->create());
    }

    public function test_get_compose_shows_form(): void
    {
        $this->get('/compose')
            ->assertStatus(200)
            ->assertSee('New message');
    }

    public function test_to_subject_required(): void
    {
        Livewire::test(Form::class)
            ->set('to', '')
            ->set('subject', '')
            ->call('send')
            ->assertHasErrors(['to' => 'required', 'subject' => 'required']);

        Mail::assertNothingOutgoing();
    }

    public function test_minimal_send_works(): void
    {
        Livewire::test(Form::class)
            ->set('to', 'rcpt@example.com')
            ->set('subject', 'hi')
            ->set('text', 'body')
            ->call('send')
            ->assertHasNoErrors()
            ->assertRedirect(route('compose.create'));

        Mail::assertSent(GenericOutboundMail::class, function ($mail) {
            return $mail->hasTo('rcpt@example.com')
                && $mail->subjectLine === 'hi'
                && $mail->textBody === 'body';
        });
    }

    public function test_cc_and_bcc_get_split_and_attached(): void
    {
        Livewire::test(Form::class)
            ->set('to',  'a@example.com, b@example.com')
            ->set('cc',  'cc1@example.com; cc2@example.com')
            ->set('bcc', 'bcc@example.com')
            ->set('subject', 'multi-recipient')
            ->set('text', 'hello')
            ->call('send')
            ->assertHasNoErrors();

        Mail::assertSent(GenericOutboundMail::class, function ($mail) {
            return $mail->hasTo('a@example.com')
                && $mail->hasTo('b@example.com')
                && $mail->hasCc('cc1@example.com')
                && $mail->hasCc('cc2@example.com')
                && $mail->hasBcc('bcc@example.com');
        });
    }

    public function test_attachment_specs_are_persisted_and_passed_through(): void
    {
        $upload = UploadedFile::fake()->create('report.pdf', 12, 'application/pdf');

        Livewire::test(Form::class)
            ->set('to', 'rcpt@example.com')
            ->set('subject', 'with attachment')
            ->set('text', 'see attached')
            ->set('attachments', [$upload])
            ->call('send')
            ->assertHasNoErrors();

        Mail::assertSent(GenericOutboundMail::class, function ($mail) {
            $specs = $mail->attachmentSpecs;
            return count($specs) === 1
                && $specs[0]['as']   === 'report.pdf'
                && $specs[0]['mime'] === 'application/pdf'
                && is_string($specs[0]['path'])
                && $specs[0]['path'] !== '';
        });
    }

    public function test_attachment_too_large_is_rejected(): void
    {
        $upload = UploadedFile::fake()->create('big.bin', 30 * 1024); // 30 MB

        // Livewire's WithFileUploads runs its own size validation when the
        // file is staged via set(). Either the upload itself errors or the
        // explicit validate() in send() rejects the attachments.* rule.
        $component = Livewire::test(Form::class)
            ->set('to', 'rcpt@example.com')
            ->set('subject', 'oversize')
            ->set('text', 'nope')
            ->set('attachments', [$upload]);

        $errors = $component->errors();
        if ($errors->isEmpty()) {
            $component->call('send');
            $errors = $component->errors();
        }

        $this->assertTrue(
            $errors->has('attachments') || $errors->has('attachments.0'),
            'Expected an error on attachments or attachments.0; got: ' . $errors->toJson()
        );

        Mail::assertNothingOutgoing();
    }

    public function test_invalid_email_in_from_field_rejected(): void
    {
        Livewire::test(Form::class)
            ->set('from', 'not-an-email')
            ->set('to', 'rcpt@example.com')
            ->set('subject', 'bad from')
            ->set('text', 'x')
            ->call('send')
            ->assertHasErrors(['from' => 'email']);
    }

    public function test_explicit_from_address_propagates_to_envelope(): void
    {
        Livewire::test(Form::class)
            ->set('to', 'rcpt@example.com')
            ->set('subject', 'branded')
            ->set('text', 'hi')
            ->set('from', 'sender@example.com')
            ->set('fromName', 'Sender Name')
            ->call('send')
            ->assertHasNoErrors();

        Mail::assertSent(GenericOutboundMail::class, function ($mail) {
            $env = $mail->envelope();
            return $env->from?->address === 'sender@example.com'
                && $env->from?->name    === 'Sender Name'
                && $env->subject         === 'branded';
        });
    }

    public function test_outbound_message_is_persisted_with_recipients_and_sent_at(): void
    {
        Livewire::test(Form::class)
            ->set('to', 'a@example.com, b@example.com')
            ->set('cc', 'cc@example.com')
            ->set('bcc', 'bcc@example.com')
            ->set('subject', 'stored')
            ->set('text', 'persist me')
            ->call('send')
            ->assertHasNoErrors();

        $msg = OutboundMessage::firstWhere('subject', 'stored');
        $this->assertNotNull($msg);
        $this->assertSame(['a@example.com', 'b@example.com'], $msg->to_addresses);
        $this->assertSame(['cc@example.com'], $msg->cc_addresses);
        $this->assertSame(['bcc@example.com'], $msg->bcc_addresses);
        $this->assertNotNull($msg->sent_at, 'sent_at should be stamped after Mail::send');
    }

    public function test_uploaded_attachment_is_stored_via_media_library(): void
    {
        $upload = UploadedFile::fake()->create('report.pdf', 12, 'application/pdf');

        Livewire::test(Form::class)
            ->set('to', 'rcpt@example.com')
            ->set('subject', 'with media')
            ->set('text', 'see attached')
            ->set('attachments', [$upload])
            ->call('send')
            ->assertHasNoErrors();

        $msg = OutboundMessage::firstWhere('subject', 'with media');
        $this->assertNotNull($msg);

        $media = $msg->getMedia('attachments');
        $this->assertCount(1, $media);
        $this->assertSame('report.pdf',      $media->first()->name);
        $this->assertSame('application/pdf', $media->first()->getCustomProperty('mime'));
        $this->assertSame('attachments',     $media->first()->collection_name);
    }
}
