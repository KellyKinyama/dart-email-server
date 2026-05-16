<?php

namespace App\Livewire\Compose;

use App\Mail\GenericOutboundMail;
use App\Models\OutboundMessage;
use Illuminate\Support\Facades\Mail;
use Livewire\Attributes\Layout;
use Livewire\Attributes\Validate;
use Livewire\Component;
use Livewire\WithFileUploads;

#[Layout('components.layout')]
class Form extends Component
{
    use WithFileUploads;

    #[Validate('nullable|email')]
    public ?string $from = null;

    #[Validate('nullable|string|max:120')]
    public ?string $fromName = null;

    #[Validate('required|string')]
    public string $to = '';

    #[Validate('nullable|string')]
    public ?string $cc = null;

    #[Validate('nullable|string')]
    public ?string $bcc = null;

    #[Validate('required|string|max:255')]
    public string $subject = '';

    #[Validate('nullable|string')]
    public ?string $text = null;

    #[Validate('nullable|string')]
    public ?string $html = null;

    /** @var array<int, \Livewire\Features\SupportFileUploads\TemporaryUploadedFile> */
    #[Validate(['attachments.*' => 'file|max:25600'])]
    public array $attachments = [];

    public bool $showCc  = false;
    public bool $showBcc = false;

    public function mount(): void
    {
        $this->from = (string) (config('dart_email.smtp.from.address') ?? '');
    }

    public function toggleCc(): void  { $this->showCc  = ! $this->showCc;  }
    public function toggleBcc(): void { $this->showBcc = ! $this->showBcc; }

    /**
     * Expand recipient tokens into bare email addresses.
     *
     * Each comma/semicolon-separated entry is treated as one of:
     *   - a literal email address (passed through)
     *   - a group reference of the form `group:slug`
     *   - the alias email of a Group (e.g. `sales@dartmail.local`)
     *
     * Group entries are replaced with the email of every linked user.
     * Empty members and duplicates are dropped while preserving order.
     *
     * @return list<string>
     */
    public static function expandRecipients(?string $raw): array
    {
        if (! $raw) { return []; }

        $tokens = array_values(array_filter(array_map('trim',
            preg_split('/[,;]+/', $raw) ?: []
        )));

        $out = [];
        foreach ($tokens as $tok) {
            $emails = [$tok];
            if (str_starts_with(strtolower($tok), 'group:')) {
                $slug   = substr($tok, 6);
                $group  = \App\Models\Group::firstWhere('slug', $slug);
                $emails = $group ? $group->memberEmails() : [];
            } else {
                $group = \App\Models\Group::firstWhere('email', $tok);
                if ($group) {
                    $emails = $group->memberEmails();
                }
            }
            foreach ($emails as $e) {
                if ($e !== '' && ! in_array($e, $out, true)) {
                    $out[] = $e;
                }
            }
        }
        return $out;
    }

    public function send(): void
    {
        $this->validate();

        $to  = self::expandRecipients($this->to);
        $cc  = self::expandRecipients($this->cc);
        $bcc = self::expandRecipients($this->bcc);

        $message = OutboundMessage::create([
            'subject'       => $this->subject,
            'from_address'  => $this->from     ?: null,
            'from_name'     => $this->fromName ?: null,
            'to_addresses'  => $to,
            'cc_addresses'  => $cc,
            'bcc_addresses' => $bcc,
            'text_body'     => $this->text ?: null,
            'html_body'     => $this->html ?: null,
        ]);

        foreach ($this->attachments as $upload) {
            if (! $upload) { continue; }
            $message
                ->addMedia($upload->getRealPath())
                ->usingFileName($upload->hashName())
                ->usingName($upload->getClientOriginalName())
                ->withCustomProperties([
                    'mime'          => $upload->getMimeType(),
                    'original_name' => $upload->getClientOriginalName(),
                ])
                ->toMediaCollection('attachments');
        }

        $mailable = new GenericOutboundMail(
            subjectLine:     $this->subject,
            textBody:        $this->text ?: null,
            htmlBody:        $this->html ?: null,
            fromAddress:     $this->from ?: null,
            fromName:        $this->fromName ?: null,
            attachmentSpecs: $message->attachmentSpecs(),
        );

        $pending = Mail::to($to);
        if ($cc)  { $pending->cc($cc); }
        if ($bcc) { $pending->bcc($bcc); }
        $pending->send($mailable);

        $message->forceFill(['sent_at' => now()])->save();

        session()->flash('status', 'Message handed to dart_email_server submission port.');

        $this->redirectRoute('compose.create', navigate: true);
    }

    public function render()
    {
        return view('livewire.compose.form')->title('Compose');
    }
}
