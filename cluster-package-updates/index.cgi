#!/usr/bin/perl
# Cluster Package Updates v0.1.17 - selectable updates, simulated preview and controlled apply.
# Builds a package-by-host checkbox matrix. Submission previews and requires
# a second explicit confirmation before any approved upgrades can run.
# Server-side pagination renders only the current page's rows.
require './cluster-package-updates-lib.pl';

# Page navigation preserves filters while avoiding huge DOM tables.
sub pager_link
{
    my ($page, $search, $kind, $per_page, $hide_current) = @_;
    return 'index.cgi?search=' . &cpu_urlencode($search) .
        '&kind=' . &cpu_urlencode($kind) .
        '&per_page=' . $per_page . '&hide_current=' . $hide_current . '&page=' . $page;
}

sub render_pager
{
    my ($page, $pages, $total, $search, $kind, $per_page, $hide_current) = @_;
    my $first = &pager_link(1, $search, $kind, $per_page, $hide_current);
    my $prev = &pager_link($page > 1 ? $page - 1 : 1,
        $search, $kind, $per_page, $hide_current);
    my $next = &pager_link($page < $pages ? $page + 1 : $pages,
        $search, $kind, $per_page, $hide_current);
    my $last = &pager_link($pages, $search, $kind, $per_page, $hide_current);
    print '<nav class="cpu-pager" aria-label="Package pages">';
    print '<span class="cpu-pager-count">', $total, ' ',
        &html_escape($text{'pager_items'}), '</span>';
    for my $item (
        [1, '&#171;', $first, $page == 1, 'First page'],
        [2, '&#8249;', $prev, $page == 1, 'Previous page']) {
        print $item->[3] ?
            '<span class="cpu-page-link cpu-page-disabled" aria-hidden="true">'.$item->[1].'</span>' :
            '<a class="cpu-page-link" href="'.&html_escape($item->[2]).'" aria-label="'.$item->[4].'">'.$item->[1].'</a>';
    }
    # Integrate page number and page size in one pager form. The two pagers
    # share the query parameters, so both show the same current page size.
    print '<form action="index.cgi" method="get" class="cpu-page-form">',
          '<input type="hidden" name="search" value="', &html_escape($search), '">',
          '<input type="hidden" name="kind" value="', &html_escape($kind), '">',
          '<input type="hidden" name="hide_current" value="', $hide_current, '">',
          '<label>', &html_escape($text{'pager_page'}), ' ',
          '<input name="page" type="number"',
          ' min="1" max="', $pages, '" value="', $page, '"',
          ' aria-label="Page number" required></label>',
          '<span>', &html_escape($text{'pager_of'}), ' ', $pages, '</span>',
          '<label class="cpu-page-size-label">',
          &html_escape($text{'pager_rows_per_page'}), ' ',
          '<select name="per_page" class="cpu-page-size" aria-label="Rows per page">';
    for my $n (20, 50, 100, 250) {
        print '<option value="', $n, '"',
            ($per_page == $n ? ' selected' : ''),
            '>', $n, '</option>';
    }
    print '</select></label>',
          '<button type="submit" class="cpu-page-go">',
          &html_escape($text{'pager_go'}), '</button></form>';
    for my $item (
        [3, '&#8250;', $next, $page == $pages, 'Next page'],
        [4, '&#187;', $last, $page == $pages, 'Last page']) {
        print $item->[3] ?
            '<span class="cpu-page-link cpu-page-disabled" aria-hidden="true">'.$item->[1].'</span>' :
            '<a class="cpu-page-link" href="'.&html_escape($item->[2]).'" aria-label="'.$item->[4].'">'.$item->[1].'</a>';
    }
    print '</nav>';
}

# Show all distinct candidate versions, without pretending there is one
# global "latest" version across different Debian/Ubuntu repositories.
sub render_version_suffix
{
    my ($row) = @_;
    my @versions = @{$row->{'versions_list'} || []};
    return '' unless @versions;
    my $display = @versions <= 2 ? join(' / ', @versions) :
        $versions[0].' + '.(@versions - 1).' more';
    return ' <span class="cpu-candidate-version" title="'.
        &html_escape(join(' / ', @versions)).'">('.
        &html_escape($display).')</span>';
}

