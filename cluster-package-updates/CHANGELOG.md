# v0.1.17 - Filter-scoped bulk selection

- Select All, Clear All, the corner header, and host headers now affect only packages matching the active search/category/hide filters, across all matching pages.
- Row headers toggle the matching package across eligible hosts.
- Individual checkboxes remain per-cell.
- Existing selections outside the active filter are retained unchanged, including when switching All updates to Security updates and back.
- Total/filtered selection counts and global Review submission remain unchanged.
- Public and private installers share the same source; private package includes site-specific host defaults.

## v0.1.15
- Move **Back to package matrix** directly below **Refresh Status** near the top of the Cluster Update Job page. Keep a navigation link for invalid/missing jobs.
- Public-source privacy cleanup: replace private LAN addresses and test IDs with RFC 5737 example hosts, and ship a blank default remote-host allow-list.
- Include a CC0-1.0 dedication for project-authored code. Webmin and any other external dependencies keep their own licences.
- No changes to the APT approval, simulation, or update worker execution paths.

## v0.1.14
- Make **Confirm updates on selected ready machines** a visibly blue native submit button under Authentic Theme, instead of styling its hidden submit input.
- Move **Refresh Status** to the top of the execution job screen and make it blue.
- Add compact, fixed 18px status circles: green check for `completed` and `completed-with-skips`, red X for failed states, orange exclamation mark for warnings, blocked and skipped machines.
- Retain per-host isolation, approval, simulation, update execution and all previous features unchanged.

# v0.1.13 - independent per-host approval and selective PVE mode

- Blocked APT previews now block only their own host; ready machines can be approved separately.
- Review shows ready / blocked status for each machine with approval checkboxes for ready machines.
- PVE uses full-upgrade when *all* pending PVE updates are selected, or `apt-get install package=version` for a selective subset, with --no-remove, dependency simulation, and explicit elevated risk acknowledgement.
- Critical PVE packages in the selection/transaction require a second explicit approval.
- Execution verifies selected hosts belong to the immutable reviewed plan, revalidates inventories and simulation digests, and processes approved hosts only, PVE last.
- Blocked/unchecked hosts are reported as blocked or skipped, not attempted.
- No automatic reboot.

# Change log

## v0.1.13
- Tint the final **Confirm and start updates** submit button a restrained green, with a stronger hover treatment and focus outline.
- Scope styling to the approval control, preserving the existing explicit confirmation checkbox, preview gating, and no-automatic-reboot policy.
- Use input/button selectors and versioned stylesheet URLs to work with Authentic Theme and avoid stale cached styling.

## v0.1.11
- Restore the em dash (—) for Not installed / unavailable matrix cells and the legend. The Hidden by filter state remains a fixed-size funnel icon.
- Fix the disappearing Webmin Authentic Theme sidebar after a review completes. Avoid automatic window.location.replace navigation; show a normal Open review results link, leaving the Webmin navigation shell intact.
- When a review fails, expose Open review details so errors can be inspected without a direct JavaScript redirect.
- Retain all prior selection and package-upgrade approval protections.

# Change log

## v0.1.10
- Review/cataloguing scans only hosts with selected updates; progress is x of actual selected hosts, not x of every registered host. Validate selected host IDs using the server-side inventory snapshot before performing a fresh scoped scan.
- Refresh the updated host's Webmin package-update cache automatically after successful APT execution, and invalidate the master matrix snapshot. Refresh failure is reported separately and never disguises the package operation result.
- Replace visually ambiguous filtered-cell dash with a 15px CSS-background funnel SVG, keeping status icons immune to theme SVG scaling. Unavailable packages remain dotted cells.
- Improve PVE partial-upgrade messaging with a safe resolution: select all PVE host updates or deselect PVE before proceeding. Proxmox's recommended full upgrade remains protected.
- Preserve the existing cross-filter/page selection state, RPC execution logic, and explicit approval process.

# Change log

