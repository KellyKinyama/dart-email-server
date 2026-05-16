<?php

namespace Tests\Feature;

use App\Mail\GenericOutboundMail;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Storage;
use Tests\TestCase;

class ComposeControllerTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        Mail::fake();
        Storage::fake('local');
    }

    public function test_get_compose_shows_form(): void
    {
        $response = $this->get('/compose');
        $response->assertStatus(200);
        $response->assertSee('compose', false);
    }

    public function test_to_subject_required(): void
    {
        $this->from('/compose')
            ->post('/compose', [])
            ->assertStatus(302)
            ->assertSessionHasErrors(['to', 'subject']);
        Mail::assertNothingOutgoing();
    }

    public function test_minimal_send_works(): void
    {
        $this->post('/compose', [
            'to'      => 'rcpt@example.com',
            'subject' => 'hi',
            'text'    => 'body',
        ])->assertRedirect(route('compose.create'))
          ->assertSessionHas('status');

        Mail::assertSent(GenericOutboundMail::class, function ($mail) {
            return $mail->hasTo('rcpt@example.com')
                && $mail->subjectLine === 'hi'
                && $mail->textBody === 'body';
        });
    }

    public function test_cc_and_bcc_get_split_and_attached(): void
    {
        $this->post('/compose', [
            'to'      => 'a@example.com, b@example.com',
            'cc'      => 'cc1@example.com; cc2@example.com',
            'bcc'     => 'bcc@example.com',
            'subject' => 'multi-recipient',
            'text'    => 'hello',
        ])->assertRedirect(route('compose.create'));

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

        $this->post('/compose', [
            'to'             => 'rcpt@example.com',
            'subject'        => 'with attachment',
            'text'           => 'see attached',
            'attachments'    => [$upload],
        ])->assertRedirect(route('compose.create'));

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
        // 30 MB > 25 MB cap.
        $upload = UploadedFile::fake()->create('big.bin', 30 * 1024);

        $this->from('/compose')
            ->post('/compose', [
                'to'          => 'rcpt@example.com',
                'subject'     => 'oversize',
                'text'        => 'nope',
                'attachments' => [$upload],
            ])
            ->assertStatus(302)
            ->assertSessionHasErrors('attachments.0');

        Mail::assertNothingOutgoing();
    }

    public function test_invalid_email_in_from_field_rejected(): void
    {
        $this->from('/compose')
            ->post('/compose', [
                'to'      => 'rcpt@example.com',
                'subject' => 'bad from',
                'text'    => 'x',
                'from'    => 'not-an-email',
            ])
            ->assertStatus(302)
            ->assertSessionHasErrors('from');
    }

    public function test_explicit_from_address_propagates_to_envelope(): void
    {
        $this->post('/compose', [
            'to'       => 'rcpt@example.com',
            'subject'  => 'branded',
            'text'     => 'hi',
            'from'     => 'sender@example.com',
            'fromName' => 'Sender Name',
        ])->assertRedirect(route('compose.create'));

        Mail::assertSent(GenericOutboundMail::class, function ($mail) {
            $env = $mail->envelope();
            return $env->from?->address === 'sender@example.com'
                && $env->from?->name    === 'Sender Name'
                && $env->subject         === 'branded';
        });
    }
}