&ReadParse();
my $refresh = exists $in{'refresh'};
my $search = substr(($in{'search'} // ''), 0, 120);
my $kind = $in{'kind'} // (($in{'security'} || '') eq '1' ? 'security' : 'all');
$kind = 'all' unless $kind =~ /^(?:all|security|standard|high)$/;
my $page_arg = $in{'page'} // 1;
my $per_page_arg = $in{'per_page'} // 20;
# Webmin ReadParse joins repeated hidden+checkbox fields with NUL bytes.
# The LAST value is the checkbox state; checking only the whole string
# would make the toggle impossible to disable.
my @hide_values = split(/\0/, ($in{'hide_current'} // '1'));
my $hide_current = ($hide_values[-1] // '1') eq '0' ? 0 : 1;
my ($states, $cells, $installed, $all_cells) =
    &load_inventory($refresh, $search, $kind);
my $rows = &build_matrix($states, $cells, $installed, $all_cells,
    !$hide_current, $search, $kind);
my ($page_rows, $page, $pages, $total, $per_page, $start) =
    &paginate_rows($rows, $page_arg, $per_page_arg);
my $selected_total = scalar(@$all_cells);

# All selection keys share one stable fleet scope, independently of any
# search, category, page, or hide-current filter. The browser retains
# deselections for currently hidden update cells and submits the full set.
my %host_index = map { $states->[$_]{'host'} => $_ } 0..$#$states;
my @selection_rows;
for (my $i = 0; $i < @$rows; $i++) {
    my $row = $rows->[$i];
    for my $host (keys %{$row->{'by_host'} || {}}) {
        next unless exists $host_index{$host};
        push @selection_rows, [$row->{'by_host'}{$host}{'key'},
            $i, $host_index{$host}];
    }
}
my %visible = map { $_->[0] => 1 } @selection_rows;
my @all_keys = map { $_->{'key'} } @$all_cells;
my $fleet_scope = sha256_hex(join("\0", 'fleet-v0.1.7',
    map { $_->{'host'} } @$states));
my $legacy_scope = sha256_hex(join("\0", $search, $kind,
    map { $_->[0] } sort { $a->[0] cmp $b->[0] } @selection_rows));
my $selection_json = JSON::PP->new->canonical->encode({
    scope => $fleet_scope, legacyScope => $legacy_scope,
    entries => \@selection_rows,
    allKeys => \@all_keys });

&ui_print_header(undef, $text{'index_title'}, '', undef, 1, 1);
print '<link rel="stylesheet" href="matrix.css?v=0.1.17">', "\n";
print '<h3>', &html_escape($text{'index_intro'}), '</h3>', "\n";
print '<p class="cpu-note">', &html_escape($text{'index_readonly'}), '</p>', "\n";

# Group related filter controls in one visual panel. Webmin's form helper
# provides the existing CSRF/session integration.
print &ui_form_start('index.cgi', 'get', undef, 'class="cpu-filter-panel"');
print '<div class="cpu-filter-fields">';
my $kind_options = '<select name="kind" aria-label="Update category">';
for my $opt ([all=>'All updates'], [security=>'Security updates'],
             [standard=>'Non-security updates'],
             [high=>'High / critical (when reported)']) {
    $kind_options .= '<option value="'.$opt->[0].'"'.
        ($kind eq $opt->[0] ? ' selected' : '').'>'.$opt->[1].'</option>';
}
$kind_options .= '</select>';
print '<label class="cpu-filter-field cpu-filter-category"><span>', &html_escape($text{'index_type'}),
      '</span>', $kind_options, '</label>';
print '<label class="cpu-filter-field cpu-filter-search"><span>', &html_escape($text{'index_search'}),
      '</span>', &ui_textbox('search', $search, 24), '</label></div>';
print '<input type="hidden" name="per_page" value="', $per_page, '">';
print '<label class="cpu-hide-current">',
      '<input type="hidden" name="hide_current" value="0">',
      '<input type="checkbox" name="hide_current" value="1"',
      ($hide_current ? ' checked' : ''),
      '> Hide packages up to date on all hosts</label>';
print '<div class="cpu-filter-actions">',
      '<button type="submit" name="filter" value="1" class="cpu-filter-button">',
      &html_escape($text{'index_filter'}), '</button>',
      '<button type="submit" name="refresh" value="1" class="cpu-refresh-button">',
      &html_escape($text{'index_refresh'}), '</button></div>';
print &ui_form_end();
print '<p class="cpu-note">', &html_escape($text{'index_filter_note'}), '</p>';

print '<details class="cpu-status"><summary>',
      &html_escape($text{'index_status'}), ' (', scalar(@$states), ')</summary>';
print '<table class="cpu-status-table"><thead><tr><th>',
      &html_escape($text{'index_name'}), '</th><th>',
      &html_escape($text{'index_result'}), '</th><th>',
      &html_escape($text{'index_count'}), '</th></tr></thead><tbody>';
for my $st (@$states) {
    my $message = $st->{'error'} || 'OK';
    $message .= ' (installed-package status unavailable: '.$st->{'current_error'}.')'
        if !$st->{'error'} && $st->{'current_error'};
    print '<tr><th scope="row">', &html_escape($st->{'label'}), '</th><td>',
          &html_escape($message), '</td><td>',
          $st->{'error'} ? '-' : $st->{'count'}, '</td></tr>';
}
print '</tbody></table></details>';

my $unavailable = scalar grep { $_->{'error'} } @$states;
if ($unavailable) {
    print '<p class="cpu-error">', $unavailable, ' ',
          &html_escape($text{'index_unavailable'}), '</p>';
}
print '<h3>', &html_escape($text{'index_matrix'}),
      ' <small>(', $total, ' ', &html_escape($text{'index_rows'}),
      ', ', $selected_total, ' ', &html_escape($text{'index_cells'}),
      ')</small></h3>';

if (!@$rows && !@$all_cells) {
    print '<p>', &html_escape($text{'index_no'}), '</p>';
}
else {
    &render_pager($page, $pages, $total, $search, $kind, $per_page, $hide_current);
    print &ui_form_start('review.cgi', 'post', undef, 'id="cpu-selection-form"');
    print '<div class="cpu-toolbar">',
          '<button type="button" class="cpu-action" id="cpu-select-all" title="Select every matching update across all filtered pages">',
           &html_escape($text{'index_selectall'}), '</button>',
          '<button type="button" class="cpu-action" id="cpu-clear-all" title="Clear matching updates across all filtered pages">',
           &html_escape($text{'index_clearall'}), '</button>',
          '<button type="submit" class="cpu-primary" id="cpu-review" disabled>',
           &html_escape($text{'index_review'}), '</button>',
          '<span class="cpu-counter" id="cpu-count" role="status" aria-live="polite">',
           $selected_total, ' ', &html_escape($text{'index_selected'}), '</span>',
          '</div>';
    # Clearly indicate when the browser-side selection handler failed to boot.
    # The script changes this text and enables Review as soon as it initializes.
    print '<p id="cpu-js-status" class="cpu-error cpu-js-status" role="status">',
          'Selection controls not initialized. Refresh the page if this persists.',
          '</p>';
    print '<div class="cpu-legend">',
          '<span><input type="checkbox" checked disabled aria-hidden="true"> Update</span>',
          '<span><input type="checkbox" disabled aria-hidden="true"> Do not update</span>',
          '<span><span class="cpu-check-icon" role="img" aria-label="Up to date" style="display:inline-flex!important;align-items:center!important;justify-content:center!important;width:18px!important;height:18px!important;max-width:18px!important;max-height:18px!important;border-radius:50%!important;background:#2e9f58!important;color:#fff!important;font:bold 13px/18px Arial,sans-serif!important;vertical-align:middle!important;flex:0 0 18px!important;">&#10003;</span> Up to date</span>',
          '<span class="cpu-legend-muted">&mdash; Not installed / unavailable</span>',
          '<span class="cpu-legend-muted"><span class="cpu-filter-icon" role="img" aria-label="Hidden by filter"></span> Hidden by filter</span>',
          '</div>';
    # Use the browser's normal page scrolling: no nested scroll region.
    print '<p class="cpu-matrix-caption" id="cpu-matrix-caption">Package update selection by host</p>';
    if (!@$rows) {
        print '<p class="cpu-note">No packages match this filter. Your selections remain unchanged.</p>';
    }
    print '<table class="cpu-matrix" id="cpu-matrix" aria-describedby="cpu-matrix-caption"><thead><tr>';
    print '<th class="cpu-corner" scope="col">',
          '<button type="button" class="cpu-head-btn" id="cpu-corner"',
          ' aria-label="Toggle updates matching current filters across all pages" title="Toggle all updates in current filter">',
          &html_escape($text{'index_package'}), ' &#x2611;</button></th>';
    for (my $j = 0; $j < @$states; $j++) {
        my $st = $states->[$j];
        my $label = &html_escape($st->{'label'});
        print '<th scope="col" class="cpu-host-head">',
              '<button type="button" class="cpu-head-btn cpu-host-btn" data-col="', $j,
              '" aria-label="Toggle matching package updates on ', $label, ' across all filtered pages">',
              $label, '</button></th>';
    }
    print '</tr></thead><tbody>';

    for (my $k = 0; $k < @$page_rows; $k++) {
        my $row = $page_rows->[$k];
        my $i = $start + $k;    # Global row index for all-page selection.
        my $label = &html_escape($row->{'name'});
        my $system = &html_escape($row->{'system'});
        my $full_versions = join(' / ', @{$row->{'versions_list'} || []});
        my $full_title = $row->{'name'} .
            ($full_versions ne '' ? ' (' . $full_versions . ')' : '');
        print '<tr><th scope="row" class="cpu-package-head">',
              '<button type="button" class="cpu-head-btn cpu-package-btn" data-row="', $i,
              '" title="', &html_escape($full_title),
              '" aria-label="Toggle ', $label, ' on all hosts matching the current filter">',
              $label, &render_version_suffix($row);
        print ' <span class="cpu-system">', $system, '</span>' if $system && $system ne 'apt';
        print ' <span class="cpu-security">SEC</span>' if $row->{'security'};
        print ' <span class="cpu-security">HIGH</span>' if $row->{'priority'} &&
            $row->{'priority'} =~ /^(?:high|critical|urgent)$/;
        print '</button></th>';
        for (my $j = 0; $j < @$states; $j++) {
            my $host = $states->[$j]{'host'};
            my $cell = $row->{'by_host'}{$host};
            if ($cell) {
                my $title = &html_escape(
                    $row->{'name'}.' on '.$states->[$j]{'label'}.': '.
                    $cell->{'old'}.' to '.$cell->{'new'}.
                    ($cell->{'security'} ? ' (security update)' : ''));
                print '<td class="cpu-eligible', ($cell->{'security'} ? ' cpu-sec-cell' : ''), '">',
                      '<label title="', $title, '">',
                      '<input class="cpu-cell" type="checkbox" value="',
                       $cell->{'key'}, '" data-row="', $i, '" data-col="', $j,
                      '" checked aria-label="', $title, '">',
                      '</label></td>';
            }
            else {
                my $status = $row->{'status'}{$host} // 'unknown';
                if ($status eq 'current') {
                    my $installed_ver = &html_escape($row->{'installed_version'}{$host} // '');
                    print '<td class="cpu-current" title="Installed version ', $installed_ver,
                        '; no update available in the current package indexes">',
                        '<span class="cpu-check-icon" role="img" aria-label="Up to date" ',
                        'style="display:inline-flex!important;align-items:center!important;',
                        'justify-content:center!important;width:18px!important;',
                        'height:18px!important;max-width:18px!important;',
                        'max-height:18px!important;border-radius:50%!important;',
                        'background:#2e9f58!important;color:#fff!important;',
                        'font:bold 13px/18px Arial,sans-serif!important;',
                        'vertical-align:middle!important;flex:0 0 18px!important;">',
                        '&#10003;</span></td>';
                }
                elsif ($status eq 'filtered') {
                    print '<td class="cpu-absent cpu-filtered" title="Update excluded by active filter" aria-label="Update excluded by filter"><span class="cpu-filter-icon" role="img" aria-label="Hidden by filter"></span></td>';
                }
                else {
                    print '<td class="cpu-absent" title="',
                        ($status eq 'unavailable' ? 'Server unreachable' :
                         $status eq 'unknown' ? 'Installed package status unavailable' :
                         'Not installed on this host'),
                        '" aria-label="No eligible update">&mdash;</td>';
                }
            }
        }
        print '</tr>';
    }
    print '</tbody></table>';
    print '<div class="cpu-footer"><strong id="cpu-count-footer">',
          $selected_total, ' ', &html_escape($text{'index_selected'}), '</strong>',
          '</div>';
    print &ui_form_end();
    &render_pager($page, $pages, $total, $search, $kind, $per_page, $hide_current);
    print '<script type="application/json" id="cpu-selection-data">',
        $selection_json, '</script>', "\n";
    # Keep the external controller for full-page loads and theme loaders that
    # fetch registered assets. The inline copy below is an additional fallback.
    # Its initialized flag prevents double binding when both run.
    print '<script src="matrix.js?v=0.1.17"></script>', "\n";
    # Inline the controller to avoid external-script loading problems in Webmin
    # Authentic Theme's dynamically rendered module pages.  The controller
    # still lives in matrix.js so it can be independently linted and tested.
    my $js_file = "$module_root_directory/matrix.js";
    if (open(my $js_fh, '<', $js_file)) {
        local $/;
        my $js = <$js_fh>;
        close($js_fh);
        print '<script type="text/javascript">', "\n", $js, "\n", '</script>', "\n";
    }
    else {
        print '<p class="cpu-error">Matrix selection script unavailable.</p>';
    }
    print '<noscript><p class="cpu-error">JavaScript is required for ',
          'cross-page selection and review.</p></noscript>';
}
print '<p class="cpu-note">', &html_escape($text{'index_note'}), '</p>';
&remote_finished();
&ui_print_footer();
