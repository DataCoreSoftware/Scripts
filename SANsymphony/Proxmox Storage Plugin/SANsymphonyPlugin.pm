package PVE::Storage::Custom::SANsymphonyPlugin;

use strict;
use warnings;
use JSON;
use LWP::UserAgent;
use HTTP::Request;
use PVE::INotify;
use PVE::Tools qw(run_command file_read_firstline trim dir_glob_regex dir_glob_foreach $IPV4RE $IPV6RE);
use PVE::Storage::ISCSIPlugin;
use base qw(PVE::Storage::Plugin);
use MIME::Base64 qw(encode_base64 decode_base64);
use Data::Dumper;
use Time::HiRes qw(gettimeofday tv_interval);
use PVE::SafeSyslog;

# Example: 192.168.122.252:3260,1 iqn.2003-01.org.linux-iscsi.proxmox-nfs.x8664:sn.00567885ba8f
my $ISCSI_TARGET_RE = qr/^((?:$IPV4RE|\[$IPV6RE\]):\d+)\,\S+\s+(\S+)\s*$/;
my $rescan_filename = "/var/run/ssy-iscsi-rescan.lock";
my $vd_id;
my $DEBUG = 0;
my $default_protocol = 'iscsi';
my $pluginVersion = "ProxmoxPlugin_dev";  # stamped to VERSION at .deb build (build-deb.sh)

# One fixed prefix on everything we emit. Proxmox support redirects third-party
# plugin problems to the vendor, so a customer's journal export has to be
# greppable back to us: our lines surface as `pvedaemon[pid]:` or
# `pvestatd[pid]:`, and the PVE 9 System Log panel has no free-text search, so
# this prefix is the only handle an operator has on them.
my $LOG_PREFIX = 'SANsymphonyPlugin';

# Rendered into the message as SANsymphonyPlugin[WARNING]: ... because the
# syslog PRIORITY is a journald FIELD, and journalctl's default output does not
# print it -- so every line looked identical regardless of severity unless the
# reader knew to pass -p or -o json. Spelt the same as the TUI's file sink
# (%(levelname)s), so one support engineer reading both sees one vocabulary.
my %LEVEL_LABEL = (
    debug   => 'DEBUG',
    info    => 'INFO',
    warning => 'WARNING',
    err     => 'ERROR',
);

my $ISCSIADM = '/usr/bin/iscsiadm';
my $found_iscsi_support;
my $NVME_CLI = '/usr/sbin/nvme';
my $found_nvme_support;
my $MULTIPATH_CLI = '/usr/sbin/multipath';

# ---------------------------------------------------------------------------
# Logging
#
# Everything goes through ssy_log so there is exactly one place that knows the
# prefix, the severity label, the escaping rule, and which levels also reach
# the task log. NEVER call openlog() or initlog() from here:
# syslog identity is process-wide, and opening it ourselves would rename
# pvedaemon's own lines. With no openlog of our own, Sys::Syslog rides whatever
# identity the calling daemon already established (pvedaemon/pvestatd both call
# PVE::SafeSyslog::initlog at startup), and falls back to basename($0) under
# `pvesm`/`qm`. Either way we stay a guest in someone else's log stream.
#
# WHY THE PREFIX. Because we are a guest: our lines land in pvedaemon's and
# pvestatd's streams, and the PVE System Log panel has no free-text search, so
# the identifier is the only handle an operator has on them.
#
# The comparison, checked on a PVE 8 node rather than assumed -- an earlier
# review asserted that upstream ISCSIPlugin and LVMPlugin call syslog, and they
# do not:
#
#   * NO upstream storage plugin calls syslog. The single occurrence across
#     /usr/share/perl5/PVE/Storage/*.pm is a COMMENTED-OUT line in BTRFSPlugin.
#   * ZFSPlugin -- not LVMPlugin -- is the one that uses log_warn, one call
#     site, via PVE::RESTEnvironment.
#   * Everything else is bare warn and die: ~70 warns against ~408 dies across
#     the whole plugin set.
#
# So upstream offers no convention to follow and no precedent to point at; the
# third-party plugins that log deliberately (Pure, StorPool) prefix their
# syslog lines, which is the practice this follows. Reported in review, not
# verified here -- neither is installed on this node.
# ---------------------------------------------------------------------------

# Defensive only. Nothing currently handed to ssy_log carries a credential --
# ssy_request deliberately logs method/endpoint/portal/status/ms and never the
# HTTP::Request, which holds the Basic auth header. But `ssy_debug` is now
# switchable at runtime BY A CUSTOMER, which makes the debug path reachable in
# production, and a future call site that passes a config hash or a Dumper of
# one should not be the thing that learns this lesson.
sub ssy_redact {
    my ($text) = @_;
    return $text if !defined($text);
    $text =~ s/((?:ssy)?password\s*(?:=>|[=:])\s*['"]?)[^'"\s,}]+/$1***/gi;
    $text =~ s/(--?[\w-]*password[=\s]+)\S+/$1***/gi;
    $text =~ s/(Authorization\s*:\s*Basic\s+)\S+/$1***/gi;
    return $text;
}

sub ssy_log {
    my ($level, $fmt, @args) = @_;

    my $msg = @args ? sprintf($fmt, @args) : $fmt;
    $msg = ssy_redact($msg);
    $msg =~ s/\s+\z//;

    # "%s" rather than passing $msg as the format: Sys::Syslog::syslog treats
    # its first argument as a printf format, and a vDisk caption or a REST
    # error body containing a literal % would otherwise be mangled (or eat the
    # next argument). %m in particular expands to errno.
    # ${LOG_PREFIX} braced, NOT "$LOG_PREFIX[...]": Perl parses that as a
    # subscript into @LOG_PREFIX and would emit an empty prefix.
    my $tag = "${LOG_PREFIX}[" . ($LEVEL_LABEL{$level} // uc($level)) . "]";

    syslog($level, "%s", "$tag: $msg");

    # ERR and WARNING ALSO go to stderr. PVE's worker captures stderr into the
    # task log and counts warnings into a task's result line, so without this a
    # failed disk operation left the operator staring at a task log that says
    # nothing while the detail sat in the journal they never thought to read.
    #
    # This is the ONLY place that decision is made. Call sites used to write
    # their own `warn` next to an ssy_log call -- two hand-maintained strings
    # per event, which had already drifted apart in wording, and only the
    # syslog half went through ssy_redact.
    #
    # INFO and DEBUG stay syslog-only: they are the per-operation narrative,
    # and pushing them to stderr would put routine lines in every task log.
    #
    # Precedent, not invention: PVE::RESTEnvironment::log_warn does the same
    # pair (syslog plus STDERR, with the same "%s" guard). We do not call it
    # because inside a task it routes to the task ONLY, dropping the syslog
    # line that makes our events greppable across daemons.
    #
    # The trailing \n matters: without it Perl appends "at <file> line N.",
    # pointing inside this sub rather than at the caller.
    warn "$tag: $msg\n" if $level eq 'err' || $level eq 'warning';
}

# Resolve the debug switch. ONE source: the storage.cfg `ssy_debug` option.
#
# There used to be a second switch, a marker file at /etc/ssy-plugin/debug,
# whose job was node-local scope -- storage.cfg lives in /etc/pve, so turning
# tracing on turns it on for every node in the cluster. That was dropped
# deliberately: two switches meant two places to look when tracing was on and
# nobody remembered enabling it, and the file needed an mkdir plus a touch that
# no package step created. Cluster-wide is the accepted cost; `pvesm set <id>
# --ssy_debug 1` is now the whole interface, and it is the one a customer can
# be talked through over the phone and read back with
# `pvesh get /storage/<id>` (there is no `pvesm config`).
#
# Called at each public entry point, where $scfg is in scope. $DEBUG is a
# file-scoped lexical, so it STAYS SET for the life of the worker process --
# that is what covers the helpers which never receive an $scfg
# (ssy_delete_scsi_paths, load_stable_nvme_paths, nvme_tcp_device_list,
# assert_*_support). Every one of them is reached through an entry point that
# has already run this, so they trace with the storage they were called for.
sub ssy_debug_enabled {
    my ($scfg) = @_;

    return $scfg && $scfg->{ssy_debug} ? 1 : 0;
}

sub api {
    my $minver = 3;
    my $maxver = 16;

    my $apiver;
    eval {
        $apiver = PVE::Storage::APIVER();
    };
    if ($@) {
        return $minver;
    }

    my $apiage;
    eval {
        $apiage = PVE::Storage::APIAGE();
    };
    if ($@) {
        if ($apiver >= $minver && $apiver <= $maxver) {
            return $apiver;
        }
        return $minver;
    }

    if ($apiver >= $maxver && $apiver <= $maxver + $apiage) {
        return $maxver;
    }

    if ($apiver <= $maxver) {
        return $apiver;
    }

    return $minver;
}

sub type {
    return 'ssy';
}

sub plugindata {
    return {
        content => [ {images => 1, none => 1}, { images => 1 }],
        'sensitive-properties' => { SSYpassword => 1 },
    };
}

sub properties {
    return {
		SSYipAddress => {
		    description => "comma separated Management IP address of the SANsymphony REST server.",
		    type => 'string',
		},
		portals => {
		    description => "comma separated iSCSI/NVMe portals (IP or DNS name with optional port).",
		    type => 'string',
		},
		targets => {
		    description => "comma separated iSCSI/NVMe targets",
		    type => 'string',
		},
        SSYusername => {
		    description => "SANsymphony user name",
		    type => 'string',
		},
        SSYpassword => {
		    description => "SANsymphony password",
		    type => 'string',
		},
        vdTemplateName => {
		    description => "Name of the VD Template to be used",
		    type => 'string',
		},
        protocol => {
            description => "Set storage protocol ( iscsi | nvme-tcp )",
            type        => 'string',
            default     => $default_protocol,
            enum        => [ $default_protocol, 'nvme-tcp'],
        },
        ssy_debug => {
            description => "Log verbose plugin tracing to syslog. Note that "
                         . "storage.cfg lives in /etc/pve, so this turns "
                         . "tracing on for this storage on EVERY node in the "
                         . "cluster, not just the one you run pvesm on.",
            type        => 'boolean',
            default     => 0,
        },
    };
}

sub options {
    return {
        portals => { fixed => 1 },
        targets => { fixed => 1 },
        SSYusername => { fixed => 1 },
        SSYpassword => { fixed => 1, optional => 1 },
        SSYipAddress => { fixed => 1},
        vdTemplateName => { fixed => 1 },
        nodes => { optional => 1},
        shared => { optional => 1 },
        disable => { optional => 1},
        content => { optional => 1},
        protocol  => { optional => 1 },
        # `ssy_debug`, not `debug`: PVE::Storage::Plugin->init() runs without
        # property_isolation, so SectionConfig merges every plugin's
        # properties() into ONE global propertyList and dies with
        # "duplicate property" on a clash. That die happens at module load, so
        # a second plugin declaring a bare `debug` would break EVERY storage on
        # the node, not just ours. `debug` is an obvious name for another
        # vendor to pick; the prefix costs nothing and removes the collision.
        #
        # optional, not fixed: a customer must be able to turn tracing on with
        # `pvesm set <id> --ssy_debug 1` without recreating the storage.
        ssy_debug => { optional => 1 },
    };
}

sub encode_password {
    my ($password) = @_;
    return encode_base64("$password", '');
}

sub decode_password {
    my ($encoded) = @_;
    my $password = decode_base64($encoded);
    return $password;
}

sub ssy_pass_file_name {
    my ($storeid) = @_;

    return "/etc/pve/priv/storage/${storeid}.pw";
}

sub ssy_set_pass {
    my ($pass, $storeid) = @_;

    my $pwfile = ssy_pass_file_name($storeid);
    mkdir "/etc/pve/priv/storage";

    PVE::Tools::file_set_contents($pwfile, "$pass\n", 0600, 1);
}

sub ssy_delete_pass {
    my ($storeid) = @_;

    my $pwfile = ssy_pass_file_name($storeid);

    unlink $pwfile;
}

sub ssy_get_pass {
    my ($storeid) = @_;

    my $pwfile = ssy_pass_file_name($storeid);

    my $contents = PVE::Tools::file_read_firstline($pwfile);

    return eval { decode('UTF-8', $contents, 1) } // $contents;
}

sub on_add_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;

    if (defined($sensitive{SSYpassword})) {
        my $pass = encode_password($sensitive{SSYpassword});
        ssy_set_pass($pass, $storeid);
    } else {
        ssy_delete_pass($storeid);
    }

    return;
}

sub on_update_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;

    return if !(exists($sensitive{SSYpassword}));

    if (defined($sensitive{SSYpassword})) {
        my $pass = encode_password($sensitive{SSYpassword});
        ssy_set_pass($pass, $storeid);
    } else {
        ssy_delete_pass($storeid);
    }

    return;
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    ssy_delete_pass($storeid);

    return;
}

my sub assert_iscsi_support {
    my ($noerr) = @_;
    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::assert_iscsi_support\n" if $DEBUG;

    return $found_iscsi_support if $found_iscsi_support;

    my $found_iscsi_adm_exe = -x $ISCSIADM;

    if (!$found_iscsi_adm_exe) {
        die "$LOG_PREFIX: no iscsi support - please install open-iscsi\n" if !$noerr;
        ssy_log('warning', "no iscsi support - please install open-iscsi");
    }

    my $found_multipath_exe = -x $MULTIPATH_CLI;

    if (!$found_multipath_exe) {
        die "$LOG_PREFIX: no multipath support - please install multipath-tools\n" if !$noerr;
        ssy_log('warning', "no multipath support - please install multipath-tools");
    }

    $found_iscsi_support = $found_iscsi_adm_exe && $found_multipath_exe;

    return $found_iscsi_support;
}

sub assert_nvme_support {
    my ($noerr) = @_;
    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::assert_nvme_support\n" if $DEBUG;

    return $found_nvme_support if $found_nvme_support;

    $found_nvme_support = -x $NVME_CLI;

    if (!$found_nvme_support) {
        die "$LOG_PREFIX: no nvme support - please install nvme-cli\n" if !$noerr;
        ssy_log('warning', "no nvme support - please install nvme-cli");
    }

    return $found_nvme_support;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    $DEBUG = ssy_debug_enabled($scfg);
    # pvestatd calls this every few seconds, so it stays off the journal unless
    # tracing is explicitly on -- an INFO line here would bury every real
    # operation within minutes.
    ssy_log('debug', "status poll on '%s'", $storeid) if $DEBUG;

    my $active;

    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp')
    {
        return if !assert_nvme_support(1);

        my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});        
        my $target = $ssy_targets[0];
        my $session = nvme_session($cache, $target);
        $active = defined($session) ? 1 : 0;
    }
    else
    {
        return if !assert_iscsi_support(1);

        my @ssy_targets = split(/\s*,\s*/, $scfg->{targets}); 
        foreach my $target (@ssy_targets)
        {
            my $session = iscsi_session($cache, $target);
            $active = defined($session) ? 1 : 0;

            last if $active eq 1;
        }
    }

    return (0, 0, 0, $active ? 1 : 0);
}

