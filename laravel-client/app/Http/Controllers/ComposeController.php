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
            'to'       => ['required', 'string'],
            'subject'  => ['required', 'string', 'max:255'],
            'text'     => ['nullable', 'string'],
            'html'     => ['nullable', 'string'],
            'from'     => ['nullable', 'email'],
            'fromName' => ['nullable', 'string', 'max:120'],
        ]);

        $recipients = array_filter(array_map('trim', preg_split('/[,;]+/', $data['to'])));

        Mail::to($recipients)->send(new GenericOutboundMail(
            subjectLine: $data['subject'],
            textBody:    $data['text'] ?? null,
            htmlBody:    $data['html'] ?? null,
            fromAddress: $data['from'] ?? null,
            fromName:    $data['fromName'] ?? null,
        ));

        return redirect()->route('compose.create')
            ->with('status', 'Message handed to dart_email_server submission port.');
    }
}
