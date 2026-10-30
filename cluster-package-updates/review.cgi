#!/usr/bin/perl
# v0.1.15 - asynchronous read-only inventory/simulation with live status.
# A second, explicit confirmation on the completed preview is required for any installation.
require './cluster-package-updates-lib.pl';
require './cpu-plan-lib.pl';
use POSIX qw(setsid);

&ReadParse();
my $job_id = $in{'job'} // '';
my $plan;
my $error = '';
if ($job_id =~ /\A[a-f0-9]{32}\z/) {
    $plan = eval { &cpu_read_job($job_id) };
    $error = $@ if !$plan;
}
elsif (($ENV{'REQUEST_METHOD'} || '') eq 'POST') {
    my %requested;
    # Compact existing format, plus legacy NUL-separated input handling.
    my $posted = $in{'cells'} // '';
    $posted = join(',', split(/\0/, $in{'cell'} // '')) unless length $posted;
    if (length($posted) > 4_000_000) {
        $error = 'Too many selected package identifiers';
    }
    else {
        for my $key (split(/,/, $posted)) {
            $requested{$key} = 1 if $key =~ /\A[a-f0-9]{64}\z/;
        }
        if (!keys %requested) { $error = 'No updates selected'; }
    }
    if (!$error) {
        my $ok = eval {
            # Resolve selected keys to hosts from the server's own full
            # inventory. The browser cannot add hosts or bypass the allow-list.
            my $selected_hosts = &cpu_hosts_for_selection(\%requested);
            $job_id = &cpu_new_job_id();
            $plan = { id => $job_id, created => time(), version => '0.1.13',
                status => 'reviewing', approved => JSON::PP::false,
                requested_keys => [sort keys %requested],
                selected_hosts => [sort keys %$selected_hosts],
                requested_count => scalar(keys %requested),
                progress => {phase => 'queued', label => 'Starting inventory', done => 0, total => 0, updated => time()},
                events => [] };
            &cpu_write_job($plan);
            my $child = fork();
            die 'Cannot start preview process' unless defined($child);
            if ($child == 0) {
                setsid();
                my $logfile = &cpu_job_dir()."/$job_id.preview.log";
                open(STDIN, '<', '/dev/null');
                open(STDOUT, '>>', $logfile);
                open(STDERR, '>&STDOUT');
                exec($^X, "$module_root_directory/preview-job.pl", $job_id);
                exit(127);
            }
            1;
        };
        if (!$ok) {
            $error = $@ || 'Could not start preview';
            if ($plan && $plan->{'id'}) {
                $plan->{'status'} = 'preview-failed';
                $plan->{'error'} = $error;
                eval { &cpu_write_job($plan) };
            }
        }
    }
}
else { $error = 'Invalid review request'; }

&ui_print_header(undef, 'Review cluster package updates', '', undef, 1, 1);
print '<link rel="stylesheet" href="matrix.css?v=0.1.15">';
print '<h2>Review selected package updates</h2>';
if ($error) {
    print '<p class="cpu-error">Unable to start review: ', &html_escape($error), '</p>';
}
elsif (!$plan) {
    print '<p class="cpu-error">Review job was not found.</p>';
}
elsif ($plan->{'status'} eq 'reviewing') {
    print '<section id="cpu-review-progress" data-job="', &html_escape($job_id), '">',
          '<p><strong>Checking package inventories and simulating APT transactions.</strong> ',
          'No packages are being installed.</p>',
          '<p id="cpu-progress-head">Starting review...</p>',
          '<progress id="cpu-progress-bar" max="1" value="0"></progress>',
          '<p id="cpu-progress-count">Starting</p>',
          '<h3>Review activity</h3>',
          '<ol id="cpu-progress-events" aria-live="polite"><li>Waiting for inventory scan...</li></ol>',
          '<p id="cpu-progress-error" class="cpu-error" hidden></p>',
          '<p><a id="cpu-review-results-link" class="cpu-review-link" ',
          'href="review.cgi?job=', &html_escape($job_id), '" hidden>',
          'Open review results</a> ',
          '<a id="cpu-review-refresh-link" href="review.cgi?job=',
          &html_escape($job_id), '">Refresh manually</a></p>',
          '</section>',
          '<script src="review-progress.js?v=0.1.15" defer></script>';
}
elsif ($plan->{'status'} eq 'preview-failed') {
    print '<p class="cpu-error">Review could not be completed: ',
          &html_escape($plan->{'error'} // 'Unknown error'), '</p>';
}
elsif ($plan->{'status'} eq 'preview') {
    if (@{$plan->{'events'} || []}) {
        print '<details class="cpu-review-host"><summary>Review activity (',
            scalar(@{$plan->{'events'}}), ' events)</summary><ol>';
        for my $event (@{$plan->{'events'}}) {
            print '<li>', &html_escape($event->{'message'} // ''), '</li>';
        }
        print '</ol></details>';
    }
    my $hosts = scalar @{$plan->{'hosts'}};
    my $actions = 0;
    my $ready_count = 0;
    my $blocked_count = 0;
    my $ready_updates = 0;
    for my $h (@{$plan->{'hosts'}}) {
        $actions += scalar @{$h->{'simulation'}{'changes'} || []};
        if (($h->{'status'} // '') eq 'ready') {
            ++$ready_count;
            $ready_updates += scalar @{$h->{'selected'}};
        }
        else { ++$blocked_count; }
    }
    my $wanted = $plan->{'requested_count'} // 0;
    my $wanted_hosts = $plan->{'requested_hosts'} // $hosts;
    print '<h3>Review: ', $ready_count, ' machines ready (', $ready_updates,
        ' selected updates), ', $blocked_count,
        ($blocked_count == 1 ? ' requires' : ' require'), ' attention</h3>';
    print '<p>', $wanted, ' requested package updates across ', $wanted_hosts,
        ' machines. ', $hosts, ' hosts reviewed; ', $actions,
        ' APT upgrade/install actions identified including dependencies. ',
        'No packages have been changed.</p>';
    for my $msg (@{$plan->{'errors'}}) {
        print '<p class="cpu-error">Global approval blocker: ', &html_escape($msg), '</p>';
    }
    my $can_approve = !@{$plan->{'errors'}} && $ready_count > 0;
    if ($can_approve) {
        print '<p><strong>Select which ready machines to update.</strong> ',
            'Blocked hosts will be skipped; you can also uncheck any ready host. ',
            'Only approved machines will be processed.</p>';
        print &ui_form_start('apply.cgi', 'post');
        print '<input type="hidden" name="job" value="', &html_escape($plan->{'id'}), '">';
    }
    for my $h (@{$plan->{'hosts'}}) {
        my $ready = ($h->{'status'} // '') eq 'ready';
        print '<details class="cpu-review-host" open><summary><strong>',
            &html_escape($h->{'label'}), '</strong> - ',
            scalar(@{$h->{'selected'}}), ' selected / ',
            scalar(@{$h->{'simulation'}{'changes'} || []}), ' planned actions ',
            ($ready ? '<span class="cpu-host-ready">Ready</span>' :
                      '<span class="cpu-host-blocked">Blocked (will be skipped)</span>'),
            ($h->{'host'} eq 'local' ?
                ' (PVE '.&html_escape($h->{'mode'} // 'unknown').' mode)' : ''),
            '</summary>';
        if ($ready && $can_approve) {
            print '<label class="cpu-host-approval"><input type="checkbox" name="approve_host" value="',
                &html_escape($h->{'host'}), '" checked> Include ',
                &html_escape($h->{'label'}), ' in this update job</label>';
        }
        print '<p><strong>Selected:</strong> ',
          &html_escape(join(', ', map { $_->{'name'}.' ('.$_->{'new'}.')' }
              @{$h->{'selected'}})), '</p>';
        if ($h->{'host'} eq 'local' && $ready && ($h->{'mode'} // '') eq 'selective') {
            print '<p class="cpu-pve-warning"><strong>Selective Proxmox update:</strong> ',
                'This updates only the selected PVE packages. Proxmox recommends ',
                'full-upgrade for system consistency. APT simulation shows no ',
                'removals or held-package changes, but this does not guarantee ',
                'compatibility with unselected updates.</p>';
            if ($can_approve) {
                print '<label class="cpu-host-approval"><input type="checkbox" name="pve_selective" value="yes"> ',
                    'I understand the additional risks of a selective PVE update.</label>';
            }
            my $risk = $h->{'critical_packages'} || [];
            if (@$risk) {
                print '<p class="cpu-pve-warning"><strong>Critical PVE components affected:</strong> ',
                    &html_escape(join(', ', @$risk)), '</p>';
                if ($can_approve) {
                    print '<label class="cpu-host-approval"><input type="checkbox" name="pve_critical" value="yes"> ',
                        'I have reviewed the critical system packages and explicitly approve them.</label>';
                }
            }
        }
        if ($h->{'error'}) {
            print '<p class="cpu-error">', &html_escape($h->{'error'}), '</p>';
        }
        print '<pre class="cpu-plan-output">',
          &html_escape(join("\n", @{$h->{'simulation'}{'actions'} || []})),
          '</pre>';
        print '</details>';
    }
    if ($can_approve) {
        print '<p>Selected hosts will be processed sequentially, with PVE last. ',
          'Every approved APT transaction will be re-simulated immediately before ',
          'execution. Changed transactions, removals and held-package changes ',
          'block only that host. No reboots are requested. ',
          'Package post-install scripts may restart services.</p>';
        print '<label class="cpu-host-approval"><input type="checkbox" name="confirm" value="yes" required> ',
          'I have reviewed the plans and approve installation on the machines selected above.</label> ';
        # Use an actual submit button: Authentic Theme's ui_submit() renders
        # a neutral type=button proxy and a hidden submit element. Styling the
        # latter does not color the visible button.
        print '<span class="cpu-confirm-action"><button type="submit" ',
          'class="cpu-confirm-button">Confirm updates on selected ready machines',
          '</button></span>';
        print &ui_form_end();
    }
    else {
        print '<p class="cpu-error">No machines can be approved. Resolve the errors above and review again.</p>';
    }
}
else {
    print '<p class="cpu-error">This review has already moved to ',
          &html_escape($plan->{'status'} // 'another state'), '.</p>';
    print '<p><a href="job.cgi?job=', &html_escape($job_id), '">View update job</a></p>';
}
print '<p><a href="index.cgi">Return to package matrix</a></p>';
&remote_finished();
&ui_print_footer();