sub iscsi_discovery {
    my ($target_in, $portal, $cache, $storeid) = @_;
    my $api_version = api();

    assert_iscsi_support();

    my $res = {};
    
    if ($api_version < 11) {
        if (!PVE::Storage::ISCSIPlugin::iscsi_test_portal($portal)) {
            print "$LOG_PREFIX: Portal $portal is unreachable - Portal test failed on '$storeid' storage.\n";
            ssy_log('warning', "portal %s unreachable on '%s'", $portal, $storeid);
            return undef;
        }
    } else {
        if (!PVE::Storage::ISCSIPlugin::iscsi_test_portal($target_in, $portal, $cache)) {
            print "$LOG_PREFIX: Portal $portal is unreachable - Portal test failed on '$storeid' storage.\n";
            ssy_log('warning', "portal %s unreachable on '%s'", $portal, $storeid);
            return undef;
        }
    } 

    my $cmd = [$ISCSIADM, '--mode', 'discovery', '--type', 'sendtargets', '--portal', $portal];
    eval {
        run_command($cmd, outfunc => sub {
        my $line = shift;

        if ($line =~ $ISCSI_TARGET_RE) {
            my ($portal, $target) = ($1, $2);
            return $res->{$target} = $portal;
        }
        });
    };

    return $res;
}

sub iscsi_login {
    my ($target, $portal, $cache, $storeid) = @_;

    assert_iscsi_support();

    my $res = iscsi_discovery($target, $portal, $cache, $storeid);
    return if !$res;

    my %iscsi_settings = (
        'node.session.initial_login_retry_max' => '0',
        'node.startup' => 'manual',
        'node.leading_login' => 'No',
        'node.session.timeo.replacement_timeout' => '15',
    );

    while (my ($key, $value) = each %iscsi_settings)
    {
        eval {
            my $cmd = [
                $ISCSIADM,
                '--mode', 'node',
                '--targetname', $target,
                '--op', 'update',
                '--name', $key,
                '--value', $value,
            ];
            run_command($cmd);
        };
        if ($@) {
            my $err = $@; $err =~ s/\s+\z//;
            ssy_log('warning', "failed to set iSCSI node setting '%s' to '%s' "
                             . "for target '%s': %s", $key, $value, $target, $err);
        }
    }

    run_command([$ISCSIADM, '--mode', 'node', '--targetname',  $target, '--login']);
}

sub iscsi_logout {
    my ($target) = @_;

    assert_iscsi_support();

    run_command([$ISCSIADM, '--mode', 'node', '--targetname', $target, '--logout']);
}

sub iscsi_session_rescan {
    my ($force_rescan, @session_list) = @_;

    assert_iscsi_support();

    my $rstat = File::stat::stat($rescan_filename);
    if (!$rstat) {
        if (my $fh = IO::File->new($rescan_filename, "a")) {
            utime undef, undef, $fh;
            close($fh);
        }
    } else {
        my $atime = $rstat->atime;
        my $tdiff = time() - $atime;
        # avoid frequent rescans unless the user force it
        return if !($tdiff < 0 || $tdiff > 10) && !$force_rescan;
        utime undef, undef, $rescan_filename;
    }

    foreach my $session (@session_list) {
        my $cmd = [$ISCSIADM, '--mode', 'session', '--sid', $session->{session_id}, '--rescan'];
        eval { run_command($cmd, outfunc => sub {}); };
        if ($@) {
            my $err = $@; $err =~ s/\s+\z//;
            ssy_log('warning', "iSCSI rescan of session %s failed: %s",
                    $session->{session_id}, $err);
        }
    }
}

sub iscsi_session_list {
    assert_iscsi_support();

    my $cmd = [$ISCSIADM, '--mode', 'session'];

    my $res = {};
    eval {
        run_command($cmd, errmsg => 'iscsi session scan failed', outfunc => sub {
            my $line = shift;
            # example: tcp: [1] 192.168.122.252:3260,1 iqn.2003-01.org.linux-iscsi.proxmox-nfs.x8664:sn.00567885ba8f (non-flash)
            if ($line =~ m/^tcp:\s+\[(\S+)\]\s+((?:$IPV4RE|\[$IPV6RE\]):\d+)\,\S+\s+(\S+)\s+\S+?\s*$/) {
                my ($session_id, $portal, $target) = ($1, $2, $3);

                push @{$res->{$target}}, { session_id => $session_id, portal => $portal };
            }
        });
    };
    if (my $err = $@) {
	    die $err if $err !~ m/: No active sessions.$/i;
    }

    return $res;
}

sub iscsi_session {
    my ($cache, $target) = @_;
    $cache->{iscsi_sessions} = iscsi_session_list() if !$cache->{iscsi_sessions};
    return $cache->{iscsi_sessions}->{$target};
}

sub nvme_discovery {
    my ($target_in, $portal, $cache, $storeid) = @_;

    assert_nvme_support();

    if (!nvme_test_portal($target_in, $portal, $cache)) {
        print "$LOG_PREFIX: Portal $portal is unreachable - Portal test failed on '$storeid' storage.\n";
        ssy_log('warning', "portal %s unreachable on '%s'", $portal, $storeid);
        return undef;
    }

    my $res = {};
    my $cmd = [$NVME_CLI, 'discover', '--transport', 'tcp', '--traddr', $portal, '--trsvcid', '8009'];
    my ($target, $address, $port);
    eval {
        run_command($cmd, outfunc => sub {
            my $line = shift;

            if ($line =~ /^\s*subnqn:\s*(\S+)/) {
                $target = $1;
            }

            if ($line =~ /^\s*traddr:\s*(\S+)/) {
                $address = $1;
            }

            if ($line =~ /^\s*trsvcid:\s*(\S+)/) {
                $port = $1;
            }

            if ($target && $address && $port) {
                push @{$res->{$target}}, { port => $port, portal => $address };
                         
                $target = undef;
                $address = undef;
                $port = undef;
            }
        });
    };

    return $res;
}

sub nvme_login {
    my ($target, $portal, $cache, $storeid) = @_;

    assert_nvme_support();

    my $res = nvme_discovery($target, $portal, $cache, $storeid);
    return if !$res;
    
    my ($entry) = grep { $_->{portal} eq $portal } @{$res->{$target}};
    my $port = $entry->{port};

    eval {
        my $cmd = [
            $NVME_CLI,
            'connect',
            '--transport', 'tcp',
            '--nqn', $target,
            '--traddr', $portal,
            '--trsvcid', $port,
            '--ctrl-loss-tmo', '0',
        ];
        run_command($cmd,
        outfunc => sub { });
    };
}

