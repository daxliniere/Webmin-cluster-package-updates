#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP ();
our (%config, %in, $module_var_directory);
$module_var_directory = tempdir(CLEANUP => 1);
%config = (include_local=>1,targets=>'');
sub init_config {}
sub foreign_require {}
sub remote_finished {}
sub ReadParse {}
sub ui_print_header {}
sub ui_print_footer {}
sub ui_form_start { return '<form action="'.$_[0].'">' }
sub ui_form_end { return '</form>' }
# Reproduce Authentic Theme: visible proxy button + hidden submit element.
sub ui_submit { return '<button type="button" class="btn btn-default">'.$_[0].'</button><input type="submit" class="hidden">' }
sub html_escape { my $s=shift // ''; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; return $s }
chdir "$Bin/../cluster-package-updates" or die $!;
require './cluster-package-updates-lib.pl';
require './cpu-plan-lib.pl';

my $id = 'a'x32;
my $sim = {ok=>1,actions=>['Inst curl (2)'],changes=>['Inst curl (2)'],removals=>[],errors=>[],digest=>'mock'};
my $preview={id=>$id, version=>'0.1.13', status=>'preview', created=>time(), approved=>JSON::PP::false,
  requested_count=>1,requested_hosts=>1,errors=>[],events=>[],hosts=>[
    {host=>'192.0.2.20',label=>'Test CT',status=>'ready',mode=>'selective',selected=>[{name=>'curl',new=>'2'}],simulation=>$sim}
  ]};
cpu_write_job($preview);
%in=(job=>$id);
my $html='';
{
  open my $f,'>',\$html or die $!;
  local *STDOUT=$f;
  do './review.cgi'; die "review.cgi failed: $@ $!" if $@;
}
like($html,qr/<button type="submit" class="cpu-confirm-button">Confirm updates on selected ready machines<\/button>/,
  'blue confirmation is a real submit control rather than theme proxy');
unlike($html,qr/<button type="button" class="btn btn-default">Confirm updates/,
  'old neutral ui_submit proxy is no longer emitted');

my @cases=(
 ['completed-with-skips','cpu-job-mark--ok', 'Skipped work counts as completed'],
 ['completed','cpu-job-mark--ok','Successful job displays green'],
 ['failed','cpu-job-mark--error','Failed job displays red X'],
 ['finished-with-errors','cpu-job-mark--error','Partial failures display red X'],
 ['unknown','cpu-job-mark--warning','Uncertain job displays orange warning'],
);
for my $case (@cases) {
  my ($state,$klass,$message)=@$case;
  my $job = {%$preview, status=>$state, approved=>JSON::PP::true,
     hosts=>[{host=>'192.0.2.20',label=>'Test CT',status=>'skipped',selected=>[],simulation=>$sim}]};
  cpu_write_job($job);
  my $out='';
  {
    open my $f,'>',\$out or die $!;
    local *STDOUT=$f;
    do './job.cgi'; die "job.cgi failed: $@ $!" if $@;
  }
  like($out,qr/Status: <strong><span class="cpu-check-icon cpu-job-mark $klass"/, $message);
  like($out,qr/<span class="cpu-check-icon cpu-job-mark cpu-job-mark--warning"[^>]*>!<\/span>/,
     'Host skipped state shows orange warning');
  my $toolbar=index($out,'class="cpu-job-toolbar"');
  my $status=index($out,'Status:');
  ok($toolbar>0 && $toolbar<$status,'Blue Refresh Status link is above job status');
  like($out,qr/class="cpu-job-refresh"[^>]*>Refresh Status<\/a>/, 'Top refresh link has dedicated style hook');
  my $back=index($out,'class="cpu-job-back"');
  ok($back>$toolbar && $back<$status,'Back to matrix is immediately after Refresh Status and before status');
  is(() = ($out =~ /Back to package matrix/g),1,'Job page shows one Back to matrix link');
}

done_testing();
