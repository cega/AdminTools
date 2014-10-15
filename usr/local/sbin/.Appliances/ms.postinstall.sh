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

##########
# NETWORK parameters
##########
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

LOCALDOMAIN=$(hostname -d)

LOCALIP=$(ifconfig eth0 | sed -rn 's/.*r:([^ ]+) .*/\1/p')
LOCALMASK=$(ifconfig eth0 | sed -n -e 's/.*Mask:\(.*\)$/\1/p')
CIDRMASK=$(mask2cdr $LOCALMASK)
# From: http://www.routertech.org/viewtopic.php?t=1609
l="${LOCALIP%.*}";r="${LOCALIP#*.}";n="${LOCALMASK%.*}";m="${LOCALMASK#*.}"
LOCALNET=$((${LOCALIP%%.*}&${LOCALMASK%%.*})).$((${r%%.*}&${m%%.*})).$((${l##*.}&${n##*.})).$((${LOCALIP##*.}&${LOCALMASK##*.}))

MXHOST=$(host mx | awk '/has address/ {print $NF}')
if [ -z "$MXHOST" ]
then
    read -p 'IP address of MX server ? ' MXHOST
fi

#########
# Base packages
#########
apt-get install lamp-server^ mail-server^

##########
# POSTFIX
##########
apt-get install postfix-pcre

# Ensure we use the correct postfix config_directory
PF_CD=$(postconf -h config_directory)

# Setup postfix transport table (recipient based routing)
postconf -e 'transport_maps = hash:'$PF_CD/transport
[ -s $PF_CD/transport ] || touch $PF_CD/transport
postmap $PF_CD/transport

# Setup sender-based email routing
postconf -e 'sender_dependent_relayhost_maps=hash:'$PF_CD/sender_mail_routing
[ -s $PF_CD/sender_mail_routing ] || touch $PF_CD/sender_mail_routing
postmap $PF_CD/sender_mail_routing

# Message size is at least 20MB (!!!)
MAXMSGSIZE=$(postconf -h message_size_limit)
[ $MAXMSGSIZE -lt $((20 * 1024 * 1024)) ] && MAXMSGSIZE=$((20 * 1024 * 1024))
QUEUE_MINFREE=$((2 * $MAXMSGSIZE))
postconf -e 'message_size_limit = '$MAXMSGSIZE
postconf -e 'queue_minfree = '$QUEUE_MINFREE
postconf -e 'local_transport = error:no local mail delivery'

# We are a final destination for some names
# (others are virtual domains)
postconf -e 'mydestination = ms.btoy1.rochester.ny.us, localhost.btoy1.rochester.ny.us, ms.btoy1.net, localhost.btoy1.net, localhost'

# Send email via the MX host
[ -z "$MXHOSTS" ] || postconf -e "relayhost = $MXHOST"

# Enable useful rejections for unknown clients
# - Allow everything from legitimate networks
# - Check 'sender_access' for rejected IPs or addresses
# - Reject IPs listed by spamhaus
postconf -e "smtpd_client_restrictions = permit_mynetworks,check_client_access hash:$PF_CD/sender_access,reject_rbl_client zen.spamhaus.org=127.0.0.2,reject_rbl_client zen.spamhaus.org=127.0.0.3,reject_rbl_client zen.spamhaus.org=127.0.0.4,reject_rbl_client zen.spamhaus.org=127.0.0.5,reject_rbl_client zen.spamhaus.org=127.0.0.6,reject_rbl_client zen.spamhaus.org=127.0.0.7,reject_rbl_client zen.spamhaus.org=127.0.0.8,permit"

# Enable useful rejections for unknown senders
# - Check 'sender_access' for rejected IPs or addresses
# - Reject senders without full-qualified domain names
# - Check 'mx_access' for rejected IPs
postconf -e "smtpd_sender_restrictions = check_sender_access hash:$PF_CD/sender_access,reject_non_fqdn_sender,check_sender_mx_access hash:$PF_CD/mx_access,permit"

# Enable useful rejections for unknown recipients
# - Allow everything from legitimate networks
# - Reject unauthorized destinations
# - Reject unauthorized pipelining
# - Reject unknown recipient domains
# - Check 'mx_access' for rejected IPs
postconf -e "smtpd_recipient_restrictions = permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination,reject_unauth_pipelining,reject_unknown_recipient_domain,check_recipient_mx_access hash:$PF_CD/mx_access"
postconf -e 'address_verify_map = btree:$data_directory/verify_cache'

# Enable useful rejections for data phase
# - Reject unauthorized pipelining
postconf -e 'smtpd_data_restrictions = reject_unauth_pipelining,permit'

# Disable some unnecessary commands
postconf -e 'smtpd_discard_ehlo_keywords=vrfy,etrn'
postconf -e 'disable_vrfy_command = yes'

if [ ! -s $PF_CD/mx_access ]
then
    cat << EOT > $PF_CD/mx_access
0        REJECT Domain MX in broadcast network
127      REJECT Domain MX in loopback network
169.254  REJECT Domain MX in link local network
224      REJECT Domain MX in class D multicast network
225      REJECT Domain MX in class D multicast network
226      REJECT Domain MX in class D multicast network
227      REJECT Domain MX in class D multicast network
228      REJECT Domain MX in class D multicast network
229      REJECT Domain MX in class D multicast network
230      REJECT Domain MX in class D multicast network
231      REJECT Domain MX in class D multicast network
232      REJECT Domain MX in class D multicast network
233      REJECT Domain MX in class D multicast network
234      REJECT Domain MX in class D multicast network
235      REJECT Domain MX in class D multicast network
236      REJECT Domain MX in class D multicast network
237      REJECT Domain MX in class D multicast network
238      REJECT Domain MX in class D multicast network
239      REJECT Domain MX in class D multicast network
240      REJECT Domain MX in class E multicast network
241      REJECT Domain MX in class E multicast network
242      REJECT Domain MX in class E multicast network
243      REJECT Domain MX in class E multicast network
244      REJECT Domain MX in class E multicast network
245      REJECT Domain MX in class E multicast network
246      REJECT Domain MX in class E multicast network
247      REJECT Domain MX in class E multicast network
248      REJECT Domain MX in class E multicast network
249      REJECT Domain MX in reserved network
250      REJECT Domain MX in reserved network
251      REJECT Domain MX in reserved network
252      REJECT Domain MX in reserved network
253      REJECT Domain MX in reserved network
254      REJECT Domain MX in reserved network
255      REJECT Domain MX in reserved network
EOT
fi
postmap $PF_CD/mx_access

if [ ! -s $PF_CD/sender_access ]
then
    cat << EOT > $PF_CD/sender_access
btoy1.net	OK
btoy1.rochester.ny.us	OK
EOT
fi
postmap $PF_CD/sender_access

# Ensure that the header and body checks are perl regex tables
postconf -e 'header_checks = pcre:'$PF_CD/header_checks
postconf -e 'mime_header_checks = pcre:'$PF_CD/header_checks
postconf -e 'nested_header_checks = pcre:'$PF_CD/header_checks
postconf -e 'body_checks = pcre:'$PF_CD/body_checks

if [ ! -s $PF_CD/header_checks ]
then
    cat << EOT > $PF_CD/header_checks
!/^\S+/ REJECT Invalid header syntax
/^Received:.*localhost/ IGNORE
/^Received:.*127.0.0.1/ IGNORE
/[^[:print:]]{8}/       REJECT Your email program is not RFC 2057 compliant
/^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.(386|ad[ept]|app|as[dpx]|ba[st]|bin|btm|cab|cb[lt]|cgi|chm|cil|cla(ss)?|cmd|cp[el]|crt|cs[chs]|cvp|dll|dot|drv)"?(;|\$)/      REJECT ".\$2" file attachment not allowed. Please zip and resend.
/^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.(em(ai)?l|ex[_e]|fon|fxp|hlp|ht[ar]|in[fips]|isp|jar|jse?|keyreg|ksh|lib|lnk|md[abetw]|mht(m|ml)?|mp3|ms[ciopt])"?(;|\$)/     REJECT ".\$2" file attachment not allowed. Please zip and resend.
/^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.(nte|nws|obj|ocx|ops|ov.|pcd|pgm|pif|p[lm]|pot|pps|prg|reg|sc[rt]|sh[bs]?|slb|smm|sw[ft]|sys|url|vb[esx]?|vir])"?(;|\$)/      REJECT ".\$2" file attachment not allowed. Please zip and resend.
/^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.(vmx|vxd|wm[dsz]|ws[cfh]|xl[^s]|xms|{[da-f]{8}(?:-[da-f]{4}){3}-[da-f]{12}})"?(;|\$)/ REJECT ".\$2" file attachment not allowed. Please zip and resend.
/^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.com(\.\S{2,4})?(?=)?"?(;|\$)/    REJECT ".com" file attachment not allowed
/charset="?(koi8-?r|windows-1251|ISO_5427|cyrillic)/    WARN Can not read cyrillic characters
/charset="?.*(JIS|-JP|jp-|Windows-31J)/ WARN Can not read japanese characters
/charset="?.*(-KR)/     WARN Can not read korean characters
/charset="?.*(arabic|hebrew)/   WARN Can not read arabic or hebrew characters
/charset="?(GP|Big5)/   WARN Can not read chinese characters
/charset="?VISCII/      WARN Can not read vietnamese characters
/charset="?(iso-8859-9|windows-1254)/   WARN Can not read turkish characters
EOT
fi
if [ ! -s $PF_CD/body_checks ]
then
    cat << EOT > $PF_CD/body_checks
/^[A-Za-z0-9+\/=]{4,76}\$/       OK
/<iframe src=(3D)?cid:.* height=(3D)?0 width=(3D)?0>/   REJECT Email contains the IFrame Exploit
/<\s*(object\s+data)\s*=/       REJECT Email with "\$1" tags not allowed
/<\s*(script\s+language\s*="vbs")/      REJECT Email with "\$1" tags not allowed
/<\s*(script\s+language\s*="VBScript\.Encode")/ REJECT Email with "\$1" tags not allowed
EOT
fi
# Postfix tuning
postconf -e 'queue_run_delay = 6m'
postconf -e 'bounce_queue_lifetime = 3h'
postconf -e 'bounce_size_limit = 512'
postconf -e 'minimal_backoff_time = 6m'
postconf -e 'maximal_backoff_time = 60m'
postconf -e 'smtpd_banner = ms.btoy1.net ESMTP UCE'
postconf -e 'biff = no'
postconf -e 'address_verify_negative_refresh_time = 60m'

# Postfix TLS debugging
postconf -e 'smtpd_tls_received_header = yes'
postconf -e 'smtpd_tls_loglevel = 1'
postconf -e 'smtp_tls_loglevel = 1'

# Postfix per-recipient domain TLS settings
postconf -e 'smtp_tls_per_site = hash:'$PF_CD/smtp_tls_per_site
# Create some dummy settings if necessary
if [ ! -s $PF_CD/smtp_tls_per_site ]
then
    [ -z "$MXHOST" ] || cat << EOT > $PF_CD/smtp_tls_per_site
# See: http://www.postfix.org/TLS_README.html
$MXHOST    none
EOT
fi
postmap $PF_CD/smtp_tls_per_site

# Set some useful names
postconf -e 'myorigin = mail.'$LOCALDOMAIN
postconf -e 'mydomain = '$LOCALDOMAIN
postconf -e 'mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 '$LOCALNET/$CIDRMASK

# Enable SUBMISSION
if [ -z "$(grep ^submission $PF_CD/master.cf)" ]
then
    cat << EOT >> $PF_CD/master.cf

# Enable "submission"
submission inet n       -       -       -       -       smtpd
  -o content_filter=
  -o syslog_name=postfix/submission
  -o receive_override_options=no_header_body_checks
  -o mynetworks=127.0.0.0/8,192.168.1.0/24
  -o smtpd_recipient_restrictions=permit_mynetworks,reject
  -o delay_warning_time=2h
EOT
fi

# Enable SMTPS
if [ -z "$(grep ^smtps $PF_CD/master.cf)" ]
then
    cat << EOT >> $PF_CD/master.cf

# Enable SMTPS
smtps     inet  n       -       -       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOT
fi

# Refresh aliases and restart postfix
newaliases
postfix start || /etc/init.d/postfix restart

##########
# AV (clamav)
##########
apt-get install clamav-daemon clamav-freshclam clamav-milter clamsmtp
freshclam -v
/etc/init.d/clamav-daemon restart

# Enable clamav filter
if [ -z "$(grep ^cscan $PF_CD/master.cf)" ]
then
    cat << EOT >> $PF_CD/master.cf

# AV scan filter (used by content_filter)
cscan      unix  -       -       n       -       16      smtp
  -o smtp_send_xforward_command=yes
  -o smtp_enforce_tls=no
# For injecting mail back into postfix from the filter
127.0.0.1:10025 inet  n -       n       -       16      smtpd
  -o content_filter=
  -o receive_override_options=no_unknown_recipient_checks,no_header_body_checks
  -o smtpd_helo_restrictions=
  -o smtpd_client_restrictions=
  -o smtpd_sender_restrictions=
  -o smtpd_recipient_restrictions=permit_mynetworks,reject
  -o mynetworks_style=host
  -o smtpd_authorized_xforward_hosts=127.0.0.0/8
EOT
    postconf -e 'content_filter = cscan:[127.0.0.1]:10026'
fi

##########
# Postfix admin frontend (adapt to newer version as shown
#  on http://sourceforge.net/projects/postfixadmin/files/postfixadmin/)
##########
wget -O /usr/local/src/postfixadmin_all.deb \
  http://sourceforge.net/projects/postfixadmin/files/postfixadmin/postfixadmin-2.91/postfixadmin_2.91-1_all.deb/download

# Setup the package, its dependencies and the database
apt-get install dbconfig-common libc-client2007e mlock php5-imap wwwconfig-common postfix-mysql sasl2-bin
dpkg -Ei /usr/local/src/postfixadmin_all.deb

PF_PASS='calf5Glo'
ADMIN_PASS=$(awk -F= '/^dbc_dbpass/ {print $2}' /etc/dbconfig-common/postfixadmin.conf | sed "s/'//g")
mysql mysql << EOT
GRANT ALL PRIVILEGES ON postfixadmin.* TO 'postfixadmin'@'%' IDENTIFIED BY '$ADMIN_PASS';
GRANT SELECT ON postfixadmin.* TO 'postfix'@'localhost' IDENTIFIED BY '$PF_PASS';
EOT

if [ ! -z "$MXHOST" ]
then
    # Allow "les" access from "mx" to postfixadmin database
    MX_PASS='CuHy4Wheat'
    mysql mysql << EOT
GRANT SELECT ON postfixadmin.* TO 'les'@'$MXHOST' IDENTIFIED BY '$MX_PASS';
EOT
fi

# Allow mysql connections from anywhere (controlled by firehol)
sed -i 's/^bind-add/#LISTEN TO ALL INTERFACES#bind-add/' /etc/mysql/my.cnf

# Protect the setup script in the Apache tree
PA_WEBROOT=$(awk '/^Alias.*postfixadmin/ {print $3}' /etc/apache2/conf.d/postfixadmin)
cat << EOT > $PA_WEBROOT/.htaccess
<Files "setup.php">
allow from "$LOCALNET/$CIDRMASK"
deny from all
</Files>
EOT

# Adapt the apache default page config
if [ -z "$(grep postfixadmin /etc/apache2/sites-enabled/default.conf)" ]
then
    rm -f /etc/apache2/sites-enabled/default.conf
    cat << EOT > /etc/apache2/sites-enabled/default.conf
<VirtualHost *:80>
	# The ServerName directive sets the request scheme, hostname and port that
	# the server uses to identify itself. This is used when creating
	# redirection URLs. In the context of virtual hosts, the ServerName
	# specifies what hostname must appear in the request's Host: header to
	# match this virtual host. For the default virtual host (this file) this
	# value is not decisive as it is used as a last resort host regardless.
	# However, you must set it for any further virtual host explicitly.
	#ServerName www.example.com

	ServerAdmin webmaster@localhost
	DocumentRoot /var/www/html

	# Available loglevels: trace8, ..., trace1, debug, info, notice, warn,
	# error, crit, alert, emerg.
	# It is also possible to configure the loglevel for particular
	# modules, e.g.
	#LogLevel info ssl:warn

	ErrorLog \${APACHE_LOG_DIR}/error.log
	CustomLog \${APACHE_LOG_DIR}/access.log combined

	# For most configuration files from conf-available/, which are
	# enabled or disabled at a global level, it is possible to
	# include a line for only one particular virtual host. For example the
	# following line enables the CGI configuration for this host only
	# after it has been globally disabled with "a2disconf".
	#Include conf-available/serve-cgi-bin.conf
	Include conf.d/postfixadmin
</VirtualHost>

# vim: syntax=apache ts=4 sw=4 sts=4 sr noet
EOT
fi

# Adapt the main index file
if [ -z "$(grep B-LUC /var/www/html/index.html)" ]
then
    cat << EOT > /var/www/html/index.html
<!DOCTYPE html>
<html>
<head>
<title>Welcome</title>
 <meta name="copyright" content="B-LUC Consulting">
 <meta http-equiv="refresh" content="2;url=postfixadmin/">
</head>
<body>
 You will be redirected to the Postfix Administrator in two seconds. If
 you aren't forwarded to the it, please click <a href=postfixadmin/> here </a>.
</body>
</html>
EOT
fi
# Adapt the database type to "mysqli"
perl -p -i -e 's/dbtype=.mysql.;/dbtype="mysqli";/' /etc/postfixadmin/dbconfig.inc.php

# Go through the necessary setup steps
if [ ! -z "$(grep 'setup_password.*changeme' /etc/postfixadmin/config.inc.php)" ]
then
    cat << EOT
Point your browser to http://$LOCALIP/postfixadmin/setup.php.

Follow the instructions on that page to choose a suitable
 setup password, and generate a hash of that password.

Add that hash to the configuration file '/etc/postfixadmin/config.inc.php' and save it:
// In order to setup Postfixadmin, you MUST specify a hashed password here.
// To create the hash, visit setup.php in a browser and type a password into
// the field,
// on submission it will be echoed out to you as a hashed value.
\$CONF['setup_password'] = '...a long hash string...';

Choose "postmaster@btoy1.net" as the administrative username and
 "Dog4Leak" as its password (or any other suitable combination
 of username and password).
EOT
    read -p 'Press <ENTER> to continue' YN
fi

# Setup the account and group for virtual mail
[ -z "$(getent group vmail)" ] && groupadd -g 5000 vmail
if [ -z "$(getent passwd vmail)" ]
then
    useradd -r -u 5000 -g vmail -d /home/vmail -s /sbin/nologin -c "Virtual maildir handler" vmail
    mkdir /home/vmail
    chmod 770 /home/vmail
    chown vmail:vmail /home/vmail
fi

# Adapt postfix
postconf -e 'virtual_uid_maps = static:5000'
postconf -e 'virtual_gid_maps = static:5000'
postconf -e 'virtual_mailbox_base = /home/vmail'
postconf -e 'virtual_mailbox_domains = mysql:'$PF_CD/mysql_virtual_mailbox_domains.cf
postconf -e 'virtual_mailbox_maps = mysql:'$PF_CD/mysql_virtual_mailbox_maps.cf
postconf -e 'virtual_alias_maps = mysql:'$PF_CD/mysql_virtual_alias_maps.cf
postconf -e 'relay_domains = mysql:'$PF_CD/mysql_relay_domains.cf

cat << EOT > $PF_CD/mysql_virtual_mailbox_domains.cf
hosts = 127.0.0.1
user = postfix
password = $PF_PASS
dbname = postfixadmin
query = SELECT domain FROM domain WHERE domain='%s' and backupmx = 0 and active = 1
EOT

cat << EOT > $PF_CD/mysql_virtual_mailbox_maps.cf
hosts = 127.0.0.1
user = postfix
password = $PF_PASS
dbname = postfixadmin
query = SELECT maildir FROM mailbox WHERE username='%s' AND active = 1
EOT

cat << EOT > $PF_CD/mysql_virtual_alias_maps.cf
hosts = 127.0.0.1
user = postfix
password = $PF_PASS
dbname = postfixadmin
query = SELECT goto FROM alias WHERE address='%s' AND active = 1
EOT

cat << EOT > $PF_CD/mysql_relay_domains.cf
hosts = 127.0.0.1
user = postfix
password = $PF_PASS
dbname = postfixadmin
query = SELECT domain FROM domain WHERE domain='%s' and backupmx = 1
EOT

cat << EOT > $PF_CD/sasl/smtpd.conf
pwcheck_method: saslauthd
allow_plaintext: true
mech_list: PLAIN LOGIN
auxprop_plugin: rimap
EOT

cat << EOT > /etc/default/saslauthd
START=yes
MECHANISMS="rimap"
#imap server address
MECH_OPTIONS="localhost"
OPTIONS="-c -m /var/spool/postfix/var/run/saslauthd -r"
EOT
adduser postfix sasl

# SASL parameters in postfix
postconf -e 'smtpd_sasl_type = dovecot'
# Referring to /var/spool/postfix/private/auth
postconf -e 'smtpd_sasl_path = private/auth'
postconf -e 'smtpd_sasl_auth_enable = yes'
postconf -e 'broken_sasl_auth_clients = yes'
postconf -e 'smtpd_sasl_security_options = noanonymous'
postconf -e 'smtpd_sasl_local_domain ='
postconf -e 'smtpd_sasl_authenticated_header = yes'

##########
# DOVECOT
##########
apt-get --purge remove dovecot-pop3d
apt-get install dovecot-sieve dovecot-managesieved dovecot-mysql

cat << EOT > /etc/dovecot/dovecot-mysql.conf
driver = mysql
connect = host=127.0.0.1 dbname=postfixadmin user=postfix password=$PF_PASS
default_pass_scheme = MD5-CRYPT
user_query = SELECT '/home/vmail/%d/%n' as home, 5000 AS uid, 5000 AS gid FROM mailbox WHERE username = '%u'
password_query = SELECT password FROM mailbox WHERE username = '%u'
EOT

cat << EOT > /etc/dovecot/local.conf
# Location for users' mailboxes. The default is empty, which means that
# Dovecot
# tries to find the mailboxes automatically. This won't work if the user
# doesn't yet have any mail, so you should explicitly tell Dovecot the full
# location.
#
# If you're using mbox, giving a path to the INBOX file (eg. /var/mail/%u)
# isn't enough. You'll also need to tell Dovecot where the other mailboxes
# are
# kept. This is called the "root mail directory", and it must be the first
# path given in the mail_location setting.
#
# There are a few special variables you can use, eg.:
#
#   %u - username
#   %n - user part in user@domain, same as %u if there's no domain
#   %d - domain part in user@domain, empty if there's no domain
#   %h - home directory
#
# See doc/wiki/Variables.txt for full list. Some examples:
#
#   mail_location = maildir:~/Maildir
#   mail_location = mbox:~/mail:INBOX=/var/mail/%u
#   mail_location = mbox:/var/mail/%d/%1n/%n:INDEX=/var/indexes/%d/%1n/%n
#
# <doc/wiki/MailLocation.txt>
#
mail_location = maildir:/home/vmail/%d/%n/Maildir:INDEX=/home/vmail/%d/%n/Maildir/indexes

# System user and group used to access mails. If you use multiple, userdb
# can override these by returning uid or gid fields. You can use either
# numbers
# or names. <doc/wiki/UserIds.txt>
mail_uid = vmail
mail_gid = vmail

# Allow LOGIN command and all other plaintext authentications
disable_plaintext_auth = no

# Space separated list of wanted authentication mechanisms:
#   plain login digest-md5 cram-md5 ntlm rpa apop anonymous gssapi otp skey
#   gss-spnego
# NOTE: See also disable_plaintext_auth setting.
auth_mechanisms = plain login

# Space separated protocols
protocols = imap sieve

# Valid UID range for users, defaults to 500 and above. This is mostly
# to make sure that users can't log in as daemons or other system users.
# Note that denying root logins is hardcoded to dovecot binary and can't
# be done even if first_valid_uid is set to 0.
#
# Use the vmail user uid here.
first_valid_uid = 5000
last_valid_uid = 5000

# See http://wiki2.dovecot.org/MailLocation/LocalDisk
# Default to no fsyncing
mail_fsync = never

###
userdb {
  driver = sql
  args = /etc/dovecot/dovecot-mysql.conf
}
passdb {
  driver = sql
  args = /etc/dovecot/dovecot-mysql.conf
}
userdb static {
  driver = static
  args = uid=5000 gid=5000 home=/home/vmail/%d/%n
}

###
protocol imap {
  mail_plugin_dir = /usr/lib/dovecot/modules
  mail_plugins = mail_log zlib fts fts_squat notify
}
protocol lda {
  auth_socket_path = /var/run/dovecot/auth-userdb
  mail_plugin_dir = /usr/lib/dovecot/modules
  mail_plugins = mail_log zlib fts fts_squat notify sieve
  postmaster_address = rootmail@$LOCALDOMAIN
  # Enable fsyncing for LDA
  mail_fsync = optimized
}
protocol lmtp {
  # Enable fsyncing for LMTP
  mail_fsync = optimized
}

###
service auth {
  # auth_socket_path points to this userdb socket by default. It's typically
  # used by dovecot-lda, doveadm, possibly imap process, etc. Its default
  # permissions make it readable only by root, but you may need to relax
  # these
  # permissions. Users that have access to this socket are able to get a
  # list
  # of all usernames and get results of everyone's userdb lookups.
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
    group = vmail
  }

  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    # Assuming the default Postfix user and group
    user = postfix
    group = postfix
  }
}
service imap-login {
  service_count = 100
  #client_limit = \$default_client_limit
  process_min_avail = 2
  #vsz_limit = 64M
}
service imap {
  service_count = 0
  process_min_avail = 2
  client_limit = 20
}

