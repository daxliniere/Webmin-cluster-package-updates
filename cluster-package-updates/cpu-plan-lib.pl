# Cluster Package Updates 0.1.13 - persistent preview/approval records.
# All managed CT operations go through authenticated Webmin RPC.
require './cpu-rpc-lib.pl';
use JSON::PP ();

sub cpu_job_dir
{
    my $dir = "$module_var_directory/jobs";
    if (!-d $dir) { mkdir($dir, 0700) or die "Cannot create jobs directory: $!"; }
    chmod(0700, $dir);
    return $dir;
}
sub cpu_new_job_id
{
    open my $random, '<:raw', '/dev/urandom' or die 'No system entropy';
    read($random, my $bits, 16) == 16 or die 'Cannot create secure job ID';
    close($random);
    return unpack('H*', $bits);
}
sub cpu_job_file
{
    my ($id) = @_;
    die 'Invalid job identifier' unless defined($id) && $id =~ /\A[a-f0-9]{32}\z/;
    return &cpu_job_dir()."/$id.json";
}
sub cpu_read_job
{
    my ($id) = @_;
    my $file = &cpu_job_file($id);
    open(my $in, '<', $file) or die "Cannot read job: $!";
    local $/;
    my $data = <$in>;
    close($in);
    my $job = JSON::PP->new->decode($data);
    die 'Invalid stored job' unless ref($job) eq 'HASH' && ($job->{'id'} // '') eq $id;
    return $job;
}
sub cpu_write_job
{
    my ($job) = @_;
    my $file = &cpu_job_file($job->{'id'});
    my $tmp = "$file.$$";
    open(my $out, '>', $tmp) or die "Cannot store job: $!";
    chmod(0600, $tmp);
    print {$out} JSON::PP->new->utf8->canonical->pretty->encode($job);
    close($out) or die "Cannot close job: $!";
    rename($tmp, $file) or die "Cannot publish job: $!";
}

# Return a host-specific blocked entry rather than turning one failed preview
# into a fleet-wide veto. Global errors still block the complete approval.
sub cpu_blocked_host
{
    my ($host, $target, $selected, $reason, $mode) = @_;
    return {
        host => $host, label => $target->{'label'}, selected => $selected,
        status => 'blocked', mode => $mode,
        error => $reason,
        simulation => {ok => 0, errors => [$reason], actions => [],
            changes => [], removals => [], digest => ''},
    };
}

sub cpu_plan_requested
{
    my ($requested, $progress, $existing_id) = @_;
    my $only_hosts;
    if ($existing_id) {
        my $previous = &cpu_read_job($existing_id);
        die 'Preview job is no longer active' unless $previous->{'status'} eq 'reviewing';
        if (ref($previous->{'selected_hosts'}) eq 'ARRAY') {
            $only_hosts = {map { $_ => 1 } @{$previous->{'selected_hosts'}}};
            die 'Preview has no selected machines' unless keys %$only_hosts;
        }
    }
    my ($states, $updates, undef, $all_updates) =
        &load_inventory(1, '', 'all', $progress, $only_hosts);
    my %by_key = map { $_->{'key'} => $_ } @$updates;
    my (%group, @errors);
    for my $key (keys %$requested) {
        my $c = $by_key{$key};
        if (!$c) { push @errors, 'One or more selections are stale; refresh and review again'; last; }
        push @{$group{$c->{'host'}}}, $c;
    }
    push @errors, 'No upgrades selected' unless keys %group;
    # Capture user intent before simulations; errors must never turn the
    # confirmation heading into the misleading "0 packages / 0 machines".
    my $requested_count = scalar(keys %$requested);
    my $requested_hosts = scalar(keys %group);
    my @hosts;
    # Keep the potentially disruptive PVE host last.
    my @selected_hosts = sort { ($a eq 'local') <=> ($b eq 'local') || $a cmp $b } keys %group;
    my $host_index = 0;
    for my $host (@selected_hosts) {
        $progress->('simulation-start', $host, $host_index, scalar(@selected_hosts)) if $progress;
        my $target = &cpu_allowed_target($host);
        if (!$target) {
            # A missing allow-listed target is a global identity/integrity issue.
            push @errors, "Host $host is no longer on the approved list";
            ++$host_index;
            $progress->('simulation-finished', $host, $host_index, scalar(@selected_hosts), 'Host is not approved', 0) if $progress;
            next;
        }
        my $selected = $group{$host};
        my %dedup;
        $selected = [ sort { $a->{'name'} cmp $b->{'name'} }
                     grep { !$dedup{$_->{'name'}}++ } @$selected ];
        my $mode = 'selective';
        if ($host eq 'local') {
            my $all_local = scalar grep { $_->{'host'} eq 'local' } @$all_updates;
            $mode = ($all_local && @$selected == $all_local) ? 'full' : 'selective';
        }
        if (grep { ($_->{'system'} // '') ne 'apt' } @$selected) {
            my $msg = "$target->{'label'} contains non-APT updates, which are not supported for execution in v0.1.15";
            push @hosts, &cpu_blocked_host($host, $target, $selected, $msg, $mode);
            ++$host_index;
            $progress->('simulation-finished', $target->{'label'}, $host_index, scalar(@selected_hosts), $msg, 0) if $progress;
            next;
        }
        my $sim = eval { &cpu_simulate($host, $selected, $mode) };
        if (!$sim) {
            my $msg = "$target->{'label'} simulation failed: $@";
            push @hosts, &cpu_blocked_host($host, $target, $selected, $msg, $mode);
            ++$host_index;
            $progress->('simulation-finished', $target->{'label'}, $host_index, scalar(@selected_hosts), $msg, 0) if $progress;
            next;
        }
        my $ready = $sim->{'ok'} ? 1 : 0;
        my $message = $ready ? '' : "$target->{'label'}: ".join('; ', @{$sim->{'errors'}});
        # Only retain non-secret host identifiers and simulation data.
        my $item = {host => $host, label => $target->{'label'},
            selected => $selected, simulation => $sim,
            mode => $mode, status => $ready ? 'ready' : 'blocked'};
        $item->{'error'} = $message unless $ready;
        if ($host eq 'local' && $ready && $mode eq 'selective') {
            $item->{'pve_selective'} = JSON::PP::true;
            $item->{'critical_packages'} = &cpu_pve_critical_packages($selected, $sim);
        }
        push @hosts, $item;
        ++$host_index;
        $progress->('simulation-finished', $target->{'label'}, $host_index, scalar(@selected_hosts), $message, scalar(@{$sim->{'changes'}})) if $progress;
    }
    my $job = {id => ($existing_id || &cpu_new_job_id()), version => '0.1.13',
        created => time(), status => 'preview', errors => \@errors,
        requested_count => $requested_count,
        requested_hosts => $requested_hosts,
        approved => JSON::PP::false, hosts => \@hosts};
    if ($existing_id) {
        my $previous = &cpu_read_job($existing_id);
        die 'Preview job is no longer active' unless $previous->{'status'} eq 'reviewing';
        $job->{'created'} = $previous->{'created'};
        $job->{'progress'} = $previous->{'progress'};
        $job->{'events'} = $previous->{'events'} || [];
    }
    &cpu_write_job($job);
    &remote_finished();
    return $job;
}

# Centralised server-side approval validation, reused by CGI and tests.
# No checkbox or hand-edited POST value can make a blocked host executable.
sub cpu_validate_approval
{
    my ($job, $requested_hosts, $pve_ack, $critical_ack) = @_;
    die 'Preview is not available for approval' unless
        $job->{'status'} eq 'preview' && ($job->{'version'} // '') eq '0.1.13' &&
        !$job->{'approved'};
    die 'Preview contains global integrity errors' if @{$job->{'errors'} || []};
    die 'No machines selected for installation' unless
        ref($requested_hosts) eq 'ARRAY' && @$requested_hosts;
    my %by_host = map { $_->{'host'} => $_ } @{$job->{'hosts'} || []};
    my %seen;
    my @accepted;
    for my $host (@$requested_hosts) {
        die 'Duplicate selected host' if $seen{$host}++;
        my $item = $by_host{$host};
        die 'Selected machine is not approved for execution' unless
            $item && ($item->{'status'} // '') eq 'ready' &&
            $item->{'simulation'}{'ok'};
        if ($host eq 'local' && ($item->{'mode'} // '') eq 'selective') {
            die 'Selective PVE update requires explicit risk acknowledgement'
                unless $pve_ack;
            die 'Critical PVE update requires separate approval'
                if @{$item->{'critical_packages'} || []} && !$critical_ack;
        }
        push @accepted, $host;
    }
    return \@accepted;
}
1;
