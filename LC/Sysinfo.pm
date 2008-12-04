#+##############################################################################
#                                                                              #
# File: Sysinfo.pm                                                             #
#                                                                              #
# Description: easy access to system-specific information                      #
#                                                                              #
#-##############################################################################

#
# module definition
#

package LC::Sysinfo;
use 5.006;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.2 $ =~ /(\d+)\.(\d+)/);

#
# export control
#

use Exporter;
our(@ISA, @EXPORT, @EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK =
    qw(uname os memory swap uptime loadavg df du ps pids netintf netstat);

#
# used modules
#

use LC::Exception qw(throw_error throw_warning);
use LC::File qw(file_contents);
use LC::Process qw(execute toutput);
use LC::Cached getpwuid => 180;

#
# internal variables used for caching
#

our(
    $_Uname,		# cached information from uname
    $_Os,		# cached information from os
    @_Df,		# df command to use
    @_Du,		# du command to use
    @_Ifconfig,		# ifconfig (or netstat -i) command to use
    @_Netstat,		# netstat command to use
);

#+++############################################################################
#                                                                              #
# uname information                                                            #
#                                                                              #
#---############################################################################

#
# uname itself, raw information
#

sub uname () {
    unless ($_Uname) {
	require POSIX;
	$_Uname = [ POSIX::uname() ];
	bless($_Uname, "LC::Sysinfo::Uname");
    }
    return($_Uname);
}

#
# access to uname fields via methods
#

{
    package LC::Sysinfo::Uname;
    use strict;
    use warnings;

    sub sysname  : method { my($self) = @_; return($self->[0]); }
    sub nodename : method { my($self) = @_; return($self->[1]); }
    sub release  : method { my($self) = @_; return($self->[2]); }
    sub version  : method { my($self) = @_; return($self->[3]); }
    sub machine  : method { my($self) = @_; return($self->[4]); }
}

#
# enhanced uname fields:
#   os->name	  distinctive/meaningful OS name
#   os->version	  version that can be numerically compared
#

sub os () {
    unless ($_Os) {
	my($name, $vers) = (uname->sysname, uname->release);
	if ($name eq "SunOS") {
	    # make $vers really numerical by removing the extra dots
	    if ($vers =~ s/^5\./2./) {
		# SunOS 5.6 -> 2.60 (Solaris)
		$name = "Solaris";
		$vers = sprintf("%d.%01d%01d", split(/\./, $vers), 0);
	    } else {
		# SunOS 4.1.3 -> 4.13
		$vers = sprintf("%d.%01d%01d", split(/\./, $vers), 0);
	    }
	} elsif ($name eq "Linux") {
	    # make $vers really numerical by removing the extra dots
	    # and ignoring the rpm "release number" like in 2.2.5-4smp
	    $vers =~ s/-.+?$//;
	    if ($vers =~ /^(\d+)\.(\d+)\.(\d+)pre(\d+)$/) {
		# Linux 2.2.15pre19 -> 2.201419
		$vers = sprintf("%d.%01d%03d%02d", $1, $2, $3-1, $4);
	    } else {
		# Linux 2.1.125 -> 2.1125
		$vers = sprintf("%d.%01d%03d", split(/\./, $vers));
	    }
	} elsif ($name eq "HP-UX") {
	    # A.09.01 or B.10.20
	    $vers =~ s/^[AB]\.0*//;
	} elsif ($name eq "AIX") {
	    $vers = uname->version . ".$vers";
	    # one could also use oslevel(1) here to get more information...
	} elsif ($name eq "OSF1") {
	    # V4.0
	    $vers =~ s/^V//;
	    # add the version number: V4.0 878 -> 4.00878
	    $vers = sprintf("%s%04d", $vers, uname->version);
	} elsif ($name =~ /^IRIX\d+$/) {
	    # name can be IRIX or IRIX64...
	    $name = "IRIX";
	}
	$_Os = [ $name, $vers ];
	bless($_Os, "LC::Sysinfo::Os");
    }
    return($_Os);
}

#
# access to os fields via methods
#

{
    package LC::Sysinfo::Os;
    use strict;
    use warnings;

    sub name    : method { my($self) = @_; return($self->[0]); }
    sub version : method { my($self) = @_; return($self->[1]); }
}

#+++############################################################################
#                                                                              #
# memory and swap information                                                  #
#                                                                              #
#---############################################################################

#
# get some information from /proc/meminfo
#

sub _get_meminfo ($) {
    my($what) = @_;
    my($path, $info, $total, $free);

    $path = "/proc/meminfo";
    $info = file_contents($path);
    return() unless defined($info);
    unless ($info =~ /^${what}Total:\s+(\d+)\s+kB/m) {
	throw_error("unexpected $path data", "no ${what}Total");
	return();
    }
    $total = $1;
    unless ($info =~ /^${what}Free:\s+(\d+)\s+kB/m) {
	throw_error("unexpected $path data", "no ${what}Free");
	return();
    }
    $free = $1;
    unless ($total >= $free) {
    throw_error("unexpected $path data", "${what}Total < ${what}Free");
	return();
    }
    return($total, $total-$free, $free);
}

#
# memory information
#

sub memory () {
    my($osname, @data);

    $osname = os->name;
    unless ($osname eq "Linux") {
	throw_error("unsupported system", $osname);
	return();
    }
    @data = _get_meminfo("Mem");
    return() unless @data;
    bless(\@data, "LC::Sysinfo::Memory");
    return(\@data);
}

#
# swap information
#

sub swap () {
    my($osname, @data);

    $osname = os->name;
    unless ($osname eq "Linux") {
	throw_error("unsupported system", $osname);
	return();
    }
    @data = _get_meminfo("Swap");
    return() unless @data;
    bless(\@data, "LC::Sysinfo::Memory");
    return(\@data);
}

#
# access to memory fields via methods
#

{
    package LC::Sysinfo::Memory;
    use strict;
    use warnings;

    sub size : method { my($self) = @_; return($self->[0]); }
    sub used : method { my($self) = @_; return($self->[1]); }
    sub free : method { my($self) = @_; return($self->[2]); }
}

#+++############################################################################
#                                                                              #
# uptime and load averages                                                     #
#                                                                              #
#---############################################################################

#
# uptime
#

sub uptime () {
    my($osname, $path, $info);

    $osname = os->name;
    unless ($osname eq "Linux") {
	throw_error("unsupported system", $osname);
	return();
    }
    $path = "/proc/uptime";
    $info = file_contents($path);
    return() unless defined($info);
    unless ($info =~ /^(\d+)\.\d+ /) {
	throw_error("unexpected $path data", chomp($info));
	return();
    }
    return($1);
}

#
# load averages
#

sub loadavg () {
    my($osname, $path, $info, $obj);

    $osname = os->name;
    unless ($osname eq "Linux") {
	throw_error("unsupported system", $osname);
	return();
    }
    $path = "/proc/loadavg";
    $info = file_contents($path);
    return() unless defined($info);
    unless ($info =~ /^(\d+\.\d+) (\d+\.\d+) (\d+\.\d+) /) {
	throw_error("unexpected $path data", chomp($info));
	return();
    }
    $obj = [ $1, $2, $3 ];
    bless($obj, "LC::Sysinfo::Loadavg");
    return($obj);
}

#
# access to loadavg fields via methods
#

{
    package LC::Sysinfo::Loadavg;
    use strict;
    use warnings;

    sub last1  : method { my($self) = @_; return($self->[0]); }
    sub last5  : method { my($self) = @_; return($self->[1]); }
    sub last15 : method { my($self) = @_; return($self->[2]); }
}

#+++############################################################################
#                                                                              #
# file system information                                                      #
#                                                                              #
#---############################################################################

#
# a kind of df, returns the list of known device ids (beware of automount!)
# in a hash, along with the corresponding information
#
# the type of the filesystem can be:
#  afs:  AFS, the Andrew FileSystem
#  dfs:  DFS, the Disributed FileSystem
#  nfs:  a remote filesystem using NFS
#  hfs:  any "local" filesystem (including Sun's swapfs or Linux's tmpfs)
# (note: proc, shm and fd pseudo-filesystems are skipped)
#

sub df () {
    my($osname, $output, @lines, $name, $type, $path, $size, $used, $dev, %df);
    local($_);

    $osname = os->name;
    unless (@_Df) {
	if ($osname eq "HP-UX") {
	    @_Df = ("/usr/bin/bdf");
	} else {
	    @_Df = (-x "/usr/bin/df" ? "/usr/bin/df" : "/bin/df");
	    if ($osname eq "SunOS") {
		# no additional option
	    } elsif ($osname eq "AIX") {
		push(@_Df, qw(-k -P));
	    } else {
		push(@_Df , qw(-k));
	    }
	}
    }
    $output = toutput(10, @_Df);
    return() unless defined($output);
    @lines = split(/\n/, $output);
    shift(@lines); # skip header
    while (@lines) {
	$_ = shift(@lines);
	if ($osname eq "IRIX") {
	    # Filesystem         Type  kbytes     use   avail %use  Mounted on
	    # /dev/root           efs  471376  439419   31957  93%  /
	    unless (/^(\S+)\s+\S+\s+(\d+)\s+(\d+)\s+-?\d+\s+\S+\s+(\S+)\s*$/) {
		throw_warning("bogus df line", $_);
		next;
	    }
	    ($name, $path, $size, $used) = ($1, $4, $2, $3);
	} else {
	    # handle broken lines :-(
	    if (/^\S+$/) {
		# /dev/vg00/sw_enware
		#                     99669   68799   20903   77% /depot/enware
		unless (@lines) {
		    throw_warning("bogus df line", $_);
		    next;
		}
		$_ .= shift(@lines);
	    }
	    # handle collapsed lines :-((
	    if ($osname eq "HP-UX" and /^AFS.+072000000/) {
		# AFS                72000000       072000000     0%   /afs
		s/^(AFS.+0)(72000000)/$1 $2/;
	    }
	    # Filesystem            kbytes    used   avail capacity  Mounted on
	    # /dev/dsk/c0t3d0s0      30991   12345   15556    45%    /
	    # /dev/dsk/c410d6s0   1213854 1101974   -9506   101%   /mnt/disk3
	    # root_domain#root       98304       53990       35776    60%    /
	    # fd                         0       0       0     0%    /dev/fd
	    unless (/^(\S+)\s+(\d+)\s+(\d+)\s+-?\d+\s+\S+\s+(\S+)\s*$/) {
		throw_warning("bogus df line", $_);
		next;
	    }
	    ($name, $path, $size, $used) = ($1, $4, $2, $3);
	}
	next if $name eq "/proc"; # SysV /proc
	next if $name eq "fd";    # SysV /dev/fd
	next if $name eq "none";  # Linux /dev/shm for instance
	$dev = (stat($path))[0];
	unless (defined($dev)) {
	    throw_warning("bogus path in df line", $_);
	    next;
	}
	if ($name eq "AFS") {
	    $type = "afs";
	} elsif ($name eq "DFS") {
	    $type = "dfs";
	} elsif ($name =~ /.\:\/./) {
	    # normal host:/path
	    $type = "nfs";
	} elsif ($name =~ /.\@./) {
	    # OSF1 /path@host
	    $type = "nfs";
	} elsif ($name =~ /.\#./) {
	    # OSF1 domain_name#fileset_name
	    $type = "hfs";
	} else {
	    # this may include special file systems
	    $type = "hfs";
	}
	$df{$path} = [$dev, $name, $type, $path, $size, $used];
	bless($df{$path}, "LC::Sysinfo::FileSystem");
    }
    bless(\%df, "LC::Sysinfo::FileSystemList");
    return(\%df);
}

#
# access to df information via methods
#

{
    package LC::Sysinfo::FileSystemList;
    use strict;
    use warnings;

    sub paths       : method { my($self) = @_; return(keys(%$self)); }
    sub filesystems : method { my($self) = @_; return(values(%$self)); }
    sub filesystem  : method { my($self, $path) = @_; return($self->{$path}); }
}

#
# access to filesystem fields via methods
#

{
    package LC::Sysinfo::FileSystem;
    use strict;
    use warnings;

    sub dev  : method { my($self) = @_; return($self->[0]); }
    sub name : method { my($self) = @_; return($self->[1]); }
    sub type : method { my($self) = @_; return($self->[2]); }
    sub path : method { my($self) = @_; return($self->[3]); }
    sub size : method { my($self) = @_; return($self->[4]); }
    sub used : method { my($self) = @_; return($self->[5]); }
}

#
# nicely print df data (for debugging)
#

sub _print_df () {
    my($df, $path, $fs, $pct);

    $df = df() or return;
    printf("%-8s %-22s %-4s %-20s %-9s %-8s %s\n",
        qw(Device Filesystem Type Mounted_on Kbytes Used Usage));
    foreach $path (sort($df->paths)) {
	$fs = $df->filesystem($path);
	$pct = ($fs->size ? $fs->used/$fs->size*100 : 0);
	printf("%08X %-22s %-4s %-20s %-9d %-8d %5.2f%%\n", $fs->dev,
	       $fs->name, $fs->type, $fs->path, $fs->size, $fs->used, $pct);
    }
}

#+++############################################################################
#                                                                              #
# disk usage                                                                   #
#                                                                              #
#---############################################################################

#
# a simple du, always returning the size in KB
#

sub du ($) {
    my($path) = @_;
    my($osname, $output, $size, $line, @warnings);

    $osname = os->name;
    unless (@_Du) {
	@_Du = (-x "/usr/bin/du" ? "/usr/bin/du" : "/bin/du");
	push(@_Du, "-k") unless $osname eq "HP-UX";
	push(@_Du, "-s");
    }
    $path =~ s/\/+$//; # remove trailing /
    $output = toutput(60, @_Du, $path);
    return() unless defined($output);
    foreach $line (split(/\n/, $output)) {
	if ($line =~ /^(\d+)\s+\Q$path\E\s*$/) {
	    $size = $1;
	} else {
	    $line =~ s/^(\S+\/)?du:\s+//;
	    push(@warnings, $line);
	}
    }
    unless (defined($size)) {
	if (@warnings) {
	    $output = pop(@warnings);
	    foreach $line (@warnings) {
		throw_warning($line);
	    }
	    throw_error($output);
	} else {
	    throw_error("no output");
	}
	return();
    }
    foreach $line (@warnings) {
	throw_warning($line);
    }
    $size = ($size + 1) >> 1 if $osname eq "HP-UX";
    return($size);
}

#+++############################################################################
#                                                                              #
# process information                                                          #
#                                                                              #
#---############################################################################

#
# run the ps command with a timeout and return also the ps process pid
#

sub _ps_output (@) {
    my(@command) = @_;
    my($output, $pid);

    $output = "";
    execute(\@command, "timeout" => 30,
	    "stdout" => \$output, "stderr" => "stdout", "pid" => \$pid)
	or return();
    return($output, $pid);
}

#
# position of the command field
#

sub _ps_cmdpos ($) {
    my($header) = @_;

    unless ($header =~ /^(.+\s)\S+\s*$/) {
	throw_error("bogus ps header", $header);
	return();
    }
    # we want the position strictly before the command field
    #      UID   PID  PPID  C    STIME TTY      TIME COMMAND
    #                                               ^
    return(length($1) - 1);
}

#
# internal parsing function for SysV-style ps
#

sub _ps_sysv () {
    my($pspid, $output, @lines, $cmdpos, $name, $pid, $ppid, $cmd, %ps);
    local($_);

    ($output, $pspid) =
	_ps_output(-x "/usr/bin/ps" ? "/usr/bin/ps" : "/bin/ps", "-ef")
	    or return();
    @lines = split(/\n/, $output);
    $_ = shift(@lines); # header
    $cmdpos = _ps_cmdpos($_) or return();
    foreach (@lines) {
	chomp($_);
	#      UID   PID  PPID  C    STIME TTY      TIME COMMAND
	#     root     0     0  0  Jan  1  ?        0:15 swapper
	unless (/^\s*(\S+)\s+(\d+)\s+(\d+)/) {
	    throw_warning("bogus ps line", $_);
	    next;
	}
	($name, $pid, $ppid) = ($1, $2, $3);
	next if $pid == $pspid;
	$cmd = substr($_, $cmdpos);
	$cmd =~ s/^\S*\s+//; # previous columns too big
	$ps{$pid} = [$pid, $name, $ppid, $cmd];
	bless($ps{$pid}, "LC::Sysinfo::Process");
    }
    bless(\%ps, "LC::Sysinfo::ProcessList");
    return(\%ps);
}

#
# internal parsing function for BSD-style ps
#

sub _ps_bsd () {
    my($pspid, $output, @lines, $cmdpos, $flagpos, $name, $pid, $ppid, $cmd, %ps);
    local($_);

    ($output, $pspid) =
	_ps_output(-x "/usr/bin/ps" ? "/usr/bin/ps" : "/bin/ps", "alxwww")
	    or return();
    @lines = split(/\n/, $output);
    $_ = shift(@lines); # header
    $cmdpos = _ps_cmdpos($_) or return();
    unless (/^(\s*\S+)/) {
	throw_error("bogus ps header", $_);
	return();
    }
    $flagpos = length($1);
    foreach (@lines) {
	chomp($_);
	# erase the flag field because it may collapse with uid
	#      F UID   PID  PPID CP PRI NI SZ RSS WCHAN  STAT TT TIME COMMAND
	# 2000015913  5903   281  0   1  0 44 320 select S    ?  0:00 rshd
	substr($_, 0, $flagpos) = " " x $flagpos;
	unless (/^\s+(\d+)\s+(\d+)\s+(\d+)/) {
	    throw_warning("bogus ps line", $_);
	    next;
	}
	($name, $pid, $ppid) = ($1, $2, $3);
	next if $pid == $pspid;
	$cmd = substr($_, $cmdpos);
	$cmd =~ s/^\S*\s+//; # previous columns too big
	$ps{$pid} = [$pid, LC::Cached::getpwuid($name)||$name, $ppid, $cmd];
	bless($ps{$pid}, "LC::Sysinfo::Process");
    }
    bless(\%ps, "LC::Sysinfo::ProcessList");
    return(\%ps);
}

#
# a kind of ps, returns the list of known pids in a hash, along with the
# corresponding information (without the "observing" ps)
#

sub ps () {
    my($osname);

    $osname = os->name;
    return(_ps_bsd()) if $osname eq "SunOS" or $osname eq "Linux";
    return(_ps_sysv());
}

#
# access to ps information via methods
#

{
    package LC::Sysinfo::ProcessList;
    use strict;
    use warnings;

    sub pids      : method { my($self) = @_; return(keys(%$self)); }
    sub processes : method { my($self) = @_; return(values(%$self)); }
    sub process   : method { my($self, $pid) = @_; return($self->{$pid}); }
}

#
# access to process fields via methods
#

{
    package LC::Sysinfo::Process;
    use strict;
    use warnings;

    sub pid     : method { my($self) = @_; return($self->[0]); }
    sub name    : method { my($self) = @_; return($self->[1]); }
    sub ppid    : method { my($self) = @_; return($self->[2]); }
    sub command : method { my($self) = @_; return($self->[3]); }
}

#
# nicely print ps data (for debugging)
#

sub _print_ps () {
    my($ps, $pid, $proc);

    $ps = ps() or return;
    printf("%-8s %5s %5s %s\n", qw(USER PID PPID COMMAND));
    foreach $pid (sort({$a <=> $b} $ps->pids)) {
	$proc = $ps->process($pid);
	printf("%-8s %5d %5d %s\n", $proc->name, $pid, $proc->ppid,
	       $proc->command);
    }
}

#
# returns all the pids matching a given regexp
#

sub pids ($) {
    my($regexp) = @_;
    my($ps, $proc, @pids);

    $ps = ps() or return();
    if (length($regexp)) {
	# real regexp filtering
	@pids = ();
	foreach $proc ($ps->processes) {
	    next unless $proc->command =~ /$regexp/;
	    push(@pids, $proc->pid);
	}
    } else {
	# all pids
	@pids = $ps->pids;
    }
    return(\@pids);
}

#+++############################################################################
#                                                                              #
# network interfaces information                                               #
#                                                                              #
#---############################################################################

#
# internal functions for _netintf_ifconfig
#

sub _addr2ip ($) {
    my($addr) = @_;
    return(join(".", unpack("C4", $addr)));
}

sub _ip2addr ($) {
    my($ip) = @_;
    return(pack("C4", split(/\./, $ip)));
}

#
# network interfaces information via ifconfig
#

sub _netintf_ifconfig () {
    my($output, @lines, %ni, $name, $mtu, $net, $addr);
    local($_);

    unless (@_Ifconfig) {
	@_Ifconfig = qw(/sbin/ifconfig);
    }
    $output = toutput(10, @_Ifconfig);
    return() unless defined($output);
    @lines = split(/\n/, $output);
    foreach (@lines) {
	# eth0  Link encap:Ethernet  HWaddr 00:A0:C9:43:A9:66
	#       inet addr:137.138.33.115 Bcast:137.138.255.255 Mask:255.255.0.0
	#       UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
	#       RX packets:19001385 errors:0 dropped:0 overruns:0
	#       TX packets:9414500 errors:0 dropped:0 overruns:0
        #       collisions:573029 txqueuelen:100 
	#       Interrupt:11 Base address:0x6000 
	next if /^\s*$/;
	if (/^(\S+)(.*)$/) {
	    $name = $1;
	    $_ = $2;
	    $ni{$name}[0] = $name;
	}
	$ni{$name}[1] = $1 if /\sMTU:(\d+)\b/;
	if (/\saddr:([\d\.]+)\s.*\bMask:([\d\.]+)\b/) {
	    $ni{$name}[2] = $1;
	    $ni{$name}[3] = _addr2ip(_ip2addr($1) & _ip2addr($2));
	    $ni{$name}[4] = $2;
	}
	if (/\sRX\spackets:(\d+)\s/) {
	    $ni{$name}[5] = $1;
	}
	if (/\sTX\spackets:(\d+)\s/) {
	    $ni{$name}[6] = $1;
	}
	if (/\scollisions:(\d+)\s/) {
	    $ni{$name}[7] = $1;
	}
    }
    foreach $name (keys(%ni)) {
	bless($ni{$name}, "LC::Sysinfo::NetworkInterface");
    }
    bless(\%ni, "LC::Sysinfo::NetworkInterfaceList");
    return(\%ni);
}

#
# network interfaces information via netstat -i
#

sub _netintf_netstat () {
    my($output, @lines, $dir, $path, %ni, $name, $mtu, $net, $addr);
    local($_);

    unless (@_Ifconfig) {
	foreach $dir (qw(etc sbin bin)) {
	    $path = "/$dir/netstat";
	    @_Ifconfig = ($path), last if -x $path;
	    $path = "/usr/$dir/netstat";
	    @_Ifconfig = ($path), last if -x $path;
	}
	unless (@_Ifconfig) {
	    throw_error("command not found", "netstat");
	    return();
	}
	push(@_Ifconfig, "-in");
    }
    $output = toutput(10, @_Ifconfig);
    return() unless defined($output);
    @lines = split(/\n/, $output);
    shift(@lines); # skip header
    foreach (@lines) {
	# Name  Mtu   Network     Address ...
	# network can be 127 or 127.0.0.0, depending on the system...
	unless (/^(\w+)\*?\s+(\d+)\s+(\S+)\s+(\S+)/) {
	    throw_warning("bogus netstat line", $_);
	    next;
	}
	($name, $mtu, $net, $addr) = ($1, $2, $3, $4);
	# Digital UNIX may have multiple lines per interface:
	#  ln0   1500  DLI         none               1203  7675 1057  1231 6173
	#  ln0   1500  <Link>      08:00:2b:30:91:86  1203  7675 1057  1231 6173
	#  ln0   1500  137.138     137.138.26.137     1203  7675 1057  1231 6173
	#  sl0*  296   <Link>                       0     0        0     0     0
	# AIX too but in addition fields can collapse :-(
	#  en0   1500  <Link>2.60.8c.f2.36.1b       2891     0  3926     0     0
	#  en0   1500  137.138     137.138.246.83   2891     0  3926     0     0
	# we assume that the last line is always the right one...
	$ni{$name} = [$name, $mtu, $addr, $net];
	bless($ni{$name}, "LC::Sysinfo::NetworkInterface");
    }
    bless(\%ni, "LC::Sysinfo::NetworkInterfaceList");
    return(\%ni);
}

#
# network interfaces information using ifconfig or netstat
#

sub netintf () {
    my($osname);

    $osname = os->name;
    return(_netintf_ifconfig()) if $osname eq "Linux";
    return(_netintf_netstat());
}

#
# access to netintf information via methods
#

{
    package LC::Sysinfo::NetworkInterfaceList;
    use strict;
    use warnings;

    sub names     : method { my($self) = @_; return(keys(%$self)); }
    sub intfs     : method { my($self) = @_; return(values(%$self)); }
    sub intf      : method { my($self, $name) = @_; return($self->{$name}); }
}

#
# access to interface fields via methods
#

{
    package LC::Sysinfo::NetworkInterface;
    use strict;
    use warnings;

    sub name : method { my($self) = @_; return($self->[0]); }
    sub mtu  : method { my($self) = @_; return($self->[1]); }
    sub addr : method { my($self) = @_; return($self->[2]); }
    sub net  : method { my($self) = @_; return($self->[3]); }
    sub mask : method { my($self) = @_; return($self->[4]); }
    sub recv : method { my($self) = @_; return($self->[5]); }
    sub sent : method { my($self) = @_; return($self->[6]); }
    sub coll : method { my($self) = @_; return($self->[7]); }
}

#
# nicely print netintf data (for debugging)
#

sub _print_netintf () {
    my($netintf, $name, $intf);

    $netintf = netintf() or return;
    printf("%-6s %-5s %-15s %-14s %-14s %s\n",
	   qw(Name Mtu Address Network Mask RX/TX/CO));
    foreach $name (sort($netintf->names)) {
	$intf = $netintf->intf($name);
	printf("%-6s %-5d %-15s %-14s %-14s %s\n",
	       $name, $intf->mtu,
	       $intf->addr, $intf->net,
	       (defined($intf->mask) ? $intf->mask : "??"),
	       (defined($intf->recv) ? $intf->recv : "??") . "/" .
	       (defined($intf->sent) ? $intf->sent : "??") . "/" .
	       (defined($intf->coll) ? $intf->coll : "??"));
    }
}

#+++############################################################################
#                                                                              #
# network connection information                                               #
#                                                                              #
#---############################################################################

#
# network connection information via netstat -an
#

sub netstat () {
    my($output, @lines, $dir, $path, $proto, @conns, $cinfo, %seen);
    local($_);

    unless (@_Netstat) {
	foreach $dir (qw(etc sbin bin)) {
	    $path = "/$dir/netstat";
	    @_Netstat = ($path), last if -x $path;
	    $path = "/usr/$dir/netstat";
	    @_Netstat = ($path), last if -x $path;
	}
	unless (@_Netstat) {
	    throw_error("command not found", "netstat");
	    return();
	}
	push(@_Netstat, "-an");
    }
    $output = toutput(10, @_Netstat);
    return() unless defined($output);
    @lines = split(/\n/, $output);
    $proto = "";
    @conns = ();
    foreach (@lines) {
	# skip header lines and detect UNIX domain sockets (end of parsing)
	next if /^Active Internet connections/;
	next if /^printing \d hashtable with \d+ buckets/;
	next if /^Proto Recv-Q Send-Q\s+Local Address/;
	next if /\sLocal Address\s+Remote Address\s/;
	next if /^[ -]+$/;
	next if /^\s*$/;
	last if /^Active UNIX domain sockets/;
	# parse meaningful lines
	if (m{ ^ (tcp[46]?|udp[46]?|raw) \s+ \d+ \s+ \d+ \s+
	       (\d+\.\d+\.\d+\.\d+ | \*) [\.\:] (\d+ | \*) \s+
	       (\d+\.\d+\.\d+\.\d+ | \*) [\.\:] (\d+ | \*) \s+
	       (\w*) \s* $ }x) {
	    # full line with proto and queue stats
	    $cinfo = [ $1, $2, $3, $4, $5, uc($6) ];
	} elsif (/^(TCP|UDP)\s*$/) {
	    # header line to mark connections of this protocol
	    $proto = lc($1);
	    next;
	} elsif (/^(TCP|UDP): IPv(4|6)\s*$/) {
	    # header line to mark connections of this protocol
	    $proto = lc($1) . $2;
	    next;
	} elsif ($proto =~ /^udp\d?$/ and
		 m{ ^ \s*
		    (\d+\.\d+\.\d+\.\d+ | \*) \. (\d+ | \*) \s+
                    (Idle|Unbound) \s* $ }x) {
	    # Solaris UDP (without remote information!)
	    $cinfo = [ $proto, $1, $2, "*", "*", "" ];
	} elsif ($proto =~ /^tcp\d?$/ and
		 m{ ^ \s*
	            (\d+\.\d+\.\d+\.\d+ | \*) \. (\d+ | \*) \s+
	            (\d+\.\d+\.\d+\.\d+ | \*) \. (\d+ | \*) \s+
                    \d+ \s+ \d+ \s+ \d+ \s+ \d+ \s+ 
	            (\w+) \s* $ }x) {
	    # Solaris TCP
	    $cinfo = [ $proto, $1, $2, $3, $4, uc($5) ];
	} else {
	    throw_warning("bogus netstat line", $_);
	    next;
	}
	# ignore IPv6 (everything is assumed to be IPv4)
	next if $cinfo->[0] =~ /^(tcp|udp)6$/;
	$cinfo->[0] =~ s/^(tcp|udp)4$/$1/;
	# replace 0.0.0.0 addresses by *
	$cinfo->[1] = "*" if $cinfo->[1] eq "0.0.0.0";
	$cinfo->[3] = "*" if $cinfo->[3] eq "0.0.0.0";
	# skip unbound or raw connections
	next if $cinfo->[0] eq "raw";
	next if $cinfo->[1] eq "*" and $cinfo->[2] eq "*" and
	        $cinfo->[3] eq "*" and $cinfo->[4] eq "*";
	# UDP connections don't have a state
	$cinfo->[5] = "" if $cinfo->[0] eq "udp";
	# remove duplicates (e.g. on AIX with tcp4 vs. tcp)
	next if $seen{join(" ", @$cinfo)}++;
	# remember this connection
	bless($cinfo, "LC::Sysinfo::NetworkConnection");
	push(@conns, $cinfo);
    }
    bless(\@conns, "LC::Sysinfo::NetworkConnectionList");
    return(\@conns);
}

#
# access to netstat information via methods
#

{
    package LC::Sysinfo::NetworkConnectionList;
    use strict;
    use warnings;

    sub connections  : method { my($self) = @_; return(@$self); }
}

#
# access to connection fields via methods
#

{
    package LC::Sysinfo::NetworkConnection;
    use strict;
    use warnings;

    sub proto        : method { my($self) = @_; return($self->[0]); }
    sub local_addr   : method { my($self) = @_; return($self->[1]); }
    sub local_port   : method { my($self) = @_; return($self->[2]); }
    sub remote_addr  : method { my($self) = @_; return($self->[3]); }
    sub remote_port  : method { my($self) = @_; return($self->[4]); }
    sub state        : method { my($self) = @_; return($self->[5]); }
}

#
# nicely print netstat data (for debugging)
#

sub _print_netstat () {
    my($netstat, $conn, $local, $remote);

    $netstat = netstat() or return;
    printf("%-6s %-22s %-22s %s\n", qw(Proto Local Remote State));
    foreach $conn ($netstat->connections) {
	$local  = $conn->local_addr  . ":" . $conn->local_port;
	$remote = $conn->remote_addr . ":" . $conn->remote_port;
	printf("%-6s %-22s %-22s %s\n", $conn->proto, $local, $remote, $conn->state);
    }
}

#+++############################################################################
#                                                                              #
# test bed                                                                     #
#                                                                              #
#---############################################################################

unless (defined(caller)) {
    my($obj);

    LC::Exception::Context->new->will_report_all;
    $obj = uname();
    printf("uname: %s %s %s %s %s\n\n", $obj->sysname, $obj->nodename,
	   $obj->release, $obj->version, $obj->machine);
    $obj = os();
    printf("os: %s %s\n\n", $obj->name, $obj->version);
    $obj = memory();
    printf("memory: %d kB used out of %d (%4.2f%%)\n\n",
	   $obj->used, $obj->size, ($obj->used / $obj->size * 100.0));
    $obj = swap();
    printf("swap: %d kB used out of %d (%4.2f%%)\n\n",
	   $obj->used, $obj->size, ($obj->used / $obj->size * 100.0));
    printf("uptime: %d seconds\n\n", uptime());
    $obj = loadavg();
    printf("load averages: %g %g %g\n\n",
	   $obj->last1, $obj->last5, $obj->last15);
    _print_df();
    print("\n");
    printf("du /bin = %d\n\n", du("/bin"));
    _print_ps();
    print("\n");
    _print_netintf();
    print("\n");
    _print_netstat();
}

1;

__END__

=head1 NAME

LC::Sysinfo - easy access to system-specific information

=head1 SYNOPSIS

    use LC::Sysinfo qw(ps);
    foreach $proc (ps->processes) {
        printf("%d %s\n", $proc->pid, $proc->command);
    }

=head1 DESCRIPTION

This module provides an easy and system independent access to system
information such as processes and filesystems. It provides several
functions returning objects that can then be inspected via methods.
The method names should be self descriptive.

Here are the available functions and methods:

=over

=item uname()

system information (methods: B<sysname()>, B<nodename()>,
B<release()>, B<version()> and B<machine()>)

=item os()

high-level system information: a meaningful name and a numerical
version (methods: B<name()> and B<version()>)

=item memory(), swap()

memory and swap information, in kB (methods: B<size()>, B<used()> and
B<free()>)

=item uptime()

system uptime, in seconds

=item loadavg()

system load averages for the last 1, 5 and 15 minutes (methods:
B<last1()>, B<last5()> and B<last15()>)

=item df()

file system information (methods: B<paths()>, B<filesystems()> and
B<filesystem(PATH)>; for a filesystem: B<dev()>, B<name()>, B<type()>,
B<path()>, B<size()> and B<used()>)

=item du(PATH)

return the disk space used by this directory and what it contains, in KB

=item ps()

process information (methods: B<pids()>, B<processes()> and
B<process(PID)>; for a process: B<pid()>, B<name()>, B<ppid()> and
B<command()>)

=item netintf()

network interface information (methods: B<names()>, B<intfs()> and
B<intf(NAME)>; for an interface: B<name()>, B<mtu()>, B<addr()>,
B<net()>, B<mask()>, B<recv()>, B<sent()> and B<coll()>)

=item netstat()

network connection information (method: B<connections()>; for a
connection: B<proto()>, B<local_addr()>, B<local_port()>,
B<remote_addr()>, B<remote_port()> and B<state()>)

=back

=head1 AUTHOR

Lionel Cons C<http://cern.ch/lionel.cons>, (C) CERN C<http://www.cern.ch>

=head1 VERSION

$Id: Sysinfo.pm,v 1.2 2008/06/30 15:27:49 poleggi Exp $

=head1 TODO

=over

=item * how to recognise a read-only filesystem like a CD?

=item * build a tree for pids?

=item * get more info about network interfaces using ifconfig (eg. flags)

=back

=cut