# Enable SSL (http://wiki2.dovecot.org/SSL/DovecotConfiguration)
ssl = yes
# Preferred permissions: root:root 0444
ssl_cert = </etc/ssl/certs/dovecot.pem
# Preferred permissions: root:root 0400
ssl_key = </etc/ssl/private/dovecot.pem

# Only allow TLSv1 and above
ssl_cipher_list = HIGH:MEDIUM:+TLSv1:!SSLv2:!SSLv3
ssl_protocols = !SSLv2

# More connections per user+IP
mail_max_userip_connections = 25

# Sieve manager
plugin {
  #login_executable = /usr/lib/dovecot/managesieve-login
  #mail_executable = /usr/lib/dovecot/managesieve
  #managesieve_logout_format = bytes=%i/%o
  sieve_storage = /home/vmail/%d/%n/sieve/
  sieve = /home/vmail/%d/%n/.dovecot.sieve
  sieve_dir = /home/vmail/%d/%n/sieve/
}
service managesieve-login {
  inet_listener sieve {
    port = 4190
  }
}

# Uncomment the following only for debugging:
# auth_debug = yes
EOT

echo "Comment the section in /etc/dovecot/conf.d/auth-system.conf.ext which enables PAM authentication"
read -p 'Press ENTER to edit' E
vi /etc/dovecot/conf.d/auth-system.conf.ext

# Make the configuration available to virtual users
chown -R vmail:dovecot /etc/dovecot
chmod -R o-rwx /etc/dovecot

# Install local transport in postfix
if [ -z "$(grep ^dovecot $PF_CD/master.cf)" ]
then
    cat << EOT >> $PF_CD/master.cf

# Use dovecot to deliver emails
dovecot unix - n n - - pipe
  flags=DRhu user=vmail:vmail argv=/usr/lib/dovecot/deliver -d ${recipient}
EOT
fi
postconf -e 'virtual_transport=dovecot'
postconf -e 'dovecot_destination_recipient_limit=1'
