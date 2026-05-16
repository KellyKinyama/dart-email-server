<x-auth-layout title="Create your account">
  <h1>Create your account</h1>
  <p class="sub">It only takes a moment.</p>

  <form method="post" action="{{ url('/register') }}">
    @csrf

    <label>Name</label>
    <input name="name" type="text" required autofocus value="{{ old('name') }}">
    @error('name') <div class="err">{{ $message }}</div> @enderror

    <label>Email</label>
    <input name="email" type="email" required value="{{ old('email') }}">
    @error('email') <div class="err">{{ $message }}</div> @enderror

    <label>Password</label>
    <input name="password" type="password" required>
    @error('password') <div class="err">{{ $message }}</div> @enderror

    <label>Confirm password</label>
    <input name="password_confirmation" type="password" required>

    <div class="btn-row">
      <a class="alt" href="{{ url('/login') }}">Already have an account?</a>
      <button class="btn" type="submit">Register</button>
    </div>
  </form>
</x-auth-layout>
