#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP ();
our (%config, %in, $module_var_directory);
$module_var_directory = tempdir(CLEANUP => 1);
%config = (include_local => 1, targets => '192.0.2.10 192.0.2.15');
sub init_config {}
sub foreign_require {}
sub remote_finished {}
sub ReadParse {}
sub ui_print_header {}
sub ui_print_footer {}
sub ui_form_start { return '<form action="'.$_[0].'">' }
sub ui_form_end { return '</form>' }
sub ui_submit { return '<button>'.$_[0].'</button>' }
sub html_escape { my $s=shift // ''; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; return $s }
chdir "$Bin/../cluster-package-updates" or die $!;
require './cluster-package-updates-lib.pl';
require './cpu-plan-lib.pl';
my $id = 'f' x 32;
my $sim = {ok=>1,actions=>['Inst curl (2)'],changes=>['Inst curl (2)'],removals=>[],errors=>[],digest=>'mock'};
my $fail_sim = {ok=>0,actions=>[],changes=>[],removals=>[],errors=>['APT lock'],digest=>''};
my $job = {id=>$id, version=>'0.1.13', status=>'preview', created=>time(), approved=>JSON::PP::false,requested_count=>3,requested_hosts=>3,errors=>[],events=>[],hosts=>[
  {host=>'192.0.2.10',label=>'Test guest A',status=>'ready',mode=>'selective',selected=>[{name=>'curl',new=>'2'}],simulation=>$sim},
  {host=>'192.0.2.15',label=>'Test guest C',status=>'blocked',mode=>'selective',error=>'APT lock',selected=>[{name=>'git',new=>'2'}],simulation=>$fail_sim},
  {host=>'local',label=>'PVE',status=>'ready',mode=>'selective',critical_packages=>['pve-manager'],selected=>[{name=>'pve-manager',new=>'9'}],simulation=>$sim},
]};
cpu_write_job($job);
%in = (job=>$id);
my $output='';
{
    open my $stdout, '>', \$output or die $!;
    local *STDOUT = $stdout;
    do './review.cgi'; die "review.cgi $@ $!" if $@;
}
like($output,qr/2 machines ready \(2 selected updates\), 1 requires attention/, 'review summary counts ready and blocked');
like($output,qr/Blocked \(will be skipped\)/, 'blocked host visibly skipped');
my @approvals = $output =~ /name="approve_host"/g;
is(scalar @approvals,2,'only two ready host checkboxes');
like($output,qr/critical system packages and explicitly approve/, 'critical PVE consent displayed');
like($output,qr/risk acknowledgement|additional risks of a selective PVE update/, 'selective PVE consent displayed');
like($output,qr/Confirm updates on selected ready machines/, 'review permits ready host execution');
my $blocked = $output =~ /value="192\.168\.2\.200" checked/ ? 1 : 0;
ok(!$blocked,'blocked host is never preselected for approval');

done_testing();
