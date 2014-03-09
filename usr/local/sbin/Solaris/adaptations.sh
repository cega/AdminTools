#!/usr/bin/bash
################################################################
# (c) Copyright 2013 B-LUC Consulting and Thomas Bullinger
################################################################

# Better have SSH enabled!
svcadm enable svc:/network/ssh:default

# Disable some basic services
svcadm disable svc:/network/login:rlogin
svcadm disable svc:/network/shell:default
svcadm disable svc:/system/filesystem/autofs:default
svcadm disable svc:/network/nis/server:default
svcadm disable svc:/network/nis/passwd:default
svcadm disable svc:/network/nis/update:default
svcadm disable svc:/network/nis/xfr:default
svcadm disable svc:/network/nis/client:default
svcadm disable svc:/network/rpc/nisplus:default
svcadm disable svc:/network/ldap/client:default
svcadm disable svc:/network/security/kadmin:default
svcadm disable svc:/network/security/krb5kdc:default
svcadm disable svc:/network/security/krb5_prop:default
svcadm disable svc:/network/security/ktkt_warn:default
svcadm disable svc:/network/rpc/smserver:default
[ -s /etc/rc3.d/S81volmgt ] && mv /etc/rc3.d/S81volmgt /etc/rc3.d/.NOS81volmgt 2> /dev/null
[ -s /etc/rc3.d/S90samba ] && mv /etc/rc3.d/S90samba /etc/rc3.d/.NOS90samba 2> /dev/null
svcadm disable svc:/network/nfs/rquota:default
svcadm disable svc:/network/telnet:default
svcadm disable svc:/network/ftp:default
svcadm disable svc:/network/dns/server:default
svcadm disable -s svc:/application/print/cleanup:default
svcadm disable svc:/application/print/server:default
svcadm disable svc:/application/print/rfc1179:default
svcadm disable svc:/network/http:apache2
[ -s /etc/rc3.d/S50apache ] && mv /etc/rc3.d/S50apache /etc/rc3.d/.NOS50apache 2> /dev/null
[ -s /etc/rc2.d/S42ncakmod ] && mv /etc/rc2.d/S42ncakmod /etc/rc2.d/.NOS42ncakmod 2> /dev/null
[ -s /etc/rc2.d/S94ncalogd ] && mv /etc/rc2.d/S94ncalogd /etc/rc2.d/.NOS94ncalogd 2> /dev/null
[ -s /etc/rc3.d/S82initsma ] && mv /etc/rc3.d/S82initsma /etc/rc3.d/.NOS82initsma 2> /dev/null
svcadm disable svc:/network/smtp:sendmail
svcadm disable svc:/network/chargen:dgram
svcadm disable svc:/network/chargen:stream
svcadm disable svc:/network/daytime:dgram
svcadm disable svc:/network/daytime:stream
svcadm disable svc:/network/discard:dgram
svcadm disable svc:/network/discard:stream
svcadm disable svc:/network/echo:dgram
svcadm disable svc:/network/echo:stream
svcadm disable svc:/network/time:dgram
svcadm disable svc:/network/time:stream
svcadm disable svc:/network/rpc/rex:default
svcadm disable svc:/network/rexec:default
svcadm disable svc:/network/uucp:default
svcadm disable svc:/network/comsat:default
svcadm disable svc:/network/rpc/spray:default
svcadm disable svc:/network/rpc/wall:default
svcadm disable svc:/network/tname:default
svcadm disable svc:/network/talk:default
svcadm disable svc:/network/finger:default
svcadm disable svc:/network/rpc/rstat:default
svcadm disable svc:/network/rpc/rusers:default
svcadm disable svc:/network/rpc/ocfserv:default
svcadm disable svc:/network/login:eklogin
svcadm disable svc:/network/login:klogin
svcadm disable svc:/network/shell:kshell
[ -s /etc/rc2.d/S40llc2 ] && mv /etc/rc2.d/S40llc2 /etc/rc2.d/.NOS40llc2 2> /dev/null
[ -s /etc/rc2.d/S47pppd ] && mv /etc/rc2.d/S47pppd /etc/rc2.d/.NOS47pppd 2> /dev/null
[ -s /etc/rc2.d/S70uucp ] && mv /etc/rc2.d/S70uucp /etc/rc2.d/.NOS70uucp 2> /dev/null
[ -s /etc/rc2.d/S72autoinstall ] && mv /etc/rc2.d/S72autoinstall /etc/rc2.d/.NOS72autoinstall 2> /dev/null
[ -s /etc/rc2.d/S73cachefs.daemon ] && mv /etc/rc2.d/S73cachefs.daemon /etc/rc2.d/.NOS73cachefs.daemon 2>/dev/null
[ -s /etc/rc2.d/S89bdconfig ] && mv /etc/rc2.d/S89bdconfig /etc/rc2.d/.NOS89bdconfig 2> /dev/null
[ -s /etc/rc2.d/S89PRESERVE ] && mv /etc/rc2.d/S89PRESERVE /etc/rc2.d/.NOS89PRESERVE 2> /dev/null
[ -s /etc/rc3.d/S16boot.server ] && mv /etc/rc3.d/S16boot.server /etc/rc3.d/.NOS16boot.server 2> /dev/null
[ -s /etc/rc3.d/S52imq ] && mv /etc/rc3.d/S52imq /etc/rc3.d/.NOS52imq 2> /dev/null
[ -s /etc/rc3.d/S84appserv ] && mv /etc/rc3.d/S84appserv /etc/rc3.d/.NOS84appserv 2> /dev/null
[ -s /etc/rc3.d/S75seaport ] && mv /etc/rc3.d/S75seaport /etc/rc3.d/.NOS75seaport 2> /dev/null
[ -s /etc/rc3.d/S76snmpdx ] && mv /etc/rc3.d/S76snmpdx /etc/rc3.d/.NOS76snmpdx 2> /dev/null
[ -s /etc/rc3.d/S77dmi ] && mv /etc/rc3.d/S77dmi /etc/rc3.d/.NOS77dmi 2> /dev/null
[ -s /etc/rc3.d/S80mipagent ] && mv /etc/rc3.d/S80mipagent /etc/rc3.d/.NOS80mipagent 2> /dev/null
perl -p -i -e 's/TCP_STRONG_ISS=.*/TCP_STRONG_ISS=2/' /etc/default/inetinit
egrep -v '(Clear exit|^exit)' /lib/svc/method/net-init > /tmp/net-init
cat << EOCF >> /tmp/net-init
# Combat ARP DOS attacks by flushing entries faster.
/usr/sbin/ndd -set /dev/arp arp_cleanup_interval 60000
/usr/sbin/ndd -set /dev/ip ip_ire_arp_interval 60000

