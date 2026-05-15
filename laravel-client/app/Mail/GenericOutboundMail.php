<?php

namespace App\Mail;

use Illuminate\Bus\Queueable;
use Illuminate\Mail\Mailable;
use Illuminate\Mail\Mailables\Address;
use Illuminate\Mail\Mailables\Content;
use Illuminate\Mail\Mailables\Envelope;
use Illuminate\Queue\SerializesModels;

class GenericOutboundMail extends Mailable
{
    use Queueable, SerializesModels;

    public function __construct(
        public string $subjectLine,
        public ?string $textBody = null,
        public ?string $htmlBody = null,
        public ?string $fromAddress = null,
        public ?string $fromName = null,
    ) {}

    public function envelope(): Envelope
    {
        $env = new Envelope(subject: $this->subjectLine);

        if ($this->fromAddress) {
            $env = new Envelope(
                from: new Address($this->fromAddress, $this->fromName ?? ''),
                subject: $this->subjectLine,
            );
        }

        return $env;
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
}
