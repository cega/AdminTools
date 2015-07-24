#!/bin/bash
################################################################
# (c) Copyright 2015 B-LUC Consulting and Thomas Bullinger
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
DEBUG='-q'
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

# Install specific packages
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    PKG_LIST='firehol joe ethtool auditd unzip git'
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
    # Make sure that rc.local runs in "bash"
    sed -i -e 's@bin/sh -e@bin/bash@;/^exit/d' /etc/rc.local

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
#iptables -t mangle -I PREROUTING -p tcp -m tcp -m state --state NEW -m tcpmss ! --mss 536:65535 -j DROP

### INPUT and OUTPUT rules
# The LAN
interface eth0 LAN
        #-----------------------------------------------------------------
        # Protect against attacks as best as we can
        policy reject
        protection strong 10/sec 10
        protection reverse strong
        #-----------------------------------------------------------------
        # Allow all traffic
        server all accept
        client all accept
EOT
else
    lokkit -p 8080:tcp
fi

#--------------------------------------------------------------------
# Download and install "artillery"
wget -q https://github.com/trustedsec/artillery/archive/master.zip \
  -O /usr/local/src/artillery.zip
cd /tmp
unzip -o /usr/local/src/artillery.zip
cd artillery-master
yes | ./setup.py

# Enable automatic updates
sed -i 's/AUTO_UPDATE="OFF"/AUTO_UPDATE="ON"/' /var/artillery/config

# Ask for SMTP parameters
read -p 'Use email notifications [Y/n] ? ' YN
[ -z "$YN" ] && YN='Y'
if [ "T${YN^^}" = 'TY' ]
then
    # SMTP_ADDRESS="smtp.gmail.com"
    read -p 'Name or IP address of SMTP server: ' SMTP_ADDRESS
    if [ ! -z "$SMTP_ADDRESS" ]
    then
        # SMTP_PORT="587"
        read -p 'Port for SMTP traffic [25] : ' SMTP_PORT
        [ -z "$SMTP_PORT" ] && SMTP_PORT=25
        SMTP_FROM="Honeypot Incident"
        read -p 'Email address of alert recipient : ' ALERT_USER_EMAIL
        read -p 'SMTP authentication required [y/N] ? ' YN
        if [ "T${YN^^}" = 'TY' ]
        then
            read -p 'Username for SMTP server : ' SMTP_USERNAME
            read -p 'Password for SMTP server : ' SMTP_PASSWORD
        else
            SMTP_USERNAME=""
            SMTP_PASSWORD=""
        fi
        sed -i 's/^SMTP/#SMTP/;s/^EMAIL_ALERTS=/#EMAIL_ALERTS=/;s/^ALERT_USER_EMAIL=/#ALERT_USER_EMAIL=/' /var/artillery/config
        cat << EOT >> /var/artillery/config
### B-LUC start
## Email alert parameters
EMAIL_ALERTS="ON"
# To and From email addresses:
ALERT_USER_EMAIL="$ALERT_USER_EMAIL"
SMTP_FROM="$SMTP_FROM"
# SMTP server:
SMTP_ADDRESS="$SMTP_ADDRESS"
SMTP_PORT="$SMTP_PORT"
# SMTP authentication (empty if not necessary):
SMTP_USERNAME="$SMTP_USERNAME"
SMTP_PASSWORD="$SMTP_PASSWORD"
### B-LUC end
EOT
    fi    
fi

service artillery restart

#--------------------------------------------------------------------
# We are done
exit 0
