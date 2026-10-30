#!/usr/bin/perl
# v0.1.13 - detached, read-only preview worker for observable progress.
# Never runs any real APT installations; only inventory and apt-get -s.
BEGIN {
    require File::Basename;
    my $dir = File::Basename::dirname(__FILE__);
    chdir($dir) or die "Cannot enter Webmin module directory: $!";
    push(@INC, '..');
}
use WebminCore;
use JSON::PP ();
&init_config();
require './cluster-package-updates-lib.pl';
require './cpu-plan-lib.pl';

my $id = shift @ARGV // '';
die 'Invalid preview job identifier' unless $id =~ /\A[a-f0-9]{32}\z/;
my $job = &cpu_read_job($id);
die 'Preview already completed or invalid' unless $job->{'status'} eq 'reviewing';
$job->{'pid'} = $$;
&cpu_write_job($job);

my $report_progress = sub {
    my ($phase, $label, $done, $total, $error, $count) = @_;
    # No credentials or full APT output are ever exposed by the status API.
    $job->{'progress'} = {
        phase => $phase, label => "$label", done => $done,
        total => $total, updated => time()
    };
    my $verb = $phase eq 'inventory-start' ? 'Scanning updates' :
        $phase eq 'inventory-finished' ? 'Inventory completed' :
        $phase eq 'simulation-start' ? 'Simulating selected packages' :
        'Simulation completed';
    push @{$job->{'events'}}, {
        time => time(), phase => $phase, label => "$label",
        message => "$verb: $label" .
            (defined($count) && $phase eq 'inventory-finished' ? " - $count available updates" : '') .
            (defined($count) && $phase eq 'simulation-finished' ? " - $count planned actions" : '') .
            (length($error // '') ? ' (needs attention)' : '')
    };
    shift @{$job->{'events'}} while @{$job->{'events'}} > 80;
    &cpu_write_job($job);
};
my %requested = map { $_ => 1 } @{$job->{'requested_keys'} || []};
my $planned = eval { &cpu_plan_requested(\%requested, $report_progress, $id) };
my $error = $@;
if (!$planned) {
    $job->{'status'} = 'preview-failed';
    $job->{'error'} = substr($error || 'Unexpected preview failure', 0, 2000);
    $job->{'progress'}{'phase'} = 'failed';
    &cpu_write_job($job);
}
&remote_finished();
exit($planned ? 0 : 1);
