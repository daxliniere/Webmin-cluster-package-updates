#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use Digest::SHA qw(sha256_hex);
use FindBin qw($Bin);
use JSON::PP ();

our (%config, $module_var_directory);
$module_var_directory = tempdir(CLEANUP => 1);
%config = (include_local => 0, targets => '192.0.2.10');
sub init_config {}
sub foreign_require {}
sub remote_finished {}
chdir "$Bin/../cluster-package-updates" or die $!;
require './cluster-package-updates-lib.pl';
require './cpu-plan-lib.pl';
no warnings 'redefine';
*get_targets = sub { return ({host => '192.0.2.10', label => 'Test guest A', remote => {host=>'192.0.2.10'}}) };
*query_updates = sub {return ([{name=>'curl',system=>'apt',oldversion=>'1.0',version=>'1.1'}], '')};
*query_installed = sub {return ([{name=>'curl',system=>'apt',version=>'1.0'}], '')};
*cpu_simulate = sub {return {ok=>1,errors=>[],actions=>['Inst curl (1.1)'],changes=>['Inst curl (1.1)'],removals=>[],digest=>'mockhash'}};
use warnings 'redefine';

my $record = {id => 'a' x 32, status => 'reviewing', version=> '0.1.9', created => time(),
    requested_keys => [], requested_count=>1, progress => {}, events => []};
my $target = (&get_targets())[0];
my $cell = &normalize_update($target,{name=>'curl',system=>'apt',oldversion=>'1.0',version=>'1.1'});
$record->{requested_keys} = [$cell->{key}];
&cpu_write_job($record);
my @seen;
my $progress = sub { push @seen, [@_]; };
my $plan = cpu_plan_requested({$cell->{key}=>1},$progress,$record->{id});
is($plan->{status},'preview','preview completed');
is($plan->{requested_count},1,'requested package count preserved');
is(scalar @{$plan->{hosts}},1,'one host planned');
is(scalar @seen,4,'inventory and simulation start/finish events emitted');
is($seen[0][0],'inventory-start','first step is inventory');
is($seen[1][0],'inventory-finished','second step is inventory finished');
is($seen[2][0],'simulation-start','third step is simulation');
is($seen[3][0],'simulation-finished','last step is simulation finished');
is(&cpu_read_job($record->{id})->{status},'preview','final job record persisted');
is($seen[-1][2],1,'final simulation count advanced');
done_testing();
