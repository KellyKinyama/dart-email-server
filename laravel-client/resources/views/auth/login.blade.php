<x-auth-layout title="Sign in">
  <h1>Sign in</h1>
  <p class="sub">Use your DartMail account.</p>

  @if (session('status'))
    <div class="flash">{{ session('status') }}</div>
  @endif

  <form method="post" action="{{ url('/login') }}">
    @csrf

    <label>Email</label>
    <input name="email" type="email" required autofocus value="{{ old('email') }}">
    @error('email') <div class="err">{{ $message }}</div> @enderror

    <label>Password</label>
    <input name="password" type="password" required>
    @error('password') <div class="err">{{ $message }}</div> @enderror

    <label class="row-check"><input type="checkbox" name="remember"> Remember me</label>

    <div class="btn-row">
      <a class="alt" href="{{ url('/forgot-password') }}">Forgot password?</a>
      <button class="btn" type="submit">Sign in</button>
    </div>
  </form>

  <p class="alt" style="margin-top:24px;text-align:center;">
    No account? <a href="{{ url('/register') }}">Create one</a>
  </p>
</x-auth-layout>
