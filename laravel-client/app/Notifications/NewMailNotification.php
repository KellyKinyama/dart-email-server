<?php

namespace App\Notifications;

use App\Models\IncomingMessage;
use Illuminate\Bus\Queueable;
use Illuminate\Notifications\Notification;
use NotificationChannels\WebPush\WebPushChannel;
use NotificationChannels\WebPush\WebPushMessage;

/**
 * Web Push (VAPID) notification fired when a new inbound mail
 * lands for a user with one or more browser push subscriptions.
 */
class NewMailNotification extends Notification
{
    use Queueable;

    public function __construct(public IncomingMessage $message) {}

    public function via(object $notifiable): array
    {
        return [WebPushChannel::class];
    }

    public function toWebPush(object $notifiable, Notification $notification): WebPushMessage
    {
        $from    = $this->message->header_from ?: $this->message->envelope_from ?: 'Unknown sender';
        $subject = $this->message->subject     ?: '(no subject)';
        $preview = trim((string) ($this->message->text_body ?? ''));
        if (strlen($preview) > 140) {
            $preview = substr($preview, 0, 137) . '...';
        }

        return (new WebPushMessage)
            ->title("New mail from {$from}")
            ->body($subject . ($preview !== '' ? "\n{$preview}" : ''))
            ->icon('/favicon.ico')
            ->tag("incoming-{$this->message->id}")
            ->data([
                'messageId' => $this->message->id,
                'url'       => url('/webhook/' . $this->message->id),
            ])
            ->options([
                'TTL' => 60 * 60, // 1h
            ]);
    }
}
