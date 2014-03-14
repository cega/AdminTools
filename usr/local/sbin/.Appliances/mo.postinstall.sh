#!/bin/bash
################################################################
# (c) Copyright 2013 B-LUC Consulting and Thomas Bullinger
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

##########
# POSTFIX
##########
apt-get install postfix-pcre

# Ensure we use the correct postfix config_directory
PF_CD=$(postconf -h config_directory)

# Setup postfix transport table (recipient based routing)
postconf -e 'transport_maps = pcre:'$PF_CD/transport
if [ ! -s $PF_CD/transport ]
then
    cat << EOT > $PF_CD/transport
# Recipient based routing using regular expressions
EOT
fi
vi $PF_CD/transport

# Setup sender-based email routing
postconf -e 'sender_dependent_relayhost_maps=pcre:'$PF_CD/sender_mail_routing
if [ ! -s $PF_CD/sender_mail_routing ]
then
    cat << EOT > $PF_CD/sender_mail_routing
# Sender based routing using regular expressions
EOT
fi
vi $PF_CD/sender_mail_routing
                                
# Message size is at least 20MB (!!!)
MAXMSGSIZE=$(postconf -h message_size_limit)
[ $MAXMSGSIZE -lt $((20 * 1024 * 1024)) ] && MAXMSGSIZE=$((20 * 1024 * 1024))
QUEUE_MINFREE=$((2 * $MAXMSGSIZE))
postconf -e 'message_size_limit = '$MAXMSGSIZE
postconf -e 'queue_minfree = '$QUEUE_MINFREE
postconf -e 'local_transport = error:no local mail delivery'

# We are a relay
postconf -e 'mydestination = '
postconf -e 'local_recipient_maps = '
postconf -e 'local_transport = error:no local mail delivery'

# Send email directly to other Internet servers
postconf -e 'relayhost = '

# Who are our sending clients
postconf -e 'mynetworks = '$PF_CD/mynetworks
if [ ! -s $PF_CD/mynetworks ]
then
    cat << EOT > $PF_CD/mynetworks
# Sending client IPs as single line entries
EOT
fi

# Enable useful rejections for unknown clients
# - Allow everything from legitimate networks
# - Check 'sender_access' for rejected IPs or addresses
postconf -e 'smtpd_client_restrictions = permit_mynetworks'

# Enable useful rejections for unknown senders
# - Check 'sender_access' for rejected IPs or addresses
# - Reject senders without full-qualified domain names
# - Check 'mx_access' for rejected IPs
postconf -e "smtpd_sender_restrictions = check_sender_access hash:$PF_CD/sender_access,reject_non_fqdn_sender,permit"

# Enable useful rejections for unknown recipients
# - Allow everything from legitimate networks
# - Reject unauthorized destinations
# - Reject unauthorized pipelining
# - Reject unknown recipient domains
# - Check 'mx_access' for rejected IPs
# - Check 'unknown_recipients' for rejected addresses
postconf -e "smtpd_recipient_restrictions = permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination,reject_unauth_pipelining,reject_unknown_recipient_domain,check_recipient_mx_access hash:$PF_CD/mx_access"
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

# Setup sender access lists
if [ ! -s $PF_CD/sender_access ]
then
    cat << EOT > $PF_CD/sender_access
# Allowed sender addresses in hash formt
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
postconf -e "smtpd_banner = mo.$LOCALDOMAIN ESMTP UCE"
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
# TLS settings for specific destinations
# See: http://www.postfix.org/TLS_README.html
EOT
fi
postmap $PF_CD/smtp_tls_per_site

# Setup useful names
postconf -e 'myorigin = mail.'$LOCALDOMAIN
postconf -e 'smtp_helo_name = mail.'$LOCALDOMAIN
postconf -e 'mydomain = '$LOCALDOMAIN

# Refresh aliases and restart postfix
newaliases
postfix start || service postfix restart
