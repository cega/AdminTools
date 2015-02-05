#!/bin/bash
# Function to convert netmasks into CIDR notation and back
# See: https://forums.gentoo.org/viewtopic-t-888736-start-0.html
mask2cdr ()
{
   # Assumes there's no "255." after a non-255 byte in the mask
   local x=${1##*255.}
   set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x})*2 )) ${x%%.*}
   x=${1%%$3*}
   echo $(( $2 + (${#x}/4) ))
}

#--------------------------------------------------------------------
# Only root can execute this script!
if [ $EUID -ne 0 ]
then
    echo 'You must be root to continue'
    exit 0
fi

#--------------------------------------------------------------------
# Sanity checks
if [ -s /etc/lsb-release ]
then
    source /etc/lsb-release
    if [ "T${DISTRIB_ID^^}" != 'TUBUNTU' ]
    then
        echo 'This is not an Ubuntu Server'
        exit 0
    fi
else
    echo 'This is not an Ubuntu Server'
    exit 0
fi

if [ "T$(uname -i)" != 'Tx86_64' ]
then
    echo 'This is not a 64-bit server'
    exit 0
fi

#--------------------------------------------------------------------
# Sensible defaults
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DEBUG=''
[[ $- = *x* ]] && DEBUG='-v'

# Ensure that only one instance is running
LOCKFILE=/tmp/$PROG.lock
if [ -f $LOCKFILE ]
then
    # The file exists so read the PID
    MYPID=$(< $LOCKFILE)
    [ -z "$(ps h -p $MYPID)" ] || exit 0
fi
trap "rm -f $LOCKFILE /tmp/$$*" EXIT
echo "$$" > $LOCKFILE            

#--------------------------------------------------------------------
# This host and domain
THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
THISDOMAIN=${THISHOST#*.}

#--------------------------------------------------------------------
# Adjust the mount options for any ext{3|4} partition
# See http://www.howtoforge.com/reducing-disk-io-by-mounting-partitions-with-noatime
awk 'substr($3,1,3) != "ext" {print}' /etc/fstab > /tmp/$$.fstab
awk 'substr($3,1,3) == "ext" {print $1" "$2" "$3" noatime,errors=remount-ro "$5" "$6}' /etc/fstab >> /tmp/$$.fstab
diff -u /tmp/$$.fstab /etc/fstab &> /dev/null
[ $? -ne 0 ] && cat /tmp/$$.fstab > /etc/fstab
rm -f /tmp/$$.fstab

#--------------------------------------------------------------------
# Install specific packages
apt-get install firehol joe ethtool sendemail haveged mysql-server \
  rt4-fcgi rt4-db-mysql rt4-extension-calendar rt4-extension-assettracker rt4-extension-authenexternalauth

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
#server_snmpd_ports="udp/162"
#client_snmpd_ports="default"

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
        server "ssh http" accept
        server ping accept

        # The following means that this machine can REQUEST anything via eth0.
        # TODO: On production servers, avoid this and allow only the
        #       client services you really need.
        client all accept

# Interface No 1b - frontend (public).
# The purpose of this interface is to control the traffic
# from/to unknown networks behind the default gateway 172.16.1.1
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
        server ping accept

        # The following means that this machine can REQUEST anything via eth0.
        # TODO: On production servers, avoid this and allow only the
        #       client services you really need.
        client all accept
EOT
    fi
    sed -ie 's/^[[:space:]]*START_FIREHOL.*/START_FIREHOL=YES/' /etc/default/firehol
fi

#--------------------------------------------------------------------
# Adapt nginx setup
if [ ! -s /etc/nginx/sites-enabled/request-tracker4.conf ] 
then
    cat << EOT > /etc/nginx/sites-enabled/request-tracker4.conf
server {
  listen 80;
  server_name $THISHOST;

EOT
    cat /usr/share/doc/rt4-fcgi/examples/request-tracker4.conf >> /etc/nginx/sites-enabled/request-tracker4.conf
    cat << EOT > /etc/nginx/sites-enabled/request-tracker4.conf
EOT
fi
if [ -z "$(grep B-LUC /usr/share/nginx/html/index.html)" ]
then
    cat << EOT > /usr/share/nginx/html/index.html
<!DOCTYPE html>
<html>
<head>
<title>Welcome</title>
 <meta name="copyright" content="B-LUC Consulting">
 <meta http-equiv="refresh" content="2;url=rt/">
</head>
<body>
 You will be redirected to the Request Tracker in two seconds. If
 you aren't forwarded to the it, please click <a href=rt/> here </a>.
</body>
</html>
EOT
fi

# The local configuration overrides
if [ ! -s /etc/request-tracker4/RT_SiteConfig.d/99-bluc ]
then
    # Get LDAP parameters
    read -p 'LDAP Server name or IP : ' LDAP_SERVER
    read -p 'LDAP Bind user : ' LDAP_BIND_USER
    read -p 'LDAP Bind password : ' LDAP_BIND_PASS
    read -p 'LDAP Base DN : ' LDAP_BASE
    
    cat << EOT > /etc/request-tracker4/RT_SiteConfig.d/99-bluc
###################################################
# Run "update-rt-siteconfig-4" and
#  "service rt4-fcgi restart" after any change
###################################################

# Setup logging
# See http://requesttracker.wikia.com/wiki/LogsConfig
Set(@LogToSyslogConf,
     ident => 'RT',
     facility => 'local0',
);

# Activate additional plugins
Set(@Plugins, qw(
   RT::Authen::ExternalAuth
   RTx::AssetTracker
));

# Definitions for 'RT::Authen::ExternalAuth'
# See http://cpansearch.perl.org/src/ALEXMV/RT-Authen-ExternalAuth-0.23/README
Set(\$ExternalAuthPriority,  [ 'My_LDAP' ] );
Set(\$ExternalInfoPriority,  [ 'My_LDAP' ] );
Set(\$ExternalServiceUsesSSLorTLS,    0);
Set(\$AutoCreateNonExternalUsers,    0);
Set(\$ExternalSettings,      {
  'My_LDAP'  =>  {
    'type'              => 'ldap',
    'server'            => '$LDAP_SERVER',
    'user'              => '$LDAP_BIND_USER',
    'pass'              => '$LDAP_BIND_PASS',
    'base'              => '$LDAP_BASE',

    'filter'            => '(&(ObjectCategory=User)(ObjectClass=Person))',
    'd_filter'          => '(userAccountControl:1.2.840.113556.1.4.803:=2)',

    'tls'               => 0,
#   'ssl_version'       => 3,

    'net_ldap_args'     => [ version => 3 ],

    'attr_match_list'   => [   'Name', 'EmailAddress'   ],
    'attr_map'          => {   'Name' => 'sAMAccountName',
                               'EmailAddress' => 'mail',
                               'Organization' => 'physicalDeliveryOfficeName',
                               'RealName' => 'cn',
                               'ExternalAuthId' => 'sAMAccountName',
                               'Gecos' => 'sAMAccountName',
                               'WorkPhone' => 'telephoneNumber',
                               'Address1' => 'streetAddress',
                               'City' => 'l',
                               'State' => 'st',
                               'Zip' => 'postalCode',
                               'Country' => 'co'
                            }
     }
}
); 

# Definitions for 'RTx::AssetTracker'
# See https://github.com/AssetTracker/rt-extension-assettracker
Set(@CustomFieldValuesSources, (qw(RT::CustomFieldValues::ATServers)));
EOT
    vi /etc/request-tracker4/RT_SiteConfig.d/99-bluc
    update-rt-siteconfig-4

    # Setup logging in "rsyslog"
    cat << EOT > /etc/rsyslog.d/99-requesttracker
local0.*		/var/log/request-tracker4/rt.log
EOT
     service rsyslog restart
fi

rm -f /etc/nginx/sites-enabled/default
sed -ie 's/^enabled.*/enabled=1/' /etc/default/rt4-fcgi
service rt4-fcgi restart
service nginx restart

#--------------------------------------------------------------------
# Tweak MySQL for performance
if [ ! -s /etc/mysql/conf.d/rt4.cnf ]
then
    cat << EOT > /etc/mysql/conf.d/rt4.cnf
# Performance adaptations
# See http://binarynature.blogspot.com/2013/10/install-request-tracker-4-on-ubuntu-server.html
# See /usr/share/doc/mysql-server-5.5/examples/my-innodb-heavy-4G.cnf.gz
[mysqld]
innodb_buffer_pool_size = 256M
EOT
    service mysql restart
fi

#--------------------------------------------------------------------
# Adapt exim4 setup
if [ -d /etc/exim4 ]
then
    # (re)configure exim4
    cat << EOT > /etc/exim4/update-exim4.conf.conf
# /etc/exim4/update-exim4.conf.conf
#
# Edit this file and /etc/mailname by hand and execute update-exim4.conf
# yourself or use 'dpkg-reconfigure exim4-config'
#
# Please note that this is _not_ a dpkg-conffile and that automatic changes
# to this file might happen. The code handling this will honor your local
# changes, so this is usually fine, but will break local schemes that mess
# around with multiple versions of the file.
#
# update-exim4.conf uses this file to determine variable values to generate
# exim configuration macros for the configuration file.
#
# Most settings found in here do have corresponding questions in the
# Debconf configuration, but not all of them.
#
# This is a Debian specific file

dc_eximconfig_configtype='smarthost'
dc_other_hostnames='$(hostname -f)'
dc_local_interfaces='127.0.0.1'
dc_readhost=''
dc_relay_domains=''
dc_minimaldns='false'
dc_relay_nets=''
dc_smarthost='mail'
CFILEMODE='644'
dc_use_split_config='false'
dc_hide_mailname='false'
dc_mailname_in_oh='true'
dc_localdelivery='maildir_home'
EOT
    dpkg-reconfigure exim4-config

    # Get the IP address of the smarthost
    SMARTHOST=$(awk -F= '/dc_smarthost/ {print $NF}' /etc/exim4/update-exim4.conf.conf | sed -e "s/'//g")
    SMIP=$(host $SMARTHOST | awk '{print $NF}')
    if [ -s /etc/exim4/exim4.conf.localmacros ]
    then
        perl -p -i -e "s/^REMOTE_SMTP_SMARTHOST_HOSTS_AVOID_TLS.*/REMOTE_SMTP_SMARTHOST_HOSTS_AVOID_TLS = $SMIP/" /etc/exim4/exim4.conf.localmacros
    else
        cat << EOT > /etc/exim4/exim4.conf.localmacros
REMOTE_SMTP_SMARTHOST_HOSTS_AVOID_TLS = $SMIP
EOT
    fi
    update-exim4.conf
    service exim4 restart
fi

#--------------------------------------------------------------------
# Setup "password" as the "root" password
# See http://requesttracker.wikia.com/wiki/RecoverRootPassword
#mysql rtdb -u root -p -e "UPDATE Users SET Password='X03MO1qnZdYdgyfeuILPmQ' WHERE Name='root'"

#--------------------------------------------------------------------
# Setup a crontab
if [ ! -s /etc/cron.d/btoy1 ]
then
    cat << EOT > /etc/cron.d/btoy1
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin
MAILTO=root
#---------------------------------------------------------------
# Perform health checks
* * * * *       root    [ -x /usr/local/sbin/HealthCheck.sh ] && HealthCheck.sh
EOT
fi

#--------------------------------------------------------------------
# Setup some housekeeping scripts
if [ ! -s /usr/local/sbin/HealthCheck.sh ]
then
    cat << EOT > /usr/local/sbin/HealthCheck.sh
#!/bin/bash

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROG=\${0##*/}
ionice -c2 -n7 -p \$\$

#--------------------------------------------------------------------
# Ensure that only one instance is running
LOCKFILE=/tmp/\$PROG.lock
if [ -f \$LOCKFILE ]
then
    # The file exists so read the PID   
    MYPID=\$(< \$LOCKFILE)
    [ -z "\$(ps h -p \$MYPID)" ] || exit 0
fi

# Make sure we remove the lock file at exit
trap "rm -f \$LOCKFILE /tmp/\$\$*" EXIT
echo "\$\$" > \$LOCKFILE            

DEBUG=''
[[ \$- = *x* ]] && DEBUG='-v'
CURMIN=\$(date +%-M)
CURHR=\$(date +%-H)

#--------------------------------------------------------------------
# Every 5 minutes:
if [ "T\$DEBUG" = 'T-v' -o \$((\$CURMIN % 5)) -eq 2 ]
then
    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    # Discard unused blocks on supported file systems
#SSD_DRIVES_ONLY#    if [ -x /sbin/fstrim-all ]
#SSD_DRIVES_ONLY#    then
#SSD_DRIVES_ONLY#        # Use the script providing by Linux distribution
#SSD_DRIVES_ONLY#        fstrim-all
#SSD_DRIVES_ONLY#    else
#SSD_DRIVES_ONLY#        for FS in \$(awk '/ext3|ext4|xfs|btrfs/ {print \$2}' /proc/mounts)
#SSD_DRIVES_ONLY#        do
#SSD_DRIVES_ONLY#            fstrim \$DEBUG \$FS
#SSD_DRIVES_ONLY#        done
#SSD_DRIVES_ONLY#    fi

    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    # Check whether we use more than 256MB swap
    SW_TOTAL=\$(awk '/^SwapTotal/ {print \$2}' /proc/meminfo)
    SW_FREE=\$(awk '/^SwapFree/ {print \$2}' /proc/meminfo)  
    SW_USED=\$((\$SW_TOTAL - \$SW_FREE))
    if [ \$SW_USED -gt 262144 ]
    then
        # Using more than 256MB swap
        logger -it HealthCheck -p daemon.info -- "Swap usage over 256MB"
        if [ \$((\$CURMIN % 30)) -eq 11 ]
        then
            # Send an email every 30 minutes
            echo "Used swap: \${SW_USED}KB" > /tmp/\$\$

            # Get the top 10 swap eating processes
            for F in /proc/*/status
            do
                awk '/^(Pid|VmSwap)/{printf \$2 " " \$3}END{ print ""}' \$F
            done | sort -k 2 -n -r | head >> /tmp/\$\$

            sendemail -q -f root@\$THISHOST -u "\$THISHOST: Swap usage over 256MB" \
              -t root -s mail -o tls=no < /tmp/\$\$
        fi
    fi

    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    # Check filesystem usage
    df -PTh | awk '/ext3|ext4|xfs|btrfs/ {print \$7" "int(\$6)}' | while read FS PERC
    do
        logger -it HealthCheck -p daemon.info -- "Filesystem usage on '\$FS' is \${PERC}%"
        if [ \$PERC -gt 90 ]
        then
            # We have a real problem!
            echo "" | sendemail -q -f root@\$THISHOST \
              -u "\$THISHOST: EXTREME HIGH DISK USAGE on '\$FS': \${PERC}%" \
              -t root -s mail -o tls=no
        elif [ \$PERC -gt 85 ]
        then
            # We should pay attention
            echo "" | sendemail -q -f root@\$THISHOST \
              -u "\$THISHOST: High disk usage on '\$FS': \${PERC}%" \
              -t root -s mail -o tls=no
        fi
    done
fi

#--------------------------------------------------------------------
# Hourly:
if [ "T\$DEBUG" = 'T-v' -o \$CURMIN -eq 2 ]
then
    # Update time
    ntpdate -u \$DEBUG 0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org &
fi

#--------------------------------------------------------------------
# We are done 
exit 0
EOT
    chmod 744 /usr/local/sbin/HealthCheck.sh
fi

#--------------------------------------------------------------------
# Tweak system for security and performance
[ -z "$(grep IS_VIRTUAL /etc/rc.local)" ] && cat << EORC >> /etc/rc.local
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
# See http://datatag.web.cern.ch/datatag/howto/tcp.html
if [ -f /lib/modules/2.6.32-279.el6.x86_64/kernel/net/ipv4/tcp_cubic.ko ]
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
sysctl -p /etc/sysctl.conf

#-------------------------------------------------------------------------
for ETH in \$(grep ':' /proc/net/dev | cut -d: -f1 | egrep -v '(lo|tap)')
do
    # Disable Wake-On-LAN
    ethtool -s \$ETH wol d
    # Increase the TX queue length
    # See http://datatag.web.cern.ch/datatag/howto/tcp.html
    ifconfig \$ETH txqueuelen 2048
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
EORC
