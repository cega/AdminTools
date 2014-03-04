#!/bin/bash
################################################################
# (c) Copyright 2013 B-LUC Consulting and Thomas Bullinger
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
mask2cdr ()
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

IS_VIRTUAL=0
if [ ! -z "$(grep -m1 VMware /proc/scsi/scsi)" ]
then
    IS_VIRTUAL=1
elif [ ! -z "$(grep QEMU /proc/cpuinfo)" -a ! -z "$(grep Bochs /sys/class/dmi/id/bios_vendor)" ]
then
    IS_VIRTUAL=2
fi
if [ $IS_VIRTUAL -ne 0 ]
then
  # Install the "virtual" kernel
  apt-get install linux-image-virtual linux-headers-virtual

  # Remove the "generic" kernel
  apt-get --purge remove linux-image-generic linux-headers-generic
fi

# Remove the PPP packages
apt-get --purge remove ppp pppconfig pppoeconf

# Install specific packages
apt-get install xtables-addons-dkms firehol joe ethtool linuxlogo libunix-syslog-perl openntpd libio-socket-ssl-perl sendemail python-software-properties chkrootkit perltidy haveged

# Activate the HPN patched SSH
apt-add-repository ppa:w-rouesnel/openssh-hpn

# Update and upgrade
apt-get update; apt-get autoremove; apt-get dist-upgrade

# Adapt SSH configs
[ -z "$(grep '^[[:space:]]*PermitRootLogin.*no' /etc/ssh/sshd_config)" ] && sed -ie 's/^[[:space:]]*PermitRootLogin.*yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -ie 's/^[[:space:]]*Protocol.*/Protocol 2/' /etc/ssh/ssh_config
[ -z "$(grep '^[[:space:]]*Ciphers.*blowfish' /etc/ssh/ssh_config)" ] && echo 'Ciphers blowfish-cbc,aes256-cbc,aes192-cbc,aes128-cbc,3des-cbc,cast128-cbc,arcfour' >> /etc/ssh/ssh_config
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

# Interface No 1a - frontend (public).
# The purpose of this interface is to control the traffic
# on the eth0 interface with IP 172.16.1.224 (net: "${LOCALNET}/${CIDRMASK}").
interface eth0 internal_1 src "${LOCALNET}/${CIDRMASK}" dst ${LOCALIP}

        # The default policy is DROP. You can be more polite with REJECT.
        # Prefer to be polite on your own clients to prevent timeouts.
        policy drop

        # If you don't trust the clients behind eth0 (net "${LOCALNET}/${CIDRMASK}"),
        # add something like this.
        protection strong 75/sec 50

        # Here are the services listening on eth0.
        # TODO: Normally, you will have to remove those not needed.
        server "ssh" accept src "${home_net} ${bluc}"
        #server "smtp imaps smtps https" accept
        server ping accept

        # The following means that this machine can REQUEST anything via eth0.
        # TODO: On production servers, avoid this and allow only the
        #       client services you really need.
        client all accept

# Interface No 1b - frontend (public).
# The purpose of this interface is to control the traffic
# from/to unknown networks behind the default gateway 172.16.1.1
interface eth0 external_1 src not "${LOCALNET}/${CIDRMASK}" dst ${LOCALIP}

        # The default policy is DROP. You can be more polite with REJECT.
        # Prefer to be polite on your own clients to prevent timeouts.
        policy drop

        # If you don't trust the clients behind eth0 (net not "\${UNROUTABLE_IPS} ${LOCALNET}/${CIDRMASK}"),
        # add something like this.
        protection strong 75/sec 50

        # Here are the services listening on eth0.
        # TODO: Normally, you will have to remove those not needed.
        server "ssh" accept src "${home_net} ${bluc}"
        #server "smtp imaps smtps http https" accept
        server ping accept

        # Portscan defense
        iptables -A in_external_1 -m psd -j LOG --log-prefix 'IN-ISP-Portscan'
        iptables -A in_external_1 -m psd -j DROP

        # The following means that this machine can REQUEST anything via eth0.
        # TODO: On production servers, avoid this and allow only the
        #       client services you really need.
        client all accept
EOT
fi
sed -ie 's/^[[:space:]]*START_FIREHOL.*/START_FIREHOL=YES/' /etc/default/firehol

# Install the audit daemon
# (configuration - see /etc/rc.local)
apt-get install auditd

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

# Give the "opa" account a meaningful full name
[ -z "$(getent passwd opa)" ] || chfn -f 'Linux Operator' opa

# NFS server/client
read -p 'Is this a NFS server [y|N] ? ' ANSWER
if [ "T${ANSWER^^}" = 'TY' ]
then
    apt-get install nfs-kernel-server
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
