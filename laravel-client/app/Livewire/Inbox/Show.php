<?php

namespace App\Livewire\Inbox;

use App\Services\ImapMailboxService;
use Livewire\Attributes\Layout;
use Livewire\Component;

#[Layout('components.layout')]
class Show extends Component
{
    public string $folder;
    public int    $uid;
    public array  $message = [];

    public function mount(ImapMailboxService $imap, string $folder, int $uid): void
    {
        $msg = $imap->getMessage($folder, $uid);
        abort_if(! $msg, 404);

        $this->folder  = $folder;
        $this->uid     = $uid;
        $this->message = $msg;
    }

    public function render()
    {
        return view('livewire.inbox.show')
            ->title($this->message['subject'] ?: '(no subject)');
    }
}
