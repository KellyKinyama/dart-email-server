<x-layout title="Compose" activeNav="compose">
  <div class="toolbar">
    <h1>New message</h1>
  </div>

  <form method="post" action="{{ route('compose.store') }}" class="form-card">
    @csrf

    <label>From</label>
    <input name="from" type="email" value="{{ old('from', $defaultFrom) }}">

    <label>From name</label>
    <input name="fromName" value="{{ old('fromName') }}" placeholder="Optional display name">

    <label>To <span style="color:var(--text-3);text-transform:none;letter-spacing:0;font-weight:400;">(comma-separated)</span></label>
    <input name="to" required value="{{ old('to') }}" placeholder="someone@example.com">

    <label>Subject</label>
    <input name="subject" required value="{{ old('subject') }}">

    <label>Message</label>
    <textarea name="text" placeholder="Write your message…">{{ old('text') }}</textarea>

    <label>HTML body <span style="color:var(--text-3);text-transform:none;letter-spacing:0;font-weight:400;">(optional, takes precedence)</span></label>
    <textarea name="html" placeholder="&lt;p&gt;…&lt;/p&gt;">{{ old('html') }}</textarea>

    <div class="btn-row">
      <button class="btn" type="submit">Send</button>
      <a class="btn ghost" href="{{ route('inbox.index') }}">Cancel</a>
    </div>
  </form>
</x-layout>
