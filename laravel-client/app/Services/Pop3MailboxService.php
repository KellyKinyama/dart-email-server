<?php

namespace App\Services;

/**
 * Minimal POP3 client speaking enough of RFC 1939 to STAT/LIST/RETR/QUIT
 * against dart_email_server. Pure stream sockets — no extension needed.
 *
 * Use this when IMAP is disabled and you only need to drain the mailbox.
 */
class Pop3MailboxService
{
    /** @var resource|null */
    protected $sock = null;

    public function __construct(
        protected string $host,
        protected int $port,
        protected string $username,
        protected string $password,
        protected ?string $encryption = null, // null | 'ssl' | 'tls'
        protected int $timeout = 15,
    ) {}

    public static function fromConfig(): self
    {
        $c = config('dart_email.pop3');
        return new self(
            $c['host'], $c['port'], $c['username'], $c['password'], $c['encryption'] ?: null
        );
    }

    public function connect(): void
    {
        $scheme = $this->encryption === 'ssl' ? 'ssl://' : '';
        $this->sock = @stream_socket_client(
            $scheme.$this->host.':'.$this->port,
            $errno, $errstr, $this->timeout
        );
        if (! $this->sock) {
            throw new \RuntimeException("POP3 connect failed: $errstr ($errno)");
        }
        $this->expectOk();

        if ($this->encryption === 'tls') {
            $this->send('STLS');
            $this->expectOk();
            stream_socket_enable_crypto($this->sock, true, STREAM_CRYPTO_METHOD_TLS_CLIENT);
        }

        $this->send('USER '.$this->username);
        $this->expectOk();
        $this->send('PASS '.$this->password);
        $this->expectOk();
    }

    /** @return array<int,int> index => octet size */
    public function listSizes(): array
    {
        $this->send('LIST');
        $this->expectOk();
        $out = [];
        while (($line = $this->readLine()) !== ".\r\n") {
            [$n, $size] = explode(' ', trim($line));
            $out[(int) $n] = (int) $size;
        }
        return $out;
    }

    public function retrieve(int $index): string
    {
        $this->send("RETR $index");
        $this->expectOk();
        $body = '';
        while (($line = $this->readLine()) !== ".\r\n") {
            // RFC 1939 §3.3 byte-stuffing: leading '.' is doubled.
            if (str_starts_with($line, '..')) {
                $line = substr($line, 1);
            }
            $body .= $line;
        }
        return $body;
    }

    public function quit(): void
    {
        if ($this->sock) {
            @$this->send('QUIT');
            @fclose($this->sock);
            $this->sock = null;
        }
    }

    protected function send(string $line): void
    {
        fwrite($this->sock, $line."\r\n");
    }

    protected function readLine(): string
    {
        return (string) fgets($this->sock, 8192);
    }

    protected function expectOk(): void
    {
        $line = $this->readLine();
        if (! str_starts_with($line, '+OK')) {
            throw new \RuntimeException('POP3 error: '.trim($line));
        }
    }
}
