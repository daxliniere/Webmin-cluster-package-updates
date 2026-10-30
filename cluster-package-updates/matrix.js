/* Cluster Package Updates v0.1.17 - filter-scoped checkbox matrix interactions.
 * Headers have tri-state semantics. No network requests or package changes.
 * Cross-page selection uses per-tab sessionStorage; candidate versions are
 * revalidated on the review/simulation page before confirmation. */
(function () {
  'use strict';

  function initMatrix() {
    const root = document.getElementById('cpu-matrix');
    const dataElement = document.getElementById('cpu-selection-data');
    if (!root || !dataElement || root.dataset.initialized === '1') return;
    root.dataset.initialized = '1';

    const status = document.getElementById('cpu-js-status');
    let data;
    try {
      data = JSON.parse(dataElement.textContent);
      if (!data || !Array.isArray(data.entries) ||
          !Array.isArray(data.allKeys) ||
          typeof data.scope !== 'string')
        throw new Error('Invalid selection inventory');
    } catch (error) {
      // Do not silently leave every action button inert if data is malformed.
      root.dataset.initialized = '0';
      if (status) status.textContent = 'Selection controls failed to load: ' + error.message;
      return;
    }
    const entries = data.entries;
    const allKeys = new Set(data.allKeys);
    // Filter matches across EVERY matching page, not just rendered page rows.
    // Selection state itself still covers the entire fleet and every filter.
    const filteredKeys = new Set(entries.map(entry => entry[0]));
    const byRow = new Map();
    const byCol = new Map();
    const checkboxes = Array.from(root.querySelectorAll('input.cpu-cell'));
    const rows = Array.from(root.querySelectorAll('.cpu-package-btn'));
    const cols = Array.from(root.querySelectorAll('.cpu-host-btn'));
    const corner = document.getElementById('cpu-corner');
    const count = document.getElementById('cpu-count');
    const countFooter = document.getElementById('cpu-count-footer');
    const review = document.getElementById('cpu-review');
    const form = document.getElementById('cpu-selection-form');
    const storageKey = 'cpu-selected-v0.1.7:' + data.scope;
    const legacyKey = 'cpu-selected-v0.1.3:' + data.legacyScope;
    let deselected = new Set();

    function appendToMap(map, group, key) {
      if (!map.has(group)) map.set(group, []);
      map.get(group).push(key);
    }

    function loadSelection() {
      try {
        // Migrate the current filter's v0.1.6 selections, if no new global
        // selection is stored yet. Old per-filter states cannot be reconciled.
        const raw = sessionStorage.getItem(storageKey) ??
          sessionStorage.getItem(legacyKey) ?? '[]';
        const saved = JSON.parse(raw);
        if (Array.isArray(saved)) {
          deselected = new Set(saved.filter(key => allKeys.has(key)));
        }
      } catch (_) {
        deselected = new Set();
      }
    }

    function saveSelection() {
      try {
        sessionStorage.setItem(storageKey, JSON.stringify(Array.from(deselected)));
      } catch (_) {
        // Browser storage may be disabled; current-page selection still works.
      }
    }

    function setState(button, keys) {
      if (!button) return;
      const chosen = keys.filter(key => !deselected.has(key)).length;
      const state = !keys.length || chosen === 0 ? 'none' :
        chosen === keys.length ? 'all' : 'some';
      button.dataset.state = state;
      button.setAttribute('aria-pressed', state === 'all' ? 'true' :
        state === 'none' ? 'false' : 'mixed');
      button.disabled = keys.length === 0;
    }

    function updateStatus() {
      const selected = allKeys.size - deselected.size;
      const filteredSelected = [...filteredKeys].filter(k => !deselected.has(k)).length;
      const summary = selected + ' of ' + allKeys.size +
        ' selected updates (all filters and pages); ' + filteredSelected +
        ' of ' + filteredKeys.size + ' in current filter';
      if (count) count.textContent = summary;
      if (countFooter) countFooter.textContent = summary;
      if (review) review.disabled = selected === 0;
      checkboxes.forEach(cb => { cb.checked = !deselected.has(cb.value); });
      rows.forEach(button => setState(button, byRow.get(Number(button.dataset.row)) || []));
      cols.forEach(button => setState(button, byCol.get(Number(button.dataset.col)) || []));
      setState(corner, Array.from(filteredKeys));
      const selectAll = document.getElementById('cpu-select-all');
      const clearAll = document.getElementById('cpu-clear-all');
      if (selectAll) selectAll.disabled = filteredKeys.size === 0;
      if (clearAll) clearAll.disabled = filteredKeys.size === 0;
    }

    // Partially-selected groups select all matches; fully selected groups
    // deselect all matches. Other filtered-out updates are never modified.
    function toggleGroup(keys) {
      if (!keys.length) return;
      const check = keys.some(key => deselected.has(key));
      keys.forEach(key => {
        if (check) deselected.delete(key);
        else deselected.add(key);
      });
      saveSelection();
      updateStatus();
    }

    function submitSelection(event) {
      const old = form.querySelector('input.cpu-submitted-cells');
      if (old) old.remove();
      // One compact POST field is less fragile in Webmin's form parser than
      // thousands of repeated hidden inputs; old 'cell' fields are still
      // accepted for backward compatibility by review.cgi.
      const selected = Array.from(allKeys).filter(key => !deselected.has(key));
      if (!selected.length) { event.preventDefault(); return; }
      const input = document.createElement('input');
      input.type = 'hidden';
      input.name = 'cells';
      input.className = 'cpu-submitted-cells';
      input.value = selected.join(',');
      form.appendChild(input);
    }

    entries.forEach(entry => {
      appendToMap(byRow, entry[1], entry[0]);
    });
    // Host headers toggle only updates matching the ACTIVE filter on this
    // host, across every filtered page. Other selections remain untouched.
    entries.forEach(entry => {
      appendToMap(byCol, entry[2], entry[0]);
    });
    loadSelection();

    root.addEventListener('click', event => {
      const button = event.target.closest('button.cpu-head-btn');
      if (!button || !root.contains(button)) return;
      if (button.id === 'cpu-corner') toggleGroup(Array.from(filteredKeys));
      else if (button.classList.contains('cpu-package-btn'))
        toggleGroup(byRow.get(Number(button.dataset.row)) || []);
      else if (button.classList.contains('cpu-host-btn'))
        toggleGroup(byCol.get(Number(button.dataset.col)) || []);
    });
    root.addEventListener('change', event => {
      if (!event.target.matches('input.cpu-cell')) return;
      const cb = event.target;
      if (cb.checked) deselected.delete(cb.value);
      else deselected.add(cb.value);
      saveSelection();
      updateStatus();
    });
    document.getElementById('cpu-select-all')?.addEventListener('click', () => {
      filteredKeys.forEach(k => deselected.delete(k));
      saveSelection();
      updateStatus();
    });
    document.getElementById('cpu-clear-all')?.addEventListener('click', () => {
      filteredKeys.forEach(k => deselected.add(k));
      saveSelection();
      updateStatus();
    });
    // Both pagination controls change page size without discarding the
    // global selection stored independently from the active filter.
    // Reset to page 1 when size changes, to avoid landing past the last page.
    document.querySelectorAll('select.cpu-page-size').forEach(select => {
      select.addEventListener('change', () => {
        if (!select.form) return;
        const pageInput = select.form.querySelector('input[name="page"]');
        if (pageInput) pageInput.value = '1';
        select.form.requestSubmit();
      });
    });
    form.addEventListener('submit', submitSelection);
    updateStatus();
    if (status) {
      status.textContent = 'Selection controls ready - bulk selection affects current filter across all matching pages.';
      status.classList.remove('cpu-error');
      status.classList.add('cpu-js-ready');
    }
  }

  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', initMatrix);
  else initMatrix();
})();
