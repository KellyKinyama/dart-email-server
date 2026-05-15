<?php

namespace App\Http\Controllers;

use App\Models\IncomingMessage;
use Illuminate\Http\Request;

/**
 * Webhook hit by dart_email_server when an inbound (port 25) message
 * passes its 'mail' event. Authenticate via shared bearer secret.
 *
 * Expected JSON shape:
 *   {
 *     "messageId":   "<...>",
 *     "envelopeFrom":"alice@example.com",
 *     "envelopeTo":  ["bob@example.com"],
 *     "headerFrom":  "Alice <alice@example.com>",
 *     "subject":     "...",
 *     "text":        "...",
 *     "html":        "...",
 *     "raw":         "<base64 bytes>",
 *     "size":        2345,
 *     "auth":        {"spf":"pass","dkim":"pass","dmarc":"pass","rdns":"pass"}
 *   }
 */
class WebhookController extends Controller
{
    public function ingest(Request $request)
    {
        $secret = config('dart_email.webhook.secret');
        $bearer = (string) $request->bearerToken();
        if (! hash_equals($secret, $bearer)) {
            return response()->json(['error' => 'unauthorized'], 401);
        }

        $data = $request->validate([
            'messageId'    => ['nullable', 'string'],
            'envelopeFrom' => ['nullable', 'string'],
            'envelopeTo'   => ['nullable', 'array'],
            'headerFrom'   => ['nullable', 'string'],
            'subject'      => ['nullable', 'string'],
            'text'         => ['nullable', 'string'],
            'html'         => ['nullable', 'string'],
            'raw'          => ['nullable', 'string'],
            'size'         => ['nullable', 'integer'],
            'auth'         => ['nullable', 'array'],
        ]);

        $auth = $data['auth'] ?? [];

        IncomingMessage::create([
            'message_id'    => $data['messageId'] ?? null,
            'envelope_from' => $data['envelopeFrom'] ?? null,
            'envelope_to'   => $data['envelopeTo'] ?? [],
            'header_from'   => $data['headerFrom'] ?? null,
            'subject'       => $data['subject'] ?? null,
            'text_body'     => $data['text'] ?? null,
            'html_body'     => $data['html'] ?? null,
            'raw'           => isset($data['raw']) ? base64_decode($data['raw'], true) ?: $data['raw'] : null,
            'spf'           => $auth['spf']   ?? null,
            'dkim'          => $auth['dkim']  ?? null,
            'dmarc'         => $auth['dmarc'] ?? null,
            'rdns'          => $auth['rdns']  ?? null,
            'size'          => $data['size'] ?? 0,
            'received_at'   => now(),
        ]);

        return response()->json(['accepted' => true]);
    }

    public function index()
    {
        $messages = IncomingMessage::orderByDesc('received_at')->limit(100)->get();
        return view('webhook.index', compact('messages'));
    }

    public function show(IncomingMessage $message)
    {
        return view('webhook.show', compact('message'));
    }
}
