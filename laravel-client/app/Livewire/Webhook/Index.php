<?php

namespace App\Livewire\Webhook;

use App\Models\IncomingMessage;
use Livewire\Attributes\Layout;
use Livewire\Component;

#[Layout('components.layout')]
class Index extends Component
{
    public function render()
    {
        return view('livewire.webhook.index', [
            'messages' => IncomingMessage::orderByDesc('received_at')->limit(100)->get(),
        ])->title('Webhook log');
    }
}