# Combat ICMP DOS attacks by ignoring them.
/usr/sbin/ndd -set /dev/ip ip_respond_to_echo_broadcast 0
/usr/sbin/ndd -set /dev/ip ip6_respond_to_echo_multicast 0
/usr/sbin/ndd -set /dev/ip ip_respond_to_timestamp_broadcast 0
/usr/sbin/ndd -set /dev/ip ip_respond_to_address_mask_broadcast 0

# Ignore redirect requests. These change routing tables.
/usr/sbin/ndd -set /dev/ip ip_ignore_redirect 1 
/usr/sbin/ndd -set /dev/ip ip6_ignore_redirect 1

# Don't send redirect requests. This is a router function.
/usr/sbin/ndd -set /dev/ip ip_send_redirects 0
/usr/sbin/ndd -set /dev/ip ip6_send_redirects 0

# Don't respond to timestamp requests. This may break rdate on some systems.
/usr/sbin/ndd -set /dev/ip ip_respond_to_timestamp 0

# If a packet isn't for the interface it came in on, drop it.
/usr/sbin/ndd -set /dev/ip ip_strict_dst_multihoming 1
/usr/sbin/ndd -set /dev/ip ip6_strict_dst_multihoming 1

# Don't forward broadcasts.
/usr/sbin/ndd -set /dev/ip ip_forward_directed_broadcasts 0

