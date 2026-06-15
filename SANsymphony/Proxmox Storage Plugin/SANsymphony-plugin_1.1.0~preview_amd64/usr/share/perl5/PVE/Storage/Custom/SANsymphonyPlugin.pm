package PVE::Storage::Custom::SANsymphonyPlugin;

use strict;
use warnings;
use JSON;
use LWP::UserAgent;
use HTTP::Request;
use PVE::Tools qw(run_command file_read_firstline trim dir_glob_regex dir_glob_foreach $IPV4RE $IPV6RE);
use PVE::Storage::ISCSIPlugin;
use base qw(PVE::Storage::Plugin);
use MIME::Base64 qw(encode_base64 decode_base64);
use Data::Dumper;

# Example: 192.168.122.252:3260,1 iqn.2003-01.org.linux-iscsi.proxmox-nfs.x8664:sn.00567885ba8f
my $ISCSI_TARGET_RE = qr/^((?:$IPV4RE|\[$IPV6RE\]):\d+)\,\S+\s+(\S+)\s*$/;
my $rescan_filename = "/var/run/ssy-iscsi-rescan.lock";
my $vd_id;
my $DEBUG = 0;
my $default_protocol = 'iscsi';

my $ISCSIADM = '/usr/bin/iscsiadm';
my $found_iscsi_support;
my $NVME_CLI = '/usr/sbin/nvme';
my $found_nvme_support;
my $MULTIPATH_CLI = '/usr/sbin/multipath';

sub api {
    my $minver = 3;
    my $maxver = 14;

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
        die "error: no iscsi support - please install open-iscsi\n" if !$noerr;
        warn "warning: no iscsi support - please install open-iscsi\n";
    }

    my $found_multipath_exe = -x $MULTIPATH_CLI;

    if (!$found_multipath_exe) {
        die "error: no multipath support - please install multipath-tools\n" if !$noerr;
        warn "warning: no multipath support - please install multipath-tools\n";
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
        die "error: no nvme support - please install nvme-cli\n" if !$noerr;
        warn "warning: no nvme support - please install nvme-cli\n";
    }

    return $found_nvme_support;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

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
            print "Portal $portal is unreachable - Portal test failed on '$storeid' storage.\n";
            return undef;
        }
    } else {
        if (!PVE::Storage::ISCSIPlugin::iscsi_test_portal($target_in, $portal, $cache)) {
            print "Portal $portal is unreachable - Portal test failed on '$storeid' storage.\n";
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
        warn "Failed to set iSCSI node setting '$key' to '$value' for target '$target': $@\n" if $@;
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
        warn $@ if $@;
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
    my ($portal, $cache, $storeid) = @_;

    assert_nvme_support();

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

    my $res = nvme_discovery($portal, $cache, $storeid);
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

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    #Set default protocol as iscsi if not defined.
    $scfg->{protocol} = 'iscsi' if !defined($scfg->{protocol}) || $scfg->{protocol} eq '';

    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp') {
        activate_nvme_storage($storeid, $scfg, $cache);
    }
    else {
        activate_iscsi_storage($storeid, $scfg, $cache);
    }

    ssy_register_host($scfg, $storeid);

    delete_stale_virtual_disks();
}

sub activate_nvme_storage {
    my ($storeid, $scfg, $cache) = @_;
    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::activate_nvme_storage\n" if $DEBUG;

    return if !assert_nvme_support(1);

    my @ssy_session_list;
    my @ssy_portals = split(/\s*,\s*/, $scfg->{portals});
    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

    if (scalar @ssy_targets > 1) {
        die "Only one NVMe target is supported, but multiple targets were configured: '" . $scfg->{targets} . "'.\n";
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
            eval { nvme_login($ssy_targets[0], $ssy_portals[$i], $cache, $storeid); };
            warn $@ if $@;
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
        die "Number of portals and targets must be equal";
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
            eval { iscsi_login($ssy_targets[$i], $ssy_portals[$i], $cache, $storeid); };
            warn $@ if $@;
        } else {
            push @ssy_session_list, @$sessions;
        }
    }

    iscsi_session_rescan(0, @ssy_session_list) if scalar @ssy_session_list;
}

