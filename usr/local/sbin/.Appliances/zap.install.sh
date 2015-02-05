#!/bin/bash

# Set a sensible path for executables
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PROG=${0##*/}

#--------------------------------------------------------------------
# Ensure that only one instance is running
LOCKFILE=/tmp/$PROG.lock
if [ -f $LOCKFILE ]
then
    # The file exists so read the PID
    MYPID=$(< $LOCKFILE)
    [ -z "$(ps h -p $MYPID)" ] || exit 0
fi

# Make sure we remove the lock file at exit
trap "rm -f $LOCKFILE /tmp/$$*" EXIT
echo "$$" > $LOCKFILE            

#--------------------------------------------------------------------
# Specifying "-x" to the bash invocation = DEBUG
DEBUG=''
[[ $- = *x* ]] && DEBUG='-v'

#--------------------------------------------------------------------
# Determine the Linux distribution
LINUX_DIST=''
if [ -s /etc/debian_version ]
then
    LINUX_DIST='DEBIAN'
    PKG_INSTALL='apt-get install'
    PKG_REMOVE='apt-get --purge remove'
    PKG_UPGRADE='apt-get update; apt-get autoremove; apt-get dist-upgrade'
    PKG_QUERY='dpkg-query -W'
elif [ -s /etc/redhat-release ]
then
    LINUX_DIST='REDHAT'
    PKG_INSTALL='yum -y install'
    PKG_REMOVE='yum erase'
    PKG_UPGRADE='yum -y update'
    PKG_QUERY='rpm -q'
else
    echo "Unsupported/unknown Linux distribution"
    exit 1
fi

#--------------------------------------------------------------------
# Overall adjustments and additions to OS base install

# Adjust the mount options for the "/" partition
awk '$2 != "/" {print}' /etc/fstab > /tmp/$$.fstab
awk '$2 == "/" {print $1" / "$3" noatime,errors=remount-ro "$5" "$6}' /etc/fstab >> /tmp/$$.fstab
diff -u /tmp/$$.fstab /etc/fstab &> /dev/null
if [ $? -ne 0 ]
then
    cat /tmp/$$.fstab > /etc/fstab
    mount -o remount,noatime /
fi
rm -f /tmp/$$.fstab

# Remove the PPP packages
for P in ppp pppconfig pppoeconf
do
    $PKG_QUERY $P &> /dev/null
    [ $? -eq 0 ] && $PKG_REMOVE $P
done

# Install specific packages
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    PKG_LIST='firehol joe ethtool auditd'
else
    PKG_LIST='wget tcpdump system-config-firewall-tui'

    # Install the necessary redhat packages
    rpm -q rpmforge-release 2> /dev/null
    if [ $? -ne 0 ]
    then
        SRV_ARCH=$(uname -i)

        # Get "rpmforge" repository and install it
        curl -L 'http://pkgs.repoforge.org/rpmforge-release/rpmforge-release-0.5.3-1.el6.rf.x86_64.rpm' \
            > /tmp/rpmforge-release-0.5.3-1.el6.rf.x86_64.rpm   
        rpm --import http://apt.sw.be/RPM-GPG-KEY.dag.txt
        $PKG_INSTALL install /tmp/rpmforge-release-0.5.3-1.el6.rf.x86_64.rpm
    fi
fi
for P in $PKG_LIST
do
    $PKG_QUERY $P &> /dev/null
    [ $? -ne 0 ] && $PKG_INSTALL $P
done

# Adapt SSH configs
[ -z "$(grep '^[[:space:]]*PermitRootLogin.*no' /etc/ssh/sshd_config)" ] && sed -ie 's/^[[:space:]]*PermitRootLogin.*yes/PermitRootLogin no/' /etc/ssh/sshd_config
[ -z "$(grep '^PermitRootLogin no' /etc/ssh/sshd_config)" ] && echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
sed -ie 's/^[[:space:]]*Protocol.*/Protocol 2/' /etc/ssh/ssh_config
[ -z "$(grep '^[[:space:]]*Ciphers.*blowfish' /etc/ssh/ssh_config)" ] && echo 'Ciphers blowfish-cbc,aes256-cbc,aes192-cbc,aes128-cbc,3des-cbc,cast128-cbc,arcfour' >> /etc/ssh/ssh_config
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    if [ ! -s /etc/apt/sources.list.d/w-rouesnel-openssh-hpn-precise.list ]
    then
        # Activate the HPN patched SSH
        apt-add-repository ppa:w-rouesnel/openssh-hpn

        # Update and upgrade
        $PKG_UPGRADE
    fi

    if [ -z "$(grep '^TcpRcvBufPoll no' /etc/ssh/ssh_config)" ]
    then
        cat << EOT  >> /etc/ssh/ssh_config
# Enable large file transfers
TcpRcvBufPoll no
EOT
    fi
    if [ -z "$(grep '^TcpRcvBufPoll no' /etc/ssh/sshd_config)" ]
    then
        cat << EOT  >> /etc/ssh/sshd_config
# Enable large file transfers
TcpRcvBufPoll no
EOT
    fi
else
    # Update and upgrade
    $PKG_UPGRADE
fi

# Enable syslog auditing via rsyslog
if [ -s /etc/audisp/plugins.d/syslog.conf ]
then
    # Use the native syslog module for auditd
    #  (secure enough since we use rsyslog)
    if [ -z "$(grep 'active = yes' /etc/audisp/plugins.d/syslog.conf)" ]
    then
        sed -i 's/^active.*/active = yes/' /etc/audisp/plugins.d/syslog.conf
        service auditd restart
    fi
fi

# Tweaks as per https://github.com/B-LUC/AdminTools/blob/master/etc/rc.local
if [ -z "$(grep ETH /etc/rc.local)" ]
then
    cat << EOT >> /etc/rc.local

#-------------------------------------------------------------------------
# See: https://klaver.it/linux/sysctl.conf
echo '# Dynamically created sysctl.conf' > /tmp/sysctl.conf

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Improve system memory management
echo '# Increase size of file handles and inode cache' >> /tmp/sysctl.conf
[ $(sysctl -n fs.file-max) -ge 209708 ] && echo -n '# ' >> /tmp/sysctl.conf
echo 'fs.file-max = 209708' >> /tmp/sysctl.conf
echo '' >> /tmp/sysctl.conf

cat << EOSC >> /tmp/sysctl.conf
# Do less swapping
vm.swappiness = 10
EOSC

if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    dpkg-query -W xserver-xorg >/dev/null 2>&1
else
    rpm -q xorg-x11-server-Xorg >/dev/null 2>&1
fi
[ $? -ne 0 ] && cat << EOSC >> /tmp/sysctl.conf
# Tune the kernel scheduler for a server
# See: http://people.redhat.com/jeder/presentations/customer_convergence/2012-04-jeder_customer_convergence.pdf
kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000
kernel.sched_migration_cost = 1000000
EOSC
cat << EOSC >> /tmp/sysctl.conf

# Adjust disk write buffers
EOSC
SYSTEM_RAM=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ $SYSTEM_RAM -lt $((2 * 1024 * 1024)) ]
then
    cat << EOSC >> /tmp/sysctl.conf