# Don't forward source routed packets.
/usr/sbin/ndd -set /dev/ip ip_forward_src_routed 0
/usr/sbin/ndd -set /dev/ip ip6_forward_src_routed 0

# Combat SYN flood attacks.
/usr/sbin/ndd -set /dev/tcp tcp_conn_req_max_q0 8192

# Combat connection exhaustion attacks.
/usr/sbin/ndd -set /dev/tcp tcp_conn_req_max_q 1024

# Don't forward reverse source routed packets.
/usr/sbin/ndd -set /dev/tcp tcp_rev_src_routes 0

# Combat IP DOS attacks by decreasing the rate at which errors are sent.
/usr/sbin/ndd -set /dev/ip ip_icmp_err_interval 1000
/usr/sbin/ndd -set /dev/ip ip_icmp_err_burst 5

# Clear exit status.
exit 0
EOCF
diff /tmp/net-init /lib/svc/method/net-init &> /dev/null
if [ $? -ne 0 ]
then
	cp /lib/svc/method/net-init /lib/svc/method/net-init.ORIG
	cat /tmp/net-init > /lib/svc/method/net-init
	svcadm restart initial
fi

if [ `uname -p` = 'sparc' ]
then
    if [ ! "`grep noexec_user_stack /etc/system`" ]
    then
        cat << EOCF >> /etc/system
set noexec_user_stack=1
set noexec_user_stack_log=1 
EOCF
    fi
fi

# See: http://techhell.badwolf.cx/?p=38
# Restrict core dumps to protected directory
mkdir -p /var/core
chown root:root /var/core
chmod 700 /var/core
coreadm -g /var/core/core_%n_%f_%u_%g_%t_%p -e log -e global \
	-e global-setid -d process -d proc-setid

if [ ! "`grep nfssrv:nfs_portmon /etc/system`" ]
then
	cat << EOCF >> /etc/system
* Require NFS clients to use privileged ports
set nfssrv:nfs_portmon = 1

EOCF
fi

# Turn on inetd tracing
inetadm -M tcp_trace=true

# Turn on additional logging for FTP daemon
inetadm -m svc:/network/ftp exec="/usr/sbin/in.ftpd -a -l -d"

# Capture FTP and inetd Connection Tracing Info
if [ ! "`grep -v '^#' /etc/syslog.conf | grep /var/log/connlog`" ]
then
	echo "daemon.debug\t\t\t/var/log/connlog" >> /etc/syslog.conf
fi
touch /var/log/connlog
chown root:root /var/log/connlog
chmod 600 /var/log/connlog
logadm -w connlog -C 13 -a 'pkill -HUP syslogd' /var/log/connlog

# Capture messages sent to syslog AUTH facility
if [ ! "`grep -v '^#' /etc/syslog.conf | grep /var/log/authlog`" ]
then
    echo "auth.info\t\t\t/var/log/authlog" >> /etc/syslog.conf
fi
logadm -w authlog -C 13 -a 'pkill -HUP syslogd' /var/log/authlog
touch /var/adm/loginlog
chown root:sys /var/adm/loginlog
chmod 600 /var/adm/loginlog

cd /etc/default
awk '/SYSLOG_FAILED_LOGINS=/ { $1 = "SYSLOG_FAILED_LOGINS=0" }; { print }' login >login.new
[ -s login.new ] && mv login.new login
pkgchk -f -n -p /etc/default/login
logadm -w connlog -C 13 /var/adm/loginlog

# Turn on cron logging
cd /etc/default
awk '/CRONLOG=/ { $1 = "CRONLOG=YES" }; { print }' cron > cron.new
[ -s cron.new ] && mv cron.new cron
pkgchk -f -n -p /etc/default/cron

# Enable system accounting
svcadm enable svc:/system/sar:default
/usr/bin/su sys -c crontab << EOCF
0,20,40 * * * * /usr/lib/sa/sa1
45 23 * * * /usr/lib/sa/sa2 -s 0:00 -e 23:59 -i 1200 -A
EOCF

