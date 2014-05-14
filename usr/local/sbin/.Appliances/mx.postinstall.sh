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
# Email flows:
# Incoming port            Component  Checks performed  Outgoing port
# *:25 (smtpd)             postfix    ppolicyd, rbl     127.0.0.1:11125 (lmtp)
# *:465 (smtpd[s])         postfix    ppolicyd, rbl     127.0.0.1:11125 (lmtp)
# 127.0.0.1:11125 (lmtpd)  dspam      antispam          127.0.0.1:10025 (smtp)
# 127.0.0.1:10025 (smtpd)  amavisd    antivirus         127.0.0.1:10026 (smtp)
# 127.0.0.1:10026 (smtpd)  postfix                      *:25 (smtp)
# *:587 (submission)       postfix                      *.25 (smtp)
# Note: 465 and 587 are not allowed from outside LAN
#       465 requires authentication

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

#####
# DCC
#####
add-apt-repository ppa:jonasped/ppa
apt-get update
apt-get dcc-client dcc-common
for F in $(grep -l loadplugin.*DCC /etc/spamassassin/*)
do
    perl -p -i -e 's/#(loadplugin.*DCC)/$1/' $F
done
# This is done later in the script anyway
# service amavis restart

##########
# ppolicyd
##########
apt-get install unzip make
perl -e 'require Mail::SPF::Query'
[ $? -ne 0 ] && cpan -f install Mail::SPF::Query
[ -s /usr/local/src/ppolicyd.zip ] || wget http://github.com/B-LUC/ppolicyd/archive/master.zip -O /usr/local/src/ppolicyd.zip
cd /tmp
unzip /usr/local/src/ppolicyd.zip
cd ppolicyd-master
./install.sh
vi /etc/default/ppolicyd

##########
# POSTFIX
##########
apt-get install postfix-pcre

# Get the IP address of the "real" mail server
MSHOST=''
while [ -z "$MSHOST" ]
do
    read -p 'IP address of the "real" mail server ? ' MSHOST
done

# Get the email domain we relay for
read -p "Domain we need to relay for [default=$LOCALDOMAIN] ? " I
if [ -z "$I" ]
then
    MDOMAIN=$LOCALDOMAIN
else
    MDOMAIN="$I" 
fi

# Ensure we use the correct postfix config_directory
PF_CD=$(postconf -h config_directory)

# Setup postfix transport table (recipient based routing)
postconf -e 'transport_maps = hash:'$PF_CD/transport

if [ ! -s $PF_CD/transport ]
then
    cat << EOT > $PF_CD/transport
# Recipient based routing
$MDOMAIN	smtp:[$MSHOST]
.$MDOMAIN	smtp:[$MSHOST]
EOT
fi
vi $PF_CD/transport
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

# We are a relay
postconf -e 'mydestination = '
postconf -e 'local_recipient_maps = '
postconf -e 'local_transport = error:no local mail delivery'

# Send email directly to other Internet servers
postconf -e 'relayhost = '

# Who we relay for
postconf -e 'relay_domains = hash:'$PF_CD/relays
if [ ! -s $PF_CD/relays ]
then
    cat << EOT > $PF_CD/relays
$MDOMAIN	OK
.$MDOMAIN	OK
EOT
fi
postmap $PF_CD/relays

# Setup list of relay recipients
postconf -e 'relay_recipient_maps = hash:'$PF_CD/relay_recipients
if [ ! -s $PF_CD/relay_recipients ]
then
    cat << EOT > $PF_CD/relay_recipients
@$MDOMAIN	OK
EOT
fi
postmap $PF_CD/relay_recipients

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
# - Check 'unknown_recipients' for rejected addresses
# - Let ppolicyd check for restrictions (port 2522)
# - Let postgey check for restrictions (port 10023)
postconf -e "smtpd_recipient_restrictions = permit_mynetworks,reject_unauth_destination,reject_unauth_pipelining,reject_unknown_recipient_domain,check_recipient_mx_access hash:$PF_CD/mx_access,check_recipient_access hash:$PF_CD/unknown_recipients,check_policy_service inet:127.0.0.1:2522,check_policy_service inet:127.0.0.1:10023"
postconf -e 'address_verify_map = btree:$data_directory/verify_cache'

# Enable useful rejections for data phase
# - Reject unauthorized pipelining
postconf -e 'smtpd_data_restrictions = reject_unauth_pipelining,permit'

# Disable some unnecessary commands
postconf -e 'smtpd_discard_ehlo_keywords=vrfy,etrn'
postconf -e 'disable_vrfy_command = yes'

# Setup list of unknown recipients
#  (automatically populated by block_spammers.pl)
[ -f $PF_CD/unknown_recipients ] || touch $PF_CD/unknown_recipients
postmap $PF_CD/unknown_recipients

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
$MDOMAIN	OK
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
/^Received:.*192.168.1/ IGNORE 
/[^[:print:]]{8}/       REJECT Your email program is not RFC 2057 compliant
/^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.(386|ad[ept]|app|as[dpx]|ba[st]|bin|btm|cab|cb[lt]|cgi|chm|cil|cla(ss)?|cmd|cp[el]|crt|cs[chs]|cvp|dll|dot|drv)"?(;|$)/      REJECT ".$2" file attachment not allowed
/^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.(em(ai)?l|ex[_e]|fon|fxp|hlp|ht[ar]|in[fips]|isp|jar|jse?|keyreg|ksh|lib|lnk|md[abetw]|mht(m|ml)?|mp3|ms[ciopt])"?(;|$)/     REJECT ".$2" file attachment not allowed
/^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.(nte|nws|obj|ocx|ops|ov.|pcd|pgm|pif|p[lm]|pot|pps|prg|reg|sc[rt]|sh[bs]?|slb|smm|sw[ft]|sys|url|vb[esx]?|vir])"?(;|$)/      REJECT ".$2" file attachment not allowed
/^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.(vmx|vxd|wm[dsz]|ws[cfh]|xl[^s]|xms|{[da-f]{8}(?:-[da-f]{4}){3}-[da-f]{12}})"?(;|$)/	REJECT ".$2" file attachment types not allowed. Please zip and resend.
/^Content-(Disposition|Type):\s+.+?(file)?name="?.+?\.com(\.\S{2,4})?(\?=)?"?(;|$)/	REJECT ".com" file attachment types not allowed. Please zip and resend.
/charset="?(koi8-?r|windows-1251|ISO_5427|cyrillic)/    REJECT Can not read cyrillic characters
/charset="?.*(JIS|-JP|jp-|Windows-31J)/ REJECT Can not read japanese characters
/charset="?.*(-KR)/     REJECT Can not read korean characters
/charset="?.*(arabic|hebrew|windows-1256)/   REJECT Can not read arabic or hebrew characters
/charset="?(GP|Big5)/   REJECT Can not read chinese characters
/charset="?VISCII/      REJECT Can not read vietnamese characters
/charset="?(iso-8859-9|windows-1254)/   REJECT Can not read turkish characters
# HELP:
#
# Check each header of an email and either reject the email
#  or strip the header from the email.  This includes checking headers
#  for attachments and rejecting email containing specific attachments
#  (see EXAMPLES).
#
# PATTERNS
#
# The appliance uses Perl Regular Expressions (man pcre) as patterns.
#
# /pattern/flags action
#  When  /pattern/  matches  the input string, execute the corresponding
#   action. See below for a list  of possible actions.
#
# !/pattern/flags action
#  When /pattern/ does  not  match the input string, execute the corresponding
#   action.
# 
# ACTIONS
# 
# DISCARD optional text...
#  Claim successful delivery and silently discard the message. Log the optional
#   text if specified, otherwise log a generic message.
#
# REJECT optional text...
#  Reject the entire message.  Reply with optional text, when the optional text
#   is specified, otherwise reply with a generic error message.
#
# IGNORE
#  Delete the current line from the input, and inspect the next input line.
#
# EXAMPLES
#
# Reject emails with invalid headers:
#  !/^\S+/ REJECT Invalid header syntax
#
# Ignore/strip header lines showing the localhost:
#  /^Received:.*127.0.0.1/ IGNORE 
#
# Reject emails with cyrillic characters in it:
#  /charset="?(koi8-?r|windows-1251|ISO_5427|cyrillic)/    REJECT Can not read cyrillic characters
#
# Reject emails containing certain attachments:
#  /^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.(386|ad[ept]|app|as[dpx]|ba[st]|bin|btm|cab|cb[lt]|cgi|chm|cil|cla(ss)?|cmd|cp[el]|crt|cs[chs]|cvp|dll|dot|drv)"?(;|$)/      REJECT "." file attachment not allowed
EOT
fi
if [ ! -s $PF_CD/body_checks ]
then
    cat << EOT > $PF_CD/body_checks
/^[A-Za-z0-9+\/=]{4,76}$/       OK 
/<iframe src=(3D)?cid:.* height=(3D)?0 width=(3D)?0>/   REJECT Email contains the IFrame Exploit
/<\s*(object\s+data)\s*=/       REJECT Email with "$1" tags not allowed
/<\s*(script\s+language\s*="vbs")/      REJECT Email with "$1" tags not allowed
/<\s*(script\s+language\s*="VBScript\.Encode")/ REJECT Email with "$1" tags not allowed

# HELP:
#
# Check each line of an email and possibly reject the email.
#  or strip the header from the email.  This includes checking attachments
#  and rejecting email containing specific patterns.
# NOTE: This is very time consuming for large emails and should only
#       be used very sparingly.
# NOTE: This can easily lead to false positives for base64 encoded
#       attachments.
#
# PATTERNS
#
# The appliance uses Perl Regular Expressions (man pcre) as patterns.
#
# /pattern/flags action
#  When  /pattern/  matches  the input string, execute the corresponding
#   action. See below for a list  of possible actions.
#
# !/pattern/flags action
#  When /pattern/ does  not  match the input string, execute the corresponding
#   action.
# 
# ACTIONS
# 
# DISCARD optional text...
#  Claim successful delivery and silently discard the message. Log the optional
#   text if specified, otherwise log a generic message.
#
# REJECT optional text...
#  Reject the entire message.  Reply with optional text, when the optional text
#   is specified, otherwise reply with a generic error message.
#
# IGNORE
#  Delete the current line from the input, and inspect the next input line.
#
# EXAMPLES
#
# Reject emails with an embedded iFrame exploit:
#  /<iframe src=(3D)?cid:.* height=(3D)?0 width=(3D)?0>/   REJECT Email contains the IFrame Exploit
EOT
fi
# Postfix tuning
postconf -e 'queue_run_delay = 6m'
postconf -e 'bounce_queue_lifetime = 3h'
postconf -e 'bounce_size_limit = 512'
postconf -e 'minimal_backoff_time = 6m'
postconf -e 'maximal_backoff_time = 60m'
postconf -e "smtpd_banner = mx.$MDOMAIN ESMTP UCE"
postconf -e 'biff = no'
postconf -e 'address_verify_negative_refresh_time = 60m'

# Postfix TLS settings
postconf -e 'smtpd_client_new_tls_session_rate_limit = 20'
postconf -e 'smtp_tls_session_cache_database = btree:${data_directory}/smtp_scache'
postconf -e 'smtp_tls_CAfile ='
postconf -e 'smtp_tls_CApath ='
postconf -e 'smtp_tls_cert_file ='
postconf -e 'smtp_tls_dcert_file ='
postconf -e 'smtp_tls_dkey_file = $smtp_tls_dcert_file'
postconf -e 'smtp_tls_enforce_peername = yes'
postconf -e 'smtp_tls_exclude_ciphers ='
postconf -e 'smtp_tls_key_file = $smtp_tls_cert_file'
postconf -e 'smtp_tls_loglevel = 0'
postconf -e 'smtp_tls_mandatory_ciphers = medium'
postconf -e 'smtp_tls_mandatory_exclude_ciphers ='
postconf -e 'smtp_tls_mandatory_protocols = SSLv3, TLSv1'
postconf -e 'smtp_tls_note_starttls_offer = no'
postconf -e 'smtp_tls_per_site ='
postconf -e 'smtp_tls_policy_maps ='
postconf -e 'smtp_tls_scert_verifydepth = 5'
postconf -e 'smtp_tls_secure_cert_match = nexthop, dot-nexthop'
postconf -e 'smtp_tls_security_level ='
postconf -e 'smtp_tls_session_cache_timeout = 3600s'
postconf -e 'smtp_tls_verify_cert_match = hostname'
postconf -e 'smtp_tls_exclude_ciphers = aNULL, MD5, DES, DES+MD5, RC4'
postconf -e 'smtp_tls_ciphers = high'
postconf -e 'smtp_use_tls = yes'

postconf -e 'smtpd_tls_CAfile ='
postconf -e 'smtpd_tls_CApath ='
postconf -e 'smtpd_tls_always_issue_session_ids = yes'
postconf -e 'smtpd_tls_ask_ccert = no'
postconf -e 'smtpd_tls_auth_only = no'
postconf -e 'smtpd_tls_ccert_verifydepth = 5'
postconf -e 'smtpd_tls_cert_file = /etc/ssl/certs/ssl-cert-snakeoil.pem'
postconf -e 'smtpd_tls_dcert_file ='
postconf -e 'smtpd_tls_dh1024_param_file ='
postconf -e 'smtpd_tls_dh512_param_file ='
postconf -e 'smtpd_tls_dkey_file = $smtpd_tls_dcert_file'
postconf -e 'smtpd_tls_exclude_ciphers ='
postconf -e 'smtpd_tls_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem'
postconf -e 'smtpd_tls_key_file=/etc/ssl/private/ssl-cert-snakeoil.key'
postconf -e 'smtpd_tls_session_cache_database = btree:${data_directory}/smtpd_scache'
postconf -e 'smtpd_tls_loglevel = 1'
postconf -e 'smtpd_tls_mandatory_ciphers = medium'
postconf -e 'smtpd_tls_mandatory_exclude_ciphers ='
postconf -e 'smtpd_tls_mandatory_protocols = SSLv3, TLSv1'
postconf -e 'smtpd_tls_received_header = yes'
postconf -e 'smtpd_tls_req_ccert = no'
postconf -e 'smtpd_tls_security_level ='
postconf -e 'smtpd_tls_session_cache_database = btree:${data_directory}/smtpd_scache'
postconf -e 'smtpd_tls_session_cache_timeout = 3600s'
postconf -e 'smtpd_tls_wrappermode = no'
postconf -e 'smtpd_tls_exclude_ciphers = aNULL, MD5, DES, DES+MD5'
postconf -e 'smtpd_tls_ciphers = medium'

# Postfix TLS debugging
postconf -e 'smtpd_tls_received_header = yes'
postconf -e 'smtpd_tls_loglevel = 1'
postconf -e 'smtp_tls_loglevel = 1'

# Postfix per-recipient domain TLS settings
postconf -e 'smtp_tls_per_site = hash:'$PF_CD/smtp_tls_per_site
# Create some dummy settings if necessary
if [ ! -s $PF_CD/smtp_tls_per_site ]
then
    cat << EOT > $PF_CD/smtp_tls_per_site
# See: http://www.postfix.org/TLS_README.html
$MSHOST	none
EOT
fi
postmap $PF_CD/smtp_tls_per_site

# Setup useful names
postconf -e 'myorigin = mail.'$LOCALDOMAIN
postconf -e 'smtp_helo_name = mail.'$LOCALDOMAIN
postconf -e 'mydomain = '$LOCALDOMAIN
postconf -e 'mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 '$LOCALNET/$CIDRMASK

# Refresh aliases and restart postfix
newaliases
postfix start || service postfix restart

# Enable synchronization of postfix legitimate email addresses
apt-get install mysql-client

cat << EOT > /usr/local/sbin/SyncLEA.sh
#!/bin/bash
# Synchronize postfix's legitimate email addresses

mysql --skip-column-names --user='les' --password='CuHy4Wheat' --host=ms postfixadmin << EOM | sort -u > /tmp/Legitimate.EmailAddresses.txt
select address from alias;
select username from mailbox;
EOM

awk '{print \$1}' $PF_CD/relay_recipients | sort -u > /tmp/Legitimate.EmailAddresses.RR
diff -w /tmp/Legitimate.EmailAddresses.txt /tmp/Legitimate.EmailAddresses.RR &> /dev/null
if [ \$? -ne 0 ]
then
    awk '{print \$1" OK"}' /tmp/Legitimate.EmailAddresses.txt > $PF_CD/relay_recipients
    postmap $PF_CD/relay_recipients
fi
EOT
chmod 700 /usr/local/sbin/SyncLEA.sh
cat << EOT > /etc/cron.d/les
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin
MAILTO=root
##############################################################################
# Synchronize list of legitimate email addresses for postfix
*/3 * * * *       root    [ -x /usr/local/sbin/SyncLEA.sh ] && SyncLEA.sh
EOT

##########
# AMAVIS
##########
apt-get install amavisd-new spamassassin zoo
apt-get install libnet-dns-perl pyzor razor arj bzip2 cabextract cpio file gzip nomarch pax unzip zip
apt-get install clamav-daemon clamav-freshclam clamav-unofficial-sigs
freshclam -v
service clamav-daemon restart

# Local customizations
cat << EOT > /etc/amavis/conf.d/99-btoy1
use strict;

# The local networks
@mynetworks = qw( 127.0.0.0/8 [::1] $LOCALNET/$CIDRMASK );

# Rules for clients defined in @mynetworks
\$policy_bank{'MYNETS'} = {  # clients in @mynetworks
  bypass_spam_checks_maps   => [1],  # don't spam-check internal mail
  bypass_banned_checks_maps => [1],  # don't banned-check internal mail
  bypass_header_checks_maps => [1],  # don't header-check internal mail
  spam_admin_maps  => ["postmaster\@"], # alert of internal spam
  spam_kill_level_maps => [7.0],  # slightly more permissive spam kill level
  spam_dsn_cutoff_level_maps => [15],
  spam_dsn_cutoff_level_bysender_maps => [15],
  originating => 1,
  allow_disclaimers => 1,
};
      
# Enable AV checks
@bypass_virus_checks_maps = (
   \%bypass_virus_checks, \@bypass_virus_checks_acl, \\\$bypass_virus_checks_re);
# Enable SPAM checks
@bypass_spam_checks_maps = (
   \%bypass_spam_checks, \@bypass_spam_checks_acl, \\\$bypass_spam_checks_re);

# Enable disclaimers via "99-DisclaimerYes"

# Be less verbose with the added header line
\$X_HEADER_LINE = "\$mydomain";

#@whitelist_sender_acl = qw( '$MDOMAIN' );
@local_domains_maps = qw( '$MDOMAIN' );

# Where to send checked mail to
\$forward_method = 'smtp:[127.0.0.1]:10025';

# Spam detection levels
# See: http://www200.pair.com/mecham/spam/amavisd-settings.html
\$sa_tag_level_deflt  = -9999; # add spam info headers if at, or above that level
\$sa_tag2_level_deflt = 4.30;  # add 'spam detected' headers at that level
\$sa_kill_level_deflt = 8.00;  # triggers spam evasive actions
\$sa_dsn_cutoff_level = 10.0;  # spam level beyond which a DSN is not sent

\$sa_mail_body_size_limit = 512*1024; # don't waste time on SA if mail is larger

# How spam is reported
\$sa_spam_level_char    = 'S';
\$sa_spam_report_header = 1;
\$sa_spam_modifies_subj = 1;
\$sa_spam_subject_tag = 'SPAM: ';

# Quarantine spams (sa_kill_level_deflt)
\$final_spam_destiny = D_DISCARD;  # (defaults to D_REJECT)
\$spam_quarantine_to = 'postmaster@$MDOMAIN';
\$hdrfrom_notify_sender = 'postmaster@$MDOMAIN';

# See http://www.mikecappella.com/logwatch/amavis-logwatch.1.htm
# http://eric.lubow.org/wp-content/uploads/2009/05/amavis-logwatch_1.49.09-1.1_i386.deb
\$log_level = 2;

# Tell the postmaster about virii
\$virus_admin = 'postmaster@$MDOMAIN';

# Defang any intercepted and labeled emails
\$defang_virus = 1;
\$defang_banned = 1;
\$defang_spam = 1;
\$defang_bad_header = 1;
\$defang_undecipherable = 1;

#------------ Do not modify anything below this line -------------
1;  # ensure a defined return
EOT
# By default enable disclaimers
cat << EOT > /etc/amavis/conf.d/99-__DisclaimersYes
# Enable disclaimers
\$defang_maps_by_ccat{+CC_CATCHALL} = [ 'disclaimer' ];
#------------ Do not modify anything below this line -------------
1;  # ensure a defined return
EOT

# (re)start amavisd
service amavis restart

# Adapt postfix to work with amavis
if [ -z "$(grep amavis $PF_CD/master.cf)" ]
then
    cat << EOT >> $PF_CD/master.cf
#
# The next two entries integrate with Amavis for anti-virus/spam checks.
#
amavis      unix    -       -       -       -       2       smtp
        -o smtp_data_done_timeout=1200
        -o smtp_send_xforward_command=yes
        -o disable_dns_lookups=yes
        -o max_use=20
127.0.0.1:10025 inet    n       -       -       -       -       smtpd
        -o content_filter=
        -o local_recipient_maps=
        -o relay_recipient_maps=
        -o smtpd_restriction_classes=
        -o smtpd_delay_reject=no
        -o smtpd_client_restrictions=permit_mynetworks,reject
        -o smtpd_helo_restrictions=
        -o smtpd_sender_restrictions=
        -o smtpd_recipient_restrictions=permit_mynetworks,reject
        -o smtpd_data_restrictions=reject_unauth_pipelining
        -o smtpd_end_of_data_restrictions=
        -o mynetworks=127.0.0.0/8
        -o smtpd_error_sleep_time=0
        -o smtpd_soft_error_limit=1001
        -o smtpd_hard_error_limit=1000
        -o smtpd_client_connection_count_limit=0
        -o smtpd_client_connection_rate_limit=0
        -o receive_override_options=no_header_body_checks,no_unknown_recipient_checks
EOT
fi
postconf -e 'content_filter = amavis:[127.0.0.1]:10024'

# Ensure that amavis can access clamav
adduser clamav amavis
adduser amavis clamav

# Restart postfix
service postfix restart

# Get the key for the standard spamassassin updates
mkdir -m 700 -p /etc/spamassassin/sa-update-keys
wget http://spamassassin.apache.org/updates/GPG.KEY -O /tmp/spamassassin.gpg.key
sa-update --import /tmp/spamassassin.gpg.key

# Add the "sought" rules to the spamassassin updates
wget http://yerp.org/rules/GPG.KEY -O /tmp/sought.gpg.key
sa-update --import /tmp/sought.gpg.key

##########
# POSTGREY
##########
apt-get install postgrey

# Adapt greylisting message
RESTART_PG=0
if [ -z "$(grep ^POSTGREY_TEXT /etc/default/postgrey)" ]
then
    cat << EOT >> /etc/default/postgrey
POSTGREY_TEXT='Greylisting is active for %r, please try again after %s seconds'
EOT
    PG_RESTART=1
fi
if [ ! -s /etc/postgrey/whitelist_clients.local ]
then
    cat << EOT > /etc/postgrey/whitelist_clients.local
# Sender-based exemptions for greylisting
# The following can be specified for client addresses:
# domain.addr      "domain.addr" domain and subdomains.
# IP1.IP2.IP3.IP4  IP address IP1.IP2.IP3.IP4. You can also leave off one
#                  number, in which case only the first specified numbers will
#                  be checked.
# IP1.IP2.IP3.IP4/MASK
#                  CIDR-syle network. Example: 192.168.1.0/24
# /regexp/         anything that matches "regexp" (the full address is matched).
EOT
    PG_RESTART=1
fi
if [ ! -s /etc/postgrey/whitelist_recipients.local ]
then
    cat << EOT > /etc/postgrey/whitelist_recipients.local
# Recipient-based exemptions for greylisting
# The following can be specified for recipient addresses:
# domain.addr      "domain.addr" domain and subdomains.
# name@            "name@.*" and extended addresses "name+blabla@.*".
# name@domain.addr "name@domain.addr" and extended addresses.
# /regexp/         anything that matches "regexp" (the full address is matched).
EOT
    PG_RESTART=1
fi
[ $PG_RESTART -ne 0 ] && service postgrey restart

##########
# ALTERMIME
##########
apt-get install altermime
if [ ! -s /etc/altermime-disclaimer.txt ]
then
    cat << EOT > /etc/altermime-disclaimer.txt

           D I S C L A I M E R       D I S C L A I M E R

Computer viruses and malware can be transmitted via email. The recipient
should check this email and any attachments for the presence of viruses or
malware. 
The server administrator accepts no liability for any damage caused by any
virus or malware transmitted by this email.  E-mail transmission cannot be
guaranteed to be secure or error-free as information could be intercepted,
corrupted, lost, destroyed, arrive late or incomplete, or contain viruses or
malware. 
The sender therefore does not accept liability for any errors or omissions
in the contents of this message, which arise as a result of e-mail
transmission.

Although the server administrator has taken reasonable precautions to ensure
no viruses are present in this email, the server administrator cannot accept
responsibility for any loss or damage arising from the use of this email or
attachments.

NOTE (as per http://www.economist.com/node/18529895):

But they [email disclaimers] are mostly, legally speaking, pointless.
Lawyers and experts on internet policy say no court case has ever turned on
the presence or absence of such an automatic e-mail footer in America, the
most litigious of rich countries.

Many disclaimers are, in effect, seeking to impose a contractual obligation
unilaterally, and thus are probably unenforceable.  This is clear in Europe,
where a directive from the European Commission tells the courts to strike
out any unreasonable contractual obligation on a consumer if he has not
freely negotiated it.  And a footer stating that nothing in the e-mail
should be used to break the law would be of no protection to a lawyer or
financial adviser sending a message that did suggest something illegal.

EOT
fi