# 60% disk cache under 2GB RAM
vm.dirty_ratio = 40
# Start writing at 10%
vm.dirty_background_ratio = 10
EOSC
elif [ $SYSTEM_RAM -lt $((8 * 1024 * 1024)) ]
then
    cat << EOSC >> /tmp/sysctl.conf
# 30% disk cache under 4GB RAM
vm.dirty_ratio = 30
# Start writing at 7%
vm.dirty_background_ratio = 7
EOSC
else
   cat << EOSC >> /tmp/sysctl.conf
# Hold up to 600MB in disk cache
vm.dirty_bytes = $((600 * 1024 * 1024))
# Start writing at 300MB
vm.dirty_background_bytes = $((300 * 1024 * 1024))
EOSC
fi

cat << EOSC >> /tmp/sysctl.conf
# Protect bottom 64k of memory from mmap to prevent NULL-dereference
# attacks against potential future kernel security vulnerabilities.
vm.mmap_min_addr = 65536

# Keep at least 64MB of free RAM space available
vm.min_free_kbytes = 65536

EOSC

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Tune overall security settings
cat << EOSC >> /tmp/sysctl.conf
# Enable /proc/\$pid/maps privacy so that memory relocations are not
# visible to other users.
kernel.maps_protect = 1

# Controls the System Request debugging functionality of the kernel
kernel.sysrq = 1