sub delete_stale_virtual_disks {
    dir_glob_foreach('/sys/block', qr/^sd[a-z]+$/, sub {
        my ($dev_name) = @_;
        my $dev_path = "/sys/block/$dev_name";

        # Read size
        my $size_file = "$dev_path/size";
        return unless -e $size_file;
        open my $fh, '<', $size_file or return;
        my $size = <$fh>;
        close $fh;
        chomp $size;

        # Only care about 0-byte devices
        return if $size != 0;

        # Read vendor
        my $vendor_file = "$dev_path/device/vendor";
        my $vendor = '';
        if (-e $vendor_file) {
            open my $vf, '<', $vendor_file or return;
            $vendor = <$vf>;
            close $vf;
            chomp $vendor;
            $vendor =~ s/^\s+|\s+$//g;  # trim leading/trailing spaces
        }

        return unless $vendor eq 'DataCore';

        # Read and trim model
        my $model_file = "$dev_path/device/model";
        my $model = '';
        if (-e $model_file) {
            open my $mf, '<', $model_file or return;
            $model = <$mf>;
            close $mf;
            chomp $model;
            $model =~ s/^\s+|\s+$//g;  # trim leading/trailing spaces
        }

        return unless $model eq 'Virtual Disk';

        # Check holders directory — skip if non-empty
        my @holders = glob("$dev_path/holders/*");
        my $has_holders = scalar(@holders);

        return if $has_holders;  # Skip devices in use by dm/LVM/etc.

        print "Stale device $dev_name detected (size=0, vendor='$vendor', model='$model', holders=None)\n" if $DEBUG;
        print "Deleting stale device $dev_name\n" if $DEBUG;

        run_command(["echo 1 > /sys/block/$dev_name/device/delete"], outfunc => sub {});
    });
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::deactivate_storage\n" if $DEBUG;
    
    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp')
    {
        return if !assert_nvme_support(1);

        my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});        
        my $target = $ssy_targets[0];
        if (defined(nvme_session($cache, $target))) {
            nvme_logout($target);
            print "SANsymphonyPlugin - logging out from NVMe target: $target";
        }
    }
    else
    {
        return if !assert_iscsi_support(1);

        my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});
        foreach my $target (@ssy_targets){
            if (defined(iscsi_session($cache, $target))) {
                iscsi_logout($target);
                print "SANsymphonyPlugin - logging out from iSCSI target: $target";
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
    die "invalid device for udevadm path query\n" if !defined($dev);

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
    die "failed to query device path for '$dev': $@\n" if $@;

    ($device_path) = $device_path =~ m!^(/devices/.+)$!; # untaint
    die "invalid resolved device path\n" if !defined($device_path);

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

    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::activate_volume\n" if $DEBUG;
    
    my $path = $class->filesystem_path($scfg, $volname, $snapname);
    my $real_path = Cwd::realpath($path);
    die "failed to get realpath for '$path': $!\n" if !$real_path;
    # in case $path does not exist or is not a symlink, check if the returned
    # $real_path is a block device
    die "resolved realpath '$real_path' is not a block device\n" if ! -b $real_path;

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
        die "volume '$volname' is not part of any configured iSCSI target\n";
    }
    
}

sub wwn_to_nvme_uuid {
    my ($wwn) = @_;
    $wwn =~ s/[^0-9a-fA-F]//g;

    die "WWN must be 32 hex chars\n"
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
        die "The specified VD template '$scfg->{vdTemplateName}' has '$vdt_protocol' protocol which is not maching with the storage class '$storeid' [protocol: '$scfg->{protocol}']\n";
    }

    ($vd_id, $vd_name, $ScsiDeviceIdString) = ssy_vd_from_vdt($scfg, $storeid, $size_GiB, $vmid, $name);

    my @host_ids = ssy_get_host_ids($scfg, $storeid);
    my $lun  = ssy_get_lun($scfg, $storeid, $vd_id);

    foreach my $host_id (@host_ids){
        ssy_serve_vd($scfg, $storeid, $host_id, $vd_id, $lun);
    }

    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp')
    {
        my $target = $ssy_targets[0];
        my $session = nvme_session($cache, $target);
        push @ssy_session_list, @$session;
    }
    else
    {
        for (my $i = 0; $i < scalar @ssy_targets; $i++) {
            my $sessions = iscsi_session($cache, $ssy_targets[$i]);
            push @ssy_session_list, @$sessions;
        }
        iscsi_session_rescan(1, @ssy_session_list) if scalar @ssy_session_list;
    }

    my $sleep = 0;
    print "Waiting for SANsymphony VD\n";
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
    
    print "Unable to allocate the disk so deleteing the created disk.";

    ssy_unserve_delete_vd($vd_id, $scfg, $storeid, @host_ids);

    die "ERROR on image allocation";
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;
    my $vd_id = undef;

    print "Free volume name : $volname\n" if $DEBUG;

    if ($volname =~ /\d+\.\d+\.\d+\.scsi-3(\w+):\d+$/)
    {
        my $wwid = $1;
        $vd_id = ssy_get_vd_id_from_wwid($scfg, $wwid, $storeid);
    }
    elsif ($volname =~ /^\d+\.\d+\.\d+\.(nvme-uuid\.[^:]+):/) # Get the nvme uuid here instead of getting scfg->protocol
    {
        my $nvmeuuid = $1;
        $vd_id = ssy_get_vd_id_from_nvmeuuid($scfg, $nvmeuuid, $storeid);
    }

    return undef if $vd_id eq 0 || undef;

    my @host_ids = ssy_get_host_ids($scfg, $storeid);

    ssy_unserve_delete_vd($vd_id, $scfg, $storeid, @host_ids);

    print "SANsymphony VD with ID $vd_id got unserved and deleted successfully\n";

    return undef;
}