# Enable kernel-level auditing
if [ ! "`grep c2audit:audit_load /etc/system`" ]
then
    echo y | /etc/security/bsmconv
    cd /etc/security
    echo '0x08000000:cc:CIS custom class' >> audit_class
    awk 'BEGIN { FS = ":"; OFS = ":" }
        ($4 ~ /fm/) && ! ($2 ~ /MCTL|FCNTL|FLOCK|UTIME/) { $4 = $4",cc" }
        ($4 ~ /p[cms]/) && ! ($2 ~ /FORK|CHDIR|KILL|VTRACE|SETGROUPS|SETPGRP/) { $4 = $4",cc" }
        { print }' audit_event >audit_event.new
    mv audit_event.new audit_event
    cat << EOCF > audit_control
dir:/var/audit
flags:lo,ad,cc
naflags:lo,ad,ex
minfree:20
EOCF
    echo root:lo,ad:no >audit_user
    awk '/^auditconfig/ { $1 = "/usr/sbin/auditconfig" }; { print }' audit_startup >audit_startup.new
    echo '/usr/sbin/auditconfig -setpolicy +argv,arge' >>audit_startup.new
    mv audit_startup.new audit_startup
    pkgchk -f -n -p /etc/security/audit_event
    pkgchk -f -n -p /etc/security/audit_control
    pkgchk -f -n -p /etc/security/audit_startup
    cd /var/spool/cron/crontabs
    crontab -l >root.tmp
    cat << EOCF >> root.tmp
0 * * * * /usr/sbin/audit -n
# Keep time in sync
1,11,21,31,41,51 * * * * /usr/sbin/ntpdate -s 0.us.pool.ntp.org 1.us.pool.ntp.org 2.us.pool.ntp.org 3.us.pool.ntp.org
EOCF
    crontab root.tmp
    rm -f root.tmp
fi