# Controls whether core dumps will append the PID to the core filename.
# Useful for debugging multi-threaded applications.
kernel.core_uses_pid = 1

# The contents of /proc/<pid>/maps and smaps files are only visible to
# readers that are allowed to ptrace() the process
kernel.maps_protect = 1

# Controls the maximum size of a message, in bytes
kernel.msgmnb = 65536

# Controls the default maxmimum size of a message queue
kernel.msgmax = 65536

# Automatic reboot
vm.panic_on_oom = 1
kernel.panic_on_oops = 1
kernel.unknown_nmi_panic = 1
kernel.panic_on_unrecovered_nmi = 1
kernel.panic = 60

# Stop low-level messages on console
kernel.printk = 4 4 1 7

EOSC

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Tune the network stack for security
cat << EOSC >> /tmp/sysctl.conf
# Prevent SYN attack, enable SYNcookies (they will kick-in when the max_syn_backlog reached)
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 5
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 4096

# Disables packet forwarding
net.ipv4.ip_forward = 0
net.ipv4.conf.all.forwarding = 0
net.ipv4.conf.default.forwarding = 0
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Disables IP source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Enable IP spoofing protection, turn on source route verification
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Enable Log Spoofed Packets, Source Routed Packets, Redirect Packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Decrease the time default value for tcp_fin_timeout connection
net.ipv4.tcp_fin_timeout = 30

# Decrease the time default value for connections to keep alive
net.ipv4.tcp_keepalive_time = 1800
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# Don't relay bootp
net.ipv4.conf.all.bootp_relay = 0

# Don't proxy arp for anyone
net.ipv4.conf.all.proxy_arp = 0

# Turn on SACK
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1

# Don't ignore directed pings
net.ipv4.icmp_echo_ignore_all = 0

# Disable timestamps
net.ipv4.tcp_timestamps = 0

# Enable ignoring broadcasts request
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Enable bad error message Protection
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Allowed local port range
net.ipv4.ip_local_port_range = 32768 60416

# Enable a fix for RFC1337 - time-wait assassination hazards in TCP
net.ipv4.tcp_rfc1337 = 1

EOSC

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Tune the network stack for performance
if [ -f /lib/modules/`uname -r`/kernel/net/ipv4/tcp_cubic.ko ]
then
    modprobe tcp_cubic
    cat << EOSC >> /tmp/sysctl.conf
# Use modern congestion control algorithm
net.ipv4.tcp_congestion_control = cubic

EOSC
fi

cat << EOSC >> /tmp/sysctl.conf
# Turn on the tcp_window_scaling
net.ipv4.tcp_window_scaling = 1

# Increase the maximum total buffer-space allocatable
net.ipv4.tcp_mem = 8388608 12582912 16777216
net.ipv4.udp_mem = 8388608 12582912 16777216

# Increase the maximum read-buffer space allocatable
net.ipv4.tcp_rmem = 8192 87380 16777216
net.ipv4.udp_rmem_min = 16384

# Increase the maximum write-buffer-space allocatable
net.ipv4.tcp_wmem = 8192 65536 16777216
net.ipv4.udp_wmem_min = 16384

# Increase the maximum and default receive socket buffer size
net.core.rmem_max=16777216
net.core.rmem_default=262144

# Increase the maximum and default send socket buffer size
net.core.wmem_max=16777216
net.core.wmem_default=262144

