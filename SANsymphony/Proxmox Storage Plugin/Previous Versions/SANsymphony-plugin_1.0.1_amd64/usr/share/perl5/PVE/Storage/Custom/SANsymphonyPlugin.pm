package PVE::Storage::Custom::SANsymphonyPlugin;

use strict;
use warnings;
use JSON;
use LWP::UserAgent;
use HTTP::Request;
use PVE::Tools qw(run_command file_read_firstline trim dir_glob_regex dir_glob_foreach $IPV4RE $IPV6RE);
use PVE::Storage::ISCSIPlugin;
use base qw(PVE::Storage::Plugin);

sub api {
    my $minver = 3;
    my $maxver = 12;

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
    };
}

sub properties {
    return {
		SSYipAddress => {
		    description => "comma separated Management IP address of the SANsymphony REST server.",
		    type => 'string',
		},
		portals => {
		    description => "comma separated iSCSI portals (IP or DNS name with optional port).",
		    type => 'string',
		},
		targets => {
		    description => "comma separated iSCSI targets",
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
    };
}

sub options {
    return {
        portals => { fixed => 1 },
        targets => { fixed => 1 },
        SSYusername => { fixed => 1},
        SSYpassword => { fixed => 1},
        SSYipAddress => { fixed => 1},
        vdTemplateName => { fixed => 1 },
        nodes => { optional => 1},
        shared => { optional => 1 },
        disable => { optional => 1},
        content => { optional => 1},
    };
}

# Example: 192.168.122.252:3260,1 iqn.2003-01.org.linux-iscsi.proxmox-nfs.x8664:sn.00567885ba8f
my $ISCSI_TARGET_RE = qr/^((?:$IPV4RE|\[$IPV6RE\]):\d+)\,\S+\s+(\S+)\s*$/;
my $rescan_filename = "/var/run/ssy-iscsi-rescan.lock";
my $ISCSIADM = '/usr/bin/iscsiadm';
my $found_iscsi_adm_exe;
my $vd_id;
my $debug = 1;

my sub assert_iscsi_support {
    my ($noerr) = @_;
    return $found_iscsi_adm_exe if $found_iscsi_adm_exe; # assume it won't be removed if ever found

    $found_iscsi_adm_exe = -x $ISCSIADM;

    if (!$found_iscsi_adm_exe) {
        die "error: no iscsi support - please install open-iscsi\n" if !$noerr;
    }
    return $found_iscsi_adm_exe;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    
    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});
    my $active;

    foreach my $target (@ssy_targets){
        my $session = iscsi_session($cache, $target);
        $active = defined($session) ? 1 : 0;

        last if $active eq 1;
    }

    return (0, 0, 0, $active);
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

    # Disable retries to avoid blocking pvestatd for too long, next iteration will retry anyway
    eval {
        my $cmd = [
            $ISCSIADM,
            '--mode', 'node',
            '--targetname', $target,
            '--op', 'update',
            '--name', 'node.session.initial_login_retry_max',
            '--value', '0',
        ];
        run_command($cmd);
    };
    warn $@ if $@;

    # Set startup to manual, so that we do not automatically login on boot
    eval {
        my $cmd = [
            $ISCSIADM,
            '--mode', 'node',
            '--targetname', $target,
            '--op', 'update',
            '--name', 'node.startup',
            '--value', 'manual',
        ];
        run_command($cmd);
    };
    warn $@ if $@;

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

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

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

    ssy_register_host($scfg);

    run_command(['multipath', '-r'], outfunc => sub {});

    delete_stale_virtual_disks();
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

        print "Stale device $dev_name detected (size=0, vendor='$vendor', model='$model', holders=None)\n" if $debug;
        print "Deleting stale device $dev_name\n" if $debug;

        run_command(["echo 1 > /sys/block/$dev_name/device/delete"], outfunc => sub {});
    });
}
sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    return if !assert_iscsi_support(1);

    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

    foreach my $target (@ssy_targets){
        if (defined(iscsi_session($cache, $target))) {
            iscsi_logout($target);
            print "logging out from $target";
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

    my $path = $class->filesystem_path($scfg, $volname, $snapname);
    my $real_path = Cwd::realpath($path);
    die "failed to get realpath for '$path': $!\n" if !$real_path;
    # in case $path does not exist or is not a symlink, check if the returned
    # $real_path is a block device
    die "resolved realpath '$real_path' is not a block device\n" if ! -b $real_path;

    my $device_path = $udev_query_path->($real_path);
    my $resolved_paths = $resolve_virtual_devices->($device_path);

    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

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

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
    my $ScsiDeviceIdString;
    my $cache = {};
    my @ssy_session_list;
    my $size_GiB = $size / (1024*1024);
    my $volid;
    my $scsi_id = undef;

    ($vd_id, $ScsiDeviceIdString) = ssy_vd_from_vdt($scfg, $size_GiB, $vmid, $name);

    my @host_ids = ssy_get_host_ids($scfg);
    my $lun  = ssy_get_lun($scfg, $vd_id);

    foreach my $host_id (@host_ids){
        ssy_serve_vd($scfg, $host_id, $vd_id, $lun);
    }

    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

    for (my $i = 0; $i < scalar @ssy_targets; $i++) {
        my $sessions = iscsi_session($cache, $ssy_targets[$i]);
        push @ssy_session_list, @$sessions;
    }
    iscsi_session_rescan(1, @ssy_session_list) if scalar @ssy_session_list;

    my $sleep = 0;
    print "Waiting for SANsymphony VD\n";
    scan:
    
    # The 3 prefix specifically indicates SCSI-3 compliant storage devices.
    # This is standardized and relates to how the device presents its World Wide Identifier (WWID).
    my $wwid = "3" . lc($ScsiDeviceIdString);

    ($wwid) = $wwid =~ /^([0-9A-Fa-f]+)$/; # untaint

    my $stabledir = "/dev/disk/by-id";

    if (my $dh = IO::Dir->new("/dev/disk/by-id")) {
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

    return $volid if $volid;

    if ($sleep < 30) {
        $sleep += 1;
        sleep(1);
        goto scan;
    }
    
    print "Unable to allocate the disk so deleteing the created disk.";

    ssy_unserve_delete_vd($vd_id, $scfg, @host_ids);

    die "ERROR on image allocation";
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;
    my $vd_id = undef;

    if ($volname =~ /\d+\.\d+\.\d+\.scsi-3(\w+):\d+$/) {
        my $wwid = $1;
        $vd_id = ssy_get_vd_id_from_wwid($scfg, $wwid);
    }

    return undef if $vd_id eq 0 || undef;

    my @host_ids = ssy_get_host_ids($scfg);

    ssy_unserve_delete_vd($vd_id, $scfg, @host_ids);

    print "SANsymphony VD with ID $vd_id got unserved and deleted successfully\n";

    return undef;
}

sub ssy_request {
    my ($request, $scfg, $method, $endpoint, $body) = @_;

    if ($request ne "GET HOSTs") {
        print "Calling the SANsymphony REST API: $request\n";
    }

    my @ssy_portals = split(/\s*,\s*/, $scfg->{SSYipAddress});

    foreach my $portal (@ssy_portals) {
        my $url = "http://$portal/RestService/rest.svc/$endpoint";
        my $ua = LWP::UserAgent->new;
        my $req = HTTP::Request->new($method => $url);

        $req->header('Content-Type' => 'application/json');
        $req->header('ServerHost' => $portal);
        $req->authorization_basic( $scfg->{SSYusername}, $scfg->{SSYpassword} );

        if ($body) {
            $req->content(encode_json($body));
        }

        next if (!PVE::Network::tcp_ping($portal, 80, 2));

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
    my ($scfg) = @_;

    my $vds = ssy_request('GET Virtual Disks', $scfg, "GET", "1.0/virtualdisks" );
    return $vds;
}

sub ssy_get_vdt_info {
    my ($scfg) = @_;

    my $data = ssy_request('GET VD Templates', $scfg, "GET", "/1.0/virtualdisktemplates" );

    foreach my $vdt (@$data){
        if ($vdt->{Caption} eq $scfg->{vdTemplateName}) {
            return ($vdt->{Id}, $vdt->{VirtualDiskAlias});
        }
    }
    die "Did not find the appropriate VD Template details";
}

sub ssy_get_vd_id_from_wwid {
    my ($scfg, $wwid) = @_;

    my $vds = ssy_get_vds($scfg);

    foreach my $virtualdisk (@$vds){
        if (lc($virtualdisk->{ScsiDeviceIdString}) eq lc($wwid)) {
            return $virtualdisk->{Id};
        }
    }

    return 0;
}

sub ssy_register_host {
    my ($scfg, $host_name, $iscsi_initiatorname) = @_;
    
    run_command(['hostname'], errmsg => 'Getting the host name', outfunc => sub {
        $host_name = shift;
    });

    run_command(['grep', '-oP', 'iqn\..*', '/etc/iscsi/initiatorname.iscsi'], 
    errmsg => 'Getting the iscsi initiator name', 
    outfunc => sub {
        $iscsi_initiatorname = shift;
    });

    my $ssy_hosts = ssy_get_hosts($scfg);
    foreach my $host (@$ssy_hosts) {
        if ($host->{Caption} eq $host_name) {
            if ($host->{State} ne 0){
                return;
            } else {
                ssy_assign_port_to_host($scfg, $iscsi_initiatorname, $host->{Id});
                return;
            }
        }
    }

    my $host_id = ssy_add_host($scfg, $host_name);

    ssy_assign_port_to_host($scfg, $iscsi_initiatorname, $host_id);
}

sub ssy_add_host {
    my ($scfg, $host_name) = @_;
    
    my $data = ssy_request('ADD HOST', $scfg, 'POST', '1.0/hosts', {
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
    my ($scfg, $port, $host_id) = @_;
    
    ssy_request('ASSIGN PORT', $scfg, 'POST', "1.0/hosts/$host_id", {
        Operation => "AssignPort",
        Port => $port
    });
}

sub ssy_get_hosts {
    my ($scfg) = @_;

    my $ssy_hosts = ssy_request('GET HOSTs', $scfg, "GET", "1.0/hosts" );

    return $ssy_hosts;
}

sub ssy_get_host_ids {
    my ($scfg) = @_;
    my @pve_hosts;
    my @hosts = ();
    my $ssy_hosts = ssy_get_hosts($scfg);


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
    my ($scfg, $size_GiB, $vmid, $name) = @_;

    my ($vdt_id, $vdt_alias) = ssy_get_vdt_info($scfg);

    my $vd_name;
    if ($name) {
        $vd_name = "$name-$vdt_alias";
    } else {
        $vd_name = "$vmid-$vdt_alias";
    }
    if ($size_GiB < 1) {
        $size_GiB = 1; # enforce minimum size of 1 GB
    }

    my $vd = ssy_request('CREATE VD from VD Template', $scfg, 'POST', '1.0/virtualdisks', {
        VirtualDiskTemplate => $vdt_id,
        Name => $vd_name,
        Size => "$size_GiB GB",
        Count => 1,
    });

    if (ref($vd) eq 'ARRAY') {
        my $vd_id = $vd->[0]{Id}; # getting the first element in the array is the new VD as we are creating only one VD
	    my $ScsiDeviceIdString = $vd->[0]{ScsiDeviceIdString};
        return ($vd_id, $ScsiDeviceIdString);
    } else {
        die "Unexpected response format from SANsymphony API";
    }

    print "SANsymphony VD got created successfully with Virtual Disk ID = $vd_id \n";
}

sub ssy_serve_vd {
    my ($scfg, $host_id, $vd_id, $lun) = @_;

    ssy_request('SERVE VD', $scfg, 'POST', "1.0/virtualdisks/$vd_id", {
        Operation => 'Serve',
        Host => $host_id,
        Redundancy => 'true',
        StartingLUN => $lun
    });
    print "SANsymphony VD {$vd_id} got served to host {$host_id} successfully \n";

}

sub ssy_get_lun {
    my ($scfg, $vd_id) = @_;
    
    my $data = ssy_request('GET Virtual Logical Units', $scfg, 'GET', "1.0/virtuallogicalunits");

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
        $data = ssy_request('DELETE VD', $scfg, 'DELETE', "1.0/virtualdisks/$vd_id");

        die "No free LUNs available for serving the new VD";
    }

    return $lun;
}

sub ssy_unserve_delete_vd {
    my ($vd_id, $scfg, @host_ids) = @_;
    
    my $data;
    foreach my $host_id (@host_ids){
        $data = ssy_request('UNSERVE VD', $scfg, 'POST', "1.0/virtualdisks/$vd_id", {
            Operation => 'Unserve',
            Host => $host_id,
        });
    }

    $data = ssy_request('DELETE VD', $scfg, 'DELETE', "1.0/virtualdisks/$vd_id");
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

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m!^\d+\.\d+\.\d+\.(\S+):(\d*)$!) {
	    return ('images', $1, $2, undef, undef, undef, 'raw');
    }

    die "unable to parse iscsi volume name '$volname'\n";
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

    my $res = $class->list_images($storeid, $scfg, $vmid);

    for my $item (@$res) {
	    $item->{content} = 'images';
    }

    return $res;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $res = [];
    my $owner;

    $cache->{iscsi_devices} = iscsi_device_list() if !$cache->{iscsi_devices};

    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

    foreach my $target (@ssy_targets) {
        if (my $dat = $cache->{iscsi_devices}->{$target}) {

            foreach my $volname (keys %$dat) {
                next if $volname !~ m/:(\d+)$/;
                $owner = $1;

                next if ($vmid && $vmid eq '0') || $owner eq '0';
                
                my $volid = "$storeid:$volname";

                if ($vollist) {
                    my $found = grep { $_ eq $volid } @$vollist;
                    next if !$found;
                } else {
                    next if defined($vmid) && ($owner ne $vmid);
                }

                my $info = $dat->{$volname};
                $info->{volid} = $volid;
                $info->{vmid} = $owner;
                
                # Avoid duplicates by checking if volid already exists in @$res
                my $exists = grep { $_->{volid} eq $info->{volid} } @$res;
                push @$res, $info unless $exists;
            }
        }
    }

    return $res;
}

sub check_connection {
    my ($class, $storeid, $scfg) = @_;
    my $cache = {};
    my $api_version = $class->api();

    my @ssy_portals = split(/\s*,\s*/, $scfg->{portals});
    my @ssy_targets = split(/\s*,\s*/, $scfg->{targets});

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
        $vd_id = ssy_get_vd_id_from_wwid($scfg, $wwid);
    }

    ssy_request('Set Virtual Disk Properties', $scfg, 'PUT', "/1.0/virtualdisks/$vd_id", {
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