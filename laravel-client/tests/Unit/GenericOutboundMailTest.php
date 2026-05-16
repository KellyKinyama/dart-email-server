<?php

namespace Tests\Unit;

use App\Mail\GenericOutboundMail;
use Illuminate\Mail\Mailables\Address;
use Illuminate\Mail\Mailables\Attachment;
use Tests\TestCase;

class GenericOutboundMailTest extends TestCase
{
    public function test_envelope_falls_back_to_default_from_when_unset(): void
    {
        $m = new GenericOutboundMail(subjectLine: 'hi');
        $env = $m->envelope();
        $this->assertSame('hi', $env->subject);
        $this->assertNull($env->from);
    }

    public function test_envelope_uses_explicit_from_address(): void
    {
        $m = new GenericOutboundMail(
            subjectLine: 'hi',
            fromAddress: 'sender@example.com',
            fromName: 'Sender',
        );
        $env = $m->envelope();
        $this->assertInstanceOf(Address::class, $env->from);
        $this->assertSame('sender@example.com', $env->from->address);
        $this->assertSame('Sender', $env->from->name);
    }

    public function test_attachments_list_is_empty_when_specs_empty(): void
    {
        $m = new GenericOutboundMail(subjectLine: 'x');
        $this->assertSame([], $m->attachments());
    }

    public function test_attachments_use_path_filename_and_mime(): void
    {
        $tmp = tempnam(sys_get_temp_dir(), 'att');
        file_put_contents($tmp, 'hello');

        $m = new GenericOutboundMail(
            subjectLine: 'x',
            attachmentSpecs: [[
                'path' => $tmp,
                'as'   => 'file.txt',
                'mime' => 'text/plain',
            ]],
        );

        $atts = $m->attachments();
        $this->assertCount(1, $atts);
        $this->assertInstanceOf(Attachment::class, $atts[0]);

        @unlink($tmp);
    }

    public function test_content_chooses_html_view_when_html_body_present(): void
    {
        $m = new GenericOutboundMail(
            subjectLine: 'x',
            htmlBody: '<p>hi</p>',
        );
        $c = $m->content();
        $this->assertSame('mail.html-only', $c->html);
        $this->assertNull($c->view);
    }

    public function test_content_chooses_text_view_when_only_text_body(): void
    {
        $m = new GenericOutboundMail(subjectLine: 'x', textBody: 'hello');
        $c = $m->content();
        $this->assertSame('mail.text-only', $c->view);
        $this->assertNull($c->html);
    }
}
