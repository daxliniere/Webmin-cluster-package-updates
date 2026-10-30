# Cluster Package Updates 0.1.13 - APT via existing Webmin cluster RPC.
# No SSH, no pct, and no extra agent or module needed on the guest.
# Remote code is executed by Webmin's documented remote_eval() facility.
# Package names and versions are strictly validated before constructing any
# command, and APT receives --no-remove for both simulation and execution.
use Digest::SHA qw(sha256_hex);
use JSON::PP ();

sub cpu_valid_package
{
    my ($p) = @_;
    return defined($p) && length($p) <= 180 &&
        $p =~ /\A[a-zA-Z0-9][a-zA-Z0-9.+:~_-]*\z/;
}
sub cpu_valid_version
{
    my ($v) = @_;
    return defined($v) && length($v) <= 240 &&
        $v =~ /\A[a-zA-Z0-9][a-zA-Z0-9.+:~_-]*\z/;
}
sub cpu_allowed_target
{
    my ($host) = @_;
    my %allowed = map { $_->{'host'} => $_ } &get_targets();
    return undef unless exists $allowed{$host} && !$allowed{$host}{'error'};
    return $allowed{$host};
}
# Use the installed Webmin Servers Index registration and credentials, but
# never copy its password or credential fields into persistent job files.
sub cpu_rpc_target
{
    my ($host) = @_;
    my $t = &cpu_allowed_target($host);
    return undef unless $t;
    return $t;
}

