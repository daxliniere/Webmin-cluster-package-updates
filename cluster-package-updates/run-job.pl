#!/usr/bin/perl
# Persistent worker: execute only a previously approved, unexpired Webmin job.
# The worker uses the existing Webmin cluster RPC registrations; no pct/SSH.
# PVE is updated locally, last. Full or selective mode is frozen in the approved preview.
# apt-get --no-remove is enforced in both modes.
BEGIN {
    require File::Basename;
    my $dir = File::Basename::dirname(__FILE__);
    chdir($dir) or die "Cannot enter Webmin module directory: $!";
    push(@INC, '..');
}
use WebminCore;
use Fcntl qw(:flock);
use JSON::PP ();
&init_config();
require './cluster-package-updates-lib.pl';
require './cpu-plan-lib.pl';

my $id = shift @ARGV // '';
die 'Invalid worker job id' unless $id =~ /\A[a-f0-9]{32}\z/;
my $lock_path = &cpu_job_dir().'/fleet-execution.lock';
open(my $lock, '>>', $lock_path) or die "Cannot open execution lock: $!";
chmod(0600, $lock_path);
if (!flock($lock, LOCK_EX | LOCK_NB)) {
    my $blocked = &cpu_read_job($id);
    if ($blocked->{'status'} eq 'queued') {
        $blocked->{'status'} = 'blocked';
        $blocked->{'error'} = 'Another cluster update job is already running';
        &cpu_write_job($blocked);
    }
    die 'Another cluster update job is running';
}
my $job = &cpu_read_job($id);
die 'Job is not approved' unless $job->{'approved'} && $job->{'status'} eq 'queued';
die 'Unsupported job version' unless ($job->{'version'} // '') eq '0.1.13';
my %approved = map { $_ => 1 } @{$job->{'approved_hosts'} || []};
die 'No approved machines in this job' unless keys %approved;
die 'Job approval is too old' if time() - $job->{'created'} > 1800;
$job->{'status'} = 'running';
$job->{'started'} = time();
$job->{'pid'} = $$;
&cpu_write_job($job);

my $any_error = 0;
my $any_skipped = 0;
for my $item (@{$job->{'hosts'}}) {
    my $host = $item->{'host'};
    # Never attempt a blocked host or one the operator did not select.
    if (!$approved{$host}) {
        $any_skipped = 1;
        if (($item->{'status'} // '') eq 'ready') {
            $item->{'status'} = 'skipped';
            $item->{'error'} = 'Not selected for this approved execution';
        }
        &cpu_write_job($job);
        next;
    }
    die 'Approved host has no valid ready preview' unless
        ($item->{'status'} // '') eq 'ready' && $item->{'simulation'}{'ok'};
    my $mode = $item->{'mode'} // '';
    die 'Unsupported PVE update mode' if $host eq 'local' &&
        $mode ne 'full' && $mode ne 'selective';
    if ($host eq 'local' && $mode eq 'selective') {
        die 'Missing selective PVE approval' unless $job->{'pve_selective_ack'};
        die 'Missing critical PVE approval' if
            @{$item->{'critical_packages'} || []} && !$job->{'pve_critical_ack'};
    }
    $item->{'status'} = 'checking';
    &cpu_write_job($job);
    my $target = &cpu_rpc_target($host);
    unless ($target) {
        $item->{'status'} = 'failed';
        $item->{'error'} = 'Host is no longer registered or allowed';
        $any_error = 1;
        &cpu_write_job($job);
        next;
    }
    my $recheck = eval {
        # Live inventory must still match exactly the approved package versions.
        my ($latest, $err) = &query_updates($target, 1);
        die "Live update check failed: $err" if $err;
        my @updates = grep { defined($_) }
            map { &normalize_update($target, $_) } @$latest;
        my %current = map { $_->{'key'} => $_ } @updates;
        for my $p (@{$item->{'selected'}}) {
            die "Selected package $p->{'name'} is no longer available at the approved version" 
                unless $current{$p->{'key'}} && $current{$p->{'key'}}{'host'} eq $host;
        }
        if ($host eq 'local' && $mode eq 'full') {
            die 'PVE host pending updates have changed since approval'
                unless @updates == @{$item->{'selected'}};
        }
        &cpu_simulate($host, $item->{'selected'}, $mode);
    };
    if (!$recheck || !$recheck->{'ok'} ||
        $recheck->{'digest'} ne $item->{'simulation'}{'digest'}) {
        $item->{'status'} = 'blocked';
        $item->{'error'} = !$recheck ? "Unable to revalidate approved transaction: $@" :
            !$recheck->{'ok'} ? join('; ', @{$recheck->{'errors'}}) :
            'APT transaction changed since approval';
        $any_error = 1;
        &cpu_write_job($job);
        &remote_finished();
        next;
    }
    $item->{'status'} = 'installing';
    $item->{'execution_started'} = time();
    &cpu_write_job($job);
    my $result = eval { &cpu_run_apt($host, $item->{'selected'}, 0, $mode) };
    if (!$result) {
        $item->{'status'} = 'unknown';
        $item->{'error'} = "Execution connection failed; inspect the host's APT/dpkg logs before retrying: $@";
        $any_error = 1;
    }
    else {
        $item->{'exit'} = $result->{'exit'};
        $item->{'output'} = $result->{'out'};
        $item->{'status'} = $result->{'exit'} == 0 ? 'completed' : 'failed';
        $item->{'error'} = 'APT returned a failure status' if $result->{'exit'};
        $any_error ||= $result->{'exit'} != 0;
        if ($result->{'exit'} == 0) {
            # Match the existing "Refresh Webmin update caches" action, but
            # only on a host whose APT transaction actually succeeded.
            # The refresh is not apt-get update and does not install anything.
            $item->{'cache_refresh'} = 'running';
            &cpu_write_job($job);
            my $refreshed = &cpu_refresh_after_success($target);
            $item->{'cache_refresh'} = $refreshed->{'status'};
            $item->{'cache_refresh_error'} = $refreshed->{'error'}
                if $refreshed->{'error'};
            $item->{'remaining_updates'} = $refreshed->{'remaining'}
                if defined $refreshed->{'remaining'};
        }
    }
    $item->{'execution_finished'} = time();
    &cpu_write_job($job);
    &remote_finished();
}
$job->{'status'} = $any_error ? 'finished-with-errors' :
    $any_skipped ? 'completed-with-skips' : 'completed';
$job->{'finished'} = time();
&cpu_write_job($job);
&remote_finished();
close($lock);
