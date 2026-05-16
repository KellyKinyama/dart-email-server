<?php

use App\Http\Controllers\InboxController;
use App\Http\Controllers\WebhookController;
use App\Livewire\Compose\Form as ComposeForm;
use App\Livewire\Inbox\Index as InboxIndex;
use App\Livewire\Inbox\Show as InboxShow;
use App\Livewire\Webhook\Index as WebhookIndex;
use App\Livewire\Webhook\Show as WebhookShow;
use Illuminate\Support\Facades\Route;

Route::get('/', fn () => redirect()->route('inbox.index'));

// Livewire-backed inbox UI (live read of dart_email_server via IMAP).
Route::get('/inbox', InboxIndex::class)->name('inbox.index');
Route::get('/inbox/{folder}/{uid}', InboxShow::class)
    ->where('folder', '[A-Za-z0-9_.-]+')
    ->where('uid', '[0-9]+')
    ->name('inbox.show');

// Binary attachment download stays a thin controller (not a Livewire component).
Route::get('/inbox/{folder}/{uid}/attachment/{index}', [InboxController::class, 'attachment'])
    ->where('folder', '[A-Za-z0-9_.-]+')
    ->where('uid', '[0-9]+')
    ->where('index', '[0-9]+')
    ->name('inbox.attachment');

// Compose + send via SMTP submission (Livewire form with file uploads).
Route::get('/compose', ComposeForm::class)->name('compose.create');

// Webhook ingest from dart_email_server's 'mail' event (server-to-server JSON API).
Route::post('/api/incoming-mail', [WebhookController::class, 'ingest'])
    ->name('webhook.ingest');

// Browse what the webhook has stored (Livewire-backed).
Route::get('/webhook',           WebhookIndex::class)->name('webhook.index');
Route::get('/webhook/{message}', WebhookShow::class)->name('webhook.show');
