<x-layout title="Compose" activeNav="compose">
  <div class="toolbar">
    <h1>New message</h1>
  </div>

  <form method="post" action="{{ route('compose.store') }}" class="form-card" enctype="multipart/form-data">
    @csrf

    <label>From</label>
    <input name="from" type="email" value="{{ old('from', $defaultFrom) }}">

    <label>From name</label>
    <input name="fromName" value="{{ old('fromName') }}" placeholder="Optional display name">

    <label>To <span class="hint">(comma-separated)</span></label>
    <input name="to" required value="{{ old('to') }}" placeholder="someone@example.com">

    @php $showCc = old('cc') !== null && old('cc') !== ''; $showBcc = old('bcc') !== null && old('bcc') !== ''; @endphp
    <div class="addr-toggles" style="display:flex;gap:12px;margin:-8px 0 4px;">
      <a href="#" class="addr-toggle" data-target="cc-row"  style="font-size:12px;color:var(--accent);text-decoration:none;">+ Cc</a>
      <a href="#" class="addr-toggle" data-target="bcc-row" style="font-size:12px;color:var(--accent);text-decoration:none;">+ Bcc</a>
    </div>

    <div id="cc-row" style="{{ $showCc ? '' : 'display:none' }}">
      <label>Cc <span class="hint">(comma-separated)</span></label>
      <input name="cc" value="{{ old('cc') }}" placeholder="cc@example.com">
    </div>

    <div id="bcc-row" style="{{ $showBcc ? '' : 'display:none' }}">
      <label>Bcc <span class="hint">(comma-separated)</span></label>
      <input name="bcc" value="{{ old('bcc') }}" placeholder="bcc@example.com">
    </div>

    <label>Subject</label>
    <input name="subject" required value="{{ old('subject') }}">

    <label>Message</label>
    <textarea name="text" placeholder="Write your message…">{{ old('text') }}</textarea>

    <label>HTML body <span class="hint">(optional, takes precedence)</span></label>
    <textarea name="html" placeholder="&lt;p&gt;…&lt;/p&gt;">{{ old('html') }}</textarea>

    <label>Attachments <span class="hint">(up to 25 MB each)</span></label>
    <input type="file" name="attachments[]" multiple id="att-input" style="display:none;">
    <div class="att-zone" id="att-zone">
      <div class="att-empty">
        <span style="font-size:24px;">📎</span>
        <div><a href="#" id="att-pick" style="color:var(--accent);text-decoration:none;font-weight:500;">Attach files</a> or drop them here</div>
      </div>
      <ul class="att-list" id="att-list"></ul>
    </div>

    <div class="btn-row">
      <button class="btn" type="submit">Send</button>
      <a class="btn ghost" href="{{ route('inbox.index') }}">Cancel</a>
    </div>
  </form>

  <style>
    .form-card .hint { color: var(--text-3); text-transform: none; letter-spacing: 0; font-weight: 400; font-size: 11px; }
    .att-zone { border: 1px dashed var(--border); border-radius: 12px; padding: 16px; background: var(--surface-2); }
    .att-zone.drag { border-color: var(--accent); background: color-mix(in srgb, var(--accent) 8%, var(--surface-2)); }
    .att-empty { display: flex; align-items: center; gap: 12px; color: var(--text-2); font-size: 13px; }
    .att-list { list-style: none; padding: 0; margin: 12px 0 0; display: flex; flex-direction: column; gap: 6px; }
    .att-list li { display: flex; align-items: center; gap: 10px; padding: 8px 12px; background: var(--surface); border: 1px solid var(--border); border-radius: 10px; font-size: 13px; }
    .att-list li .att-name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .att-list li .att-size { color: var(--text-3); font-size: 11px; }
  </style>

  <script>
    (function () {
      document.querySelectorAll('.addr-toggle').forEach(function (a) {
        a.addEventListener('click', function (e) {
          e.preventDefault();
          var t = document.getElementById(a.dataset.target);
          if (t) { t.style.display = t.style.display === 'none' ? '' : 'none'; }
        });
      });

      var input = document.getElementById('att-input');
      var pick  = document.getElementById('att-pick');
      var zone  = document.getElementById('att-zone');
      var list  = document.getElementById('att-list');
      if (!input || !zone) return;

      var staged = new DataTransfer();
      function fmtSize (n) { if (n < 1024) return n + ' B'; if (n < 1048576) return (n/1024).toFixed(1) + ' KB'; return (n/1048576).toFixed(1) + ' MB'; }
      function render () {
        list.innerHTML = '';
        Array.from(staged.files).forEach(function (f, i) {
          var li = document.createElement('li');
          li.innerHTML = '<span>📄</span><span class="att-name"></span><span class="att-size"></span><a href="#" class="att-rm" style="color:var(--text-3);text-decoration:none;">✕</a>';
          li.querySelector('.att-name').textContent = f.name;
          li.querySelector('.att-size').textContent = fmtSize(f.size);
          li.querySelector('.att-rm').addEventListener('click', function (e) {
            e.preventDefault();
            var dt = new DataTransfer();
            Array.from(staged.files).forEach(function (g, j) { if (j !== i) dt.items.add(g); });
            staged = dt;
            input.files = staged.files;
            render();
          });
          list.appendChild(li);
        });
      }
      function add (files) {
        Array.from(files).forEach(function (f) { staged.items.add(f); });
        input.files = staged.files;
        render();
      }
      pick.addEventListener('click', function (e) { e.preventDefault(); input.click(); });
      input.addEventListener('change', function () { add(input.files); });
      ['dragenter','dragover'].forEach(function (ev) {
        zone.addEventListener(ev, function (e) { e.preventDefault(); zone.classList.add('drag'); });
      });
      ['dragleave','drop'].forEach(function (ev) {
        zone.addEventListener(ev, function (e) { e.preventDefault(); zone.classList.remove('drag'); });
      });
      zone.addEventListener('drop', function (e) { if (e.dataTransfer && e.dataTransfer.files) add(e.dataTransfer.files); });
    })();
  </script>
</x-layout>
