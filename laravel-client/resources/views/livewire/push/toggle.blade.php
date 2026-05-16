<div x-data="{
        status: 'unknown',
        busy: false,
        msg: null,
        async init() {
          try { this.status = await window.dartmailPush.status(); } catch (e) { this.status = 'unsupported'; }
        },
        async toggle() {
          this.busy = true; this.msg = null;
          try {
            if (this.status === 'subscribed') {
              await window.dartmailPush.unsubscribe();
              this.status = 'idle';
              this.msg = 'Notifications disabled.';
            } else {
              await window.dartmailPush.subscribe();
              this.status = 'subscribed';
              this.msg = 'Notifications enabled.';
            }
          } catch (e) { this.msg = e.message || String(e); }
          this.busy = false;
        }
      }"
     style="padding: 10px 16px; border-top:1px solid var(--line); font-size:12px; color:var(--text-2);">

  <script>
    window.__DARTMAIL_PUSH = {
      vapidPublicKey: @json($vapidPublicKey),
      subscribeUrl:   @json($subscribeUrl),
      unsubscribeUrl: @json($unsubscribeUrl),
      csrf:           @json(csrf_token()),
    };
  </script>

  <div style="display:flex;align-items:center;gap:8px;">
    <span>🔔 Notifications</span>
    <button @click="toggle"
            :disabled="busy || status === 'unsupported' || status === 'denied'"
            class="btn ghost"
            style="margin-left:auto;padding:2px 10px;font-size:12px;"
            x-text="status === 'subscribed' ? 'Disable' :
                    status === 'denied'     ? 'Blocked' :
                    status === 'unsupported'? 'N/A'     : 'Enable'">
    </button>
  </div>
  <div x-show="msg" x-text="msg" style="margin-top:6px;font-size:11px;color:var(--text-2);"></div>
</div>
