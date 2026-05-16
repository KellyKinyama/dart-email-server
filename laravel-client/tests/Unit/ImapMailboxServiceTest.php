<?php

namespace Tests\Unit;

use App\Services\ImapMailboxService;
use Tests\TestCase;
use Webklex\PHPIMAP\Address;

class ImapMailboxServiceTest extends TestCase
{
    private function addr(string $mail, string $personal = ''): Address
    {
        return new Address((object) ['mail' => $mail, 'personal' => $personal]);
    }

    public function test_normalize_returns_empty_for_null(): void
    {
        $this->assertSame([], ImapMailboxService::normalizeAddressList(null));
    }

    public function test_normalize_handles_single_address_object(): void
    {
        // Regression: webklex returns a bare Address (not a Collection)
        // when there's only one recipient. The old iterator_to_array()
        // call blew up with "Argument #1 must be of type Traversable|array".
        $this->assertSame(
            ['solo@example.com'],
            ImapMailboxService::normalizeAddressList($this->addr('solo@example.com'))
        );
    }

    public function test_normalize_handles_array_of_addresses(): void
    {
        $list = [$this->addr('a@example.com'), $this->addr('b@example.com')];
        $this->assertSame(
            ['a@example.com', 'b@example.com'],
            ImapMailboxService::normalizeAddressList($list)
        );
    }

    public function test_normalize_handles_attribute_like_wrapper(): void
    {
        // Anything with a ->get() method should have it called.
        $wrapper = new class ($this) {
            public function __construct(private \Tests\Unit\ImapMailboxServiceTest $t) {}
            public function get(): array
            {
                return [
                    new Address((object) ['mail' => 'wrap@example.com']),
                ];
            }
        };
        $this->assertSame(
            ['wrap@example.com'],
            ImapMailboxService::normalizeAddressList($wrapper)
        );
    }

    public function test_normalize_filters_blank_mails(): void
    {
        $list = [$this->addr(''), $this->addr('keep@example.com'), $this->addr('')];
        $this->assertSame(
            ['keep@example.com'],
            ImapMailboxService::normalizeAddressList($list)
        );
    }
}
