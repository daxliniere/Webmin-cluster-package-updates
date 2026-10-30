#!/usr/bin/env python3
"""Browser regression for filter-scoped bulk actions. No Webmin server required."""
import json
import tempfile
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = (ROOT / 'cluster-package-updates/matrix.js').read_text()
ALL_KEYS = [f'k{i}' for i in range(1, 7)]
ALL = [["k1", 0, 0], ["k2", 0, 1], ["k3", 1, 0], ["k4", 1, 1], ["k5", 2, 0], ["k6", 2, 1]]
SEC = [["k1", 0, 0], ["k2", 0, 1], ["k5", 1, 0]]
SCOPE = "stable-host-fleet-regression"


def page_html(entries, displayed_keys):
    by_key = {cell[0]:cell for cell in entries}
    rows = sorted({by_key[k][1] for k in displayed_keys})
    cells = '\n'.join(
        f'<input class="cpu-cell" type="checkbox" value="{k}" checked>'
        for k in displayed_keys)
    row_buttons = '\n'.join(
        f'<button type="button" class="cpu-head-btn cpu-package-btn" data-row="{r}">row {r}</button>'
        for r in rows)
    host_buttons = '\n'.join(
        f'<button type="button" class="cpu-head-btn cpu-host-btn" data-col="{c}">host {c}</button>'
        for c in (0,1))
    data = json.dumps({"scope":SCOPE,"legacyScope":"unused","entries":entries,"allKeys":ALL_KEYS})
    return f'''<!DOCTYPE html><html><head><meta charset="UTF-8"></head><body>
        <button type="button" id="cpu-select-all">Select all matching</button>
        <button type="button" id="cpu-clear-all">Clear matching</button>
        <span id="cpu-count"></span><span id="cpu-count-footer"></span>
        <p id="cpu-js-status"></p>
        <form id="cpu-selection-form"><button type="submit" id="cpu-review" disabled>Review</button>
        <div id="cpu-matrix"><button type="button" id="cpu-corner" class="cpu-head-btn">corner</button>
        {host_buttons}{row_buttons}{cells}</div></form>
        <script id="cpu-selection-data" type="application/json">{data}</script>
        <script>{SCRIPT}</script>
    </body></html>'''



def test():
    with tempfile.TemporaryDirectory() as temp, sync_playwright() as playwright:
        root = Path(temp)
        (root/'all.html').write_text(page_html(ALL, ALL_KEYS))
        (root/'security.html').write_text(page_html(SEC, ['k1','k2'])) # k5 on next page
        (root/'security2.html').write_text(page_html(SEC, ['k5']))
        browser = playwright.chromium.launch(headless=True, executable_path='/usr/bin/chromium', args=['--no-sandbox'])
        page = browser.new_page()
        errors = []
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.evaluate("""() => {
            const data = {};
            Object.defineProperty(window, 'sessionStorage', {
                configurable: true,
                value: {getItem(k) {return Object.hasOwn(data,k) ? data[k] : null;},
                        setItem(k,v) {data[k] = String(v);}}
            });
        }""")
        def goto(path):
            page.set_content((root / path).read_text())
            assert 'Selection controls ready' in page.locator('#cpu-js-status').inner_text()
        def count(expected):
            actual = page.locator('#cpu-count').inner_text()
            assert expected in actual, (expected, actual)
        def save_keys():
            return page.evaluate('''() => JSON.parse(sessionStorage.getItem('cpu-selected-v0.1.7:stable-host-fleet-regression'))''')
        try:
            goto('all.html')
            count('6 of 6 selected updates (all filters and pages); 6 of 6 in current filter')
            goto('security.html')
            page.locator('#cpu-clear-all').click()
            count('3 of 6 selected updates (all filters and pages); 0 of 3 in current filter')
            assert set(save_keys()) == {'k1','k2','k5'}, save_keys()
            # Host 0 header re-selects two filtered security updates, including k5 on page 2.
            page.locator('.cpu-host-btn[data-col="0"]').click()
            count('5 of 6 selected updates (all filters and pages); 2 of 3 in current filter')
            assert set(save_keys()) == {'k2'}, save_keys()
            page.locator('.cpu-host-btn[data-col="0"]').click()
            count('3 of 6 selected updates (all filters and pages); 0 of 3 in current filter')
            # Package row header applies to both filtered hosts for that package.
            page.locator('.cpu-package-btn[data-row="0"]').click()
            count('5 of 6 selected updates (all filters and pages); 2 of 3 in current filter')
            page.locator('.cpu-package-btn[data-row="0"]').click()
            count('3 of 6 selected updates (all filters and pages); 0 of 3 in current filter')
            # Filtered select-all leaves non-security selections alone.
            page.locator('#cpu-select-all').click()
            count('6 of 6 selected updates (all filters and pages); 3 of 3 in current filter')
            # Deselect all security using top-left corner, not all six packages.
            page.locator('#cpu-corner').click()
            count('3 of 6 selected updates (all filters and pages); 0 of 3 in current filter')
            assert set(save_keys()) == {'k1','k2','k5'}, save_keys()
            goto('all.html')
            count('3 of 6 selected updates (all filters and pages); 3 of 6 in current filter')
            # Review submits selected keys even if they would be hidden under security filter.
            page.evaluate('''() => {document.getElementById('cpu-selection-form').addEventListener('submit',e=>e.preventDefault());}''')
            page.locator('#cpu-review').click()
            assert set(page.locator('input.cpu-submitted-cells').input_value().split(',')) == {'k3','k4','k6'}
            # Select all in filtered view, proving page 2 included without rendering it.
            goto('security2.html')
            page.locator('#cpu-select-all').click()
            count('6 of 6 selected updates (all filters and pages); 3 of 3 in current filter')
            goto('all.html')
            count('6 of 6 selected updates (all filters and pages); 6 of 6 in current filter')
            # Global clear when no filter still clears the fleet, as expected.
            page.locator('#cpu-clear-all').click()
            count('0 of 6 selected updates (all filters and pages); 0 of 6 in current filter')
            # Restore two nonsecurity selections; filtered operations leave them exactly as set.
            page.locator('#cpu-select-all').click()
            goto('security.html')
            page.locator('#cpu-clear-all').click()
            goto('all.html')
            count('3 of 6 selected updates (all filters and pages); 3 of 6 in current filter')
            assert not errors, errors
            print('PASS: filter-scoped actions, host/row/corner headers, all-page behavior, persisted hidden selections, review submission')
        finally:
            browser.close()


if __name__ == '__main__':
    test()
