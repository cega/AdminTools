#!/bin/bash
################################################################
# (c) Copyright 2013 B-LUC Consulting and Thomas Bullinger
#
# Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
################################################################

#--------------------------------------------------------------------
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
[[ $- = *x* ]] && DEBUG='-x'

#--------------------------------------------------------------------
# This host and domain
THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
THISDOMAIN=${THISHOST#*.}

# Function to convert netmasks into CIDR notation and back
# See: https://forums.gentoo.org/viewtopic-t-888736-start-0.html
function mask2cdr ()
{
   # Assumes there's no "255." after a non-255 byte in the mask
   local x=${1##*255.}
   set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x})*2 )) ${x%%.*}
   x=${1%%$3*}
   echo $(( $2 + (${#x}/4) ))
}
function cdr2mask ()
{
   # Number of args to shift, 255..255, first non-255 byte, zeroes
   set -- $(( 5 - ($1 / 8) )) 255 255 255 255 $(( (255 << (8 - ($1 % 8))) & 255 )) 0 0 0
   [ $1 -gt 1 ] && shift $1 || shift
   echo ${1-0}.${2-0}.${3-0}.${4-0}
}

#--------------------------------------------------------------------
# Determine the Linux distribution
LINUX_DIST=''
INSTALL_PROG=''
if [ -s /etc/debian_version ]
then
    LINUX_DIST='DEBIAN'
    INSTALL_PROG='apt-get'
elif [ -s /etc/redhat-release ]
then
    LINUX_DIST='REDHAT'
    INSTALL_PROG='yum'

    # Install the necessary redhat packages
    $INSTALL_PROG list > /tmp/redhat.packages.list
    SRV_ARCH=$(uname -i)
    if [ -z "$(grep '^rpmforge-release.'$SRV_ARCH /tmp/redhat.packages.list)" ]
    then
        # Get "rpmforge" repository and install it
        curl -L 'http://pkgs.repoforge.org/rpmforge-release/rpmforge-release-0.5.3-1.el6.rf.x86_64.rpm' \
            > /tmp/rpmforge-release-0.5.3-1.el6.rf.x86_64.rpm	
        rpm --import http://apt.sw.be/RPM-GPG-KEY.dag.txt
        $INSTALL_PROG install /tmp/rpmforge-release-0.5.3-1.el6.rf.x86_64.rpm
        # Reget the list of install packages
        $INSTALL_PROG list > /tmp/redhat.packages.list
    fi
else
    echo "Unsupported Linux distribution"
    exit 1
fi

# Is this a virtual guest?
#IS_VIRTUAL=0
#if [ ! -z "$(grep -m1 VMware /proc/scsi/scsi)" ]
#then
#    IS_VIRTUAL=1
#elif [ ! -z "$(grep QEMU /proc/cpuinfo)" -a ! -z "$(grep Bochs /sys/class/dmi/id/bios_vendor)" ]
#then
#    IS_VIRTUAL=2
#elif [ ! -z "$(grep '^flags[[:space:]]*.*hypervisor' /proc/cpuinfo)" ]
#then
#    IS_VIRTUAL=3
#fi

#--------------------------------------------------------------------
# Remove the PPP packages
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    $INSTALL_PROG --purge remove ppp pppconfig pppoeconf
else
    $INSTALL_PROG erase ppp pppconfig pppoeconf
fi

#--------------------------------------------------------------------
# Install specific packages
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    $INSTALL_PROG install sudo xtables-addons-dkms firehol joe ethtool linuxlogo libunix-syslog-perl openntpd libio-socket-ssl-perl sendemail chkrootkit perltidy haveged
    source /etc/lsb-release
    if [ ${DISTRIB_RELEASE%.*} -lt 14 ]
    then
        $INSTALL_PROG install python-software-properties
    else
        $INSTALL_PROG install software-properties-common
    fi

    # Get some updated packages from 3rd party
    wget http://neuro.debian.net/lists/${DISTRIB_CODENAME}.us-nh.full -O /etc/apt/sources.list.d/neurodebian.sources.list
    apt-key adv --recv-keys --keyserver hkp://pgp.mit.edu:80 0xA5D32F012649A5A9
else
    $INSTALL_PROG install sudo vim-minimal ethtool perltidy system-config-network-tui system-config-firewall-tui
fi

#--------------------------------------------------------------------
# Activate the HPN patched SSH
[ "T$LINUX_DIST" = 'TDEBIAN' ] && apt-add-repository ppa:w-rouesnel/openssh-hpn

if [ $(grep -c '^processor' /proc/cpuinfo) -gt 1 ]
then
    # Install multi-core versions of gzip and bzip2
    $INSTALL_PROG install pigz pbzip2
fi

# Update and upgrade
$INSTALL_PROG update
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    $INSTALL_PROG autoremove
    $INSTALL_PROG dist-upgrade
fi

#--------------------------------------------------------------------
# Adapt SSH configs (for security)
# Disable password-based root logins
[ -z "$(grep '^[[:space:]]*PermitRootLogin.*without-password' /etc/ssh/sshd_config)" ] && sed -ie 's/^[[:space:]]*PermitRootLogin.*yes/PermitRootLogin without-password/' /etc/ssh/sshd_config
[ -z "$(grep '^PermitRootLogin without-password' /etc/ssh/sshd_config)" ] && echo 'PermitRootLogin without-password' >> /etc/ssh/sshd_config
# Only use SSH protocol 2 to avoid man-in-middle attacks
sed -ie 's/^[[:space:]]*Protocol.*/Protocol 2/' /etc/ssh/ssh_config
# Use secure and fast ciphers only
[ -z "$(grep '^[[:space:]]*Ciphers.*blowfish' /etc/ssh/ssh_config)" ] && echo 'Ciphers blowfish-cbc,aes256-cbc,aes192-cbc,aes128-cbc,3des-cbc,cast128-cbc,arcfour' >> /etc/ssh/ssh_config

if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    for F in ssh_config sshd_config
    do
        if [ -z "$(grep '^TcpRcvBufPoll no' /etc/ssh/$F)" ]
        then
        cat << EOT >> /etc/ssh/$F
# Enable large file transfers
TcpRcvBufPoll no
EOT
        fi
    done
fi

#--------------------------------------------------------------------
# Adjust the mount options for any ext{3|4} partition
# See http://www.howtoforge.com/reducing-disk-io-by-mounting-partitions-with-noatime
awk 'substr($3,1,3) != "ext" {print}' /etc/fstab > /tmp/$$.fstab
awk 'substr($3,1,3) == "ext" {print $1" "$2" "$3" noatime,errors=remount-ro "$5" "$6}' /etc/fstab >> /tmp/$$.fstab
diff -u /tmp/$$.fstab /etc/fstab &> /dev/null
[ $? -ne 0 ] && cat /tmp/$$.fstab > /etc/fstab
rm -f /tmp/$$.fstab
        
#--------------------------------------------------------------------
# Adapt firehol.conf
if [ -d /etc/firehol ]
then
    # Adapt firehol config
    if [ -z "$(grep bellow /etc/firehol/firehol.conf)" ]
    then
        LOCALIP=$(ifconfig eth0 | sed -n "s/.*inet addr:\([0-9.]*\).*/\1/p")
        LOCALMASK=$(ifconfig eth0 | sed -n -e 's/.*Mask:\(.*\)$/\1/p')
        # From: http://www.routertech.org/viewtopic.php?t=1609
        l="${LOCALIP%.*}";r="${LOCALIP#*.}";n="${LOCALMASK%.*}";m="${LOCALMASK#*.}"
        LOCALNET=$((${LOCALIP%%.*}&${LOCALMASK%%.*})).$((${r%%.*}&${m%%.*})).$((${l##*.}&${n##*.})).$((${LOCALIP##*.}&${LOCALMASK##*.}))
        CIDRMASK=$(mask2cdr $LOCALMASK)

        # Install packages for Geo-based firewall rules
        apt-get install xtables-addons-dkms geoip-database libtext-csv-perl unzip

        cat << EOT > /etc/firehol/firehol.conf
#!/sbin/firehol
# : firehol.sh,v 1.273 2008/07/31 00:46:41 ktsaou Exp $
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

bluc='24.97.81.129'
home_net='${LOCALNET}/${CIDRMASK}'

# Private server ports
#server_xwaadmin_ports="tcp/7071"
#client_xwaadmin_ports="default"

# Fix some TOS values
# See: http://www.docum.org/docum.org/faq/cache/49.html
# and: https://github.com/ktsaou/firehol/blob/master/sbin/firehol.in
iptables -t mangle -N ackfix
iptables -t mangle -A ackfix -m tos ! --tos Normal-Service -j RETURN
iptables -t mangle -A ackfix -p tcp -m length --length 0:128 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A ackfix -p tcp -m length --length 128: -j TOS --set-tos Maximize-Throughput
iptables -t mangle -A ackfix -j RETURN
iptables -t mangle -I POSTROUTING -p tcp -m tcp --tcp-flags SYN,RST,ACK ACK -j ackfix

iptables -t mangle -N tosfix
iptables -t mangle -A tosfix -p tcp -m length --length 0:512 -j RETURN
iptables -t mangle -A tosfix -m limit --limit 2/s --limit-burst 10 -j RETURN
iptables -t mangle -A tosfix -j TOS --set-tos Maximize-Throughput
iptables -t mangle -A tosfix -j RETURN
iptables -t mangle -I POSTROUTING -p tcp -m tos --tos Minimize-Delay -j tosfix

# See also /usr/local/sbin/LocalHealthCheck.sh
#  for database updates
action chain GEOIP_GEN ACCEPT
iptables -I GEOIP_GEN -m geoip --src-cc CN,UA,RU,KP -j DROP
iptables -I GEOIP_GEN -m geoip --src-cc CN,UA,RU,KP -j LOG --log-prefix "Geo-based rejection "
iptables -I GEOIP_GEN -m geoip --dst-cc CN,UA,RU,KP -j DROP
iptables -I GEOIP_GEN -m geoip --dst-cc CN,UA,RU,KP -j LOG --log-prefix "Geo-based rejection "
# Do not allow any incoming SSDP traffic
#iptables -I GEOIP_GEN -p udp -m udp --sport 1900 -j DROP
#iptables -I GEOIP_GEN -p udp -m udp --sport 1900 -j LOG --log-prefix "SSDP rejection "
# Limit the incoming traffic (needs tuning for seconds/hitcount)
#iptables -I GEOIP_GEN 7 -m recent --set --name geoip_recent 
#iptables -I GEOIP_GEN 8 -m recent --update --seconds 5 --hitcount 20 --name geoip_recent --rsource RETURN  
# Limit the incoming traffic (needs tuning for limts)
#iptables -I GEOIP_GEN_LIMIT 7 -m limit --limit 120/s --limit-burst 12 -j ACCEPT

# Interface No 1a - frontend (public).
# The purpose of this interface is to control the traffic
# on the eth0 interface with IP ${LOCALIP} (net: "${LOCALNET}/${CIDRMASK}").
interface eth0 internal_1 src "\${home_net}" dst ${LOCALIP}

        # The default policy is DROP. You can be more polite with REJECT.
        # Prefer to be polite on your own clients to prevent timeouts.
        policy drop

        # If you don't trust the clients behind eth0 (net "${LOCALNET}/${CIDRMASK}"),
        # add something like this.
        protection strong 75/sec 50

        # Here are the services listening on eth0.
        # TODO: Normally, you will have to remove those not needed.
        server "ssh" accept src "\${home_net} \${bluc}"
        #server "smtp imaps smtps https" accept
        server ping accept

        # The following means that this machine can REQUEST anything via eth0.
        # TODO: On production servers, avoid this and allow only the
        #       client services you really need.
        client all accept

# Interface No 1b - frontend (public).
# The purpose of this interface is to control the traffic
# from/to unknown networks behind the default gateway
interface eth0 external_1 src not "\${home_net}" dst ${LOCALIP}

        # The default policy is DROP. You can be more polite with REJECT.
        # Prefer to be polite on your own clients to prevent timeouts.
        policy drop

        # If you don't trust the clients behind eth0 (net not "\${UNROUTABLE_IPS} ${LOCALNET}/${CIDRMASK}"),
        # add something like this.
        protection strong 75/sec 50

        # Here are the services listening on eth0.
        # TODO: Normally, you will have to remove those not needed.
        server "ssh" accept src "\${bluc}"
        #server "smtp imaps smtps http https" GEOIP_GEN
        server ping GEOIP_GEN

        # Portscan defense
        iptables -A in_external_1 -m psd -j LOG --log-prefix 'IN-ISP-Portscan'
        iptables -A in_external_1 -m psd -j DROP

        # The following means that this machine can REQUEST anything via eth0.
        # TODO: On production servers, avoid this and allow only the
        #       client services you really need.
        client all GEOIP_GEN
EOT
    fi
    sed -ie 's/^[[:space:]]*START_FIREHOL.*/START_FIREHOL=YES/' /etc/default/firehol
elif [ -x /usr/bin/system-config-firewall-tui ]
then
    system-config-firewall-tui
fi

#--------------------------------------------------------------------
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    # Install the audit daemon
    # (configuration - see /etc/rc.local)
    $INSTALL_PROG install auditd

    # Enable syslog via rsyslog
    if [ -s /etc/audisp/plugins.d/syslog.conf ]
    then
        # Use the native syslog module for auditd
        #  (secure enough since we use rsyslog)
        sed -i -e 's/^active.*/active = yes/' /etc/audisp/plugins.d/syslog.conf

        service auditd restart
    fi
    if [ -d /etc/rsyslog.d ]
    then
        cat << EOT > /etc/rsyslog.d/40-auditd.conf
# Ex.: Suppress anything but "forbidden" messages
#if (\$programname contains 'audispd') and (not (\$rawmsg contains ' forbidden')) then ~
EOT
    fi
fi

#--------------------------------------------------------------------
if [ -z "$(grep opa /etc/passwd)" ]
then
    # Create the operator account
    useradd -s /bin/bash -m -c 'Linux Operator' opa
    passwd opa
else
    # Give the "opa" account a meaningful full name
    [ -z "$(getent passwd opa)" ] || chfn -f 'Linux Operator' opa
fi
if [ -d /etc/sudoers.d ]
then
    # Make sure that "opa" can execute "sudo"
    cat << EOT > /etc/sudoers.d/opa
## Allow opa to run any commands anywhere 
opa    ALL=(ALL)       ALL
EOT
    chmod 440 /etc/sudoers.d/opa
fi

#--------------------------------------------------------------------
# Tweak system for security and performance
if [ -z "$(grep IS_VIRTUAL /etc/rc.local)" ]
then
    # Make sure that rc.local runs in "bash"
    sed -i -e 's@bin/sh -e@bin/bash@;/^exit/d' /etc/rc.local

    # Expand /etc/rc.local
    cat << EORC >> /etc/rc.local
#-------------------------------------------------------------------------
# See: https://klaver.it/linux/sysctl.conf
echo '# Dynamically created sysctl.conf' > /tmp/sysctl.conf

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Improve system memory management
echo '# Increase size of file handles and inode cache' >> /tmp/sysctl.conf
[ \$(sysctl -n fs.file-max) -ge 209708 ] && echo -n '# ' >> /tmp/sysctl.conf
echo 'fs.file-max = 209708' >> /tmp/sysctl.conf
echo '' >> /tmp/sysctl.conf

cat << EOSC >> /tmp/sysctl.conf
# Do less swapping
vm.swappiness = 10
EOSC

rpm -q xorg-x11-server-Xorg >/dev/null 2>&1
[ \$? -ne 0 ] && cat << EOSC >> /tmp/sysctl.conf
# Tune the kernel scheduler for a server
# See: http://people.redhat.com/jeder/presentations/customer_convergence/2012-04-jeder_customer_convergence.pdf
kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000
kernel.sched_migration_cost = 1000000
EOSC
cat << EOSC >> /tmp/sysctl.conf

# Adjust disk write buffers
EOSC
SYSTEM_RAM=\$(awk '/MemTotal/ {print \$2}' /proc/meminfo)
if [ \$SYSTEM_RAM -lt 2097152 ]
then
    cat << EOSC >> /tmp/sysctl.conf
# 60% disk cache under 2GB RAM
vm.dirty_ratio = 40
# Start writing at 10%
vm.dirty_background_ratio = 10
EOSC
elif [ \$SYSTEM_RAM -lt 8388608 ]
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
vm.dirty_bytes = 629145600
# Start writing at 300MB
vm.dirty_background_bytes = 314572800
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
if [ -f /lib/modules/\$(uname -r)/kernel/net/ipv4/tcp_htcp.ko ]
then
    # See https://calomel.org/network_performance.html
    CALG=htcp
elif [ -f /lib/modules/\$(uname -r)/kernel/net/ipv4/tcp_cubic.ko ]
then
    # See http://datatag.web.cern.ch/datatag/howto/tcp.html
    CALG=cubic
fi
modprobe tcp_\$CALG
cat << EOSC >> /tmp/sysctl.conf
# Use modern congestion control algorithm
net.ipv4.tcp_congestion_control = \$CALG

# No slowness for idle connections
net.ipv4.tcp_slow_start_after_idle = 0

# Turn on the tcp_window_scaling
net.ipv4.tcp_window_scaling = 1

# Increase the maximum total buffer-space allocatable
net.ipv4.tcp_mem = 8388608 12582912 16777216
net.ipv4.udp_mem = 8388608 12582912 16777216

# Increase the maximum read-buffer space allocatable
net.ipv4.tcp_rmem = 8192 256960 16777216
net.ipv4.udp_rmem_min = 16384

# Increase the maximum write-buffer-space allocatable
net.ipv4.tcp_wmem = 8192 256960 16777216
net.ipv4.udp_wmem_min = 16384

# Increase the maximum and default receive socket buffer size
net.core.rmem_max=16777216
net.core.rmem_default=256960

# Increase the maximum and default send socket buffer size
net.core.wmem_max=16777216
net.core.wmem_default=256960

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
sysctl -p /etc/sysctl.conf

#-------------------------------------------------------------------------
for ETH in \$(awk -F: '/eth/ {sub(/^ */,"");print \$1}' /proc/net/dev)
do
    # Disable Wake-On-LAN for Ethernet interface
    # (this might show errors with some Ethernet drivers)
    ethtool -s \$ETH wol d

    # As per https://wiki.gentoo.org/wiki/Traffic_shaping
    # (this might show errors with some Ethernet drivers)
    ethtool -K \$ETH tso off gso off gro off

    # Increase the TX queue length:
    ifconfig \$ETH txqueuelen 2048
done

# Increase initial window for TCP on ALL routes
# See http://www.cablelabs.com/wp-content/uploads/2014/05/Analysis_of_Google_SPDY_TCP.pdf
ip route show | grep eth | while read L
do
    if [[ ! \$L =~ init.wnd ]]
    then
        ip route change \$L initcwnd 10 initrwnd 10
    fi
done
                    
#-------------------------------------------------------------------------
# Set readahead for disks
# See http://linuxmantra.com/2013/11/disk-read-ahead-in-linux.html
#     http://michael.otacoo.com/postgresql-2/tuning-disks-and-linux-for-postgres/
SECTORS=16384
# MegaRaid controller:
if [ -x /opt/MegaRAID/MegaCli/MegaCli64 ]
then
    SECTORS=\$(/opt/MegaRAID/MegaCli/MegaCli64 -AdpAllInfo -aAll -NoLog | awk '/^Max Data Transfer Size/ {print \$(NF-1)}')
fi
if [ -e /proc/mdstat ]
then
    for DEV in \$(awk '/^md/ {gsub(/\[[0-9]\]/,"");print \$1" "\$5" "\$6}' /proc/mdstat)
    do
        RA=\$(blockdev --getra /dev/\$DEV)
        [ \$RA -ne \$SECTORS ] && blockdev --setra \$SECTORS /dev/\$DEV
    done
fi
for DEV in \$( ls /dev/[hs]d[a-z][0-9] | awk '{sub(/\/dev\//,"");printf "%s ",\$1}')
do
    RA=\$(blockdev --getra /dev/\$DEV)
    [ \$RA -ne \$SECTORS ] && blockdev --setra \$SECTORS /dev/\$DEV
done
for DEV in \$( ls /dev/xvd[a-z][0-9] | awk '{sub(/\/dev\//,"");printf "%s ",\$1}')
do
    RA=\$(blockdev --getra /dev/\$DEV)
    [ \$RA -ne \$SECTORS ] && blockdev --setra \$SECTORS /dev/\$DEV
done
for DEV in \$( ls /dev/mapper/* | awk '{sub(/\/dev\/mapper\//,"");printf "%s ",\$1}')
do
    [ "T\$DEV" = 'Tcontrol' ] && continue
    RA=\$(blockdev --getra /dev/mapper/\$DEV)
    [ \$RA -ne \$SECTORS ] && blockdev --setra \$SECTORS /dev/mapper/\$DEV
done
if [ -d /dev/etherd ]
then
    for DEV in \$(ls /dev/etherd/e[0-9].[0-9]p[0-9] | awk'{sub(/\/dev\/etherd\//,"");printf "%s ",\$1}')
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
for DEV in [vhs]d? xvd?
do
    [ -w \${DEV}/queue/nr_requests ] && echo 512 > \${DEV}/queue/nr_requests
    if [ -w \${DEV}/queue/read_ahead_kb ]
    then
        [ \$(< \${DEV}/queue/read_ahead_kb) -lt 2048 ] && echo 2048 > \${DEV}/queue/read_ahead_kb
    fi
    if [ -f \${DEV}/device/vendor ]
    then
        if [ ! -z "\$(egrep '(DELL|3ware|Areca)' \${DEV}/device/vendor)" ]
        then
            # Use "noop" for 3ware/Dell/Areca (Raid) units
            [ -w \${DEV}/queue/scheduler ] && echo noop > \${DEV}/queue/scheduler
            continue
        fi
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

#-------------------------------------------------------------------------
# Setup security (kernel) auditing
AC=\$(which auditctl)
if [ ! -z "\$AC" ]
then
    ARCH32=\$(uname -m)
    # See also: http://security.blogoverflow.com/tag/standards/
    \$AC -D
    \$AC -b 1024
#    \$AC -a exit,always -F arch=\$ARCH32 -S unlink -S rmdir -k deletion
#    \$AC -a exit,always -F arch=\$ARCH32 -S setrlimit -k system-limits

    \$AC -a always,exit -F arch=\$ARCH32 -S adjtimex -S stime -S clock_settime -k time-change
    \$AC -a always,exit -F arch=\$ARCH32 -S adjtimex -S settimeofday -S clock_settime -k time-change

    \$AC -a always,exit -F arch=\$ARCH32 -S sethostname -S setdomainname -k system-locale

    \$AC -w /etc/group -p wa -k identity
    \$AC -w /etc/passwd -p wa -k identity
    \$AC -w /etc/shadow -p wa -k identity
    [ -f /etc/sudoers ] && \$AC -w /etc/sudoers -p wa -k identity

#    \$AC -w /var/run/utmp -p wa -k session
#    \$AC -w /var/log/wtmp -p wa -k session
#    \$AC -w /var/log/btmp -p wa -k session

    [ -d /etc/selinux ] && \$AC -w /etc/selinux/ -p wa -k MAC-policy

    \$AC -w /tmp -p x -k suspicious-exec
    if [ -d /var/www ]
    then
        \$AC -w /var/www -p wa -k suspicious-write
        \$AC -w /var/www -p x -k suspicious-exec
    fi
fi

#-------------------------------------------------------------------------
# Watch system performance (adapt email address "-a")
[ -x /usr/local/sbin/SysMon.pl ] && /usr/local/sbin/SysMon.pl -D -a root -o /var/tmp

#-------------------------------------------------------------------------
# We are done
exit 0
EORC
    read -p "Review/correct the '-a root' email address in /etc/rc.local" -t 30 REPLY
fi

#--------------------------------------------------------------------
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    # NFS server/client
    read -p 'Is this a NFS server [y|N] ? ' ANSWER
    if [ "T${ANSWER^^}" = 'TY' ]
    then
        $INSTALL_PROG install nfs-kernel-server
        LOCALIP=$(ifconfig eth0 | sed -n "s/.*inet addr:\([0-9.]*\).*/\1/p")
        LOCALMASK=$(ifconfig eth0 | sed -n -e 's/.*Mask:\(.*\)$/\1/p')
        # From: http://www.routertech.org/viewtopic.php?t=1609
        l="${LOCALIP%.*}";r="${LOCALIP#*.}";n="${LOCALMASK%.*}";m="${LOCALMASK#*.}"
        LOCALNET=$((${LOCALIP%%.*}&${LOCALMASK%%.*})).$((${r%%.*}&${m%%.*})).$((${l##*.}&${n##*.})).$((${LOCALIP##*.}&${LOCALMASK##*.}))
        read -p "Name or IP of NFS client(s) [ default=$LOCALNET/$LOCALMASK]: " NFS_CLIENT
        [ -z "$NFS_CLIENT" ] && NFS_CLIENT="$LOCALNET/$LOCALMASK"
        read -p 'Name of NFS share on server: ' NFS_SHARE
        if [ ! -z "$NFS_SHARE" ]
        then
            # Finally - we have all the necessary infos
            cat << EOT >> /etc/exports
$NFS_SHARE  $NFS_CLIENT(rw,async,subtree_check,no_root_squash)
EOT
            exportfs -a

            cat << EOT > /etc/default/nfs-common
# If you do not set values for the NEED_ options, they will be attempted
# autodetected; this should be sufficient for most people. Valid alternatives
# for the NEED_ options are "yes" and "no".

# Do you want to start the statd daemon? It is not needed for NFSv4.
NEED_STATD=

# Options for rpc.statd.
#   Should rpc.statd listen on a specific port? This is especially useful
#   when you have a port-based firewall. To use a fixed port, set this
#   this variable to a statd argument like: "--port 4000 --outgoing-port 4001".
#   For more information, see rpc.statd(8) or http://wiki.debian.org/?SecuringNFS
STATDOPTS="--port 32765 --outgoing-port 32766"

# Do you want to start the idmapd daemon? It is only needed for NFSv4.
NEED_IDMAPD=

# Do you want to start the gssd daemon? It is required for Kerberos mounts.
NEED_GSSD=
EOT
           service portmap restart
        fi
    else
        read -p 'Is this a NFS client [y|N] ? ' ANSWER
        if [ "T${ANSWER^^}" = 'TY' ]
        then
            read -p 'Name or IP of NFS server: ' NFS_SRV
            if [ ! -z "$NFS_SRV" ]
            then
                read -p 'Name of NFS share on server: ' NFS_SHARE
                if [ ! -z "$NFS_SHARE" ]
                then
                    read -p 'Mount point of NFS share on this server: ' NFS_MP
                    if [ ! -z "$NFS_MP" ]
                    then
                        # Finally - we have all the necessary infos
                        mkdir -p $NFS_MP
                        if [ -z "$(grep ^$NFS_SRV:$NFS_SHARE /etc/fstab)" ]
                        then
                            cat << EOT >> /etc/fstab
$NFS_SRV:$NFS_SHARE $NFS_MP nfs rw,vers=3,rsize=524288,wsize=524288,hard,proto=tcp,timeo=600,retrans=2,sec=sys,addr=$NFS_SRV 0 0
EOT
                        fi
                    fi
                fi
            fi
        fi
    fi
fi
