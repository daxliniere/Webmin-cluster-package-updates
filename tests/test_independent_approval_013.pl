#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP ();
our (%config, $module_var_directory);
$module_var_directory = tempdir(CLEANUP => 1);
%config = (include_local => 1, targets => '192.0.2.10 192.0.2.15');
sub init_config {}
sub foreign_require {}
sub remote_finished {}
chdir "$Bin/../cluster-package-updates" or die $!;
require './cluster-package-updates-lib.pl';
require './cpu-plan-lib.pl';
no warnings 'redefine';
my @targets = (
    {host=>'local', label=>'PVE (this server)'},
    {host=>'192.0.2.10', label=>'Test guest A', remote=>{host=>'192.0.2.10'}},
    {host=>'192.0.2.15', label=>'Test guest C', remote=>{host=>'192.0.2.15'}},
);
*get_targets = sub { @targets };
my %inventory = (
    local => [
        {name=>'openssl',system=>'apt',oldversion=>'1',version=>'2'},
        {name=>'proxmox-ve',system=>'apt',oldversion=>'8',version=>'9'}
    ],
    '192.0.2.10' => [{name=>'curl',system=>'apt',oldversion=>'1',version=>'2'}],
    '192.0.2.15' => [{name=>'git',system=>'apt',oldversion=>'1',version=>'2'}]
);
*query_updates = sub { ($inventory{$_[0]->{host}}, '') };
*query_installed = sub { ([], '') };
my @sim_calls;
my $block200 = 1;
*cpu_simulate = sub {
    my ($host, $selected, $mode) = @_;
    push @sim_calls, [$host, $mode];
    die 'Mock APT lock on Test guest C' if $block200 && $host eq '192.0.2.15';
    my @acts = map { 'Inst '.$_->{name}.' ('.$_->{new}.')' } @$selected;
    return {ok=>1,errors=>[],actions=>\@acts,changes=>\@acts,removals=>[],digest=>'mock'};
};
use warnings 'redefine';
my ($states, $all) = &load_inventory(1, '', 'all');
my %by = map { join('/',$_->{host},$_->{name}) => $_->{key} } @$all;
my %req = map { $_=>1 } @by{'local/openssl','192.0.2.10/curl','192.0.2.15/git'};
my $job = cpu_plan_requested(\%req, undef, undef);
is($job->{requested_count},3,'three selected updates retained');
is($job->{requested_hosts},3,'three requested machines retained');
is(scalar @{$job->{hosts}},3,'all hosts accounted for, including blocked host');
my %h = map { $_->{host} => $_ } @{$job->{hosts}};
is($h{'192.0.2.15'}->{status},'blocked','failed host isolated as blocked');
is($h{'192.0.2.10'}->{status},'ready','unaffected guest ready');
is($h{local}->{status},'ready','PVE partial selection can be ready');
is($h{local}->{mode},'selective','PVE partial selection uses selective mode');
is(scalar @{$job->{errors}},0,'host failures do not populate global blockers');
my $approved = cpu_validate_approval($job,['192.0.2.10'],0,0);
is_deeply($approved,['192.0.2.10'],'approve guest without approving blocked host or PVE');
eval { cpu_validate_approval($job,['192.0.2.15'],1,1) };
like($@,qr/not approved for execution/,'forged blocked-host approval rejected');
eval { cpu_validate_approval($job,['192.0.2.10','192.0.2.10'],1,1) };
like($@,qr/Duplicate/,'duplicate host approval rejected');
eval { cpu_validate_approval($job,['local'],0,1) };
like($@,qr/[Ss]elective PVE/, 'selective PVE requires additional acknowledgement');
my $ok_pve = cpu_validate_approval($job,['local'],1,0);
is_deeply($ok_pve,['local'],'non-core selective PVE approval accepted with acknowledgement');
my $pve_cmd = cpu_commands('local',$h{local}->{selected},0,$h{local}->{mode});
is($pve_cmd->[6],'install','partial PVE uses targeted install not full-upgrade');
like(join(' ',@$pve_cmd),qr/openssl=2/,'partial PVE pins selected version');
unlike(join(' ',@$pve_cmd),qr/proxmox-ve=9/,'unselected PVE package excluded');
my %req_core = map { $_=>1 } @by{'local/proxmox-ve','192.0.2.10/curl'};
my $critical = cpu_plan_requested(\%req_core,undef,undef);
my ($core) = grep { $_->{host} eq 'local' } @{$critical->{hosts}};
is($core->{mode},'selective','critical PVE partial selection remains selective');
ok(grep({$_ eq 'proxmox-ve'} @{$core->{critical_packages}}),'core package risk detected');
eval { cpu_validate_approval($critical,['local'],1,0) };
like($@,qr/Critical PVE/, 'critical PVE requires separate acknowledgement');
is_deeply(cpu_validate_approval($critical,['local'],1,1),['local'],'critical PVE can be specifically approved');
my %req_full = map { $_=>1 } @by{'local/openssl','local/proxmox-ve'};
my $full = cpu_plan_requested(\%req_full,undef,undef);
my ($full_item) = grep { $_->{host} eq 'local' } @{$full->{hosts}};
is($full_item->{mode},'full','all pending PVE updates use full mode');
my $full_cmd = cpu_commands('local',$full_item->{selected},0,$full_item->{mode});
is($full_cmd->[6],'full-upgrade','full PVE uses apt full-upgrade');
is_deeply(cpu_validate_approval($full,['local'],0,0),['local'],'full PVE needs no selective override');
my $tampered = {%$job,errors=>['Inventory stale']};
eval { cpu_validate_approval($tampered,['192.0.2.10'],0,0) };
like($@,qr/global integrity/, 'global integrity errors still block all');
eval { cpu_validate_approval($job,['192.0.2.99'],1,1) };
like($@,qr/not approved for execution/, 'unknown host rejected');

done_testing();