# Confirm permissions on system log files
pkgchk -f -n -p /var/log/syslog
pkgchk -f -n -p /var/log/authlog
pkgchk -f -n -p /var/adm/utmpx
pkgchk -f -n -p /var/adm/wtmpx
chown root:sys /var/adm/loginlog
chown root:root /var/cron/log /var/adm/messages /var/log/connlog
chmod go-wx /var/adm/messages
chmod go-rwx /var/adm/loginlog /var/cron/log /var/log/connlog
chown sys:sys /var/adm/sa/*
chmod go-wx /var/adm/sa/*
dir=`awk -F: '($1 == "dir") { print $2 }' /etc/security/audit_control`
chown root:root $dir/*
chmod go-rwx $dir/*

# Set daemon umask
cd /etc/default
awk '/^CMASK=/ { $1 = "CMASK=022" } { print }' init >init.new
[ -s init.new ] && mv init.new init
pkgchk -f -n -p /etc/default/init

echo Add 'nosuid' option to /etc/rmmount.conf
if [ ! "`grep -- '-o nosuid' /etc/rmmount.conf`" ]
then
    fs=`awk '($1 == "ident") && ($2 != "pcfs") { print $2 }' /etc/rmmount.conf`
    echo mount \* $fs -o nosuid >>/etc/rmmount.conf
fi

# Verify passwd, shadow, and group file permissions
pkgchk -f -n -p /etc/passwd
pkgchk -f -n -p /etc/shadow
pkgchk -f -n -p /etc/group

# World-writable directories should have their sticky bit set
find / \( -fstype nfs -o -fstype cachefs \) -prune -o -type d \( -perm -0002 -a ! -perm -1000 \) -print

# Find unauthorized SUID/SGID system executables
find / \( -fstype nfs -o -fstype cachefs \) -prune -o -type f \( -perm -04000 -o -perm -02010 \) -print

# Find "Unowned" Files and Directories
find / \( -fstype nfs -o -fstype cachefs \) -prune -o \( -nouser -o -nogroup \) -print

# Find Files and Directories with Extended Attributes
find / \( -fstype nfs -o -fstype cachefs \) -prune -o -xattr -print

# Disable "nobody" access for secure RPC
cd /etc/default
awk '/ENABLE_NOBODY_KEYS=/ { $1 = "ENABLE_NOBODY_KEYS=NO" } { print }' keyserv >keyserv.new
pkgchk -f -n -p /etc/default/keyserv

# Configure SSH SUN SSH THAT IS ..
cat << EOCF >> /etc/ssh/ssh_config
Host *
Protocol 2
EOCF
awk '/^Protocol/ { $2 = "2" }; \
	/^X11Forwarding/ { $2 = "yes"}; \
	/^MaxAuthTries/ { $2 = "5" }; \
	/^MaxAuthTriesLog/ { $2 = "0" }; \
	/^IgnoreRhosts/ { $2 = "yes" }; \
	/^RhostsAuthentication/ { $2 = "no" }; \
	/^RhostsRSAAuthentication/ { $2 = "no" }; \
	/^PermitRootLogin/ { $2 = "no" }; \
	/^PermitEmptyPasswords/ { $2 = "no" }; \
	/^#Banner/ { $1 = "Banner" } \
	{ print }' sshd_config > sshd_config.new
[ -z "$(grep '^LookupClientHostnames' sshd_config)" ] && echo 'LookupClientHostnames no' >> sshd_config.new
[ -s sshd_config.new ] && mv sshd_config.new sshd_config
pkgchk -f -n -p /etc/ssh/sshd_config

# Remove .rhosts support in /etc/pam.conf
cd /etc
grep -v rhosts_auth pam.conf > pam.conf.new
[ -s pam.conf.new ] && mv pam.conf.new pam.conf
pkgchk -f -n -p /etc/pam.conf

# Create /etc/ftpd/ftpusers
cd /etc/ftpd
for user in root daemon bin sys adm lp uucp nuucp smmsp listen gdm webservd nobody noaccess nobody4
do
    echo $user >>ftpusers
done
sort -u ftpusers >ftpusers.new
[ -s ftpusers.new ] && mv ftpusers.new ftpusers
pkgchk -f -n -p /etc/ftpd/ftpusers

# Prevent email server from listening on external interfaces
cd /etc/mail
awk '/DaemonPortOptions=/ && /inet6/ { print "#"$0; next };
	/DaemonPortOptions=/ && !/inet6/ \
	{ print $0 ", Addr=127.0.0.1"; next };
	{ print }' sendmail.cf >sendmail.cf.new
[ -s sendmail.cf.new ] && mv sendmail.cf.new sendmail.cf
pkgchk -f -n -p /etc/mail/sendmail.cf

# Prevent Syslog from accepting messages from network
cd /etc/default
awk '/LOG_FROM_REMOTE=/ { $1 = "LOG_FROM_REMOTE=NO" } { print }' syslogd >syslogd.new
[ -s syslogd.new ] && mv syslogd.new syslogd
pkgchk -f -n -p /etc/default/syslogd

# Remove empty crontab files and restrict file permissions
cd /var/spool/cron/crontabs
for file in *
do
    lines=`grep -v '^#' $file | wc -l | sed 's/ //g'`
    if [ "$lines" = "0" ]
    then
        crontab -r $file
    fi
done
chown root:sys *
chmod 400 *

# Restrict at/cron to authorized users
cd /etc/cron.d
rm -f cron.deny at.deny
echo root >cron.allow
cp /dev/null at.allow
chown root:root cron.allow at.allow
chmod 400 cron.allow at.allow

# Restrict root logins to system console
cd /etc/default
awk '/CONSOLE=/ { print "CONSOLE=/dev/console"; next }; { print }' login >login.new
[ -s login.new ] && mv login.new login
pkgchk -f -n -p /etc/default/login

# Set retry limit for account lockout
cd /etc/default
awk '/RETRIES=/ { $1 = "RETRIES=5" } { print }' login >login.new
[ -s login.new ] && mv login.new login
pkgchk -f -n -p /etc/default/login
cd /etc/security
awk '/LOCK_AFTER_RETRIES=/ { $1 = "LOCK_AFTER_RETRIES=YES" } { print }' policy.conf >policy.conf.new
[ -s policy.conf.new ] && mv policy.conf.new policy.conf
pkgchk -f -n -p /etc/security/policy.conf

# passwd -l daemon
for user in bin nuucp smmsp listen gdm webservd nobody noaccess nobody4
do
    passwd -l $user
    /usr/sbin/passmgmt -m -s /dev/null $user
done
passwd -N sys
for user in adm lp uucp
do
    passwd -N $user
    /usr/sbin/passmgmt -m -s /dev/null $user
done

# Verify that there are no accounts with empty password fields
echo ============
echo There should be nothing here ...
echo logins -p
echo ============

# Verify no legacy '+' entries exist in passwd, shadow, and group files
echo ============
echo There should be nothing here ...
grep '^+:' /etc/shadow /etc/passwd /etc/shadow /etc/group
echo ============

# Verify that no UID 0 accounts exist other than root
echo ============
echo There can be only one root ...
logins -o | awk -F: '($2 == 0) { print $1 }'
echo ============

# Set default group for root account
passmgmt -m -g 0 root

# User home directories should be mode 750 or more restrictive
for dir in `logins -ox | awk -F: '($8 == "PS" && $1 != "root") { print $6 }'`
do
    chmod g-w $dir
    chmod o-rwx $dir
done

# No user dot-files should be group/world writable
# Remove user .netrc files
for dir in `logins -ox | awk -F: '($8 == "PS") { print $6 }'`
do
    rm -f $dir/.netrc
    for file in $dir/.[A-Za-z0-9]*
    do
        if [ ! -h "$file" -a -f "$file" ]
        then
            chmod go-w "$file"
        fi
    done
done

# Set default umask for users
cd /etc/default
awk '/UMASK=/ { $1 = "UMASK=077" } { print }' login >login.new
[ -s login.new ] && mv login.new login
cd /etc
for file in profile .login
do
    if [ "`grep umask $file`" ]
    then
        awk '$1 == "umask"{ $2 = "077" } { print }' $file >$file.new
        mv $file.new $file
    else
        echo umask 077 >>$file
    fi
done
pkgchk -f -n -p /etc/default/login
pkgchk -f -n -p /etc/profile
pkgchk -f -n -p /etc/.login

# Set default umask for FTP users
cd /etc/ftpd
if [ "`grep '^defumask' ftpaccess`" ]
then
    awk '/^defumask/ { $2 = "077" } { print }' ftpaccess >ftpaccess.new
    mv ftpaccess.new ftpaccess
else
    echo defumask 077 >>ftpaccess
fi
pkgchk -f -n -p /etc/ftpd/ftpaccess

# Set "mesg n" as default for all users
cd /etc
for file in profile .login
do
    if [ "`grep mesg $file`" ]
    then
        awk '$1 == "mesg" { $2 = "n" } { print }' $file >$file.new
        mv $file.new $file
    else
        echo mesg n >>$file
    fi
    pkgchk -f -n -p /etc/$file
done

# Banners ...
cat << EOCF > /etc/issue
#
#
#  WARNING:  You must have prior authorization to access this system.
#            All connections are logged and monitored. By connecting to
#            to this system you fully consent to all monitoring.
#            Unauthorized access or use will be prosecuted to the full
#            extent of the law.  You have been warned.
#
#
EOCF
cp /etc/issue /etc/motd
pkgchk -f -n -p /etc/motd
chown root:root /etc/issue
chmod 644 /etc/issue

# Create warnings for FTP daemon
echo 'Authorized uses only. All activity may be monitored and reported.' >/etc/ftpd/banner.msg 
chown root:root /etc/ftpd/banner.msg
chmod 444 /etc/ftpd/banner.msg

if [ `uname -p` = 'sparc' ]
then
    # Create power-on warning
    eeprom oem-banner='Authorized uses only. All activity may be monitored and reported.'
    eeprom oem-banner?=true
fi

#-----------------------------------------------------------
mkdir -p /usr/local/var/lib
echo "All users in the 'wheel' grounp are already allowed to use 'sudo'"
read -p 'Sudo users [e.g. joe,jim,sally] ? ' SADMIN
cat << EOT > /usr/local/etc/sudoers
# sudoers file.
#
# This file MUST be edited with the 'visudo' command as root.
#
# See the sudoers man page for the details on how to write a sudoers file.
#

# Reset environment by default
Defaults       env_reset

# Host alias specification

# User alias specification
User_Alias      ADMIN = $SADMIN

# Cmnd alias specification

# Defaults specification
#Defaults        syslog=authpriv
Defaults        always_set_home,insults,requiretty
Defaults        passprompt="%u's password: "

# Runas alias specification

# User privilege specification
root    ALL=(ALL) ALL
ADMIN   ALL=(ALL) ALL

# Uncomment to allow people in group wheel to run all commands
%wheel        ALL=(ALL)       ALL

# Same thing without a password
# %wheel        ALL=(ALL)       NOPASSWD: ALL

# Samples
# %users  ALL=/sbin/mount /cdrom,/sbin/umount /cdrom
# %users  localhost=/sbin/shutdown -h now

## Read drop-in files from /usr/local/etc/sudoers.d
## (the '#' here does not indicate a comment)
#includedir /usr/local/etc/sudoers.d
EOT

#-----------------------------------------------------------
cat << EOT > /tmp/profile
#ident  "@(#)profile    1.18    98/10/03 SMI"   /* SVr4.0 1.3   */

