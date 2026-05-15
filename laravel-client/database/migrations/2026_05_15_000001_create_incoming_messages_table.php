<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('incoming_messages', function (Blueprint $table) {
            $table->id();
            $table->string('message_id')->nullable()->index();
            $table->string('envelope_from')->nullable()->index();
            $table->json('envelope_to')->nullable();
            $table->string('header_from')->nullable();
            $table->string('subject')->nullable();
            $table->longText('text_body')->nullable();
            $table->longText('html_body')->nullable();
            $table->longText('raw')->nullable();
            $table->string('spf', 32)->nullable();
            $table->string('dkim', 32)->nullable();
            $table->string('dmarc', 32)->nullable();
            $table->string('rdns', 32)->nullable();
            $table->unsignedInteger('size')->default(0);
            $table->timestamp('received_at')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('incoming_messages');
    }
};
