# OAuth2 Provider (Laravel Passport)

The Laravel client (`laravel-client/`) is configured as a full **OAuth2
authorization server** via [Laravel Passport](https://laravel.com/docs/passport).
Third-party applications can let their users sign in with their DartMail
account, get an access token, and call protected endpoints on this server on
the user's behalf — the same role Google or Microsoft play for "Sign in with
Google" buttons.

This chapter documents how the provider is wired up, what endpoints it
exposes, and how a partner app integrates with it.

## 1. What was installed

| Piece | Where |
|---|---|
| Passport package | `laravel/passport ^13.7` (composer) |
| Encryption keys | `laravel-client/storage/oauth-private.key`, `oauth-public.key` |
| Tables | `oauth_clients`, `oauth_auth_codes`, `oauth_access_tokens`, `oauth_refresh_tokens`, `oauth_device_codes` |
| `auth:api` guard | `laravel-client/config/auth.php` |
| `HasApiTokens` trait | [`App\Models\User`](../laravel-client/app/Models/User.php) |
| Admin UI | [`App\Livewire\Admin\OauthClients`](../laravel-client/app/Livewire/Admin/OauthClients.php) at `/admin/oauth-clients` |
| `/api/user` example | [`laravel-client/routes/api.php`](../laravel-client/routes/api.php) |
| Tests | [`tests/Feature/OauthProviderTest.php`](../laravel-client/tests/Feature/OauthProviderTest.php) |

Note: PHP must have the **`sodium`** extension enabled (uncomment
`extension=sodium` in `php.ini`) — Passport's JWT library requires it.

## 2. Endpoints exposed

Passport auto-registers these routes inside the `web` middleware group:

| Method | Path | Purpose |
|---|---|---|
| `GET`  | `/oauth/authorize` | Show the consent screen and start the authorization-code flow |
| `POST` | `/oauth/token` | Exchange code / refresh token / device code / client credentials for an access token |
| `POST` | `/oauth/token/refresh` | Refresh an access token using a refresh token |
| `GET`  | `/oauth/clients` | (User-scoped) list a user's own first-party clients |
| `GET`  | `/oauth/scopes` | List declared scopes |
| `GET`  | `/oauth/personal-access-tokens` | Manage personal access tokens |
| `POST` | `/oauth/device/code` | Device-authorization flow start |
| `POST` | `/oauth/device/authorize` | Device-authorization flow confirm |

A user-info endpoint protected by the bearer token is provided as
[`GET /api/user`](../laravel-client/routes/api.php).

## 3. Operator workflow — registering a third-party app

1. Sign in as an admin (`admin@dartmail.local` / `ChangeMe!2026` by default —
   see [`RolesAndAdminSeeder`](../laravel-client/database/seeders/RolesAndAdminSeeder.php)).
2. Open **Admin · OAuth Clients** in the sidebar (`/admin/oauth-clients`).
3. Fill in:
   - **App name** (display label),
   - **Redirect URI** (must match exactly what the partner app uses), and
   - Whether the client is **confidential** (server-side, can keep a secret)
     or **public** (SPA / native; uses PKCE instead of a secret).
4. Click **Create client**. The `client_id` and `client_secret` are shown
   **once** — copy them now; the secret is hashed in the database after
   creation and cannot be revealed again.
5. Hand the credentials to the partner app's developer along with the
   authorize / token URLs.

To revoke access for all installations of a partner app, click **Revoke** on
the row — the underlying `oauth_clients.revoked` flag is flipped and Passport
will refuse to issue or accept tokens for it.

## 4. Partner-side: authorization-code flow

Suppose `https://partner.example/` wants to add a "Sign in with DartMail"
button. Their redirect URI is `https://partner.example/oauth/callback`.

### 4.1 Redirect the user to /oauth/authorize

```http
GET /oauth/authorize
    ?client_id=01HV...XYZ
    &redirect_uri=https%3A%2F%2Fpartner.example%2Foauth%2Fcallback
    &response_type=code
    &scope=
    &state=<csrf-protection-nonce>
```

The user signs in with Fortify if they aren't already, sees the Passport
consent screen, and approves. Passport redirects back to:

```
https://partner.example/oauth/callback?code=<auth-code>&state=<same-nonce>
```

### 4.2 Exchange the code for tokens

```bash
curl -X POST https://dartmail.example/oauth/token \
  -F grant_type=authorization_code \
  -F client_id=01HV...XYZ \
  -F client_secret=<the-secret-shown-once> \
  -F redirect_uri=https://partner.example/oauth/callback \
  -F code=<auth-code>
```

Response:

```json
{
  "token_type": "Bearer",
  "expires_in": 31536000,
  "access_token":  "eyJ0eXAiOiJKV1Qi...",
  "refresh_token": "def50200a3..."
}
```

### 4.3 Call protected APIs on behalf of the user

```bash
curl https://dartmail.example/api/user \
  -H "Authorization: Bearer eyJ0eXAiOiJKV1Qi..."
```

```json
{
  "id":    7,
  "name":  "Ada Lovelace",
  "email": "ada@dartmail.local",
  "roles": ["user"]
}
```

### 4.4 Refresh when the access token expires

```bash
curl -X POST https://dartmail.example/oauth/token \
  -F grant_type=refresh_token \
  -F refresh_token=def50200a3... \
  -F client_id=01HV...XYZ \
  -F client_secret=<the-secret-shown-once>
```

### 4.5 Public clients (SPA / mobile) — use PKCE

When the admin unchecks "Confidential" at client-creation time, no secret is
issued. The partner app must instead use PKCE:

1. Generate `code_verifier` (random 43–128 char string) and
   `code_challenge = base64url(sha256(code_verifier))`.
2. Send `code_challenge=<challenge>&code_challenge_method=S256` on the
   authorize redirect.
3. Send `code_verifier=<verifier>` (instead of `client_secret`) on the
   `/oauth/token` exchange.

## 5. Personal access tokens (PAT)

For scripts, CI jobs or trusted internal tools, a user can mint a PAT and
use it as a bearer token directly — no authorize redirect needed:

```php
$token = $user->createToken('ci-pipeline')->accessToken;
```

The personal-access client is created at install time by
`php artisan passport:client --personal`. A test that round-trips a PAT
through `/api/user` lives in
[`OauthProviderTest::test_personal_access_token_authenticates_api_user`](../laravel-client/tests/Feature/OauthProviderTest.php).

## 6. Server-to-server (client credentials)

If a partner needs to act as itself (no user context), the admin should
register a dedicated client and configure it for the `client_credentials`
grant via `php artisan passport:client --client`. The partner then calls:

```bash
curl -X POST https://dartmail.example/oauth/token \
  -F grant_type=client_credentials \
  -F client_id=... \
  -F client_secret=... \
  -F scope=
```

Tokens issued this way are not tied to a user; protect those routes with
the `client` Passport middleware rather than `auth:api`.

## 7. Re-keying / rotation

Regenerate the encryption keys (this invalidates every issued token):

```bash
php artisan passport:keys --force
```

Rotate a single client's secret:

```bash
# Delete the row from the admin UI and create a new client.
# Passport does not currently surface secret-rotation as a separate UI action.
```

## 8. Running the test suite

The tests use sqlite `:memory:` (see `laravel-client/phpunit.xml`) so they
do not touch the dev MySQL database. The OAuth tests regenerate Passport's
keys on setup:

```bash
cd laravel-client
php artisan test --filter=OauthProviderTest
```

Expected: **4 passed**. The full suite is currently **61 passed** (144
assertions).
