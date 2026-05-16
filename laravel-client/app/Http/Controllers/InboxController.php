<?php

namespace App\Http\Controllers;

use App\Services\ImapMailboxService;

/**
 * Thin controller for the IMAP attachment download endpoint.
 *
 * The interactive inbox UI lives in App\Livewire\Inbox\{Index,Show}.
 * Binary file download isn't a Livewire concern (it returns raw bytes,
 * not HTML), so it stays as a stateless controller action.
 */
class InboxController extends Controller
{
    public function __construct(protected ImapMailboxService $imap) {}

    public function attachment(string $folder, int $uid, int $index)
    {
        $att = $this->imap->getAttachment($folder, $uid, $index);
        abort_if(! $att, 404);

        return response($att['content'], 200, [
            'Content-Type'        => $att['mime'],
            'Content-Disposition' => 'attachment; filename="' . addslashes($att['name']) . '"',
            'Content-Length'      => (string) strlen($att['content']),
        ]);
    }
}
