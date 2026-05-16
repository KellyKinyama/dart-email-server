<?php

namespace App\Services;

use Webklex\PHPIMAP\ClientManager;
use Webklex\PHPIMAP\Client;

/**
 * Thin wrapper around webklex/php-imap that opens a connection to the
 * dart_email_server IMAP listener using credentials from
 * config/dart_email.php.
 */
class ImapMailboxService
{
    protected Client $client;

    public function __construct()
    {
        $cfg = config('dart_email.imap');

        $this->client = (new ClientManager())->make([
            'host'           => $cfg['host'],
            'port'           => $cfg['port'],
            'encryption'     => $cfg['encryption'],
            'validate_cert'  => $cfg['validate_cert'],
            'username'       => $cfg['username'],
            'password'       => $cfg['password'],
            'protocol'       => $cfg['protocol'],
        ]);
    }

    public function client(): Client
    {
        if (! $this->client->isConnected()) {
            $this->client->connect();
        }
        return $this->client;
    }

    /** @return array<string,string> folder name => path */
    public function folders(): array
    {
        $out = [];
        foreach ($this->client()->getFolders() as $folder) {
            $out[$folder->name] = $folder->path;
        }
        return $out;
    }

    /**
     * Return a paginated-ish slice of messages from a folder, newest first.
     *
     * @return array<int, array<string,mixed>>
     */
    public function listMessages(string $folder = 'INBOX', int $limit = 50): array
    {
        $folder = $this->client()->getFolder($folder);
        if (! $folder) {
            return [];
        }

        $messages = $folder->messages()->all()->limit($limit)->get();

        $out = [];
        foreach ($messages as $msg) {
            $out[] = [
                'uid'       => $msg->getUid(),
                'subject'   => (string) $msg->getSubject(),
                'from'      => optional($msg->getFrom()[0] ?? null)->mail,
                'fromName'  => optional($msg->getFrom()[0] ?? null)->personal,
                'date'      => optional($msg->getDate())->toDate()?->format('Y-m-d H:i'),
                'seen'      => $msg->getFlags()->has('seen'),
                'size'      => $msg->getSize(),
                'hasAttach' => $msg->getAttachments()->count() > 0,
            ];
        }
        // Newest first.
        usort($out, fn($a, $b) => strcmp($b['date'] ?? '', $a['date'] ?? ''));
        return $out;
    }

    /**
     * @return array<string,mixed>|null
     */
    public function getMessage(string $folder, int $uid): ?array
    {
        $folder = $this->client()->getFolder($folder);
        if (! $folder) {
            return null;
        }
        $msg = $folder->query()->getMessageByUid($uid);
        if (! $msg) {
            return null;
        }

        $msg->setFlag(['Seen']);

        $addrList = function ($attr): array {
            if (! $attr) return [];
            $items = method_exists($attr, 'get') ? ($attr->get() ?? []) : (array) $attr;
            if (! is_array($items)) { $items = iterator_to_array($items); }
            return array_values(array_map(fn ($a) => $a->mail, $items));
        };

        $atts = [];
        foreach ($msg->getAttachments() as $i => $att) {
            $atts[] = [
                'index' => $i,
                'name'  => $att->getName() ?: ('attachment-' . $i),
                'size'  => (int) $att->getSize(),
                'mime'  => $att->getMimeType() ?: 'application/octet-stream',
            ];
        }

        return [
            'uid'         => $msg->getUid(),
            'subject'     => (string) $msg->getSubject(),
            'from'        => optional($msg->getFrom()[0] ?? null)->mail,
            'fromName'    => optional($msg->getFrom()[0] ?? null)->personal,
            'to'          => $addrList($msg->getTo()),
            'cc'          => $addrList($msg->getCc()),
            'bcc'         => $addrList($msg->getBcc()),
            'replyTo'     => $addrList($msg->getReplyTo()),
            'date'        => optional($msg->getDate())->toDate()?->format('Y-m-d H:i:s'),
            'text'        => (string) $msg->getTextBody(),
            'html'        => (string) $msg->getHTMLBody(),
            'headers'     => $msg->getHeader()->raw ?? '',
            'size'        => $msg->getSize(),
            'attachments' => $atts,
        ];
    }

    /**
     * Fetch raw bytes for a single attachment.
     * @return array{name:string, mime:string, content:string}|null
     */
    public function getAttachment(string $folder, int $uid, int $index): ?array
    {
        $folder = $this->client()->getFolder($folder);
        if (! $folder) return null;

        $msg = $folder->query()->getMessageByUid($uid);
        if (! $msg) return null;

        $atts = $msg->getAttachments();
        $att  = $atts[$index] ?? null;
        if (! $att) return null;

        return [
            'name'    => $att->getName() ?: ('attachment-' . $index),
            'mime'    => $att->getMimeType() ?: 'application/octet-stream',
            'content' => $att->getContent(),
        ];
    }
}
