<?php

namespace App\Mail;

use Illuminate\Bus\Queueable;
use Illuminate\Mail\Mailable;
use Illuminate\Mail\Mailables\Address;
use Illuminate\Mail\Mailables\Attachment;
use Illuminate\Mail\Mailables\Content;
use Illuminate\Mail\Mailables\Envelope;
use Illuminate\Queue\SerializesModels;

class GenericOutboundMail extends Mailable
{
    use Queueable, SerializesModels;

    /**
     * @param  array<int, array{path:string, as:?string, mime:?string}>  $attachmentSpecs
     */
    public function __construct(
        public string $subjectLine,
        public ?string $textBody = null,
        public ?string $htmlBody = null,
        public ?string $fromAddress = null,
        public ?string $fromName = null,
        public array $attachmentSpecs = [],
    ) {}

    public function envelope(): Envelope
    {
        if ($this->fromAddress) {
            return new Envelope(
                from: new Address($this->fromAddress, $this->fromName ?? ''),
                subject: $this->subjectLine,
            );
        }

        return new Envelope(subject: $this->subjectLine);
    }

    public function content(): Content
    {
        return new Content(
            view: $this->htmlBody ? null : 'mail.text-only',
            html: $this->htmlBody ? 'mail.html-only' : null,
            with: [
                'textBody' => $this->textBody ?? '',
                'htmlBody' => $this->htmlBody ?? '',
            ],
        );
    }

    /** @return array<int, Attachment> */
    public function attachments(): array
    {
        $out = [];
        foreach ($this->attachmentSpecs as $spec) {
            $a = Attachment::fromPath($spec['path']);
            if (! empty($spec['as']))   { $a = $a->as($spec['as']); }
            if (! empty($spec['mime'])) { $a = $a->withMime($spec['mime']); }
            $out[] = $a;
        }
        return $out;
    }
}