sub nvme_logout {
    my ($target) = @_;

    assert_nvme_support();

    run_command([$NVME_CLI, 'disconnect', '--nqn', $target]);
}


sub nvme_session_list {
    assert_nvme_support();

    my $cmd = [$NVME_CLI, 'list-subsys'];
    my $res = {};
    my $current_nqn;

    eval {
        run_command($cmd, errmsg => 'nvme session scan failed', outfunc => sub {
            my $line = shift;

            # Capture NQN
            if ($line =~ m/NQN=(\S+)/) {
                $current_nqn = $1;
                return;
            }
            # Capture nvme id and IP
            if ($line =~ /^\s*\+\-\s+(nvme\d+)\s+\S+\s+traddr=([^,\s]+)/) {
                my ($nvme_id, $ip) = ($1, $2);
                push @{$res->{$current_nqn}}, { session_id => $nvme_id, portal => $ip };
            }
        });
    };
    if (my $err = $@) {
	    die $err if $err !~ m/: No active sessions.$/i;
    }

    return $res;
}

sub nvme_session {
    my ($cache, $target) = @_;
    $cache->{nvme_sessions} = nvme_session_list() if !$cache->{nvme_sessions};
    return $cache->{nvme_sessions}->{$target};
}

sub nvme_test_session {
    my ($session_id) = @_;

    my $state = file_read_firstline("/sys/class/nvme/$session_id/state");
    return $state && $state =~ /^live/ ? 1 : 0;
}

sub nvme_test_portal {
    my ($target, $portal, $cache) = @_;
    $cache //= {};

    if (defined($target)) {
        # check controller state instead if available
        my $sessions = nvme_session($cache, $target);
        for my $session (@{ $sessions // [] }) {
            next if $session->{portal} ne $portal;
            my $state = nvme_test_session($session->{session_id});
            return $state if $state;
        }
    }
    # check portal via tcp
    my ($server, $port) = PVE::Tools::parse_host_and_port($portal);
    return 0 if !$server;
    return PVE::Network::tcp_ping($server, $port || 8009, 2);
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    $DEBUG = ssy_debug_enabled($scfg);
    # DEBUG, not INFO: pvestatd re-enters this every few seconds per storage
    # (PVE::Storage's $cache->{activated} guard is per call chain, not per
    # process), so an INFO line here would bury every real operation within
    # minutes. The state CHANGES -- an actual iSCSI/NVMe login -- are logged at
    # INFO where they happen, below.
    ssy_log('debug', "activate_storage '%s' (protocol %s, portals %s)",
            $storeid, $scfg->{protocol} || $default_protocol,
            $scfg->{portals} // '-') if $DEBUG;

    #Set default protocol as iscsi if not defined.
    $scfg->{protocol} = 'iscsi' if !defined($scfg->{protocol}) || $scfg->{protocol} eq '';

    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp') {
        activate_nvme_storage($storeid, $scfg, $cache);
    }
    else {
        activate_iscsi_storage($storeid, $scfg, $cache);
    }

    ssy_register_host($scfg, $storeid);
}

sub activate_nvme_storage {
    my ($storeid, $scfg, $cache) = @_;
    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::activate_nvme_storage\n" if $DEBUG;

    return if !assert_nvme_support(1);

    my @ssy_session_list;
    my @ssy_portals = split(/\s*,\s*/, $scfg->{portals});
    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

    if (scalar @ssy_targets > 1) {
        die "$LOG_PREFIX: Only one NVMe target is supported, but multiple targets were configured: '" . $scfg->{targets} . "'.\n";
    }

    for (my $i = 0; $i < scalar @ssy_portals; $i++) {
        my $sessions = nvme_session($cache, $ssy_targets[0]);
        my $do_login = !defined($sessions);

        if (!$do_login) {
            my $session_portals = [ map { $_->{portal} } (@$sessions) ];

            if (!grep { /^$ssy_portals[$i]/ } @$session_portals) {
                $do_login = 1;
            }
        }

        if ($do_login) {
            ssy_log('info', "NVMe login to target %s via portal %s on '%s'",
                    $ssy_targets[0], $ssy_portals[$i], $storeid);
            eval { nvme_login($ssy_targets[0], $ssy_portals[$i], $cache, $storeid); };
            if ($@) {
                my $err = $@; $err =~ s/\s+\z//;
                ssy_log('warning', "NVMe login to target %s via portal %s "
                                 . "failed on '%s': %s -- continuing with the "
                                 . "remaining portals",
                        $ssy_targets[0], $ssy_portals[$i], $storeid, $err);
            }
        } else {
            push @ssy_session_list, @$sessions;
        }
    }
}

sub activate_iscsi_storage {
    my ($storeid, $scfg, $cache) = @_;
    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::activate_iscsi_storage\n" if $DEBUG;
  
    return if !assert_iscsi_support(1);

    my @ssy_session_list;
    my @ssy_portals = split(/\s*,\s*/, $scfg->{portals});
    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

    if (scalar @ssy_portals != scalar @ssy_targets) {
        die "$LOG_PREFIX: Number of portals and targets must be equal";
    }
    
    for (my $i = 0; $i < scalar @ssy_portals; $i++) {
        my $sessions = iscsi_session($cache, $ssy_targets[$i]);
        my $do_login = !defined($sessions);

        if (!$do_login) {
            my $session_portals = [ map { $_->{portal} } (@$sessions) ];

            if (!grep { /^$ssy_portals[$i]:/ } @$session_portals) {
                $do_login = 1;
            }
        }

        if ($do_login) {
            ssy_log('info', "iSCSI login to target %s via portal %s on '%s'",
                    $ssy_targets[$i], $ssy_portals[$i], $storeid);
            eval { iscsi_login($ssy_targets[$i], $ssy_portals[$i], $cache, $storeid); };
            if ($@) {
                my $err = $@; $err =~ s/\s+\z//;
                ssy_log('warning', "iSCSI login to target %s via portal %s "
                                 . "failed on '%s': %s -- continuing with the "
                                 . "remaining portals",
                        $ssy_targets[$i], $ssy_portals[$i], $storeid, $err);
            }
        } else {
            push @ssy_session_list, @$sessions;
        }
    }

    iscsi_session_rescan(0, @ssy_session_list) if scalar @ssy_session_list;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    $DEBUG = ssy_debug_enabled($scfg);
    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::deactivate_storage\n" if $DEBUG;
    
    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp')
    {
        return if !assert_nvme_support(1);

        my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});        
        my $target = $ssy_targets[0];
        if (defined(nvme_session($cache, $target))) {
            nvme_logout($target);
            print "$LOG_PREFIX: logging out from NVMe target: $target\n";
            ssy_log('info', "logging out from NVMe target %s", $target);
        }
    }
    else
    {
        return if !assert_iscsi_support(1);

        my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});
        foreach my $target (@ssy_targets){
            if (defined(iscsi_session($cache, $target))) {
                iscsi_logout($target);
                print "$LOG_PREFIX: logging out from iSCSI target: $target\n";
                ssy_log('info', "logging out from iSCSI target %s", $target);
            }
        }
    }
}

my $check_devices_part_of_target = sub {
    my ($device_paths, $target) = @_;

    my $found = 0;
    for my $path (@$device_paths) {
	if ($path =~ m!^/devices/platform/host\d+/session(\d+)/target\d+:\d:\d!) {
	    my $session_id = $1;

	    my $targetname = file_read_firstline(
		"/sys/class/iscsi_session/session$session_id/targetname",
	    );
	    if ($targetname && ($targetname eq $target)) {
		$found = 1;
		last;
	    }
	}
    }
    return $found;
};

my $udev_query_path = sub {
    my ($dev) = @_;

    # only accept device names (see `man udevadm`)
    ($dev) = $dev =~ m!^(/dev/.+)$!; # untaint
    die "$LOG_PREFIX: invalid device for udevadm path query\n" if !defined($dev);

    my $device_path;
    my $cmd = [
	'udevadm',
	'info',
	'--query=path',
	$dev,
    ];
    eval {
	run_command($cmd, outfunc => sub {
	    $device_path = shift;
	});
    };
    die "$LOG_PREFIX: failed to query device path for '$dev': $@\n" if $@;

    ($device_path) = $device_path =~ m!^(/devices/.+)$!; # untaint
    die "$LOG_PREFIX: invalid resolved device path\n" if !defined($device_path);

    return $device_path;
};

my $resolve_virtual_devices;
$resolve_virtual_devices = sub {
    my ($dev, $visited) = @_;

    $visited = {} if !defined($visited);

    my $resolved = [];
    if ($dev =~ m!^/devices/virtual/block/!) {
	dir_glob_foreach("/sys/$dev/slaves", '([^.].+)', sub {
	    my ($slave) = @_;

	    # don't check devices multiple times
	    return if $visited->{$slave};
	    $visited->{$slave} = 1;

	    my $path;
	    eval { $path = $udev_query_path->("/dev/$slave"); };
	    return if $@;

	    my $nested_resolved = $resolve_virtual_devices->($path, $visited);

	    push @$resolved, @$nested_resolved;
	});
    } else {
	push @$resolved, $dev;
    }

    return $resolved;
};

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    $DEBUG = ssy_debug_enabled($scfg);

    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::activate_volume\n" if $DEBUG;
    
    my $path = $class->filesystem_path($scfg, $volname, $snapname);
    my $real_path = Cwd::realpath($path);
    die "$LOG_PREFIX: failed to get realpath for '$path': $!\n" if !$real_path;
    # in case $path does not exist or is not a symlink, check if the returned
    # $real_path is a block device
    die "$LOG_PREFIX: resolved realpath '$real_path' is not a block device\n" if ! -b $real_path;

    my $device_path = $udev_query_path->($real_path);
    my $resolved_paths = $resolve_virtual_devices->($device_path);

    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp')
    {
        #Do some check for NVMe
    }
    else
    {
        # foreach my $target (@ssy_targets){
        #     my $found = $check_devices_part_of_target->($resolved_paths, $target);
        #     warn "volume '$volname' not part of target '$target'\n" if !$found;
        # }
        foreach my $target (@ssy_targets){
            my $found = $check_devices_part_of_target->($resolved_paths, $target);
            return if $found;
        }
        die "$LOG_PREFIX: volume '$volname' is not part of any configured iSCSI target\n";
    }
    
}

