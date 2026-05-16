<?php

namespace App\Http\Controllers;

use App\Models\IncomingMessage;
use Illuminate\Http\Request;

/**
 * Thin controller for the inbound webhook ingest endpoint.
 *
 * The browse/show UI lives in App\Livewire\Webhook\{Index,Show}.
 * The ingest endpoint stays as a stateless controller because it is a
 * server-to-server JSON API hit by dart_email_server, not a Livewire
 * component.
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
}
