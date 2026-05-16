<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsToMany;
use Illuminate\Support\Str;

/**
 * A group / mailing list. Sending mail to a group expands it into the
 * email addresses of every linked user at compose time.
 */
class Group extends Model
{
    use HasFactory;

    protected $fillable = ['name', 'slug', 'email', 'description'];

    protected static function booted(): void
    {
        // Auto-derive a slug from the name when one isn't supplied.
        static::creating(function (Group $g) {
            if (! $g->slug) {
                $g->slug = Str::slug($g->name);
            }
        });
    }

    public function members(): BelongsToMany
    {
        return $this->belongsToMany(User::class)->withTimestamps();
    }

    /**
     * @return list<string>
     */
    public function memberEmails(): array
    {
        return $this->members()
            ->pluck('email')
            ->filter()
            ->values()
            ->all();
    }
}
