#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP ();
our (%config, $module_var_directory);
$module_var_directory = tempdir(CLEANUP => 1);
%config = (include_local => 1, targets => '192.0.2.10 192.0.2.11 192.0.2.12 192.0.2.13 192.0.2.14 192.0.2.15');
sub init_config {}
sub foreign_require {}
sub remote_finished {}
chdir "$Bin/../cluster-package-updates" or die $!;
require './cluster-package-updates-lib.pl';
require './cpu-plan-lib.pl';
no warnings 'redefine';
my @targets = ({host=>'local',label=>'PVE (this server)'},
    map { {host=>"192.0.2.$_",label=>"Test host $_",remote=>{host=>"192.0.2.$_"}} } (10,11,12,13,14,15));
*get_targets = sub {return @targets};
my @queried;
*query_updates = sub {
    my ($target, $refresh) = @_;
    push @queried, [$target->{host}, $refresh];
    return ([{name=>'curl',system=>'apt',oldversion=>'1.0',version=>'1.1'}], '');
};
my @installed_queried;
*query_installed = sub { push @installed_queried, $_[0]->{host}; return ([], '') };
*cpu_simulate = sub {return {ok=>1, errors=>[],actions=>['Inst curl [1.0] (1.1 test)'],changes=>['Inst curl [1.0] (1.1 test)'],removals=>[],digest=>'stub'}};
use warnings 'redefine';

my ($allstates, $all, $installed) = &raw_inventory(1, undef);
is(scalar @$allstates, 7, 'matrix inventory includes seven registered targets');
is(scalar @queried,7,'matrix inventories all seven');
is(scalar @installed_queried,7,'full matrix includes installed records');
my %selected = map { $_->{key}=>1 } grep { $_->{host} eq '192.0.2.10' || $_->{host} eq '192.0.2.11' } @$all;
is(scalar(keys %selected),2,'two selections on two machines');
my $only = &cpu_hosts_for_selection(\%selected);
is(scalar(keys %$only), 2, 'server-side cache resolves only two requested hosts');
eval { &cpu_hosts_for_selection({'f'x64 => 1}) };
like($@, qr/no longer in the inventory/, 'fabricated selection key rejected');
@queried=(); @installed_queried=();
my $job={id=>'b'x32, status=>'reviewing', created=>time(), selected_hosts=>[sort keys %$only], events=>[], progress=>{},requested_count=>2};
&cpu_write_job($job);
my @progress;
my $plan = &cpu_plan_requested(\%selected, sub{push @progress,[@_]},$job->{id});
is($plan->{status},'preview','scoped review completes');
is($plan->{requested_count},2,'both selected package count preserved');
is($plan->{requested_hosts},2,'two selected host count preserved');
is(scalar @{$plan->{hosts}},2,'two simulation plans created');
is(scalar @queried,2,'only two hosts queried during preview');
is(scalar @installed_queried,0,'no unused installed inventory queries during preview');
is(scalar @progress,8,'two inventory and two simulation start/finish phases');
for my $p (@progress) { is($p->[3],2,'progress denominator is two selected hosts') }
my ($refreshed_states, $refreshed_updates) = &raw_inventory(0,undef);
is(scalar @$refreshed_states,7,'scoped review does not overwrite complete matrix cache');
@queried=();
my $cache_file=&inventory_cache_file();
ok(-f $cache_file,'matrix cache exists before post-upgrade refresh');
my $result=&cpu_refresh_after_success($targets[1]);
is($result->{status},'completed','post-update Webmin refresh succeeds');
is($result->{remaining},1,'post-update remaining update count captured');
is(scalar @queried,1,'refresh affects only the successfully updated target');
is($queried[0][1],1,'Webmin package list refresh flag enabled');
ok(!-f $cache_file,'master matrix snapshot invalidated after update');
# A cache refresh failure is reported separately, without claiming APT failed.
*query_updates = sub { return ([], 'RPC unavailable') };
my $error_result = &cpu_refresh_after_success($targets[2]);
is($error_result->{status},'failed','cache refresh failures are reported');
like($error_result->{error},qr/RPC unavailable/,'actual cache refresh reason retained');
done_testing();
