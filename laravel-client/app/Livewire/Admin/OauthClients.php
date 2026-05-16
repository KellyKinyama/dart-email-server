<?php

namespace App\Livewire\Admin;

use Laravel\Passport\Client;
use Laravel\Passport\ClientRepository;
use Livewire\Attributes\Layout;
use Livewire\Component;

#[Layout('components.layout')]
class OauthClients extends Component
{
    public string $newName     = '';
    public string $newRedirect = '';
    public bool   $newConfidential = true;

    public ?string $statusMessage = null;
    /** The most-recently generated client secret (shown ONCE). */
    public ?string $revealedSecret   = null;
    public ?string $revealedClientId = null;

    protected function rules(): array
    {
        return [
            'newName'     => ['required', 'string', 'max:160'],
            'newRedirect' => ['required', 'url', 'max:255'],
        ];
    }

    public function createClient(): void
    {
        $data = $this->validate();

        /** @var ClientRepository $repo */
        $repo = app(ClientRepository::class);

        $client = $repo->createAuthorizationCodeGrantClient(
            name: $data['newName'],
            redirectUris: [$data['newRedirect']],
            confidential: $this->newConfidential,
            user: auth()->user(),
        );

        $this->revealedClientId = (string) $client->getKey();
        $this->revealedSecret   = $client->plainSecret;
        $this->reset(['newName', 'newRedirect']);
        $this->statusMessage    = 'OAuth client created. Copy the secret now — it will not be shown again.';
    }

    public function deleteClient(string $clientId): void
    {
        Client::query()->whereKey($clientId)->delete();
        $this->statusMessage = 'Client deleted.';
    }

    public function revokeClient(string $clientId): void
    {
        $client = Client::query()->findOrFail($clientId);
        $client->forceFill(['revoked' => true])->save();
        $this->statusMessage = 'Client revoked.';
    }

    public function unrevokeClient(string $clientId): void
    {
        $client = Client::query()->findOrFail($clientId);
        $client->forceFill(['revoked' => false])->save();
        $this->statusMessage = 'Client re-enabled.';
    }

    public function render()
    {
        $clients = Client::query()
            ->where('personal_access_client', false)
            ->orderByDesc('id')
            ->get();

        return view('livewire.admin.oauth-clients', compact('clients'))
            ->title('Admin · OAuth Clients');
    }
}
