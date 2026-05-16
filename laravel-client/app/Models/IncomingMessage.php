<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Spatie\MediaLibrary\HasMedia;
use Spatie\MediaLibrary\InteractsWithMedia;

/**
 * Cache of inbound mail delivered via the /api/incoming-mail webhook.
 * Source of truth is dart_email_server; this table is populated as the
 * server emits its 'mail' event.
 *
 * Parsed MIME attachments are pinned into the `attachments` media
 * collection by spatie/laravel-medialibrary so they can be served back to
 * the inbox UI without going through IMAP again.
 */
class IncomingMessage extends Model implements HasMedia
{
    use HasFactory;
    use InteractsWithMedia;

    protected $fillable = [
        'message_id',
        'envelope_from',
        'envelope_to',
        'header_from',
        'subject',
        'text_body',
        'html_body',
        'raw',
        'spf',
        'dkim',
        'dmarc',
        'rdns',
        'size',
        'received_at',
    ];

    protected $casts = [
        'envelope_to' => 'array',
        'received_at' => 'datetime',
    ];

    public function registerMediaCollections(): void
    {
        $this->addMediaCollection('attachments');
    }
}
