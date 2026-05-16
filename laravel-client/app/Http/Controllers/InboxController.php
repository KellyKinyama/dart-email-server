<?php

namespace App\Http\Controllers;

use App\Services\ImapMailboxService;
use Illuminate\Http\Request;

class InboxController extends Controller
{
    public function __construct(protected ImapMailboxService $imap) {}

    public function index(Request $request)
    {
        $folder = $request->query('folder', 'INBOX');
        try {
            $folders  = $this->imap->folders();
            $messages = $this->imap->listMessages($folder, 100);
            $error    = null;
        } catch (\Throwable $e) {
            $folders  = [];
            $messages = [];
            $error    = $e->getMessage();
        }

        return view('inbox.index', compact('folders', 'messages', 'folder', 'error'));
    }

    public function show(string $folder, int $uid)
    {
        $message = $this->imap->getMessage($folder, $uid);
        abort_if(! $message, 404);

        return view('inbox.show', compact('message', 'folder'));
    }

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
