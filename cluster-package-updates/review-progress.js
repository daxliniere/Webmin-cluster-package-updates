/* v0.1.15 - review progress; status polling never installs packages. */
(() => {
  'use strict';
  const root = document.getElementById('cpu-review-progress');
  if (!root) return;
  const job = root.dataset.job;
  const head = document.getElementById('cpu-progress-head');
  const count = document.getElementById('cpu-progress-count');
  const bar = document.getElementById('cpu-progress-bar');
  const events = document.getElementById('cpu-progress-events');
  const failure = document.getElementById('cpu-progress-error');
  const resultLink = document.getElementById('cpu-review-results-link');
  const refreshLink = document.getElementById('cpu-review-refresh-link');
  let failures = 0;
  let stopped = false;
  const phaseNames = {
    queued: 'Preparing review',
    'inventory-start': 'Cataloguing available updates',
    'inventory-finished': 'Cataloguing available updates',
    'simulation-start': 'Simulating APT transactions',
    'simulation-finished': 'Simulating APT transactions',
    failed: 'Review failed'
  };
  const poll = async () => {
    if (stopped) return;
    try {
      const response = await fetch(`preview-status.cgi?job=${encodeURIComponent(job)}`, {
        cache: 'no-store', credentials: 'same-origin'
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      failures = 0;
      if (data.status === 'preview') {
        stopped = true;
        // Authentic Theme intercepts normal links; a raw window.location.replace
        // bypasses its navigation shell and can make the sidebar disappear.
        // Keep the page intact and let the user open results via a real link.
        head.textContent = 'Review complete';
        count.textContent = 'APT simulations finished. Open the review results to inspect the plan.';
        bar.max = 1;
        bar.value = 1;
        resultLink.hidden = false;
        refreshLink.hidden = true;
        return;
      }
      if (data.status === 'preview-failed' || data.status === 'not-found') {
        stopped = true;
        failure.hidden = false;
        failure.textContent = data.message || 'The preview did not complete. Open review details for information.';
        resultLink.textContent = 'Open review details';
        resultLink.hidden = false;
        refreshLink.hidden = true;
        return;
      }
      const p = data.progress || {};
      const done = Math.max(0, Number(p.done || 0));
      const total = Math.max(0, Number(p.total || 0));
      const phase = phaseNames[p.phase] || 'Preparing review';
      head.textContent = `${phase}${p.label ? ': ' + p.label : ''}`;
      count.textContent = total ? `${Math.min(done, total)} of ${total} machines completed in this stage` : 'Waiting for the next stage';
      if (total) {
        bar.max = total;
        bar.value = Math.min(done, total);
      } else {
        bar.removeAttribute('value');
      }
      events.replaceChildren();
      for (const e of (data.events || []).slice(-30)) {
        const li = document.createElement('li');
        li.textContent = e.message || '';
        events.appendChild(li);
      }
    } catch (error) {
      failures += 1;
      if (failures >= 3) {
        failure.hidden = false;
        failure.textContent = 'Unable to fetch live progress. The review may still be running. Use Refresh manually.';
      }
    }
    if (!stopped) window.setTimeout(poll, 2000);
  };
  poll();
})();