# Increase the tcp-time-wait buckets pool size
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_max_orphans = 1440000
net.ipv4.tcp_tw_recycle = 1
net.ipv4.tcp_tw_reuse = 1

# Increase the maximum memory used to reassemble IP fragments
net.ipv4.ipfrag_high_thresh = 512000
net.ipv4.ipfrag_low_thresh = 446464

# Increase the maximum amount of option memory buffers
net.core.optmem_max = 65536

# Increase the maximum number of skb-heads to be cached
#net.core.hot_list_length = 1024

# don't cache ssthresh from previous connection
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# Increase RPC slots
sunrpc.tcp_slot_table_entries = 32
sunrpc.udp_slot_table_entries = 32

# Increase size of RPC datagram queue length
net.unix.max_dgram_qlen = 50

# Don't allow the arp table to become bigger than this
net.ipv4.neigh.default.gc_thresh3 = 2048

# Tell the gc when to become aggressive with arp table cleaning.
# Adjust this based on size of the LAN. 1024 is suitable for most /24
# networks
net.ipv4.neigh.default.gc_thresh2 = 1024

# Adjust where the gc will leave arp table alone - set to 32.
net.ipv4.neigh.default.gc_thresh1 = 32

# Adjust to arp table gc to clean-up more often
net.ipv4.neigh.default.gc_interval = 30

# Increase TCP queue length
net.ipv4.neigh.default.proxy_qlen = 96
net.ipv4.neigh.default.unres_qlen = 6

# Enable Explicit Congestion Notification (RFC 3168), disable it if it
# doesn't work for you
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_reordering = 3

# How many times to retry killing an alive TCP connection
net.ipv4.tcp_retries2 = 15
net.ipv4.tcp_retries1 = 3

# Increase number of incoming connections
net.core.somaxconn = 32768

# Increase number of incoming connections backlog
net.core.netdev_max_backlog = 4096
net.core.dev_weight = 64

# This will enusre that immediatly subsequent connections use the new values
net.ipv4.route.flush = 1
net.ipv6.route.flush = 1

EOSC

if [ -d /etc/sysctl.d ]
then
    cat /tmp/sysctl.conf > /etc/sysctl.d/90-bluc.conf
elif [ -z "\$(grep 'Dynamically created' /etc/sysctl.conf)" ]
then
    cat /tmp/sysctl.conf >> /etc/sysctl.conf
fi
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    service procps start
else
    sysctl -p /etc/sysctl.conf
fi
EOT
fi

if [ -z "$(grep ETH /etc/rc.local)" ]
then
    cat << EOT >> /etc/rc.local

#-------------------------------------------------------------------------
for ETH in \$(grep ':' /proc/net/dev | cut -d: -f1 | egrep -v '(lo|tap)')
do
    # Disable Wake-On-LAN
    ethtool -s \$ETH wol d
    # Increase the TX queue length
    ifconfig \$ETH txqueuelen 2048
done
EOT
fi

if [ -z "$(grep tune2fs /etc/rc.local)" ]
then
    cat << EOT >> /etc/rc.local

#-------------------------------------------------------------------------
# Set readahead for disks
SECTORS=$((32 * 512))
# MegaRaid controller:
if [ -x /opt/MegaRAID/MegaCli/MegaCli64 ]
then
    SECTORS=\$(/opt/MegaRAID/MegaCli/MegaCli64 -AdpAllInfo -aAll -NoLog | awk '/^Max Data Transfer Size/ {print \$(NF-1)}')
fi
if [ -e /proc/mdstat ]
then
    for DEV in \$(awk '/^md/ {gsub(/\\[[0-9]\]/,"");print \$1" "\$5" "\$6}' /proc/mdstat)
    do
        RA=\$(blockdev --getra /dev/\$DEV)
        [ \$RA -ne \$SECTORS ] && blockdev --setra \$SECTORS /dev/\$DEV
    done
