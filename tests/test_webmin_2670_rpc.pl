#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
our ($sent_module, $sent_code, $did_require, $backquoted, $fake_exit, $throw);
$fake_exit = 0;

# Reproduce Webmin 2.670's rpc.cgi 'eval' action, notably the exact
# 'package $module;' interpolation used by non-fast registered servers.
sub remote_eval {
    my ($server, $module, $code) = @_;
    $sent_module = $module;
    $sent_code = $code;
    my @rv;
    if ($module) {
        @rv = eval "package $module;\n" . $code;
    }
    else {
        @rv = eval $code;
    }
    # In standard RPC, an eval compilation failure is swallowed and
    # serialised as an empty result list, not a regular RPC error.
    return @rv == 1 ? $rv[0] : scalar(@rv) ? \@rv : '';
}
sub remote_foreign_require {
    my ($server,$module,$lib) = @_;
    $did_require++;
    die 'wrong remote module' unless $module eq 'package-updates';
    return 1;
}
sub remote_error_setup { return 1; }
sub backquote_command {
    my ($cmd) = @_;
    $backquoted = $cmd;
    die 'synthetic remote error' if $throw;
    $? = $fake_exit << 8;
    return "Reading package lists...\nInst testpackage [1.0] (1.1 Debian:stable [amd64])\n";
}
require "$Bin/../cluster-package-updates/cpu-rpc-lib.pl";

# Show that the pre-v0.1.8 module-scoped invocation truly fails
# with the exact codepath in Webmin 2.670; not a made-up mock response.
my $sim = cpu_rpc_eval_code('/usr/bin/apt-get -s --no-remove install testpackage=1.1');
my $broken = remote_eval({}, 'package-updates', $sim);
is(ref($broken), '', 'Webmin 2.670 module-scoped eval returns scalar on hyphenated package name');
like($@, qr/(?:Invalid version format|syntax error)/, 'Actual Perl compilation error reproduced');

my $target = {remote=>{host=>'test-guest',fast=>0}};
my $ok = cpu_remote_command($target,'/usr/bin/apt-get -s --no-remove install testpackage=1.1');
is($sent_module,undef,'Corrected remote_eval uses global context, not hyphenated module');
is($did_require,1,'Existing authenticated Webmin RPC module session established');
is(ref($ok),'HASH','Webmin 2.670 RPC result is a structured hash');
is($ok->{exit},0,'Exit code 0 is preserved');
like($ok->{out},qr/Inst testpackage/,'APT simulation output is preserved');
like($backquoted,qr/(?:^|\s)-s(?:\s|$)/,'Simulation flag reaches the backend');

$fake_exit = 100;
my $bad = cpu_remote_command($target,'/usr/bin/apt-get -s --no-remove install testpackage=1.1');
is($bad->{exit},100,'Nonzero APT exit code is preserved for blocking');

$throw = 1;
my $died = eval { cpu_remote_command($target,'/usr/bin/apt-get -s --no-remove install testpackage=1.1'); 1 };
ok(!$died,'Remote execution failure blocks the transaction');
like($@,qr/Remote Webmin evaluation failed: synthetic remote error/,'Remote exception is reported instead of invalid scalar');

$throw = 0;
my $invalid = eval {cpu_rpc_eval_code("anything; rm -rf /");1};
ok(!$invalid,'Unsafe command injection is rejected');

# Assert Webmin's fastrpc.cgi also sees a global context expression.
my $fast=eval $sim;
is(ref($fast),'HASH','Global eval is also valid under fastRPC evaluation');

# Never execute apt during regression tests.
like($backquoted,qr{^/usr/bin/apt-get }, 'Only stub receives the command');
done_testing();
