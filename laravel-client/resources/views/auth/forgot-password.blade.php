<x-auth-layout title="Forgot password">
  <h1>Forgot password</h1>
  <p class="sub">Enter your email and we'll send you a reset link.</p>

  @if (session('status'))
    <div class="flash">{{ session('status') }}</div>
  @endif

  <form method="post" action="{{ url('/forgot-password') }}">
    @csrf
    <label>Email</label>
    <input name="email" type="email" required autofocus value="{{ old('email') }}">
    @error('email') <div class="err">{{ $message }}</div> @enderror

    <div class="btn-row">
      <a class="alt" href="{{ url('/login') }}">Back to sign in</a>
      <button class="btn" type="submit">Send link</button>
    </div>
  </form>
</x-auth-layout>
