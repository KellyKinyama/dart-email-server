<?php

use App\Http\Controllers\ComposeController;
use App\Http\Controllers\InboxController;
use App\Http\Controllers\WebhookController;
use Illuminate\Support\Facades\Route;

Route::get('/', fn () => redirect()->route('inbox.index'));

// IMAP-backed inbox view (live read of dart_email_server).
Route::get('/inbox', [InboxController::class, 'index'])->name('inbox.index');
Route::get('/inbox/{folder}/{uid}', [InboxController::class, 'show'])
    ->where('folder', '[A-Za-z0-9_./-]+')
    ->name('inbox.show');

// Compose + send via SMTP submission.
Route::get('/compose',  [ComposeController::class, 'create'])->name('compose.create');
Route::post('/compose', [ComposeController::class, 'store'])->name('compose.store');

// Webhook ingest from dart_email_server's 'mail' event.
Route::post('/api/incoming-mail', [WebhookController::class, 'ingest'])
    ->name('webhook.ingest');

// Browse what the webhook has stored.
Route::get('/webhook',           [WebhookController::class, 'index'])->name('webhook.index');
Route::get('/webhook/{message}', [WebhookController::class, 'show'])->name('webhook.show');
