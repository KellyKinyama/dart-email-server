<x-auth-layout title="Reset password">
  <h1>Reset password</h1>
  <p class="sub">Choose a new password for your account.</p>

  <form method="post" action="{{ url('/reset-password') }}">
    @csrf
    <input type="hidden" name="token" value="{{ $request->route('token') }}">

    <label>Email</label>
    <input name="email" type="email" required value="{{ old('email', $request->email) }}">
    @error('email') <div class="err">{{ $message }}</div> @enderror

    <label>New password</label>
    <input name="password" type="password" required>
    @error('password') <div class="err">{{ $message }}</div> @enderror

    <label>Confirm new password</label>
    <input name="password_confirmation" type="password" required>

    <div class="btn-row">
      <a class="alt" href="{{ url('/login') }}">Back to sign in</a>
      <button class="btn" type="submit">Reset</button>
    </div>
  </form>
</x-auth-layout>
