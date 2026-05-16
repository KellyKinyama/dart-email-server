<?php

namespace App\Http\Controllers;

use App\Mail\GenericOutboundMail;
use App\Models\OutboundMessage;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Mail;

class ComposeController extends Controller
{
    public function create()
    {
        return view('compose', [
            'defaultFrom' => config('dart_email.smtp.from.address'),
        ]);
    }

    public function store(Request $request)
    {
        $data = $request->validate([
            'to'             => ['required', 'string'],
            'cc'             => ['nullable', 'string'],
            'bcc'            => ['nullable', 'string'],
            'subject'        => ['required', 'string', 'max:255'],
            'text'           => ['nullable', 'string'],
            'html'           => ['nullable', 'string'],
            'from'           => ['nullable', 'email'],
            'fromName'       => ['nullable', 'string', 'max:120'],
            'attachments'    => ['nullable', 'array'],
            'attachments.*'  => ['file', 'max:25600'], // 25 MB each
        ]);

        $split = fn (?string $s) => $s
            ? array_values(array_filter(array_map('trim', preg_split('/[,;]+/', $s))))
            : [];

        $to  = $split($data['to']);
        $cc  = $split($data['cc']  ?? null);
        $bcc = $split($data['bcc'] ?? null);

        // Persist the message record. Attachments are pinned to it via
        // spatie/laravel-medialibrary, which keeps the original filename,
        // mime type, and disk path under our control.
        $message = OutboundMessage::create([
            'subject'       => $data['subject'],
            'from_address'  => $data['from']     ?? null,
            'from_name'     => $data['fromName'] ?? null,
            'to_addresses'  => $to,
            'cc_addresses'  => $cc,
            'bcc_addresses' => $bcc,
            'text_body'     => $data['text'] ?? null,
            'html_body'     => $data['html'] ?? null,
        ]);

        foreach ((array) $request->file('attachments', []) as $upload) {
            if (! $upload || ! $upload->isValid()) { continue; }
            $message
                ->addMedia($upload->getRealPath())
                ->usingFileName($upload->hashName())
                ->usingName($upload->getClientOriginalName())
                ->withCustomProperties([
                    'mime'          => $upload->getClientMimeType(),
                    'original_name' => $upload->getClientOriginalName(),
                ])
                ->toMediaCollection('attachments');
        }

        $mailable = new GenericOutboundMail(
            subjectLine:     $data['subject'],
            textBody:        $data['text'] ?? null,
            htmlBody:        $data['html'] ?? null,
            fromAddress:     $data['from'] ?? null,
            fromName:        $data['fromName'] ?? null,
            attachmentSpecs: $message->attachmentSpecs(),
        );

        $pending = Mail::to($to);
        if ($cc)  { $pending->cc($cc); }
        if ($bcc) { $pending->bcc($bcc); }
        $pending->send($mailable);

        $message->forceFill(['sent_at' => now()])->save();

        return redirect()->route('compose.create')
            ->with('status', 'Message handed to dart_email_server submission port.');
    }
}