# The profile that all logins get before using their own .profile.

trap ""  2 3
if [ -d /usr/local/bin ]; then
    PATH=\$PATH:/usr/local/bin
    [ "T\$LOGNAME" = "Troot" ] && PATH=\$PATH:/usr/local/sbin
    MANPATH=\$MANPATH:/usr/man:/usr/local/man
fi
if [ -d /usr/local/ssl/lib ]; then
    LD_LIBRARY_PATH="\$LD_LIBRARY_PATH:/usr/local/ssl/lib"
fi
if [ "T\$LOGNAME" = "Troot" ]; then
    [ -d /usr/ccs/bin ] && PATH=\$PATH:/usr/ccs/bin
    [ -d /usr/opt/SUNWmd/sbin ] && PATH=\$PATH:/usr/opt/SUNWmd/sbin
    [ -d /usr/local/ssl/bin ] && PATH=\$PATH:/usr/local/ssl/bin
fi
export LOGNAME PATH MANPATH LD_LIBRARY_PATH
EOT
sed '1,/^export/d' /etc/profile >> /tmp/profile
cat /tmp/profile > /etc/profile

#-----------------------------------------------------------
cat << EOT > /etc/resolv.conf
nameserver 4.2.2.1
nameserver 4.2.2.2
EOT

cat << EOT > /etc/nsswitch.conf
#
# Copyright 2006 Sun Microsystems, Inc.  All rights reserved.
# Use is subject to license terms.
#

#
# /etc/nsswitch.dns:
#
# An example file that could be copied over to /etc/nsswitch.conf; it uses
# DNS for hosts lookups, otherwise it does not use any other naming service.
#
# "hosts:" and "services:" in this file are used only if the
# /etc/netconfig file has a "-" for nametoaddr_libs of "inet" transports.

# DNS service expects that an instance of svc:/network/dns/client be
# enabled and online.

passwd:     files
group:      files

# You must also set up the /etc/resolv.conf file for DNS name
# server lookup.  See resolv.conf(4).
hosts:      files dns

# Note that IPv4 addresses are searched for in all of the ipnodes databases
# before searching the hosts databases.
ipnodes:   files dns

networks:   files
protocols:  files
rpc:        files
ethers:     files
netmasks:   files
bootparams: files
publickey:  files
# At present there isn't a 'files' backend for netgroup;  the system will 
#   figure it out pretty quickly, and won't use netgroups at all.
netgroup:   files
automount:  files
aliases:    files
services:   files
printers:       user files

auth_attr:  files
prof_attr:  files
project:    files

tnrhtp:     files
tnrhdb:     files
EOT