sub ssy_request {
    my ($request, $scfg, $storeid, $method, $endpoint, $body) = @_;

    if ( ($request ne "GET HOSTs") && ($request ne "GET VD Templates")  && ($request ne "GET PORTS") ) {
        print "Calling the SANsymphony REST API: $request\n";
    }

    my @ssy_portals = split(/\s*,\s*/, $scfg->{SSYipAddress});

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

        my $encoded_pass = ssy_get_pass($storeid);
        my $password = decode_password($encoded_pass);
        $req->authorization_basic( $scfg->{SSYusername}, $password);

        if ($body) {
            $req->content(encode_json($body));
        }

        next if (!PVE::Network::tcp_ping($portal, 443, 2));

        my $res = $ua->request($req);
        if ($res->is_success) {
            if (eval { decode_json($res->decoded_content); 1 }){
                return decode_json($res->decoded_content);
            } else {
                return $res;
            }
        } else {
            die "SANsymphony API request $request failed with HTTP Error: " . $res->status_line ." \nHTTP Response: " . $res->decoded_content;
        }
    }

    die "The REST server is not reachable on @ssy_portals \n";
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
    die "Did not find the appropriate VD Template details";
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
        run_command(['grep', '-oP', 'nqn\..*', '/etc/nvme/hostnqn'],
        errmsg => 'Getting the nvme initiator name',
        outfunc => sub {
            $initiatorname = shift;
        });
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

    my $ssy_hosts = ssy_get_hosts($scfg, $storeid);
    foreach my $host (@$ssy_hosts) {
        if ($host->{Caption} eq $host_name) {
            my $assign_status = ssy_check_port_assigned_to_host($scfg, $storeid, $initiatorname, $host->{Id});
            print "Initiator: $initiatorname, Host: $host_name, STATE: $assign_status\n" if $DEBUG;
            if ($assign_status eq 0)
            {
                ssy_assign_port_to_host($scfg, $storeid, $initiatorname, $host->{Id});
                return;
            }
            else
            {
                return;
            }
        }
    }

    my $host_id = ssy_add_host($scfg, $storeid, $host_name);

    ssy_assign_port_to_host($scfg, $storeid, $initiatorname, $host_id);
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

sub ssy_check_port_assigned_to_host {
    my ($scfg, $storeid, $portname, $host_id) = @_;
    
    print "ssy_check_port_assigned_to_host() -> Portname: $portname, Hostid: $host_id\n" if $DEBUG;
    
    my $supportsNVMeTcpPorts = "true";
    my $ports = ssy_request('GET PORTS', $scfg, $storeid, 'GET', "1.0/ports?supportsNVMeTcpPorts=$supportsNVMeTcpPorts" );

    my $assigned = 0;
    foreach my $port (@$ports)
    {
        #Print all the ports
        print "Port: $port->{PortName}, Hostid: $port->{HostId}\n" if $DEBUG;
        if ( (defined($host_id) && defined($portname)) && ($host_id ne '' && $portname ne '') &&
            (defined($port->{HostId}) && defined($port->{PortName})) && ($port->{HostId} ne '' && $port->{PortName} ne '') &&
            (lc($port->{HostId}) eq lc($host_id)) && (lc($port->{PortName}) eq lc($portname)) )
        {
            $assigned = 1;
        }
    }

    return $assigned;
}

sub ssy_get_hosts {
    my ($scfg, $storeid) = @_;

    my $ssy_hosts = ssy_request('GET HOSTs', $scfg, $storeid, "GET", "1.0/hosts" );

    return $ssy_hosts;
}

sub ssy_get_host_ids {
    my ($scfg, $storeid) = @_;
    my @pve_hosts;
    my @hosts = ();
    my $ssy_hosts = ssy_get_hosts($scfg, $storeid);


    if ($scfg->{nodes}){
	    my $nodes = PVE::Storage::Plugin->encode_value($scfg->{type}, 'nodes', $scfg->{nodes});
        @pve_hosts = split(/\s*,\s*/, $nodes);
    } else {
        @pve_hosts = `ls /etc/pve/nodes`;
        chomp @pve_hosts;
    }

    foreach my $host (@$ssy_hosts) {
        foreach my $pve (@pve_hosts) {
            if ($host->{Caption} eq $pve) {
                push @hosts, $host->{Id};
            }
        }
    }

    if (@hosts){
        return @hosts;
    } else {
        die "Did not find the appropriate Host details";
    }
}

