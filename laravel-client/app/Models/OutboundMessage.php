<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Spatie\MediaLibrary\HasMedia;
use Spatie\MediaLibrary\InteractsWithMedia;
use Spatie\MediaLibrary\MediaCollections\Models\Media;

/**
 * A message handed off to the SMTP submission port via the compose UI.
 *
 * Uploaded attachments are stored via spatie/laravel-medialibrary in the
 * `attachments` media collection so they outlive the request and can be
 * re-attached, audited, or re-downloaded.
 */
class OutboundMessage extends Model implements HasMedia
{
    use HasFactory;
    use InteractsWithMedia;

    protected $fillable = [
        'subject',
        'from_address',
        'from_name',
        'to_addresses',
        'cc_addresses',
        'bcc_addresses',
        'text_body',
        'html_body',
        'sent_at',
    ];

    protected $casts = [
        'to_addresses'  => 'array',
        'cc_addresses'  => 'array',
        'bcc_addresses' => 'array',
        'sent_at'       => 'datetime',
    ];

    public function registerMediaCollections(): void
    {
        $this->addMediaCollection('attachments');
    }

    /**
     * Convert attached media items into the array shape the
     * GenericOutboundMail mailable expects.
     *
     * @return array<int, array{path:string, as:string, mime:string}>
     */
    public function attachmentSpecs(): array
    {
        return $this->getMedia('attachments')
            ->map(fn (Media $m) => [
                'path' => $m->getPath(),
                'as'   => $m->getCustomProperty('original_name')
                    ?: ($m->name ?: $m->file_name),
                'mime' => $m->getCustomProperty('mime')
                    ?: ($m->mime_type ?: 'application/octet-stream'),
            ])
            ->all();
    }
}
