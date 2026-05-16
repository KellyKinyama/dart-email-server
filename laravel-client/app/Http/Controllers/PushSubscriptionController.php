<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;

/**
 * Stores or removes a Web Push (PushSubscription) for the authenticated
 * user. The browser hands us an endpoint URL + a P-256 public key + an
 * auth secret; we hash them via the package's HasPushSubscriptions trait.
 */
class PushSubscriptionController extends Controller
{
    public function store(Request $request)
    {
        $data = $request->validate([
            'endpoint'        => ['required', 'string', 'url'],
            'keys.p256dh'     => ['required', 'string'],
            'keys.auth'       => ['required', 'string'],
            'content_encoding' => ['nullable', 'string'],
        ]);

        $user = $request->user();
        abort_unless($user, 401);

        $user->updatePushSubscription(
            $data['endpoint'],
            $data['keys']['p256dh'],
            $data['keys']['auth'],
            $data['content_encoding'] ?? null,
        );

        return response()->json(['ok' => true]);
    }

    public function destroy(Request $request)
    {
        $endpoint = (string) $request->input('endpoint');
        $user     = $request->user();
        if ($user && $endpoint !== '') {
            $user->deletePushSubscription($endpoint);
        }
        return response()->json(['ok' => true]);
    }
}