fi
for DEV in \$( ls /dev/[hs]d[a-z][0-9] | awk '{sub(/\\/dev\\//,"");printf "%s ",\$1}')
do
    RA=\$(blockdev --getra /dev/\$DEV)
    [ \$RA -ne \$SECTORS ] && blockdev --setra \$SECTORS /dev/\$DEV
done
for DEV in \$( ls /dev/mapper/* | awk '{sub(/\\/dev\/mapper\\//,"");printf "%s ",\$1}')
do
    [ "T\$DEV" = 'Tcontrol' ] && continue
    RA=\$(blockdev --getra /dev/mapper/\$DEV)
    [ \$RA -ne \$SECTORS ] && blockdev --setra \$SECTORS /dev/mapper/\$DEV
done
if [ -d /dev/etherd ]
then
    for DEV in \$(ls /dev/etherd/e[0-9].[0-9]p[0-9] | awk'{sub(/\\/dev\\/etherd\\//,"");printf "%s ",\$1}')
    do
        [ "T\$DEV" = 'Tcontrol' ] && continue
        RA=\$(blockdev --getra /dev/etherd/\$DEV)
        [ \$RA -ne \$SECTORS ] && blockdev --setra \$SECTORS /dev/etherd/\$DEV
    done
fi

# Filesystem errors force a reboot
for FS in \$(awk '/ext[234]/ {print \$1}' /proc/mounts)
do
    tune2fs -e panic -c 5 -i 1m \$FS
done
EOT
fi

if [ -z "$(grep IS_VIRTUAL /etc/rc.local)" ]
then
    cat << EOT >> /etc/rc.local

#-------------------------------------------------------------------------
# Set the correct I/O scheduler
# Tweak the cfq scheduler
IS_VIRTUAL=0
if [ ! -z "\$(grep -m1 VMware /proc/scsi/scsi)" -o ! -z "\$(grep 'DMI:.*VMware' /var/log/dmesg)" ]
then
    IS_VIRTUAL=1
elif [ ! -z "\$(egrep 'KVM|QEMU' /proc/cpuinfo)" -o ! -z "\$(grep Bochs /sys/class/dmi/id/bios_vendor)" ]
then
    IS_VIRTUAL=2
elif [ ! -z "\$(grep '^flags[[:space:]]*.*hypervisor' /proc/cpuinfo)" ]
then
    IS_VIRTUAL=3
fi
cd /sys/block
for DEV in [vhs]d?
do
    [ -w \${DEV}/queue/nr_requests ] && echo 512 > \${DEV}/queue/nr_requests
    if [ -w \${DEV}/queue/read_ahead_kb ]
    then
        [ \$(< \${DEV}/queue/read_ahead_kb) -lt 2048 ] && echo 2048 > \${DEV}/queue/read_ahead_kb
    fi
    if [ \$IS_VIRTUAL -eq 0 ]
    then
        [ -w \${DEV}/queue/scheduler ] && echo cfq > \${DEV}/queue/scheduler
        [ -w \${DEV}/device/queue_depth ] && echo 1 > \${DEV}/device/queue_depth
        # See: http://www.nextre.it/oracledocs/ioscheduler_03.html
        [ -w \${DEV}/queue/iosched/slice_idle ] && echo 0 > \${DEV}/queue/iosched/slice_idle
        [ -w \${DEV}/queue/iosched/max_depth ] && echo 64 > \${DEV}/queue/iosched/max_depth
        [ -w \${DEV}/queue/iosched/queued ] && echo 8 > \${DEV}/queue/iosched/queued
        # See: http://www.linux-mag.com/id/7572/2
        [ -w \${DEV}/queue/iosched/quantum ] && echo 32 > \${DEV}/queue/iosched/quantum
        # See: http://lkml.indiana.edu/hypermail/linux/kernel/0906.3/02344.html
        # (favors writes over reads)
        [ -w \${DEV}/queue/iosched/slice_async ] && echo 10 > \${DEV}/queue/iosched/slice_async
        [ -w \${DEV}/queue/iosched/slice_sync ] && echo 100 > \${DEV}/queue/iosched/slice_sync
        # See: http://oss.oetiker.ch/rrdtool-trac/wiki/TuningRRD
        [ -w \${DEV}/queue/nr_requests ] && echo 512 > \${DEV}/queue/nr_requests
    else
        # Use "noop" for VMware and KVM guests
        [ -w \${DEV}/queue/scheduler ] && echo noop > \${DEV}/queue/scheduler
        # As per http://kb.vmware.com/selfservice/microsites/search.do?language=en_US&cmd=displayKC&externalId=1009465
        [ -w \${DEV}/device/timeout ] && echo 180 > \${DEV}/device/timeout
    fi
done
EOT
fi

#--------------------------------------------------------------------
# Setup a "zap" account (with a simple password for now)
if [ -z "$(getent passwd zap)" ]
then
    useradd -s /bin/bash -c 'ZAP Daemon' -m zap
    echo 'zap:zap' | chpasswd
    # Unlock the account and force a password change at next login
    passwd -u zap
    chage -d 0 zap
fi

#--------------------------------------------------------------------
# Install the necessary java runtime environment
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    if [ ! -s /etc/apt/sources.list.d/duinsoft.list ]
    then
        cat << EOT > /etc/apt/sources.list.d/duinsoft.list
# See: http://www.duinsoft.nl/packages.php?t=en
deb http://www.duinsoft.nl/pkg debs all
EOT
    fi
    [ -z "$(apt-key list | grep 5CB26B26)" ] && apt-key adv --keyserver keys.gnupg.net --recv-keys 5CB26B26
    $PKG_UPGRADE
    $PKG_INSTALL update-sun-jre
else
    wget $DEBUG -o /tmp/$$.log -O /tmp/$$.html \
      http://www.java.com/en/download/linux_manual.jsp
    if [ $? -ne 0 ]
    then
        echo "Can't determine download link for ZAP"
        cat /tmp/$$.log
        exit 1
    fi
    DNLINK=$(grep -m 1 'x64 RPM' /tmp/$$.html | sed -e 's/^.*href="//;s/" onclick.*//')
    if [ -z "$DNLINK" ]
    then
        echo "Can't determine download link for ZAP"
        less /tmp/$$.html
        exit 1
    fi
    wget $DEBUG -o /tmp/$$.log -O /usr/local/src/sunjre.rpm $DNLINK
    mkdir -p /usr/java
    cd /usr/java
    rpm $DEBUG -Uh /usr/local/src/sunjre.rpm
fi
exit 0

#--------------------------------------------------------------------
# Determine the download link for the newest ZAP tarball
wget $DEBUG -o /tmp/$$.log -O /tmp/$$.html \
  http://sourceforge.net/projects/zaproxy/files 
if [ $? -ne 0 ]
then
    echo "Can't determine download link for ZAP"
    cat /tmp/$$.log
    exit 1
fi
DNLINK=$(grep '[Tt]he latest release' /tmp/$$.html | sed -e 's/^.*href="//;s/".*//;s@/$@@')
if [ -z "$DNLINK" ]
then
    echo "Can't determine download link for ZAP"
    less /tmp/$$.html
    exit 1
fi
DNLINK=${DNLINK/https/http}

VERSION=${DNLINK##*/}
# Example:
#  http://sourceforge.net/projects/zaproxy/files/2.3.1/ZAP_2.3.1_Linux.tar.gz/download
TARBALL="ZAP_${VERSION}_Linux.tar.gz"
URL="$DNLINK/$TARBALL/download"

# Download the newest tarball
wget $DEBUG -o /tmp/$$.log --no-check-certificate \
  -O /usr/local/src/$TARBALL "$URL"
if [ $? -ne 0 ]
then
    echo "ZAP download failed"
    cat /tmp/$$.log
    exit 1
fi

# Untar it
cd /home/zap
tar $DEBUG -xzf /usr/local/src/$TARBALL
chown -R zap ZAP*
rm -f bin
ln -s ZAP_${VERSION} bin
chown zap bin

#--------------------------------------------------------------------
# Create the invocation script and enable it
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    cat << EOT > /etc/init.d/zap
#! /bin/sh
### BEGIN INIT INFO
# Provides:		zap
# Required-Start:	\$remote_fs \$network \$syslog
# Required-Stop:	\$remote_fs \$network \$syslog
# Default-Start:	2 3 4 5
# Default-Stop:		0 1 6
# Short-Description:	Start zap at boot time
# Description:		ZAP, the OWASP Zero-Attack-Proxy
### END INIT INFO

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
NAME=zap
USER=zap
DESC=ZAP

test -e /home/zap/bin/zap.sh || exit 0
test -f /lib/lsb/init-functions || exit 1
. /lib/lsb/init-functions

# Set zap options
# 1. Run as daemon (no UI)
# 2. Listen on Ethernet interface instead of loopback
ZAP_OPTS='-daemon -config proxy.ip='\`ifconfig eth0 | sed -n "s/.*inet addr:\([0-9.]*\).*/\1/p"\`

set -e

case "\$1" in
	start)
		log_begin_msg "Starting \$DESC."
		if [ -z "\`netstat  -ntap | grep '8080.*java'\`" ]
		then
			su - zap -c "nohup zap.sh \$ZAP_OPTS &"
			while [ -z "\`netstat  -ntap | grep '8080.*java'\`" ]
			do
				echo -n '.'
				sleep 1
			done
			echo ' done'
		else
			echo "\$DESC already running."
		fi
		log_end_msg 0
		;;

	stop)
		log_begin_msg "Stopping \$DESC."
		killall java
		while [ ! -z "\`netstat  -ntap | grep '8080.*java'\`" ]
		do
			echo -n '.'
			sleep 1
		done
		echo ' done'
		log_end_msg 0
		;;

	restart)
		set +e
		\$0 stop
		\$0 start
		set -e
		;;

	status)
		if [ -z "\`netstat  -ntap | grep '8080.*java'\`" ]
		then
			log_failure_msg "\$DESC daemon is NOT running"
			exit 1
		else
			log_success_msg "\$DESC daemon is running."
		fi
		;;		

	*)
		N=/etc/init.d/\$NAME
		echo "Usage: \$N {start|stop|restart|status}" >&2
		exit 1
		;;
esac

exit 0
EOT
else
    cat << EOT > /etc/init.d/zap
#!/bin/bash
#
# zap        Startup script for zap.
#
# chkconfig: 2345
# description: ZAP is the Zero-Access-Proxy server
### BEGIN INIT INFO
# Provides: \$zap
# Required-Start: \$local_fs \$network
# Required-Stop: \$local_fs \$network
# Default-Start:  2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: Zero-Access_Proxy
# Description: ZAP is the Zero-Access-Proxy server
### END INIT INFO

# Source function library.
. /etc/init.d/functions

RETVAL=0
PIDFILE=/var/run/zap.pid

prog=zap
exec=/home/zap/bin/zap.sh
lockfile=/var/lock/subsys/\$prog

# Set zap options
# 1. Run as daemon (no UI)
# 2. Listen on Ethernet interface instead of loopback
ZAP_OPTS='-daemon -config proxy.ip='\`ifconfig eth0 | sed -n "s/.*inet addr:\([0-9.]*\).*/\1/p"\`

# Source config
if [ -f /etc/sysconfig/\$prog ] ; then
    . /etc/sysconfig/\$prog
fi

start() {
	[ -x \$exec ] || exit 5

	umask 077

        echo -n "Starting ZAP: "
	if [ -z "\`netstat  -ntap | grep '8080.*java'\`" ]
	then
		su - zap -c "nohup zap.sh \$ZAP_OPTS &"
		while [ -z "\`netstat  -ntap | grep '8080.*java'\`" ]
		do
			echo -n '.'
			sleep 1
		done
		echo ' done'
	else
		echo "ZAP already running."
	fi
        return 0
}
stop() {
	echo -n "Stopping ZAP."
	killall java
	while [ ! -z "\`netstat  -ntap | grep '8080.*java'\`" ]
	do
		echo -n '.'
		sleep 1
	done
	echo ' done'
        return 0
}
rhstatus() {
	if [ -z "\`netstat  -ntap | grep '8080.*java'\`" ]
	then
		echo "ZAP daemon is NOT running"
		return 1
	else
		echo "ZAP daemon is running."
		return 0
	fi
}
restart() {
        stop
        start
}

case "\$1" in
  start)
        start
        ;;
  stop)
        stop
        ;;
  restart)
        restart
        ;;
  reload)
        exit 3
        ;;
  force-reload)
        restart
        ;;
  status)
        rhstatus
        ;;
  condrestart|try-restart)
        rhstatus >/dev/null 2>&1 || exit 0
        restart
        ;;
  *)
        echo "Usage: \$0 {start|stop|restart|condrestart|try-restart|reload|force-reload|status}"
        exit 3
esac

exit \$?
EOT
fi
chmod 744 /etc/init.d/zap
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    update-rc.d zap defaults
else
    chkconfig --add zap
    chkconfig zap on
fi
/etc/init.d/zap start

#--------------------------------------------------------------------
# Adapt the firewall
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    cat << EOT > /etc/firehol/firehol.conf
#!/sbin/firehol
# : firehol.sh,v 1.273 2008/07/31 00:46:41 ktsaou Exp \$
#
# This config will have the same effect as NO PROTECTION!
# Everything that found to be running, is allowed.
# YOU SHOULD NEVER USE THIS CONFIG AS-IS.
#
# Date: Fri Oct 15 07:38:13 EDT 2010 on host linux2
#
# IMPORTANT:
# The TODOs bellow, are *YOUR* to-dos!
#
version 5

# Enable port redirect 80 -> 8080
#redirect to 8080 inface eth0 proto tcp dport 80

# Fix some TOS values
# See: http://www.docum.org/docum.org/faq/cache/49.html
# and: https://github.com/ktsaou/firehol/blob/master/sbin/firehol.in
iptables -t mangle -N ackfix
iptables -t mangle -A ackfix -m tos ! --tos Normal-Service -j RETURN
iptables -t mangle -A ackfix -p tcp -m length --length 0:128 -j TOS --set-tos Mi
nimize-Delay
iptables -t mangle -A ackfix -p tcp -m length --length 128: -j TOS --set-tos Max
imize-Throughput
iptables -t mangle -A ackfix -j RETURN
iptables -t mangle -I POSTROUTING -p tcp -m tcp --tcp-flags SYN,RST,ACK ACK -j a
ckfix

iptables -t mangle -N tosfix
iptables -t mangle -A tosfix -p tcp -m length --length 0:512 -j RETURN
iptables -t mangle -A tosfix -m limit --limit 2/s --limit-burst 10 -j RETURN
iptables -t mangle -A tosfix -j TOS --set-tos Maximize-Throughput
iptables -t mangle -A tosfix -j RETURN
iptables -t mangle -I POSTROUTING -p tcp -m tos --tos Minimize-Delay -j tosfix

# Protect against SYN attacks
# See http://www.ramil.pro/2013/07/linux-syn-attacks.html
iptables -t mangle -I PREROUTING -p tcp -m tcp -m state --state NEW -m tcpmss !
--mss 536:65535 -j DROP

### INPUT and OUTPUT rules
# The LAN
interface eth0 LAN
        #-----------------------------------------------------------------
        # Protect against attacks as best as we can
        policy reject
        protection strong 10/sec 10
        protection reverse strong
        #-----------------------------------------------------------------
        # Allow specific traffic only
        server ssh accept
        server custom zap tcp/8080 default accept
        client all accept
EOT
else
    lokkit -p 8080:tcp
fi

#--------------------------------------------------------------------
# We are done
exit 0
