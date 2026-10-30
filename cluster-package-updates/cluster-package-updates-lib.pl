# Common functions for Cluster Package Updates (v0.1.15).
# Read-only module. Do not add mutation calls here.
BEGIN { push(@INC, ".."); }
use WebminCore;
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
&init_config();
&foreign_require("servers", "servers-lib.pl");

# get_targets() returns a local record and the explicitly approved RPC targets.
# No credential values are ever rendered in output.
sub get_targets
{
    my @rv;
    if ($config{'include_local'}) {
        push @rv, { label => 'PVE (this server)', host => 'local', remote => undef };
    }

    my %registered = map { ($_->{'host'} // '') => $_ }
                     &servers::list_servers();
    my %seen;
    for my $host (split(/\s+/, ($config{'targets'} // ''))) {
        next unless length $host;
        next if $seen{$host}++;
        my $s = $registered{$host};
        if (!$s || !$s->{'user'}) {
            push @rv, { label => $host, host => $host,
                        error => 'Not registered for authenticated RPC' };
            next;
        }
        push @rv, { label => ($s->{'desc'} || $host),
                    host => $host, remote => $s };
    }
    return @rv;
}

# query_updates(target, refresh) -> (arrayref, error-string)
# refresh invalidates Webmin's package caches but does not run apt-get update.
sub query_updates
{
    my ($target, $refresh) = @_;
    return ([], $target->{'error'}) if $target->{'error'};
    my $remote_error = '';
    my @updates;

    if ($target->{'remote'}) {
        # Webmin remote RPC uses an error callback rather than Perl die for
        # transport errors, so capture both failure mechanisms.
        my $handler = sub { $remote_error = join('', @_); };
        &remote_error_setup($handler);
        my $okay = eval {
            &remote_foreign_require($target->{'remote'},
                  'package-updates', 'package-updates-lib.pl');
            if (!$remote_error) {
                @updates = &remote_foreign_call($target->{'remote'},
                   'package-updates', 'list_possible_updates',
                   $refresh ? 1 : 0, 0);
            }
            1;
        };
        my $exception = $@;
        &remote_error_setup(undef);
        if (!$okay) {
            return ([], "RPC failed: $exception");
        }
        return ([], "RPC failed: $remote_error") if $remote_error;
    }
    else {
        my $okay = eval {
            &foreign_require('package-updates', 'package-updates-lib.pl');
            @updates = &package_updates::list_possible_updates(
                $refresh ? 1 : 0, 0);
            1;
        };
        return ([], "Local query failed: $@") unless $okay;
    }
    return (\@updates, '');
}

# Normalize each update and build a deterministic cell identifier.
# The hash ties a submitted selection to host, package, and both versions;
# re-checking this on preview prevents stale row-number selection errors.
sub normalize_update
{
    my ($target, $pkg) = @_;
    return undef unless ref($pkg) eq 'HASH';
    my $name = $pkg->{'name'} // '';
    return undef unless length($name);
    my $system = $pkg->{'system'} // '';
    my $old = $pkg->{'oldversion'} // '';
    my $new = $pkg->{'version'} // '';
    my $key = sha256_hex(join("\0", $target->{'host'}, $system,
                              $name, $old, $new));
    return {
        key => $key, host => $target->{'host'}, name => $name,
        system => $system, old => $old, new => $new,
        apt_version => (($pkg->{'epoch'} // '') ne '' ? $pkg->{'epoch'}.':'.$new : $new),
        security => $pkg->{'security'} ? 1 : 0,
        desc => $pkg->{'desc'} // '', source => $pkg->{'source'} // '',
        priority => (defined $pkg->{'severity'} &&
            $pkg->{'severity'} =~ /^(?:high|critical|urgent)$/i) ?
                lc($pkg->{'severity'}) : ''
    };
}

# query_installed(target) returns cached installed package versions.
# These are required to distinguish up-to-date from uninstalled / unreachable.
# A blank update cell must not be interpreted as up-to-date on its own.
sub query_installed
{
    my ($target) = @_;
    return ([], $target->{'error'}) if $target->{'error'};
    my $remote_error = '';
    my @installed;
    if ($target->{'remote'}) {
        my $handler = sub { $remote_error = join('', @_); };
        &remote_error_setup($handler);
        my $okay = eval {
            &remote_foreign_require($target->{'remote'},
                'package-updates', 'package-updates-lib.pl');
            if (!$remote_error) {
                @installed = &remote_foreign_call($target->{'remote'},
                    'package-updates', 'list_current', 0);
            }
            1;
        };
        my $exception = $@;
        &remote_error_setup(undef);
        return ([], "RPC failed: $exception") unless $okay;
        return ([], "RPC failed: $remote_error") if $remote_error;
    }
    else {
        my $okay = eval {
            &foreign_require('package-updates', 'package-updates-lib.pl');
            @installed = &package_updates::list_current(0);
            1;
        };
        return ([], "Local query failed: $@") unless $okay;
    }
    # Keep only fields needed to render honest per-host status.
    my @compact = map {
        { name => $_->{'name'} // '', system => $_->{'system'} // '',
          version => $_->{'version'} // '' }
    } grep { ref($_) eq 'HASH' && length($_->{'name'} // '') } @installed;
    return (\@compact, '');
}

# Short-lived on-disk inventory avoids re-querying all hosts for each page.
# No passwords or authentication material are saved in this cache.
sub inventory_cache_file
{
    my $dir = $module_var_directory;
    return undef unless $dir;
    if (!-d $dir) {
        mkdir($dir, 0700) or return undef;
    }
    return "$dir/matrix-inventory-v0.1.3.json";
}

# Resolve submitted selection IDs using the inventory snapshot that built
# the matrix. This is a lookup of server-side records, never a trusted host
# list supplied by the browser. The selected hosts are re-queried during review.
sub cpu_hosts_for_selection
{
    my ($requested) = @_;
    die 'No updates selected' unless ref($requested) eq 'HASH' && keys %$requested;
    my $file = &inventory_cache_file();
    die 'Update inventory expired; refresh the matrix and review again'
        unless $file && -r $file;
    open(my $fh, '<', $file) or die 'Cannot read update inventory';
    local $/;
    my $raw = <$fh>;
    close($fh);
    my $snapshot = eval { JSON::PP->new->decode($raw) };
    my $fingerprint = sha256_hex(join("\0", $config{'targets'} // '',
        $config{'include_local'} // ''));
    die 'Update inventory changed; refresh the matrix and review again'
        unless $snapshot && ref($snapshot) eq 'HASH' &&
        ($snapshot->{'fingerprint'} // '') eq $fingerprint &&
        ref($snapshot->{'cells'}) eq 'ARRAY';
    my %available = map { ($_->{'key'} // '') => ($_->{'host'} // '') }
        grep { ref($_) eq 'HASH' } @{$snapshot->{'cells'}};
    my %allowed = map { $_->{'host'} => 1 } &get_targets();
    my %hosts;
    for my $key (keys %$requested) {
        die 'Selected update is no longer in the inventory; refresh the matrix'
            unless exists($available{$key}) && $allowed{$available{$key}};
        $hosts{$available{$key}} = 1;
    }
    return \%hosts;
}

sub raw_inventory
{
    my ($refresh, $progress, $only_hosts) = @_;
    my $file = &inventory_cache_file();
    my $fingerprint = sha256_hex(join("\0", $config{'targets'} // '',
        $config{'include_local'} // ''));
    # A targeted review is intentionally uncached and MUST NOT overwrite the
    # complete matrix cache with only a subset of hosts.
    if (!$only_hosts && !$refresh && $file && -r $file && time - (stat($file))[9] < 180) {
        if (open(my $fh, '<', $file)) {
            local $/;
            my $serialized = <$fh>;
            close($fh);
            my $cached = eval { JSON::PP->new->decode($serialized) };
            if ($cached && ref($cached) eq 'HASH' &&
                ($cached->{'fingerprint'} // '') eq $fingerprint &&
                ref($cached->{'states'}) eq 'ARRAY' &&
                ref($cached->{'cells'}) eq 'ARRAY' &&
                ref($cached->{'installed'}) eq 'ARRAY') {
                return ($cached->{'states'}, $cached->{'cells'},
                    $cached->{'installed'});
            }
        }
    }

    my (@states, @cells, @installed);
    my @targets = &get_targets();
    @targets = grep { $only_hosts->{$_->{'host'}} } @targets if $only_hosts;
    my $target_index = 0;
    for my $target (@targets) {
        $target_index++;
        $progress->('inventory-start', $target->{'label'}, $target_index - 1, scalar(@targets)) if $progress;
        my ($updates, $err) = &query_updates($target, $refresh);
        my $count = 0;
        if (!$err) {
            for my $pkg (@$updates) {
                my $cell = &normalize_update($target, $pkg);
                next unless $cell;
                ++$count;
                push @cells, $cell;
            }
        }
        my $current_error = '';
        if (!$err && !$only_hosts) {
            my ($current, $cerr) = &query_installed($target);
            $current_error = $cerr;
            unless ($cerr) {
                for my $pkg (@$current) {
                    push @installed, { host => $target->{'host'}, %$pkg };
                }
            }
        }
        push @states, { host => $target->{'host'}, label => $target->{'label'},
            count => $count, error => $err, current_error => $current_error };
        $progress->('inventory-finished', $target->{'label'}, $target_index, scalar(@targets), $err || $current_error, $count) if $progress;
    }
    if ($file && !$only_hosts) {
        my $tmp = "$file.$$";
        if (open(my $fh, '>', $tmp)) {
            chmod(0600, $tmp);
            print {$fh} JSON::PP->new->canonical->encode({
                fingerprint => $fingerprint, states => \@states,
                cells => \@cells, installed => \@installed });
            close($fh);
            rename($tmp, $file) or unlink($tmp);
        }
    }
    return (\@states, \@cells, \@installed);
}

# Following a successfully completed update, re-query only that host's
# Webmin update cache and invalidate the shared matrix snapshot. A refresh
# error never changes the result of the completed package transaction.
sub cpu_refresh_after_success
{
    my ($target) = @_;
    my ($updates, $error) = eval { &query_updates($target, 1) };
    $error = "Refresh RPC failed: $@" if $@;
    $error ||= 'Webmin returned no package-update inventory' unless ref($updates) eq 'ARRAY';
    my $file = &inventory_cache_file();
    unlink($file) if $file && -f $file;
    return $error ? {status => 'failed', error => substr($error, 0, 800)} :
        {status => 'completed', remaining => scalar(@$updates)};
}

# Fleet inventory is read from exactly the configured allow-listed hosts.
# Filtering happens after the shared snapshot is loaded, not on each RPC call.
# Return (target states, matching update cells, installed packages, all updates).
sub load_inventory
{
    my ($refresh, $search, $kind, $progress, $only_hosts) = @_;
    $search //= '';
    $search = lc(substr($search, 0, 120));
    $kind //= 'all';
    $kind = 'all' unless $kind =~ /^(?:all|security|standard|high)$/;
    my ($states, $all_cells, $installed) = &raw_inventory($refresh, $progress, $only_hosts);
    my @cells = grep {
        my $c = $_;
        (!length($search) ||
            index(lc($c->{'name'}.' '.$c->{'desc'}), $search) >= 0) &&
        ($kind eq 'all' ||
            ($kind eq 'security' && $c->{'security'}) ||
            ($kind eq 'standard' && !$c->{'security'}) ||
            ($kind eq 'high' && $c->{'priority'} =~ /^(?:high|critical|urgent)$/))
    } @$all_cells;
    my %counts;
    $counts{$_->{'host'}}++ for @cells;
    my @copied_states = map { { %$_, eligible => $counts{$_->{'host'}} || 0 } }
        @$states;
    return (\@copied_states, \@cells, $installed, $all_cells);
}

# Build the matrix from packages with pending matching updates. Installed
# packages without a pending update display the green up-to-date symbol;
# never claim that status for an unreachable or uninstalled package.
sub build_matrix
{
    my ($states, $cells, $installed, $all_cells, $show_current, $search, $kind) = @_;
    my %matrix;
    for my $c (@$cells) {
        my $rowkey = $c->{'system'} . "\0" . $c->{'name'};
        $matrix{$rowkey}{'name'} = $c->{'name'};
        $matrix{$rowkey}{'system'} = $c->{'system'};
        $matrix{$rowkey}{'by_host'}{$c->{'host'}} = $c;
        $matrix{$rowkey}{'security'} ||= $c->{'security'};
        $matrix{$rowkey}{'versions'}{$c->{'new'}} = 1 if length $c->{'new'};
        $matrix{$rowkey}{'priority'} ||= $c->{'priority'};
    }
    # Include installed-only packages when the hide-up-to-date filter is off.
    # Installed records have no security priority, so only include them in
    # "All updates"; other categories continue to mean pending updates.
    if ($show_current && ($kind // 'all') eq 'all') {
        my $needle = lc($search // '');
        for my $p (@$installed) {
            next unless ref($p) eq 'HASH' && length($p->{'name'} // '');
            next if length($needle) && index(lc($p->{'name'}), $needle) < 0;
            my $rowkey = ($p->{'system'} // '') . "\0" . $p->{'name'};
            $matrix{$rowkey}{'name'} //= $p->{'name'};
            $matrix{$rowkey}{'system'} //= $p->{'system'} // '';
            $matrix{$rowkey}{'by_host'} //= {};
            $matrix{$rowkey}{'versions'} //= {};
            $matrix{$rowkey}{'security'} //= 0;
            $matrix{$rowkey}{'priority'} //= '';
        }
    }
    my %pending_any = map {
        join("\0", $_->{'host'}, $_->{'system'}, $_->{'name'}) => 1
    } @$all_cells;
    my %installed_map = map {
        join("\0", $_->{'host'}, $_->{'system'}, $_->{'name'}) =>
            ($_->{'version'} // '')
    } @$installed;
    my @rows = map {
        my $row = $matrix{$_};
        $row->{'versions_list'} = [sort keys %{$row->{'versions'} || {}}];
        for my $st (@$states) {
            my $host = $st->{'host'};
            next if $row->{'by_host'}{$host};
            my $key = join("\0", $host, $row->{'system'}, $row->{'name'});
            if ($st->{'error'}) {
                $row->{'status'}{$host} = 'unavailable';
            }
            elsif ($pending_any{$key}) {
                $row->{'status'}{$host} = 'filtered';
            }
            elsif ($st->{'current_error'}) {
                $row->{'status'}{$host} = 'unknown';
            }
            elsif (exists $installed_map{$key}) {
                $row->{'status'}{$host} = 'current';
                $row->{'installed_version'}{$host} = $installed_map{$key};
            }
            else {
                $row->{'status'}{$host} = 'absent';
            }
        }
        $row;
    } sort {
        lc($matrix{$a}{'name'}) cmp lc($matrix{$b}{'name'}) ||
        $matrix{$a}{'system'} cmp $matrix{$b}{'system'}
    } keys %matrix;
    return \@rows;
}

# Pure helper for consistent pagination and predictable bounds.
sub paginate_rows
{
    my ($rows, $page, $per_page) = @_;
    $per_page = 20 unless defined($per_page) &&
        $per_page =~ /^(?:20|50|100|250)$/;
    $page = 1 unless defined($page) && $page =~ /^\d{1,7}$/ && $page > 0;
    my $total = scalar(@$rows);
    my $pages = $total ? int(($total + $per_page - 1) / $per_page) : 1;
    $page = $pages if $page > $pages;
    my $start = ($page - 1) * $per_page;
    my $end = $start + $per_page - 1;
    $end = $total - 1 if $end >= $total;
    my @slice = $total ? @$rows[$start..$end] : ();
    return (\@slice, $page, $pages, $total, $per_page, $start);
}

# Url-escape only known query parameters used by pager links.
sub cpu_urlencode
{
    my ($value) = @_;
    $value //= '';
    $value =~ s/([^A-Za-z0-9_.~-])/sprintf("%%%02X", ord($1))/eg;
    return $value;
}

1;
