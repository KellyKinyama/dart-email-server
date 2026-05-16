<?php

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;

// Standard /api/user endpoint, protected by Passport bearer tokens.
// Third-party apps that complete an OAuth2 authorization-code flow against
// this server can call this endpoint with `Authorization: Bearer <token>` to
// fetch the authenticated user's profile.
Route::middleware('auth:api')->get('/user', function (Request $request) {
    $user = $request->user();
    return [
        'id'    => $user->id,
        'name'  => $user->name,
        'email' => $user->email,
        'roles' => $user->getRoleNames(),
    ];
});
