# Cluster Package Updates v0.1.17

Public distribution. Filters scope bulk actions but not selection storage. Includes source and regression tests. On a new installation configure your own Webmin remote server allow-list.

# Cluster Package Updates v0.1.15

A Webmin cluster module providing a package-by-host update matrix, selected-update APT simulations, explicit per-host approval and execution tracking. Works through existing Webmin RPC connections.

## v0.1.15 changes
- **Back to package matrix** now appears directly below **Refresh Status** at the top of the Cluster Update Job page.
- Sanitised public source code and test fixtures. No site-specific host allow-list is distributed.
- Default remote host list is empty. Configure authorised Webmin RPC targets after installing on a new server.

## Installation
Use **Webmin > Webmin Configuration > Webmin Modules** to install the `.wbm.gz` file. For an existing installation, back up `/etc/webmin/cluster-package-updates/config` first and confirm your approved hosts remain configured afterward. The installer ships with blank *defaults* and does not contain your addresses.

## Tests
The `tests/` directory is bundled in the source archive only. These are mocked tests; they do not upgrade live hosts. Run from this archive's root with `prove -I tests/stub tests/*.pl` (requires Perl's standard Test::More and JSON::PP).

## Security and safety
The module can run package upgrades on the user-approved servers. Review its code before deploying on systems you administer. Package changes require simulation and explicit approval, but simulations do not eliminate the risk of failed or disruptive upgrades. Do not expose Webmin over an untrusted network.

## Licensing
The original code and documentation in this release are dedicated under **CC0-1.0 Universal** (see `LICENSE`). This dedication does not relicense Webmin, Perl, Node.js, or other external software. Icons included here are simple original geometric artwork. Please check any additional assets or contributions before reusing the CC0 designation for them.

## v0.1.17 filter-scoped bulk selection
Select all matching / Clear matching and the top-left or host-column headers operate only on packages matching the active search, update category, and hide-up-to-date settings. Actions include all matching pages, even rows not currently rendered. Selections outside the filter remain unchanged. Review always includes all selected updates.

Browser regression (optional, requires Playwright and Chromium): `python tests/test_filter_scoped_selection.py`
