<?php

namespace App\Http\Controllers;

use App\Mail\GenericOutboundMail;
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

        // Persist uploads so the mailable can read them at send time.
        $specs = [];
        foreach ((array) $request->file('attachments', []) as $upload) {
            if (! $upload || ! $upload->isValid()) { continue; }
            $stored = $upload->store('outbound-attachments');
            $path   = storage_path('app/private/' . $stored);
            if (! is_file($path)) {
                $path = storage_path('app/' . $stored);
            }
            $specs[] = [
                'path' => $path,
                'as'   => $upload->getClientOriginalName(),
                'mime' => $upload->getClientMimeType(),
            ];
        }

        $mailable = new GenericOutboundMail(
            subjectLine:     $data['subject'],
            textBody:        $data['text'] ?? null,
            htmlBody:        $data['html'] ?? null,
            fromAddress:     $data['from'] ?? null,
            fromName:        $data['fromName'] ?? null,
            attachmentSpecs: $specs,
        );

        $pending = Mail::to($to);
        if ($cc)  { $pending->cc($cc); }
        if ($bcc) { $pending->bcc($bcc); }
        $pending->send($mailable);

        return redirect()->route('compose.create')
            ->with('status', 'Message handed to dart_email_server submission port.');
    }
}
