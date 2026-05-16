<?php

namespace App\Livewire\Webhook;

use App\Models\IncomingMessage;
use Livewire\Attributes\Layout;
use Livewire\Component;

#[Layout('components.layout')]
class Show extends Component
{
    public IncomingMessage $message;

    public function mount(IncomingMessage $message): void
    {
        $this->message = $message;
    }

    public function render()
    {
        return view('livewire.webhook.show')
            ->title($this->message->subject ?: '(no subject)');
    }
}