# The host's operation is frozen in the approved preview. A selective PVE
# upgrade must never silently turn into a full-upgrade during execution.
sub cpu_commands
{
    my ($host, $selected, $simulate, $mode) = @_;
    die 'No packages selected' unless ref($selected) eq 'ARRAY' && @$selected;
    my @args = ('/usr/bin/apt-get',
        '-o', 'DPkg::Lock::Timeout=120', '--no-remove',
        $simulate ? '-s' : ('-y', '-q'));
    if ($host eq 'local' && ($mode // 'full') eq 'full') {
        push @args, 'full-upgrade';
    }
    else {
        die 'Invalid host upgrade mode' if $host eq 'local' && ($mode // '') ne 'selective';
        push @args, 'install';
        for my $c (@$selected) {
            die 'Invalid selected package or version' unless
                ref($c) eq 'HASH' && &cpu_valid_package($c->{'name'}) &&
                &cpu_valid_version($c->{'apt_version'} // $c->{'new'});
            push @args, $c->{'name'}.'='.($c->{'apt_version'} // $c->{'new'});
        }
    }
    return \@args;
}

# Only strings using our strict safe argument alphabet are sent remotely.
# No shell operators, redirects, environment assignment or untrusted Perl
# source ever comes from the selected package list.
sub cpu_shell_cmd
{
    my ($args) = @_;
    for my $a (@$args) {
        die 'Invalid command argument' unless defined($a) &&
            $a =~ /\A[a-zA-Z0-9\/_:.+~=-]+\z/;
    }
    return join(' ', @$args);
}

# Build the remote Perl expression separately, so it can be tested
# against Webmin's exact rpc.cgi and fastrpc.cgi evaluation semantics.
# The command is a strictly validated shell-safe APT invocation.
sub cpu_rpc_eval_code
{
    my ($cmd) = @_;
    die 'Invalid command' unless defined($cmd) &&
        $cmd =~ /\A[a-zA-Z0-9\/_:.+~= -]+\z/;
    # Error capture takes place on the remote host, since standard rpc.cgi
    # does not report evaluation exceptions reliably to the caller.
    return "my \$report = eval { " .
        "local \$ENV{'LC_ALL'} = 'C'; " .
        "local \$ENV{'DEBIAN_FRONTEND'} = 'noninteractive'; " .
        "local \$ENV{'APT_LISTCHANGES_FRONTEND'} = 'none'; " .
        "local \$ENV{'NEEDRESTART_MODE'} = 'l'; " .
        "my \$output = &main::backquote_command('$cmd 2>&1 </dev/null'); " .
        "my \$status = \$?; " .
        "{ out => substr(\$output // '', 0, 350000), " .
        "exit => (\$status & 127 ? 128 + (\$status & 127) : \$status >> 8) } " .
        "}; " .
        "\$@ ? { rpc_error => substr(\$@, 0, 3000) } : \$report;";
}

sub cpu_remote_command
{
    my ($t, $cmd) = @_;
    die 'Unknown remote Webmin target' unless $t && $t->{'remote'};
    # Validated by cpu_rpc_eval_code before quotation for remote Perl.
    my $remote_error = '';
    &remote_error_setup(sub { $remote_error = join('', @_); });
    my $result;
    my $ok = eval {
        &remote_foreign_require($t->{'remote'}, 'package-updates', 'package-updates-lib.pl');
        if (!$remote_error) {
            # Standard Webmin 2.670 rpc.cgi inserts an unescaped module
            # directory name into "package MODULE;" for remote_eval().
            # package-updates is a valid Webmin directory but NOT a valid
            # Perl package name. Standard RPC then silently returns an empty
            # eval result (seen as an invalid scalar by the caller).
            # Reuse the authenticated RPC session established above, but
            # evaluate in the global Webmin context (module => undef).
            # Webmin's documented remote_eval API explicitly supports this.
            my $code = &cpu_rpc_eval_code($cmd);
            $result = &remote_eval($t->{'remote'}, undef, $code);
        }
        1;
    };
    my $exception = $@;
    &remote_error_setup(undef);
    die "Webmin RPC failed: $exception" unless $ok;
    die "Webmin RPC error: $remote_error" if $remote_error;
    # A structured error is returned even when standard rpc.cgi suppresses
    # the exception from the remote Perl eval.
    die 'Remote Webmin evaluation failed: '.($result->{'rpc_error'} // '')
        if ref($result) eq 'HASH' && exists $result->{'rpc_error'};
    # Do not print raw RPC data here: APT output may include private paths.
    die 'Invalid RPC command result (expected hash with exit and output; got '.
        (ref($result) || (defined($result) ? 'scalar' : 'undef')).')'
        unless ref($result) eq 'HASH' &&
            defined($result->{'exit'}) && defined($result->{'out'}) &&
            $result->{'exit'} =~ /\A\d+\z/ && !ref($result->{'out'});
    return $result;
}

# For local host execution avoid shell quoting entirely. Webmin's own installed
# CLI runs the package manager with the same arguments. The local worker can
# survive the Webmin process being restarted by package updates.
sub cpu_local_command
{
    my ($args) = @_;
    require POSIX;
    require File::Temp;
    my ($f, $path) = File::Temp::tempfile('cpu-apt-XXXXXXXX', DIR => '/tmp', UNLINK => 0);
    close($f);
    my $pid = fork();
    die "Cannot fork apt: $!" unless defined($pid);
    if (!$pid) {
        open(STDIN, '<', '/dev/null') or POSIX::_exit(126);
        open(STDOUT, '>', $path) or POSIX::_exit(126);
        open(STDERR, '>&STDOUT') or POSIX::_exit(126);
        $ENV{'LC_ALL'} = 'C';
        $ENV{'DEBIAN_FRONTEND'} = 'noninteractive';
        $ENV{'APT_LISTCHANGES_FRONTEND'} = 'none';
        $ENV{'NEEDRESTART_MODE'} = 'l';
        exec {$args->[0]} @$args;
        POSIX::_exit(127);
    }
    waitpid($pid, 0);
    my $status = $?;
    open(my $in, '<', $path) or die "Cannot read apt output: $!";
    local $/;
    my $output = <$in> // '';
    close($in);
    unlink($path);
    return {out => substr($output, 0, 350000),
        exit => ($status & 127 ? 128 + ($status & 127) : $status >> 8)};
}

sub cpu_run_apt
{
    my ($host, $selected, $simulate, $mode) = @_;
    my $t = &cpu_rpc_target($host);
    die 'Host not on Webmin RPC allow-list' unless $t;
    my $args = &cpu_commands($host, $selected, $simulate, $mode);
    return $host eq 'local' ? &cpu_local_command($args) :
        &cpu_remote_command($t, &cpu_shell_cmd($args));
}

sub cpu_sim_actions
{
    my ($output) = @_;
    my (@changes, @removals, @actions);
    for my $l (split(/\r?\n/, $output)) {
        next unless $l =~ /\A(Inst|Remv|Purg|Conf)\s+(\S+)(.*)/;
        next if $1 eq 'Conf';
        my $item = "$1 $2$3";
        push @actions, $item;
        if ($1 eq 'Remv' || $1 eq 'Purg') { push @removals, $item; }
        else { push @changes, $item; }
    }
    return (\@actions, \@changes, \@removals);
}
sub cpu_simulate
{
    my ($host, $selected, $mode) = @_;
    my $res = &cpu_run_apt($host, $selected, 1, $mode);
    my ($actions, $changes, $removals) = &cpu_sim_actions($res->{'out'});
    my @errors;
    push @errors, "APT simulation exited $res->{'exit'}" if $res->{'exit'};
    push @errors, 'APT simulation includes package removals' if @$removals;
    push @errors, 'No package changes shown by APT' unless @$changes;
    push @errors, 'APT reports held-package changes' if
        $res->{'out'} =~ /held packages will be changed/i;
    push @errors, 'APT reports a downgrade' if
        $res->{'out'} =~ /will be DOWNGRADED/i;
    if ($host ne 'local') {
        for my $pkg (@$selected) {
            my $name = quotemeta($pkg->{'name'});
            my $version = quotemeta($pkg->{'apt_version'} // $pkg->{'new'});
            my $matched = grep { /\AInst\s+$name(?:\s|:)/ && /\($version(?:\s|\))/ } @$changes;
            push @errors, "Selected package $pkg->{'name'} was not scheduled at version $pkg->{'new'}"
                unless $matched;
        }
    }
    return {ok => @errors ? 0 : 1, errors => \@errors,
        actions => $actions, changes => $changes, removals => $removals,
        digest => sha256_hex(join("\n", sort @$actions)),
        output => substr($res->{'out'}, 0, 120000)};
}
# Host-side selective updates involving core virtualization or boot components
# are not prohibited, but require an additional, explicit approval checkbox.
sub cpu_pve_critical_packages
{
    my ($selected, $simulation) = @_;
    my %critical;
    my @names = map { $_->{'name'} } @$selected;
    push @names, map { /^Inst\s+([^\s:]+)/ ? $1 : () }
        @{$simulation->{'changes'} || []};
    for my $name (@names) {
        if ($name =~ /\A(?:proxmox-ve|pve-manager|pve-cluster|pve-ha-manager|pve-container|qemu-server|pve-qemu-kvm|pve-kernel-.*|proxmox-kernel-.*|proxmox-default-kernel|proxmox-boot-tool|libpve-.*|pve-.*|zfsutils-linux|zfs-zed|grub-.*|systemd|apt|dpkg|linux-image-.*)\z/i) {
            $critical{$name} = 1;
        }
    }
    return [sort keys %critical];
}
1;
