<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

/**
 * Cache of inbound mail delivered via the /api/incoming-mail webhook.
 * Source of truth is dart_email_server; this table is populated as the
 * server emits its 'mail' event.
 */
class IncomingMessage extends Model
{
    use HasFactory;

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
}
