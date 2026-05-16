<?php

namespace App\Livewire\Inbox;

use App\Services\ImapMailboxService;
use Livewire\Attributes\Layout;
use Livewire\Attributes\Title;
use Livewire\Attributes\Url;
use Livewire\Component;

#[Layout('components.layout')]
class Index extends Component
{
    #[Url(as: 'folder')]
    public string $folder = 'INBOX';

    public function render(ImapMailboxService $imap)
    {
        try {
            $folders  = $imap->folders();
            $messages = $imap->listMessages($this->folder, 100);
            $error    = null;
        } catch (\Throwable $e) {
            $folders  = [];
            $messages = [];
            $error    = $e->getMessage();
        }

        return view('livewire.inbox.index', [
            'folders'  => $folders,
            'messages' => $messages,
            'error'    => $error,
        ])->title($this->folder);
    }
}
