<x-layout title="Compose">
  <h2>Compose message</h2>
  <form method="post" action="{{ route('compose.store') }}">
    @csrf
    <label>From (override)</label>
    <input name="from" type="email" value="{{ old('from', $defaultFrom) }}">

    <label>From name</label>
    <input name="fromName" value="{{ old('fromName') }}">

    <label>To <span class="small">(comma-separated)</span></label>
    <input name="to" required value="{{ old('to') }}">

    <label>Subject</label>
    <input name="subject" required value="{{ old('subject') }}">

    <label>Plain-text body</label>
    <textarea name="text">{{ old('text') }}</textarea>

    <label>HTML body <span class="small">(optional, takes precedence)</span></label>
    <textarea name="html">{{ old('html') }}</textarea>

    <button type="submit">Send via dart_email_server</button>
  </form>
</x-layout>
