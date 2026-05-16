<?php

namespace App\Livewire\Push;

use Livewire\Component;

/**
 * Tiny UI in the sidebar/header that lets the signed-in user enable or
 * disable browser push notifications. The actual subscription dance
 * happens in the browser via /js/push.js; this component just publishes
 * the VAPID public key + endpoints the JS needs.
 */
class Toggle extends Component
{
    public function render()
    {
        return view('livewire.push.toggle', [
            'vapidPublicKey' => config('webpush.vapid.public_key', env('VAPID_PUBLIC_KEY', '')),
            'subscribeUrl'   => route('push.subscribe'),
            'unsubscribeUrl' => route('push.unsubscribe'),
        ]);
    }
}