sub wwn_to_nvme_uuid {
    my ($wwn) = @_;
    $wwn =~ s/[^0-9a-fA-F]//g;

    die "$LOG_PREFIX: WWN must be 32 hex chars\n"
        unless length($wwn) == 32;

    my @bytes = map { hex($_) } ($wwn =~ /(..)/g);

    $bytes[6] = ($bytes[6] & 0x0F) | 0x40;
    $bytes[8] = ($bytes[8] & 0x3F) | 0x80;

    return sprintf(
        "nvme-uuid.%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        @bytes
    );
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
    $DEBUG = ssy_debug_enabled($scfg);
    ssy_log('info', "alloc_image: VM %s wants %s KiB on '%s' (protocol %s)",
            $vmid // '-', $size, $storeid,
            $scfg->{protocol} || $default_protocol);
    my $ScsiDeviceIdString;
    my $cache = {};
    my @ssy_session_list;
    my $size_GiB = $size / (1024*1024);
    my $volid;
    my $vd_name;
    my $scsi_id = undef;

    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp')
    {
        assert_nvme_support();
    }
    else
    {
        assert_iscsi_support();
    }

    my ($vdt_id, $vdt_alias, $nvme_enabled) = ssy_get_vdt_info($scfg, $storeid);
    my $vdt_protocol = $nvme_enabled ? "nvme-tcp" : "iscsi";

    if (($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp' && !$nvme_enabled) ||
        ($scfg->{protocol} && $scfg->{protocol} eq 'iscsi' && $nvme_enabled))
    {
        die "$LOG_PREFIX: The specified VD template '$scfg->{vdTemplateName}' has '$vdt_protocol' protocol which does not match the storage class '$storeid' [protocol: '$scfg->{protocol}']. Re-add the storage class with a VD template that uses '$scfg->{protocol}'\n";
    }

    # Resolve the hosts first: failing after the VD exists would leave an orphan on the SAN
    my @host_ids = ssy_get_host_ids($scfg, $storeid);

    ($vd_id, $vd_name, $ScsiDeviceIdString) = ssy_vd_from_vdt($scfg, $storeid, $size_GiB, $vmid, $name);

    my $lun  = ssy_get_lun($scfg, $storeid, $vd_id);

    foreach my $host_id (@host_ids){
        ssy_serve_vd($scfg, $storeid, $host_id, $vd_id, $lun);
    }

    # A VM with 2+ VDs gets one VD group; a group failure must never fail the allocation.
    eval { ssy_ensure_vd_group($class, $scfg, $storeid, $vmid, $vd_id); };
    ssy_log('warning', "Could not group the VDs of VM %s: %s", $vmid, $@) if $@;

    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp')
    {
        my $target = $ssy_targets[0];
        my $session = nvme_session($cache, $target);
        push @ssy_session_list, @$session if defined($session);
    }
    else
    {
        for (my $i = 0; $i < scalar @ssy_targets; $i++) {
            my $sessions = iscsi_session($cache, $ssy_targets[$i]);
            push @ssy_session_list, @$sessions if defined($sessions);
        }
        iscsi_session_rescan(1, @ssy_session_list) if scalar @ssy_session_list;
    }

    if (!scalar @ssy_session_list) {
        ssy_unserve_delete_vd($vd_id, $scfg, $storeid, @host_ids);
        die "$LOG_PREFIX: no active " . (($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp') ? "NVMe" : "iSCSI")
          . " session for storage '$storeid' - check portal connectivity\n";
    }

    my $sleep = 0;
    print "$LOG_PREFIX: Waiting for SANsymphony VD\n";
    scan:

    my $stabledir = "/dev/disk/by-id";

    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp')
    {
        my $nvme_uuid = wwn_to_nvme_uuid($ScsiDeviceIdString);

        print "NVMe disk uuid: $nvme_uuid\n" if $DEBUG;

        if (my $dh = IO::Dir->new($stabledir)) {
            foreach my $entry (sort $dh->read) {
                if(lc($entry) eq lc($nvme_uuid)) {
                    $scsi_id = $entry;

                    # Call nvme_tcp_device_list() and match by uuid to get
                    # real ctrl_num and ns_num
                    my $devices = nvme_tcp_device_list();
                    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

                    FIND_VOLID: foreach my $target (@ssy_targets) {
                        next if !$devices->{$target};
                        foreach my $vol_key (keys %{$devices->{$target}}) {
                            if ($vol_key =~ /\Q$nvme_uuid\E/) {
                                # vol_key is like "0.<ctrl_num>.<ns_num>.nvme-uuid.xxx:<vmid>"
                                # Replace the discovered vmid with the actual vmid
                                ($volid = $vol_key) =~ s/:\d+$/:$vmid/;
                                print "NVMe VolId: $volid\n" if $DEBUG;
                                last FIND_VOLID;
                            }
                        }
                    }

                    # Fallback if nvme_tcp_device_list() hasn't caught up yet
                    $volid //= "0.0.0.$nvme_uuid:$vmid";
                    print "NVMe VolId (fallback): $volid\n" if $DEBUG;
                    last;
                }
            }
            $dh->close;
        }
    }
    else
    {
        # The 3 prefix specifically indicates SCSI-3 compliant storage devices.
        # This is standardized and relates to how the device presents its World Wide Identifier (WWID).
        my $wwid = "3" . lc($ScsiDeviceIdString);

        ($wwid) = $wwid =~ /^([0-9A-Fa-f]+)$/; # untaint

        if (my $dh = IO::Dir->new($stabledir)) {
            foreach my $entry (sort $dh->read) {
                if($entry =~ m/^scsi-$wwid$/i){
                    $scsi_id = $entry;
                    last;
                }
            }
            $dh->close;
        }

        run_command(['multipath', '-ll', $wwid], outfunc => sub {
            my $line = shift;

            if ($line =~ /(\d+):(\d+):(\d+):(\d+)/) {
                my ($host, $channel, $target, $lun) = ($1, $2, $3, $4);
                $volid = "$channel.$target.$lun.$scsi_id:$vmid";
                return;
            }
        });
    }
    
    return $volid if $volid;

    if ($sleep < 30) {
        $sleep += 1;
        sleep(1);
        goto scan;
    }
    
    print "$LOG_PREFIX: unable to allocate the disk - deleting the vDisk that was created\n";
    ssy_log('err', "alloc_image: device for vDisk %s did not appear within "
                 . "%ds - rolling back (unserve + delete)", $vd_id, $sleep);

    ssy_unserve_delete_vd($vd_id, $scfg, $storeid, @host_ids);

    ssy_log('err', "alloc_image failed on '%s' for VM %s", $storeid, $vmid);
    die "$LOG_PREFIX: ERROR on image allocation\n";
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;
    $DEBUG = ssy_debug_enabled($scfg);
    my $vd_id = undef;

    print "Free volume name : $volname\n" if $DEBUG;

    my $mp_wwid;
    my $scsi_id;
    if ($volname =~ /\d+\.\d+\.\d+\.scsi-3(\w+):\d+$/)
    {
        my $wwid = $1;
        $scsi_id = $wwid;    # 32-hex ScsiDeviceIdString, for SCSI path cleanup
        $mp_wwid = "3$wwid"; # multipath map WWID (SCSI-3 prefix), for local cleanup
        $vd_id = ssy_get_vd_id_from_wwid($scfg, $wwid, $storeid);
    }
    elsif ($volname =~ /^\d+\.\d+\.\d+\.(nvme-uuid\.[^:]+):/) # Get the nvme uuid here instead of getting scfg->protocol
    {
        my $nvmeuuid = $1;
        $vd_id = ssy_get_vd_id_from_nvmeuuid($scfg, $nvmeuuid, $storeid);
    }

    # Was `return undef if $vd_id eq 0 || undef;` -- three problems: `eq 0` is a
    # string comparison that warns under `use warnings` when $vd_id is undef
    # (the case it exists to catch), the `|| undef` half is a no-op, and the
    # whole thing returned silently. A delete that quietly does nothing is the
    # worst outcome here: PVE goes on to drop the disk from the VM config while
    # the vDisk stays served on the SAN, so the orphan is only found much later.
    if (!defined($vd_id) || !$vd_id) {
        ssy_log('warning', "free_image('%s') on '%s': no SANsymphony vDisk "
                         . "found for that volume -- nothing unserved or "
                         . "deleted; check for an orphaned vDisk on the SAN",
                $volname, $storeid);
        return undef;
    }

    ssy_log('info', "free_image: unserving and deleting vDisk %s ('%s' on '%s')",
            $vd_id, $volname, $storeid);

    my @host_ids = ssy_get_host_ids($scfg, $storeid);

    # the group lookup must never stop the disk from being freed
    my $group_id;
    eval {
        my ($vd) = grep { lc($_->{Id}) eq lc($vd_id) } @{ ssy_get_vds($scfg, $storeid) };
        $group_id = $vd->{VirtualDiskGroupId} if $vd;
    };
    ssy_log('warning', "Could not read the VD group of VD %s: %s", $vd_id, $@) if $@;

    ssy_unserve_delete_vd($vd_id, $scfg, $storeid, @host_ids);

    print "$LOG_PREFIX: SANsymphony VD with ID $vd_id got unserved and deleted successfully\n";
    ssy_log('info', "vDisk %s unserved and deleted successfully", $vd_id);

    # drop the VM's VD group once its last VD is gone
    if ($group_id) {
        eval {
            # DataCore destroys the snapshots and rollbacks of a VD group when
            # the group is deleted, so keep the group while a snapshot or
            # rollback group under it still has member vDisks. But DataCore
            # removes a deleted VD's own snapshots a few seconds AFTER the
            # delete returns (seen live: ~20 s), so look again before giving
            # up: keeping the group on the first look leaked it for good.
            # The REST list can still show the VD just deleted: leave it out.
            # Empty shells DataCore keeps listed hold nothing, so they do not
            # count. Fail CLOSED: a record without ParentGroupId is treated
            # as possibly ours while it has members.
            my ($left, $kept) = (0, 0);
            for my $try (1 .. 10) {
                my $now = ssy_get_vds($scfg, $storeid);
                $left = grep { lc($_->{Id}) ne lc($vd_id) && lc($_->{VirtualDiskGroupId} // '') eq lc($group_id) } @$now;
                last if $left;
                $kept = 0;
                foreach my $kind ('snapshotgroups', 'rollbackgroups') {
                    my $groups = ssy_request("GET $kind", $scfg, $storeid, 'GET', "1.0/$kind");
                    foreach my $g (@$groups) {
                        # (null / empty counts as missing, not as "someone else's")
                        next if ($g->{ParentGroupId} // '') ne ''
                                && lc($g->{ParentGroupId}) ne lc($group_id);
                        next if !defined($g->{Id});
                        $kept ||= grep { lc($_->{Id}) ne lc($vd_id) && lc($_->{VirtualDiskGroupId} // '') eq lc($g->{Id}) } @$now;
                    }
                }
                last if !$kept;
                sleep 3 if $try < 10;
            }
            ssy_log('info', "Keeping VD group %s: snapshots or rollbacks still depend on it", $group_id) if !$left && $kept;
            ssy_request('DELETE VD Group', $scfg, $storeid, 'DELETE', "1.0/virtualdiskgroups/$group_id") if !$left && !$kept;
        };
        ssy_log('warning', "Could not remove the empty VD group %s: %s", $group_id, $@) if $@;
    }

    eval { run_command(['multipath', '-f', $mp_wwid], outfunc => sub {}, errfunc => sub {}); }
        if defined($mp_wwid);

    ssy_delete_scsi_paths($scsi_id) if defined($scsi_id);

    return undef;
}

sub ssy_delete_scsi_paths {
    my ($scsi_id) = @_;                 # 32-hex ScsiDeviceIdString (no SCSI-3 '3')
    my $want = lc($scsi_id // '');
    $want =~ s/[^0-9a-f]//g;
    return if length($want) < 16;       # guard against empty/garbage input

    dir_glob_foreach('/sys/block', qr/^sd[a-z]+$/, sub {
        my ($dev) = @_;
        my $wwid = lc(file_read_firstline("/sys/block/$dev/device/wwid") // '');
        $wwid =~ s/[^0-9a-f]//g;        # 'naa.60030d90...' -> '60030d90...'
        return if index($wwid, $want) < 0;

        print "Deleting stale SCSI path $dev (WWID $scsi_id)\n" if $DEBUG;
        eval { run_command(["echo 1 > /sys/block/$dev/device/delete"], outfunc => sub {}); };
    });
}

sub ssy_request {
    my ($request, $scfg, $storeid, $method, $endpoint, $body) = @_;

    # Chatty GETs stay off the journal: pvestatd calls status() every few
    # seconds and each of those fans out to host/template/port lookups, so
    # logging them would bury every real operation. The snapshot / rollback
    # group lists are read on every free_image. They are still traced under
    # `debug`.
    my $chatty = ($request eq "GET HOSTs" || $request eq "GET VD Templates"
                  || $request eq "GET PORTS"
                  || $request =~ /^GET (?:snapshot|rollback)groups$/);
    if ($chatty) {
        ssy_log('debug', "REST %s %s (%s)", $method, $endpoint, $request)
            if $DEBUG;
    } else {
        ssy_log('info', "REST %s %s (%s)", $method, $endpoint, $request);
    }

    my @ssy_portals = split(/\s*,\s*/, $scfg->{SSYipAddress});
    my @unreachable;

    foreach my $portal (@ssy_portals) {
        my $url = "https://$portal/RestService/rest.svc/$endpoint";
        my $ua = LWP::UserAgent->new(
            ssl_opts => {
                verify_hostname => 0,
                SSL_verify_mode => 0x00,
            }
        );
        my $req = HTTP::Request->new($method => $url);

        $req->header('Content-Type' => 'application/json');
        $req->header('ServerHost' => $portal);
        $req->header('Source' => $pluginVersion);

        my $encoded_pass = ssy_get_pass($storeid);
        my $password = decode_password($encoded_pass);
        # NEVER log $req itself, or $req->as_string: this line puts the SAN
        # password into it as an Authorization: Basic header.
        $req->authorization_basic( $scfg->{SSYusername}, $password);

        if ($body) {
            $req->content(encode_json($body));
        }

        # A skipped portal used to be invisible, which is exactly the evidence
        # needed to tell "the SAN refused us" from "we never reached the SAN".
        if (!PVE::Network::tcp_ping($portal, 443, 2)) {
            push @unreachable, $portal;
            ssy_log('warning', "REST portal %s unreachable (tcp_ping :443 "
                             . "timed out after 2s), trying the next portal",
                    $portal);
            next;
        }

        my $t0 = [gettimeofday];
        my $res = $ua->request($req);
        my $ms = int(tv_interval($t0) * 1000);

        if ($res->is_success) {
            ssy_log($chatty ? 'debug' : 'info',
                    "REST %s %s -> %s in %dms via %s (%s)",
                    $method, $endpoint, $res->code, $ms, $portal, $request)
                if !$chatty || $DEBUG;

            if (eval { decode_json($res->decoded_content); 1 }){
                return decode_json($res->decoded_content);
            } else {
                return $res;
            }
        } else {
            # Note: this dies on the FIRST portal that answers with an HTTP
            # error rather than trying the next one, so portal failover only
            # covers TCP unreachability. Deliberately left as-is; the log line
            # names the portal so the behaviour is at least visible.
            # info, not err: the die below already puts the failure in the task log
            ssy_log('info', "REST %s %s -> %s in %dms via %s (%s) FAILED",
                    $method, $endpoint, $res->status_line, $ms, $portal,
                    $request);
            die "$LOG_PREFIX: SANsymphony API request $request failed with HTTP Error: " . $res->status_line ." \nHTTP Response: " . $res->decoded_content;
        }
    }

    ssy_log('err', "REST %s %s (%s) failed: no portal reachable of %s",
            $method, $endpoint, $request, join(', ', @ssy_portals));
    die "$LOG_PREFIX: The REST server is not reachable on @ssy_portals \n";
}

sub ssy_get_vds {
    my ($scfg, $storeid) = @_;

    my $vds = ssy_request('GET Virtual Disks', $scfg, $storeid, "GET", "1.0/virtualdisks" );
    return $vds;
}

sub ssy_get_vdt_info {
    my ($scfg, $storeid) = @_;

    my $data = ssy_request('GET VD Templates', $scfg, $storeid, "GET", "/1.0/virtualdisktemplates" );

    foreach my $vdt (@$data){
        if ($vdt->{Caption} eq $scfg->{vdTemplateName}) {
            return ($vdt->{Id}, $vdt->{VirtualDiskAlias}, $vdt->{NVMeEnabled});
        }
    }
    die "$LOG_PREFIX: Did not find the appropriate VD Template details";
}

sub ssy_get_vd_id_from_wwid {
    my ($scfg, $wwid, $storeid) = @_;

    my $vds = ssy_get_vds($scfg, $storeid);

    foreach my $virtualdisk (@$vds){
        if (lc($virtualdisk->{ScsiDeviceIdString}) eq lc($wwid)) {
            return $virtualdisk->{Id};
        }
    }

    return 0;
}

sub ssy_get_vd_id_from_nvmeuuid {
    my ($scfg, $nvmeuuid, $storeid) = @_;

    print "ssy_get_vd_id_from_nvmeuuid($nvmeuuid) called.\n" if $DEBUG;
    
    my $vds = ssy_get_vds($scfg, $storeid);
    foreach my $virtualdisk (@$vds)
    {
        my $vd_nvme_uuid = wwn_to_nvme_uuid($virtualdisk->{ScsiDeviceIdString});
        if (lc($vd_nvme_uuid) eq lc($nvmeuuid)) {
            return $virtualdisk->{Id};
        }
    }

    return 0;
}

sub ssy_register_host {
    my ($scfg, $storeid, $host_name, $initiatorname) = @_;

    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::ssy_register_host\n" if $DEBUG;
    
    run_command(['hostname'], errmsg => 'Getting the host name', outfunc => sub {
        $host_name = shift;
    });

    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp')
    {
        # nvme-cli resolves the NQN exactly as 'nvme connect' will present it
        my $nqn;
        run_command([$NVME_CLI, 'show-hostnqn'],
        errmsg => 'Getting the nvme initiator name',
        outfunc => sub {
            $nqn //= shift;
        });
        $initiatorname = $nqn;
        $initiatorname =~ s/^\s+|\s+$//g if defined $initiatorname;
        die "$LOG_PREFIX: Invalid NVMe host NQN '" . ($initiatorname // '') . "' from 'nvme show-hostnqn'; "
            . "/etc/nvme/hostnqn must contain a single line starting with 'nqn.' (no comments)\n"
            if !defined($initiatorname) || $initiatorname !~ /^nqn\./;
    }
    else
    {
        run_command(['grep', '-oP', 'iqn\..*', '/etc/iscsi/initiatorname.iscsi'], 
        errmsg => 'Getting the iscsi initiator name', 
        outfunc => sub {
            $initiatorname = shift;
        });
    }

    print "Debug :: Initiator Name: $initiatorname\n" if $DEBUG;

    # The initiator (port) identifies this node's DataCore host; the caption is only
    # the name given to a host we create, so a host pre-registered under any name is reused.
    my $initiator_file = ssy_initiator_file(PVE::INotify::nodename(), $scfg);
    my $ports = ssy_get_ports($scfg, $storeid);
    my $host_id = ssy_find_host_id_by_port($scfg, $storeid, $initiatorname, $ports);

    if (!defined $host_id) {
        # Initiator changed (e.g. /etc/nvme/hostnqn): the host owning the previously
        # published one is still this node's host, move the new port onto it.
        # The node's other initiators (iSCSI + NVMe on one node): published by an earlier
        # activation, or still only present locally (registered by an older plugin version).
        my @known;
        foreach my $proto ('iscsi', 'nvme-tcp') {
            push @known, ssy_read_initiator(ssy_initiator_file(PVE::INotify::nodename(), { %$scfg, protocol => $proto }));
        }
        push @known, ssy_local_initiators($scfg);
        foreach my $known (grep { defined $_ && lc($_) ne lc($initiatorname) } @known) {
            $host_id = ssy_find_host_id_by_port($scfg, $storeid, $known, $ports);
            last if defined $host_id;
        }
        ssy_assert_host_not_of_other_node($scfg, $storeid, $host_id, $ports) if defined $host_id;

        # A host pre-created under this node's name with no ports yet is reused too, DataCore
        # rejects a second host with the same name. One that already has ports belongs to
        # another node (e.g. same name in another cluster) and is never given this port.
        if (!defined $host_id) {
            my $hosts = ssy_get_hosts($scfg, $storeid);
            my ($same_name) = grep { ($_->{Caption} // '') eq $host_name } @$hosts;
            if ($same_name) {
                my @owned = grep { lc($_->{HostId} // '') eq lc $same_name->{Id} } @$ports;
                die "$LOG_PREFIX: DataCore host '$host_name' already exists and has other ports assigned "
                    . "(" . join(', ', map { $_->{PortName} } @owned) . "); assign port '$initiatorname' "
                    . "to the right host in DataCore, then activate the storage again\n" if @owned;
                $host_id = $same_name->{Id};
            }
        }

        if (!defined $host_id) {
            $host_id = eval { ssy_add_host($scfg, $storeid, $host_name) };
            die "$LOG_PREFIX: Could not add host '$host_name' to DataCore: $@"
                . "If a host for this node already exists, assign port '$initiatorname' to it in DataCore\n"
                if $@;
        }
        ssy_assign_port_to_host($scfg, $storeid, $initiatorname, $host_id);
    } else {
        # found through this node's own initiator: a cloned image shares it with another node
        ssy_assert_host_not_of_other_node($scfg, $storeid, $host_id, $ports);
    }

    # Published last, so other nodes only ever see an initiator that is registered
    (my $node_dir = $initiator_file) =~ s{/[^/]+$}{};
    die "$LOG_PREFIX: Cannot publish initiator, $node_dir does not exist (is this node's name '"
        . PVE::INotify::nodename() . "' a member of the cluster?)\n" if !-d $node_dir;
    my $published = ssy_read_initiator($initiator_file);
    return if defined $published && $published eq $initiatorname;    # avoid a pmxcfs write per activation
    eval {
        open(my $fh, '>', $initiator_file) or die "$!\n";
        print $fh "$initiatorname\n";
        close($fh) or die "$!\n";
    };
    die "$LOG_PREFIX: Cannot publish initiator to $initiator_file, check cluster quorum: $@" if $@;
}

# Cluster-visible (pmxcfs) file holding a node's initiator name for the storage protocol
sub ssy_initiator_file {
    my ($node, $scfg) = @_;
    return "/etc/pve/nodes/$node/ssy-initiator-" . ($scfg->{protocol} || 'iscsi');
}

sub ssy_read_initiator {
    my ($file) = @_;
    open(my $fh, '<', $file) or return undef;
    my $line = <$fh>;
    close($fh);
    return undef if !defined $line;
    $line =~ s/^\s+|\s+$//g;
    return $line eq '' ? undef : $line;
}

# A host found through this node's other initiator must not already be another node's host
# (two nodes cloned from one image share an initiator name).
sub ssy_assert_host_not_of_other_node {
    my ($scfg, $storeid, $host_id, $ports) = @_;
    my $me = PVE::INotify::nodename();
    # advisory check: an unreadable members list must not stop this node activating
    my @others = eval { grep { $_ ne $me } ssy_cluster_nodes() };
    if ($@) {
        ssy_log('warning', "clone check skipped: $@");
        return;
    }
    foreach my $node (@others) {
        foreach my $proto ('iscsi', 'nvme-tcp') {
            my $ini = ssy_read_initiator(ssy_initiator_file($node, { %$scfg, protocol => $proto }));
            my $owner = eval { ssy_find_host_id_by_port($scfg, $storeid, $ini, $ports) };
            if ($@) {    # that node's own problem, not a reason to stop this node
                ssy_log('warning', "clone check skipped for node '$node': $@");
                next;
            }
            die "$LOG_PREFIX: DataCore host $host_id already belongs to node '$node' (initiator '$ini'), "
                . "so this node's initiator names are duplicates of that node's (cloned image?); "
                . "give each node its own /etc/nvme/hostnqn and /etc/iscsi/initiatorname.iscsi\n"
                if defined $owner && lc($owner) eq lc($host_id);
        }
    }
}

our $NVME_HOSTNQN_FILE = '/etc/nvme/hostnqn';    # overridable for tests
our $ISCSI_INITIATORNAME_FILE = '/etc/iscsi/initiatorname.iscsi';

# Initiators of the protocol this storage does NOT use, as configured on this node
sub ssy_local_initiators {
    my ($scfg) = @_;
    my @found;
    if (($scfg->{protocol} // '') eq 'nvme-tcp') {
        if (open(my $fh, '<', $ISCSI_INITIATORNAME_FILE)) {
            while (my $l = <$fh>) { push @found, $1 if $l =~ /^InitiatorName=\s*(iqn\.\S+)/; }
            close($fh);
        }
    } else {
        # the stored hostnqn only: 'nvme show-hostnqn' may print a value generated on the fly
        if (open(my $fh, '<', $NVME_HOSTNQN_FILE)) {
            while (my $l = <$fh>) { push @found, $1 if $l =~ /^\s*(nqn\.\S+)\s*$/; }
            close($fh);
        }
    }
    return @found;
}

sub ssy_get_ports {
    my ($scfg, $storeid) = @_;
    my $ports = ssy_request('GET PORTS', $scfg, $storeid, 'GET', "1.0/ports?supportsNVMeTcpPorts=true");
    die "$LOG_PREFIX: Unexpected response listing DataCore ports\n" if ref($ports) ne 'ARRAY';
    return $ports;
}

# DataCore host Id that owns the given initiator port, undef if none. $ports may be
# passed to avoid refetching.
sub ssy_find_host_id_by_port {
    my ($scfg, $storeid, $initiator, $ports) = @_;
    return undef if !defined $initiator || $initiator eq '';

    $ports //= ssy_get_ports($scfg, $storeid);

    my %owners;
    foreach my $port (@$ports) {
        next if !defined($port->{PortName}) || !defined($port->{HostId}) || $port->{HostId} eq '';
        $owners{lc $port->{HostId}} = $port->{HostId} if lc($port->{PortName}) eq lc($initiator);
    }

    my @ids = values %owners;
    die "$LOG_PREFIX: Initiator '$initiator' is assigned to several DataCore hosts (" . join(', ', sort @ids)
        . "); keep it on one host\n" if @ids > 1;
    return $ids[0];
}

sub ssy_add_host {
    my ($scfg, $storeid, $host_name) = @_;
    
    my $data = ssy_request('ADD HOST', $scfg, $storeid, 'POST', '1.0/hosts', {
        Name => $host_name,
        Description => "This host is beeing added by proxmox storage plugin",
        OperatingSystem => 7,
        MPIO => 'true',
        Alua => 'true' 
        # PreferredServer => "Array of preferred server IDs, the default is auto-select" (optional),
    });

    return $data->{Id};
}

sub ssy_assign_port_to_host {
    my ($scfg, $storeid, $port, $host_id) = @_;
    
    ssy_request('ASSIGN PORT', $scfg, $storeid, 'POST', "1.0/hosts/$host_id", {
        Operation => "AssignPort",
        Port => $port
    });
}

sub ssy_get_hosts {
    my ($scfg, $storeid) = @_;

    my $ssy_hosts = ssy_request('GET HOSTs', $scfg, $storeid, "GET", "1.0/hosts" );

    return $ssy_hosts;
}

# Current cluster members. /etc/pve/nodes also keeps the directory of a node removed with
# 'pvecm delnode', which has no initiator file and would block every create/delete.
our $MEMBERS_FILE = '/etc/pve/.members';

sub ssy_cluster_nodes {
    my $file = $MEMBERS_FILE;
    # Without the members list a clustered node would silently shrink to itself, leaving the other
    # nodes' mappings in place on delete: fail instead (pmxcfs not mounted / quorum lost).
    die "$LOG_PREFIX: Cannot list the cluster nodes, $file is missing (is /etc/pve mounted?)\n" if !-e $file;
    my $members = eval { decode_json(PVE::Tools::file_get_contents($file)) };
    die "$LOG_PREFIX: Cannot read the cluster members from $file: " . ($@ || "unexpected content\n")
        if ref($members) ne 'HASH';
    my $list = $members->{nodelist};
    return (PVE::INotify::nodename()) if !defined $list;    # standalone node: no nodelist
    die "$LOG_PREFIX: Unexpected nodelist in $file\n" if ref($list) ne 'HASH';
    my @nodes = sort keys %$list;
    return @nodes if @nodes;
    return (PVE::INotify::nodename());
}

sub ssy_get_host_ids {
    my ($scfg, $storeid) = @_;
    my @pve_hosts;
    my @hosts;
    my %node_of;

    if ($scfg->{nodes}){
	    my $nodes = PVE::Storage::Plugin->encode_value($scfg->{type}, 'nodes', $scfg->{nodes});
        @pve_hosts = split(/\s*,\s*/, $nodes);
    } else {
        @pve_hosts = ssy_cluster_nodes();
    }

    my $ports = ssy_get_ports($scfg, $storeid);

    foreach my $pve (@pve_hosts) {
        my $initiator = ssy_read_initiator(ssy_initiator_file($pve, $scfg));
        my $host_id = ssy_find_host_id_by_port($scfg, $storeid, $initiator, $ports);
        die "$LOG_PREFIX: No registered DataCore host found for node '$pve'; activate the storage on that node\n"
            if !defined $host_id;

        ssy_log('warning', "nodes '$node_of{lc $host_id}' and '$pve' resolve to the same DataCore host $host_id")
            if $node_of{lc $host_id};
        next if $node_of{lc $host_id};
        $node_of{lc $host_id} = $pve;
        push @hosts, $host_id;
    }

    return @hosts;
}

sub ssy_get_vmid {
    my ($scsi_id) = @_;
    my $scsi_value;
    # Directory containing VM .conf files
    my $dir = '/etc/pve/qemu-server/';

    opendir(my $dh, $dir) or die "$LOG_PREFIX: Cannot open directory $dir: $!\n";
    my @files = grep { /\.conf$/ && -f "$dir/$_" } readdir($dh);
    closedir($dh);

    foreach my $file (@files) {
        my $config_file = "$dir$file";
        
        open(my $fh, '<', $config_file) or die "$LOG_PREFIX: Could not open file '$config_file': $!\n";

        while (my $line = <$fh>) {
            chomp $line;
            if ($line =~ /^scsi\d+:\s*(.+)$/g) {
                $scsi_value = $1;

                if (index($1, $scsi_id) != -1) {
                    if ($file =~ /^(\d+)\.conf$/) {
                        close($fh);
                        return $1;
                    }
                }
            }
        }
    }
    return 0;
}

sub ssy_vd_from_vdt {
    my ($scfg, $storeid, $size_GiB, $vmid, $name) = @_;

    my ($vdt_id, $vdt_alias, $nvme_enabled) = ssy_get_vdt_info($scfg, $storeid);

    my $vd_name;
    if ($name) {
        $vd_name = "$name-$vdt_alias";
    } else {
        $vd_name = "$vmid-$vdt_alias";
    }
    if ($size_GiB < 1) {
        $size_GiB = 1; # enforce minimum size of 1 GB
    }

    my $vd = ssy_request('CREATE VD from VD Template', $scfg, $storeid, 'POST', '1.0/virtualdisks', {
        VirtualDiskTemplate => $vdt_id,
        Name => $vd_name,
        Description => ssy_vm_tag($vmid),
        Size => "$size_GiB GB",
        Count => 1,
    });

    if (ref($vd) eq 'ARRAY') {
        my $vd_id = $vd->[0]{Id}; # getting the first element in the array is the new VD as we are creating only one VD
	    my $ScsiDeviceIdString = $vd->[0]{ScsiDeviceIdString};

        # Wait until the VD reaches a healthy status before returning
        my $max_wait = 60; # seconds
        my $waited = 0;
        while (1)
        {
            my $vds = ssy_get_vds($scfg, $storeid);
            my ($vd) = grep { lc($_->{Id}) eq lc($vd_id) } @$vds;
            if (!$vd)
            {
                die "$LOG_PREFIX: VD '$vd_name' not found in virtual disk list after creation\n";
            }

            my $health = $vd->{DiskStatus} // '';
            print "Waiting for VD '$vd_name' to become healthy... DiskStatus=$health\n" if $DEBUG;
            last if $health eq '0';

            if ($waited >= $max_wait)
            {
                die "$LOG_PREFIX: VD '$vd_name' did not become healthy within ${max_wait}s (DiskStatus=$health)\n";
            }

            sleep(1);
            $waited++;
        }

        print "VD '$vd_name' is healthy after ${waited}s\n" if $DEBUG;
        # This line used to sit after the if/else below, i.e. after a return in
        # one branch and a die in the other -- it was never reached, so a
        # successful create announced itself nowhere. Moved to where it fires.
        print "$LOG_PREFIX: SANsymphony VD got created successfully with Virtual Disk ID = $vd_id\n";
        ssy_log('info', "created vDisk %s ('%s', ScsiDeviceIdString %s) healthy after %ds",
                $vd_id, $vd_name, $ScsiDeviceIdString // '-', $waited);
        return ($vd_id, $vd_name, $ScsiDeviceIdString);
    } else {
        ssy_log('err', "create vDisk: unexpected response format from the "
                     . "SANsymphony API");
        die "$LOG_PREFIX: Unexpected response format from SANsymphony API\n";
    }
}

sub ssy_serve_vd {
    my ($scfg, $storeid, $host_id, $vd_id, $lun) = @_;

    ssy_request('SERVE VD', $scfg, $storeid, 'POST', "1.0/virtualdisks/$vd_id", {
        Operation => 'Serve',
        Host => $host_id,
        Redundancy => 'true',
        StartingLUN => $lun
    });
    print "$LOG_PREFIX: SANsymphony VD {$vd_id} got served to host {$host_id} successfully\n";
    ssy_log('info', "served vDisk %s to host %s at LUN %s", $vd_id, $host_id, $lun);

}

sub ssy_get_lun {
    my ($scfg, $storeid, $vd_id) = @_;
    
    my $data = ssy_request('GET Virtual Logical Units', $scfg, $storeid, 'GET', "1.0/virtuallogicalunits");

    my @used_luns = ();
    foreach my $entry (@$data) {
        if ($entry->{Type} eq '1'){ # Type 1 is for Type 'Client', we are ignoring Type Mirror here
            push @used_luns, $entry->{Lun}{Quad};
        }
    }

    my $lun = 0;
    while ($lun < 255) { # LUNs are limited to 0-254
        if (!grep { $_ == $lun } @used_luns) {
            last;
        }
        $lun++;
    }

    if ($lun >= 255) {
        # Deleting the VD as there are no free LUNs available
        $data = ssy_request('DELETE VD', $scfg, $storeid, 'DELETE', "1.0/virtualdisks/$vd_id");

        die "$LOG_PREFIX: No free LUNs available for serving the new VD";
    }

    return $lun;
}

sub ssy_unserve_delete_vd {
    my ($vd_id, $scfg, $storeid, @host_ids) = @_;

    my $data;
    foreach my $host_id (@host_ids){
        ssy_log('info', "unserving vDisk %s from host %s", $vd_id, $host_id);
        $data = ssy_request('UNSERVE VD', $scfg, $storeid, 'POST', "1.0/virtualdisks/$vd_id", {
            Operation => 'Unserve',
            Host => $host_id,
        });
    }

    ssy_log('info', "deleting vDisk %s on '%s'", $vd_id, $storeid);
    $data = ssy_request('DELETE VD', $scfg, $storeid, 'DELETE', "1.0/virtualdisks/$vd_id");
}

sub ssy_vm_tag { return sprintf("[Proxmox VM %s]", $_[0]); }

# Keep all VDs of a VM (2+) in one VD group named after the VM id.
# VDs are matched by SCSI id, groups by VirtualDiskGroupId - never by caption.
sub ssy_ensure_vd_group {
    my ($class, $scfg, $storeid, $vmid, $new_vd_id) = @_;

    # VDs are tagged with their owner at creation (ssy_vd_from_vdt): during a multi-disk
    # create PVE allocates every disk before it writes the VM config, so list_images
    # cannot see the earlier disks yet.
    my $owner_tag = ssy_vm_tag($vmid);

    my $vds = ssy_get_vds($scfg, $storeid);

    my %ids;    # lc(wwid or nvme-uuid) of the VM's existing disks
    foreach my $img (@{ $class->list_images($storeid, $scfg, $vmid) }) {
        $ids{lc($1)} = 1 if $img->{volid} =~ /\d+\.\d+\.\d+\.scsi-3(\w+):\d+$/
                         || $img->{volid} =~ /\d+\.\d+\.\d+\.(nvme-uuid\.[^:]+):\d+$/;
    }

    my @vm_vds = grep {
        lc($_->{Id}) ne lc($new_vd_id)
        && (index($_->{Description} // '', $owner_tag) >= 0
            || $ids{lc($_->{ScsiDeviceIdString} // '')} || $ids{lc(eval { wwn_to_nvme_uuid($_->{ScsiDeviceIdString}) } // '')})
    } @$vds;
    return if !@vm_vds;    # single VD: no group

    my @disks = ((map { $_->{Id} } @vm_vds), $new_vd_id);
    my %want = map { lc($_) => 1 } @disks;

    my ($gid) = grep { defined && length } map { $_->{VirtualDiskGroupId} } @vm_vds;
    if ($gid) {
        # never extend a group that holds VDs of other VMs
        if (grep { lc($_->{VirtualDiskGroupId} // '') eq lc($gid) && !$want{lc($_->{Id})} } @$vds) {
            ssy_log('warning', "VD group %s holds VDs of other VMs, leaving it alone", $gid);
            return;
        }
        my @missing = grep { my $id = $_; !grep { lc($_->{Id}) eq lc($id) && lc($_->{VirtualDiskGroupId} // '') eq lc($gid) } @$vds } @disks;
        ssy_request('ADD VDs to VD Group', $scfg, $storeid, 'POST', "1.0/virtualdiskgroups/$gid/virtualdisks",
            { VirtualDisks => \@missing }) if @missing;
        return;
    }

    # groups already named like this VM, so cleanup below never touches one that predates the create
    my $before = eval { ssy_request('GET VD Groups', $scfg, $storeid, 'GET', '1.0/virtualdiskgroups') } // [];
    my %preexisting = map { lc($_->{Id} // '') => 1 } @$before;
    eval {
        ssy_request('CREATE VD Group', $scfg, $storeid, 'POST', '1.0/virtualdiskgroups', {
            Name => "$vmid",
            Description => "VDs of Proxmox VM $vmid, managed by the proxmox storage plugin",
            Disks => \@disks,
        });
    };
    if (my $err = $@) {
        # a failed create can leave an empty group behind
        eval {
            my $now = ssy_get_vds($scfg, $storeid);
            my $groups = ssy_request('GET VD Groups', $scfg, $storeid, 'GET', '1.0/virtualdiskgroups');
            foreach my $g (grep { ($_->{Caption} // '') eq "$vmid" && !$preexisting{lc($_->{Id} // '')} } @$groups) {
                next if grep { lc($_->{VirtualDiskGroupId} // '') eq lc($g->{Id}) } @$now;
                ssy_request('DELETE VD Group', $scfg, $storeid, 'DELETE', "1.0/virtualdiskgroups/$g->{Id}");
            }
        };
        die $err;
    }
}

sub load_stable_scsi_paths {

    my $stable_paths = {};

    my $stabledir = "/dev/disk/by-id";

    if (my $dh = IO::Dir->new($stabledir)) {
	    foreach my $tmp (sort $dh->read) {
            # exclude filenames with part in name (same disk but partitions) and the ID associated with DataCore_Virtual_Disk
            # use only filenames with scsi(with multipath i have the same device
            # with dm-uuid-mpath , dm-name and scsi in name)
            if($tmp !~ m/-part\d+$/ && $tmp !~ m/DataCore_Virtual_Disk_[A-Fa-f0-9]{32}/ && $tmp =~ m/^scsi-/) {
                my $path = "$stabledir/$tmp";
                my $bdevdest = readlink($path);

                if ($bdevdest && $bdevdest =~ m|^../../([^/]+)|) {
                    $stable_paths->{$1}=$tmp;
                }
            }
        }
        $dh->close;
    }
    return $stable_paths;
}

sub iscsi_device_list {
    my $res = {};
    my $volid;

    my $dirname = '/sys/class/iscsi_session';

    my $stable_paths = load_stable_scsi_paths();

    dir_glob_foreach($dirname, 'session(\d+)', sub {
        my ($ent, $session) = @_;

        my $target = file_read_firstline("$dirname/$ent/targetname");
        return if !$target;

        my (undef, $host) = dir_glob_regex("$dirname/$ent/device", 'target(\d+):.*');
        return if !defined($host);

        dir_glob_foreach("/sys/bus/scsi/devices", "$host:" . '(\d+):(\d+):(\d+)', sub {
            my ($tmp, $channel, $id, $lun) = @_;
            
            my $vendor = file_read_firstline("/sys/bus/scsi/devices/$tmp/vendor");
            my $wwid = file_read_firstline("/sys/bus/scsi/devices/$tmp/wwid");

            my $type = file_read_firstline("/sys/bus/scsi/devices/$tmp/type");
            return if !defined($type) || $type ne '0';

            my $bdev;
            if (-d "/sys/bus/scsi/devices/$tmp/block") {
                (undef, $bdev) = dir_glob_regex("/sys/bus/scsi/devices/$tmp/block/", '([A-Za-z]\S*)');
            } else {
                (undef, $bdev) = dir_glob_regex("/sys/bus/scsi/devices/$tmp", 'block:(\S+)');
            }
            return if !$bdev;

            #check multipath
            if (-d "/sys/block/$bdev/holders") {
                my $multipathdev = dir_glob_regex("/sys/block/$bdev/holders", '[A-Za-z]\S*');
                $bdev = $multipathdev if $multipathdev;
            }

            my $blockdev = $stable_paths->{$bdev};
            return if !$blockdev;

            my $size = file_read_firstline("/sys/block/$bdev/size");
            return if !$size;

            if ($blockdev =~ /scsi-(\w+)$/ ){
                my $scsi_id = $1;
                my $ssy_vmid = ssy_get_vmid($scsi_id);
                $volid = "$channel.$id.$lun.$blockdev:$ssy_vmid";
            } else {
                $volid = "$channel.$id.$lun.$blockdev:0";
            }

            $res->{$target}->{$volid} = {
                'bdev' => $bdev,
                'volid' => $volid,
                'vendor' => $vendor,
                'wwid' => $wwid,
                'format' => 'raw',
                'size' => int($size * 512),
                'channel' => int($channel),
                'id' => int($id),
                'lun' => int($lun),
            };
        });
    });
    return $res;
}

sub load_stable_nvme_paths {
    my $stable_paths = {};
    my $stabledir = "/dev/disk/by-id";

    if (my $dh = IO::Dir->new($stabledir)) {
        foreach my $tmp (sort $dh->read) {
            # Only nvme-uuid.* entries, skip partitions
            next if $tmp =~ m/-part\d+$/;
            next unless $tmp =~ m/^nvme-uuid\./;

            my $path = "$stabledir/$tmp";
            my $bdevdest = readlink($path);

            if ($bdevdest && $bdevdest =~ m|^../../([^/]+)|) {
                $stable_paths->{$1} = $tmp;  # e.g. nvme0n1 -> nvme-uuid.xxxx-xxxx-...
            }
        }
        $dh->close;
    }

    print "load_stable_nvme_paths:\n" . ssy_redact(Dumper($stable_paths)) . "\n" if $DEBUG;
    return $stable_paths;
}

sub nvme_tcp_device_list {
    my $res = {};
    my $dirname = '/sys/class/nvme';

    # Track merged bdevs we have already recorded so that when two
    # controllers (nvme1 + nvme2) both expose nvme0c1n1 / nvme0c2n1
    # pointing at the same merged namespace nvme0n1 we only emit one entry.
    my %seen_bdev;

    my $stable_paths = load_stable_nvme_paths();

    dir_glob_foreach($dirname, 'nvme(\d+)', sub {
        my ($ent, $ctrl_num) = @_;
        # $ent = "nvme1", $ctrl_num = "1"

        my $transport = file_read_firstline("$dirname/$ent/transport");
        return if !$transport || $transport ne 'tcp';

        my $subsysnqn = file_read_firstline("$dirname/$ent/subsysnqn");
        return if !$subsysnqn;

        my $state = file_read_firstline("$dirname/$ent/state");
        return if !$state || $state !~ /^live/;

        my $address = file_read_firstline("$dirname/$ent/address");
        return if !$address;
        my ($traddr)  = $address =~ /traddr=([^,]+)/;
        my ($trsvcid) = $address =~ /trsvcid=([^,]+)/;

        my $model = file_read_firstline("$dirname/$ent/model");

        # ----------------------------------------------------------------
        # Native-multipath layout:  nvme<subsys>c<ctrl>n<ns>  (no block entry)
        # Standard layout:          nvme<subsys>n<ns>          (has block entry)
        # Match both with one regex; the 'c\d+' part is optional.
        # Capture groups: ($ns_ent, $subsys_num, $ns_num)
        # ----------------------------------------------------------------
        dir_glob_foreach("$dirname/$ent", 'nvme(\d+)(?:c\d+)?n(\d+)', sub {
            my ($ns_ent, $subsys_num, $ns_num) = @_;

            # Reconstruct the *merged* block device name regardless of layout:
            #   nvme0c1n1  ->  nvme0n1
            #   nvme0n1    ->  nvme0n1   (unchanged)
            my $bdev = "nvme${subsys_num}n${ns_num}";
            print "nvme_tcp_device_list()-> bdev:$bdev\n" if $DEBUG;

            # Skip if already processed by an earlier controller path
            return if $seen_bdev{$bdev}++;

            # Confirm the merged block device actually exists in sysfs
            return if !-d "/sys/block/$bdev";

            # nsid lives on the merged namespace, not the per-path entry
            my $nsid = file_read_firstline("/sys/block/$bdev/nsid");
            return if !defined($nsid);

            my $wwid = file_read_firstline("/sys/block/$bdev/wwid");

            # Check multipath holders (dm-multipath on top of NVMe native mp)
            if (-d "/sys/block/$bdev/holders") {
                my $multipathdev = dir_glob_regex("/sys/block/$bdev/holders", '[A-Za-z]\S*');
                $bdev = $multipathdev if $multipathdev;
            }

            my $blockdev = $stable_paths->{$bdev};
            return if !$blockdev;

            my $size = file_read_firstline("/sys/block/$bdev/size");
            return if !$size;

            my $volid;
            if ($blockdev =~ /^(nvme-uuid\.[^.]+)/) {
                my $nvme_uuid = $1;
                my $ssy_vmid  = ssy_get_vmid($nvme_uuid);
                $volid = "0.$ctrl_num.$nsid.$blockdev:$ssy_vmid";
            } else {
                $volid = "$blockdev.$bdev:0";
            }

            $res->{$subsysnqn}->{$volid} = {
                'bdev'       => $bdev,
                'volid'      => $volid,
                'vendor'     => $model,
                'wwid'       => $wwid,
                'format'     => 'raw',
                'size'       => int($size * 512),
                'controller' => $ent,
                'nsid'       => int($nsid),
                'traddr'     => $traddr,
                'trsvcid'    => $trsvcid,
                'channel'    => int($ctrl_num),   # nvme controller index (e.g. 1 from nvme1)
                'id'         => 0,
                'lun'        => int($nsid),     # namespace ID plays the LUN role
            };
        });
    });

    #print "nvme_tcp_device_list():\n" . Dumper($res) . "\n" if $DEBUG;
    return $res;
}

sub parse_volname {
    my ($class, $volname) = @_;

    print "parse_volname() Volume name: $volname\n" if $DEBUG;

    if ($volname =~ m/^(nvme-uuid\.[^.]+)\.[^:]+:(\d+)$/) #Get NVMe uuid, VD name and VM id
    {
        my ($name, $vmid) = ($1, $2);
        return ('images', $name, int($vmid), undef, undef, undef, 'raw');
    }
    elsif ($volname =~ m!^\d+\.\d+\.\d+\.(\S+):(\d*)$!)
    {
        return ('images', $1, $2, undef, undef, undef, 'raw');
    }

    die "$LOG_PREFIX: unable to parse volume name '$volname'\n";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    die "$LOG_PREFIX: snapshot is not possible on iscsi storage\n" if defined($snapname);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $path = "/dev/disk/by-id/$name";

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;
    $DEBUG = ssy_debug_enabled($scfg);

    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::list_volumes\n" if $DEBUG;

    my $res = $class->list_images($storeid, $scfg, $vmid);

    for my $item (@$res) {
	    $item->{content} = 'images';
    }

    return $res;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    $DEBUG = ssy_debug_enabled($scfg);

    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::list_images\n" if $DEBUG;

    my $res = [];
    my $owner;

    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

    # Choose device list based on configured protocol
    my $devices;
    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp') {
        $cache->{nvme_devices} = nvme_tcp_device_list() if !$cache->{nvme_devices};
        $devices = $cache->{nvme_devices};
    } else {
        $cache->{iscsi_devices} = iscsi_device_list() if !$cache->{iscsi_devices};
        $devices = $cache->{iscsi_devices};
    }

    foreach my $target (@ssy_targets) {
        my $dat = $devices->{$target};
        next if !$dat;

        foreach my $volname (keys %$dat) {
            # Every volid ends in ":<vmid>" — skip malformed entries
            next if $volname !~ m/:(\d+)$/;
            $owner = $1;

            print "list_images() -> foreach loop volname: $volname\n" if $DEBUG;
            # Skip volumes with no owner
            next if $owner eq '0';

            my $volid = "$storeid:$volname";

            if ($vollist) {
                my $found = grep { $_ eq $volid } @$vollist;
                next if !$found;
            } else {
                # $vmid undef or 0 means "show all", otherwise filter by owner
                next if defined($vmid) && $vmid ne '0' && ($owner ne $vmid);
            }

            my $info = $dat->{$volname};
            $info->{volid} = $volid;
            $info->{vmid}  = $owner;

            # Deduplicate (can happen with multipath)
            my $exists = grep { $_->{volid} eq $info->{volid} } @$res;
            push @$res, $info unless $exists;
        }
    }

    #print "list_images():\n" . Dumper($res) . "\n" if $DEBUG;
    return $res;
}

sub check_connection {
    my ($class, $storeid, $scfg) = @_;
    $DEBUG = ssy_debug_enabled($scfg);

    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::check_connection\n" if $DEBUG;
    my $cache = {};
    my $api_version = $class->api();

    my @ssy_portals = split(/\s*,\s*/, $scfg->{portals});
    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp') {
        return if !assert_nvme_support(1);

        my $target = $ssy_targets[0]; # NVMe supports a single target
        foreach my $portal (@ssy_portals) {
            my $result = nvme_test_portal($target, $portal, $cache);
            return $result if $result;
        }

        return 0;
    }
    else {
        for (my $i = 0; $i < scalar @ssy_portals; $i++) {
            my $result;
            if ($api_version < 11) {
                $result = PVE::Storage::ISCSIPlugin::iscsi_test_portal($ssy_portals[$i]);
            } else {
                $result = PVE::Storage::ISCSIPlugin::iscsi_test_portal($ssy_targets[$i], $ssy_portals[$i], $cache);
            }
            return $result if $result;
        }

        return 0;
    }
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    die "$LOG_PREFIX: can't create base images in iscsi storage\n";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    die "$LOG_PREFIX: can't clone images in iscsi storage\n";
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;
    $DEBUG = ssy_debug_enabled($scfg);

    my $size_GiB = $size / (1024*1024*1024);

    # A LOCAL $vd_id, deliberately shadowing the file-scoped one declared at the
    # top of this module. Without it an unparsable $volname left the package
    # variable holding whatever the last alloc_image in this same worker process
    # had put there -- and the PUT below then resized THAT vDisk instead, with
    # no warning. pvedaemon reuses workers, so the two calls really can share a
    # process.
    my $vd_id;

    if ($volname =~ /\d+\.\d+\.\d+\.scsi-3(\w+):\d+$/) {
        my $wwid = $1;
        $vd_id = ssy_get_vd_id_from_wwid($scfg, $wwid, $storeid);
    }
    elsif ($volname =~ /^\d+\.\d+\.\d+\.(nvme-uuid\.[^:]+):/)
    {
        my $nvmeuuid = $1;
        $vd_id = ssy_get_vd_id_from_nvmeuuid($scfg, $nvmeuuid, $storeid);
    }
    else {
        ssy_log('err', "resize of '%s' on '%s': volume name matches neither "
                     . "the SCSI nor the NVMe form", $volname, $storeid);
        die "$LOG_PREFIX: cannot resize '$volname': unrecognised volume name\n";
    }

    if (!$vd_id) {
        ssy_log('err', "resize of '%s' on '%s': no SANsymphony vDisk found for "
                     . "that volume", $volname, $storeid);
        die "$LOG_PREFIX: cannot resize '$volname': no matching SANsymphony vDisk\n";
    }

    print "volume_resize() -> Volname: $volname, VD id: $vd_id, Size: $size_GiB GB\n" if $DEBUG;
    ssy_log('info', "resize vDisk %s ('%s' on '%s') to %s GB",
            $vd_id, $volname, $storeid, $size_GiB);

    ssy_request('Set Virtual Disk Properties', $scfg, $storeid, 'PUT', "/1.0/virtualdisks/$vd_id", {
        Size => "$size_GiB GB"
    });

    ssy_log('info', "resize vDisk %s to %s GB completed", $vd_id, $size_GiB);
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
    copy => { current => 1},
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
	$class->parse_volname($volname);

    my $key = undef;
    if ($snapname){
	$key = 'snap';
    } else {
	$key = $isBase ? 'base' : 'current';
    }
    return 1 if $features->{$feature}->{$key};

    return undef;
}

1;