sub ssy_get_vmid {
    my ($scsi_id) = @_;
    my $scsi_value;
    # Directory containing VM .conf files
    my $dir = '/etc/pve/qemu-server/';

    opendir(my $dh, $dir) or die "Cannot open directory $dir: $!";
    my @files = grep { /\.conf$/ && -f "$dir/$_" } readdir($dh);
    closedir($dh);

    foreach my $file (@files) {
        my $config_file = "$dir$file";
        
        open(my $fh, '<', $config_file) or die "Could not open file '$config_file' $!";

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
                die "VD '$vd_name' not found in virtual disk list after creation\n";
            }

            my $health = $vd->{DiskStatus} // '';
            print "Waiting for VD '$vd_name' to become healthy... DiskStatus=$health\n" if $DEBUG;
            last if $health eq '0';

            if ($waited >= $max_wait)
            {
                die "VD '$vd_name' did not become healthy within ${max_wait}s (DiskStatus=$health)\n";
            }

            sleep(1);
            $waited++;
        }

        print "VD '$vd_name' is healthy after ${waited}s\n" if $DEBUG;
        return ($vd_id, $vd_name, $ScsiDeviceIdString);
    } else {
        die "Unexpected response format from SANsymphony API";
    }

    print "SANsymphony VD got created successfully with Virtual Disk ID = $vd_id \n";
}

sub ssy_serve_vd {
    my ($scfg, $storeid, $host_id, $vd_id, $lun) = @_;

    ssy_request('SERVE VD', $scfg, $storeid, 'POST', "1.0/virtualdisks/$vd_id", {
        Operation => 'Serve',
        Host => $host_id,
        Redundancy => 'true',
        StartingLUN => $lun
    });
    print "SANsymphony VD {$vd_id} got served to host {$host_id} successfully \n";

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

        die "No free LUNs available for serving the new VD";
    }

    return $lun;
}

sub ssy_unserve_delete_vd {
    my ($vd_id, $scfg, $storeid, @host_ids) = @_;
    
    my $data;
    foreach my $host_id (@host_ids){
        $data = ssy_request('UNSERVE VD', $scfg, $storeid, 'POST', "1.0/virtualdisks/$vd_id", {
            Operation => 'Unserve',
            Host => $host_id,
        });
    }

    $data = ssy_request('DELETE VD', $scfg, $storeid, 'DELETE', "1.0/virtualdisks/$vd_id");
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

    print "load_stable_nvme_paths:\n" . Dumper($stable_paths) . "\n" if $DEBUG;
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

    die "unable to parse volume name '$volname'\n";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    die "snapshot is not possible on iscsi storage\n" if defined($snapname);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $path = "/dev/disk/by-id/$name";

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;

    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::list_volumes\n" if $DEBUG;

    my $res = $class->list_images($storeid, $scfg, $vmid);

    for my $item (@$res) {
	    $item->{content} = 'images';
    }

    return $res;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

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

    print "Debug :: PVE::Storage::Custom::SANsymphonyPlugin::sub::check_connection\n" if $DEBUG;
    my $cache = {};
    my $api_version = $class->api();

    my @ssy_portals = split(/\s*,\s*/, $scfg->{portals});
    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

    if ($scfg->{protocol} && $scfg->{protocol} eq 'nvme-tcp') {
        return if !assert_nvme_support(1);

        foreach my $portal (@ssy_portals) {
            my $res = eval { nvme_discovery($portal, $cache, $storeid) };
            next if $@;
            return 1 if $res && %$res;
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

    die "can't create base images in iscsi storage\n";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    die "can't clone images in iscsi storage\n";
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    my $size_GiB = $size / (1024*1024*1024);

    if ($volname =~ /\d+\.\d+\.\d+\.scsi-3(\w+):\d+$/) {
        my $wwid = $1;
        $vd_id = ssy_get_vd_id_from_wwid($scfg, $wwid, $storeid);
    }
    elsif ($volname =~ /^(nvme-uuid\.[^.]+)\..*/) # Get the nvme uuid here instead of getting scfg->protocol
    {
        my $nvmeuuid = $1;
        $vd_id = ssy_get_vd_id_from_nvmeuuid($scfg, $nvmeuuid, $storeid);
    }

    print "volume_resize() -> Volname: $volname, VD id: $vd_id, Size: $size_GiB GB\n" if $DEBUG;

    ssy_request('Set Virtual Disk Properties', $scfg, $storeid, 'PUT', "/1.0/virtualdisks/$vd_id", {
        Size => "$size_GiB GB"
    });

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