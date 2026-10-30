#!/usr/bin/perl
# Per-machine execution status and audit output; never replays operations.
require './cluster-package-updates-lib.pl';
require './cpu-plan-lib.pl';
# Render fixed-size icons like the existing 18px circular green matrix tick.
# Avoid inline SVG/img elements, which Authentic Theme can scale unexpectedly.
sub cpu_job_status_icon {
    my ($state) = @_;
    $state //= '';
    my ($kind, $glyph, $description);
    if ($state eq 'completed' || $state eq 'completed-with-skips') {
        ($kind, $glyph, $description) = ('ok', '&#10003;', 'Success');
    }
    elsif ($state eq 'failed' || $state eq 'finished-with-errors' ||
           $state eq 'preview-failed') {
        ($kind, $glyph, $description) = ('error', '&#10005;', 'Failure');
    }
    elsif ($state eq 'blocked' || $state eq 'skipped' ||
           $state eq 'unknown' || $state eq 'warning') {
        ($kind, $glyph, $description) = ('warning', '!', 'Warning');
    }
    else { return ''; }
    return '<span class="cpu-check-icon cpu-job-mark cpu-job-mark--'.$kind.
        '" role="img" aria-label="'.$description.'">'.$glyph.'</span> ';
}
&ReadParse();
my $id = $in{'job'} // '';
my $job = eval { &cpu_read_job($id) };
&ui_print_header(undef, 'Cluster update job', '', undef, 1, 1);
print '<link rel="stylesheet" href="matrix.css?v=0.1.15">';
if (!$job) {
    print '<p class="cpu-error">Job not found or invalid.</p>';
    print '<p><a href="index.cgi">Back to package matrix</a></p>';
}
else {
    print '<h2>Job ', &html_escape($id), '</h2>';
    # Place refresh beside the job heading, before the status and host logs.
    print '<p class="cpu-job-toolbar"><a class="cpu-job-refresh" href="job.cgi?job=',
        &html_escape($id), '">Refresh Status</a></p>';
    # Keep navigation with job controls; Webmin's main sidebar stays available.
    print '<p class="cpu-job-back"><a href="index.cgi">Back to package matrix</a></p>';
    print '<p>Status: <strong>', &cpu_job_status_icon($job->{'status'}),
        &html_escape($job->{'status'}), '</strong></p>';
    print '<p class="cpu-error">', &html_escape($job->{'error'}), '</p>' if $job->{'error'};
    if (($job->{'status'} eq 'running' || $job->{'status'} eq 'queued') &&
        ($job->{'pid'} || 0) && !kill(0, $job->{'pid'})) {
        print '<p class="cpu-error">The update worker is no longer running; ',
          'the last status may be incomplete. Check the host before retrying.</p>';
    }
    print '<p>Updates were started only after explicit approval. ',
          'No automatic reboot is issued.</p>';
    for my $h (@{$job->{'hosts'}}) {
        print '<details class="cpu-review-host" open><summary>',
          &html_escape($h->{'label'}), ' - ',
          &cpu_job_status_icon($h->{'status'}),
          &html_escape($h->{'status'} // 'pending'), '</summary>';
        print '<p>', scalar(@{$h->{'selected'}}), ' selected package(s)</p>';
        if ($h->{'cache_refresh'}) {
            print '<p>Post-update Webmin cache refresh: ',
                &html_escape($h->{'cache_refresh'}),
                ($h->{'cache_refresh'} eq 'completed' && defined($h->{'remaining_updates'}) ?
                    ' ('.int($h->{'remaining_updates'}).' updates still listed)' : ''),
                '</p>';
            print '<p class="cpu-error">',
                &html_escape($h->{'cache_refresh_error'}), '</p>'
                if $h->{'cache_refresh_error'};
        }
        print '<p class="cpu-error">', &html_escape($h->{'error'}), '</p>' if $h->{'error'};
        print '<pre class="cpu-plan-output">',
          &html_escape($h->{'output'} // join("\n", @{$h->{'simulation'}{'actions'}})),
          '</pre></details>';
    }
}
&ui_print_footer();
