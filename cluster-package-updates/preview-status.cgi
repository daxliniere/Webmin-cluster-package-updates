#!/usr/bin/perl
# v0.1.15 - authenticated Webmin CGI JSON status, no sensitive fields.
require './cluster-package-updates-lib.pl';
require './cpu-plan-lib.pl';
&ReadParse();
my $id = $in{'job'} // '';
print "Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n";
my $status = {status => 'not-found', progress => {}, events => []};
if ($id =~ /\A[a-f0-9]{32}\z/) {
    my $job = eval { &cpu_read_job($id) };
    if ($job) {
        $status = {status => $job->{'status'},
            progress => $job->{'progress'} || {},
            events => $job->{'events'} || [],
            requested_count => $job->{'requested_count'} || 0};
        if ($job->{'status'} eq 'reviewing' && $job->{'pid'} &&
            !kill(0, $job->{'pid'})) {
            $status->{'status'} = 'preview-failed';
            $status->{'message'} = 'Preview worker exited unexpectedly. Check its log.';
        }
        elsif ($job->{'status'} eq 'reviewing' && !$job->{'pid'} &&
               time() - ($job->{'created'} || time()) > 30) {
            $status->{'status'} = 'preview-failed';
            $status->{'message'} = 'Preview worker did not start. Check its log.';
        }
        elsif ($job->{'status'} eq 'preview-failed') {
            $status->{'message'} = 'Preview worker failed. See review page for details.';
        }
    }
}
print JSON::PP->new->utf8->canonical->encode($status);