## v0.1.9
- Read-only review runs in a detached process with a persistent job record.
- Progress page displays per-machine inventory and APT simulation stages with completion counts.
- Authenticated status endpoint polls every two seconds; automatically opens approval page when ready.
- No package changes take place before separate explicit confirmation.
- Retains v0.1.8 Webmin cluster RPC and update safety gates.

# Changelog

## 0.1.8
- Fix standard Webmin 2.670 RPC evaluation of a hyphenated module name: run remote_eval in supported global context after establishing existing package-updates RPC session.
- Report structured remote eval failures and retain read-only simulation blocking when any host fails.
- Add regression tests that reproduce rpc.cgi's parsing bug and validate the corrected returned APT status/output structure.
- Preserve v0.1.7 browser selection-state namespace across the patch upgrade.
- Fix structured return from Webmin RPC APT simulation.
- Keep accurate requested-package/host totals even when an RPC simulation fails; block execution until all previews succeed.
- Preserve all selections across update-category and search filters, pagination and row-count changes; use compact single-field review submission.
- Add filter checkbox to hide up-to-date-only package rows, with working on/off state.
- Make row/host and whole-grid controls apply across all pages and filters; green checks stay read-only status indicators.
- Retain existing two-stage approval, job reporting and no-automatic-reboot policy.

## 0.1.6
- Fix unresponsive Select All, Clear All and clickable headers by embedding a fallback copy of matrix.js into the rendered module page alongside the versioned external script.
- Display an explicit JavaScript initialization status so a failed load cannot silently leave controls inert.
- Put Review selected updates beside Clear all in the main toolbar.
- Swap category and search fields, halve the search field width, and tint the Filter button light grey.
- Preserve earlier version's matrix, RPC configuration, and update preview/apply workflow.


## 0.1.4
- Add a Rows per page selector (20, 50, 100, 250) integrated into the page-number controls above and below the table.
- On changing the selector, navigate to page 1, preserving current filters and per-tab selections.
- Keep Select All operating on every eligible update across all filtered pages, not only the current page.
- Remove the duplicate page-size field from the filter form and use a single page/size Go button, but preserve its value on filter submits.
- Preserve read-only operation, site-specific host exclusions, prior Webmin RPC configuration and v0.1.3 selection storage.

## 0.1.3
- Fix green up-to-date icons appearing enormously large under Authentic Theme: render an 18px self-contained green circle/check, no external image scaling.
- Make all package rows compact and uniform at 36px; truncate oversized names/versions with a tooltip carrying the full value.
- Remove the nested scrollable matrix container entirely; use the main Webmin/browser page scrolling.
- Set a version-specific query string for CSS/JS assets to avoid using v0.1.2 cached styles.
- Retain pagination, RPC inventory, filters, cross-page header selection, and read-only safety.


## 0.1.2
- Add target-version labels after package names, with multiple versions shown honestly when repositories differ.
- Add green up-to-date icons only for verified installed packages without available upgrades. Never mistake missing or unreachable hosts for current.
- Add server-rendered pagination (20/50/100 rows), first/previous/page input/next/last controls, and a compact cached inventory.
- Preserve selections across pages in the same browser tab; clickable row, column and corner headers operate on the entire filtered selection, not just the visible page.
- Add All, Security, Non-security and High/Critical-if-supplied category filters. Never manufacture severity from guessed package names.
- Keep read-only review, stale-version validation and explicit site-specific host exclusions.

## 0.1.1
- Add package-by-host checkbox matrix with clickable row, column, and corner headers.
- Add tri-state selection indication, Select All / Clear All, live counts.
- Add read-only grouped selection review with server-side revalidation.
- Preserve fixed RPC allow-list and v0.1.0 read-only model.

## 0.1.0
- Initial read-only Webmin RPC inventory and per-host update tables.

## 0.1.5

- Group package search and category in one row, with Filter and Refresh below in the same panel.
- Introduce safe per-host APT dependency/removal simulations and explicit two-step approval.
- Use existing Webmin RPC for remote hosts rather than host-side pct/SSH commands.
- Queue sequential upgrades with PVE last, reject changed plans, record per-host results.
- Retain cross-page selection, compact cells, primary-page scrolling, and pagination.
