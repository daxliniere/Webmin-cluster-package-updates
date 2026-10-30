#!/usr/bin/perl
# Confirm an immutable preview, then start one detached worker.
require './cluster-package-updates-lib.pl';
require './cpu-plan-lib.pl';
use POSIX qw(setsid);
use Fcntl qw(:flock);

&ReadParse();
my $id = $in{'job'} // '';
my $confirmed = ($in{'confirm'} // '') eq 'yes';
# ReadParse represents repeated checkbox fields as NUL-separated values.
my @requested_hosts = grep { length } split(/\0/, ($in{'approve_host'} // ''));
my $pve_ack = ($in{'pve_selective'} // '') eq 'yes';
my $critical_ack = ($in{'pve_critical'} // '') eq 'yes';
&ui_print_header(undef, 'Apply cluster updates', '', undef, 1, 1);
print '<link rel="stylesheet" href="matrix.css?v=0.1.15">';
if (!$confirmed || $id !~ /\A[a-f0-9]{32}\z/) {
    print '<p class="cpu-error">Explicit confirmation and a valid plan are required.</p>';
}
else {
    my $result = eval {
        my $approval_lock = &cpu_job_dir().'/approval.lock';
        open(my $fh, '>>', $approval_lock) or die "Approval lock failed: $!";
        chmod(0600, $approval_lock);
        flock($fh, LOCK_EX) or die 'Cannot lock approval';
        my $job = &cpu_read_job($id);
        die 'Already approved or applied' unless $job->{'status'} eq 'preview' && !$job->{'approved'};
        die 'Review has expired. Please create a new preview.' if time()-$job->{'created'} > 1800;
        # A blocked preview host is not a global error. Only explicit ready
        # hosts may be approved; the UI and submitted checkboxes are untrusted.
        my $approved_hosts = &cpu_validate_approval(
            $job, \@requested_hosts, $pve_ack, $critical_ack);
        $job->{'approved_hosts'} = $approved_hosts;
        $job->{'pve_selective_ack'} = $pve_ack ? JSON::PP::true : JSON::PP::false;
        $job->{'pve_critical_ack'} = $critical_ack ? JSON::PP::true : JSON::PP::false;
        $job->{'approved'} = JSON::PP::true;
        $job->{'status'} = 'queued';
        $job->{'approved_at'} = time();
        &cpu_write_job($job);
        # Child leaves the CGI process so package updates may restart Webmin.
        my $child = fork();
        unless (defined($child)) {
            $job->{'status'} = 'failed';
            $job->{'error'} = 'Could not fork update worker';
            &cpu_write_job($job);
            die 'Cannot start background worker';
        }
        if ($child == 0) {
            setsid();
            my $logfile = &cpu_job_dir()."/$id.worker.log";
            open(STDIN, '<', '/dev/null');
            open(STDOUT, '>>', $logfile);
            open(STDERR, '>&STDOUT');
            exec($^X, "$module_root_directory/run-job.pl", $id);
            exit(127);
        }
        close($fh);
        1;
    };
    my $error = $@;
    if ($result) {
        print '<p>Update worker started. This request will not run twice.</p>',
          '<p><a href="job.cgi?job=', $id, '">View update status and per-host results</a></p>';
    }
    else {
        print '<p class="cpu-error">Cannot approve plan: ', &html_escape($error), '</p>';
    }
}
print '<p><a href="index.cgi">Return to update matrix</a></p>';
&remote_finished();
&ui_print_footer();
