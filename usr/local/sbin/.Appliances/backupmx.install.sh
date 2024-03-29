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
# 127.0.0.1:11124 (lmtpd)  dspam      antispam          127.0.0.1:10025 (smtp)
# 127.0.0.1:10025 (smtpd)  clamsmtpd  antivirus         127.0.0.1:10026 (smtp)
# 127.0.0.1:10026 (smtpd)  postfix                      *:25 (smtp)
# *:587 (submission)       postfix                      *.25 (smtp)
# Note: 465 and 587 are not allowed from outside LAN
#       465 requires authentication

##########

is_validip()
{
    case "$*" in
    ""|*[!0-9.]*|*[!0-9]) return 1 ;;
    esac

    local IFS=.  ## local is bash-specific
    set -- $*
    [ $# -eq 4 ] &&
        [ ${1:-666} -le 255 ] && [ ${2:-666} -le 255 ] &&
        [ ${3:-666} -le 255 ] && [ ${4:-666} -le 254 ]
}

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

# Get the email domain we relay for
read -p "Domain we need to relay for [default=$LOCALDOMAIN] ? " I
if [ -z "$I" ]
then
    MDOMAIN=$LOCALDOMAIN
else
    MDOMAIN="$I" 
fi

##########
# ppolicyd
##########
apt-get install unzip make
perl -e 'require Mail::SPF::Query'
[ $? -ne 0 ] && cpan -f install Mail::SPF::Query
[ -s /usr/local/src/ppolicyd.zip ] || wget http://github.com/B-LUC/ppolicyd/archive/master.zip -O usr/local/src/ppolicyd.zip
cd /tmp
unzip /usr/local/src/ppolicyd.zip
cd ppolicyd-master
./install.sh
vi /etc/default/ppolicyd

###########
# clamsmtpd
###########
if [ -s /etc/lsb-release ]
then
    source /etc/lsb-release
    cat << EOT > /etc/apt/preferences.d/clamav
Package: clamav*
Pin: release a=${DISTRIB_CODENAME}-backports
Pin-Priority: 500  

Package: libclamav6
Pin: release a=${DISTRIB_CODENAME}-backports
Pin-Priority: 500  
EOT
fi

apt-get install clamsmtp clamav-unofficial-sigs
cat << EOT > /etc/clamsmtpd.conf
# ------------------------------------------------------------------------------
#                        SAMPLE CLAMSMTPD CONFIG FILE
# ------------------------------------------------------------------------------
# 
# - Comments are a line that starts with a #
# - All the options are found below with their defaults commented out


# The address to send scanned mail to. 
# This option is required unless TransparentProxy is enabled
OutAddress: 10026

# The maximum number of connection allowed at once.
# Be sure that clamd can also handle this many connections
#MaxConnections: 64

# Amount of time (in seconds) to wait on network IO
#TimeOut: 180

# Address to listen on (defaults to all local addresses on port 10025)
Listen: 127.0.0.1:10025

# The address clamd is listening on
ClamAddress: /var/run/clamav/clamd.ctl

# A header to add to all scanned email
#Header: X-AV-Checked: ClamAV using ClamSMTP

# Directory for temporary files
TempDirectory: /var/spool/clamsmtp

# PidFile: location of PID file
PidFile: /var/run/clamsmtp/clamsmtpd.pid

# Whether or not to bounce email (default is to silently drop)
#Bounce: off

# Whether or not to keep virus files 
#Quarantine: off

# Enable transparent proxy support 
#TransparentProxy: off

# User to run as
User: clamsmtp

# Virus actions: There's an option to run a script every time a 
# virus is found. Read the man page for clamsmtpd.conf for details.
EOT

cat << EOT > /etc/clamav/clamd.conf 
#Automatically Generated by clamav-base postinst
#To reconfigure clamd run #dpkg-reconfigure clamav-base
#Please read /usr/share/doc/clamav-base/README.Debian.gz for details
LocalSocket /var/run/clamav/clamd.ctl
FixStaleSocket true
LocalSocketGroup clamav
LocalSocketMode 666
# TemporaryDirectory is not set to its default /tmp here to make overriding
# the default with environment variables TMPDIR/TMP/TEMP possible
User clamav
AllowSupplementaryGroups true
ScanMail true
ScanArchive true
ArchiveBlockEncrypted false
MaxDirectoryRecursion 15
FollowDirectorySymlinks false
FollowFileSymlinks false
ReadTimeout 180
MaxThreads 12
MaxConnectionQueueLength 15
LogSyslog false
LogFacility LOG_LOCAL6
LogClean false
LogVerbose false
PidFile /var/run/clamav/clamd.pid
DatabaseDirectory /var/lib/clamav
SelfCheck 3600
Foreground false
Debug false
ScanPE true
ScanOLE2 true
ScanHTML true
DetectBrokenExecutables false
ExitOnOOM false
LeaveTemporaryFiles false
AlgorithmicDetection true
ScanELF true
IdleTimeout 30
PhishingSignatures true
PhishingScanURLs true
PhishingAlwaysBlockSSLMismatch false
PhishingAlwaysBlockCloak false
DetectPUA false
ScanPartialMessages false
HeuristicScanPrecedence false
StructuredDataDetection false
CommandReadTimeout 5
SendBufTimeout 200
MaxQueue 100
ExtendedDetectionInfo true
OLE2BlockMacros false
StreamMaxLength 25M
LogFile /var/log/clamav/clamav.log
LogTime true
LogFileUnlock false
LogFileMaxSize 0
Bytecode true
BytecodeSecurity TrustSigned
BytecodeTimeout 60000
OfficialDatabaseOnly false
CrossFilesystems true
EOT

cat << EOT > /etc/clamav/freshclam.conf 
# Automatically created by the clamav-freshclam postinst
# Comments will get lost when you reconfigure the clamav-freshclam package

DatabaseOwner clamav
UpdateLogFile /var/log/clamav/freshclam.log
LogVerbose false
LogSyslog false
LogFacility LOG_LOCAL6
LogFileMaxSize 0
LogTime true
Foreground false
Debug false
MaxAttempts 5
DatabaseDirectory /var/lib/clamav
DNSDatabaseInfo current.cvd.clamav.net
AllowSupplementaryGroups false
PidFile /var/run/clamav/freshclam.pid
ConnectTimeout 30
ReceiveTimeout 30
TestDatabases yes
ScriptedUpdates yes
CompressLocalDatabase no
Bytecode true
# Check for new database 24 times a day
Checks 24
DatabaseMirror db.local.clamav.net
DatabaseMirror database.clamav.net
EOT
freshclam -v

###########
# dspam
###########
# Based on https://help.ubuntu.com/community/Postfix/Dspam
apt-get install dspam
# Listen on 127.0.0.1:11124 and pass on to clamsmtpd on 127.0.0.1:10025
cat << EOT > /etc/dspam/dspam.d/backupmx.conf
Home /var/spool/dspam
StorageDriver /usr/lib/dspam/libhash_drv.so
TrustedDeliveryAgent "/usr/sbin/sendmail"
DeliveryHost        127.0.0.1
DeliveryPort        10025
DeliveryIdent       localhost
DeliveryProto       SMTP
OnFail error
Trust root
Trust dspam
Trust mail
Trust mailnull 
Trust smmsp
Trust daemon
Trust postfix
Trust www-data
TrainingMode teft
TestConditionalTraining on
Feature chained
Feature whitelist
Algorithm graham burton
PValue graham
Preference "spamAction=tag"
Preference "signatureLocation=headers"  # 'message' or 'headers'
Preference "showFactors=off"
AllowOverride trainingMode
AllowOverride spamAction spamSubject
AllowOverride statisticalSedation
AllowOverride enableBNR
AllowOverride enableWhitelist
AllowOverride signatureLocation
AllowOverride showFactors
AllowOverride optIn optOut
AllowOverride whitelistThreshold
HashRecMax              98317
HashAutoExtend          on  
HashMaxExtents          0
HashExtentSize          49157
HashMaxSeek             100
HashConnectionCache     10
Notifications   off
PurgeSignatures 14          # Stale signatures
PurgeNeutral    90          # Tokens with neutralish probabilities
PurgeUnused     90          # Unused tokens
PurgeHapaxes    30          # Tokens with less than 5 hits (hapaxes)
PurgeHits1S     15          # Tokens with only 1 spam hit
PurgeHits1I     15          # Tokens with only 1 innocent hit
LocalMX 127.0.0.1
SystemLog on
UserLog   on
Opt out
TrackSources spam ham
ParseToHeaders on
ChangeModeOnParse on
ChangeUserOnParse on
ServerPort              11124
ServerQueueSize         32
ServerPID              /var/run/dspam/dspam.pid
ServerMode auto
ServerParameters        "--deliver=innocent -d %u"
ServerIdent             "localhost.localdomain"
ClientHost      127.0.0.1
ClientPort      11124
ProcessorBias on
EOT
sed -i 's/^START.*/START=yes/' /etc/default/dspam

cat << EOT > /etc/dspam/dspam-retrain
#!/usr/bin/perl
# Get arguments
\$class  = \$ARGV[0] || die; shift;
\$sender = \$ARGV[0] || die; shift;
\$recip  = \$ARGV[0] || die; shift;

if (\$recip =~ /^(spam|ham)-(\w+)@/) {
    # username is part of the recipient
    \$user = \$2;
} elsif (\$sender =~ /^(\w+)@/) {
    # username is in the sender
    \$user = \$1;
} else {
    print "Can't determine user\n";
    exit 75;                    # EX_TEMPFAIL
}

# Pull out DSPAM signatures and send them to the dspam program
while (<>) {
    if ((! \$subj) && (/^Subject: /o)) {
        \$subj = \$_;
    } elsif (/(!DSPAM:[a-f0-9]+!)/o) {
        open(F, "|/usr/bin/dspam --source=error --class=\$class --user \$user");
        print F "\$subj\n\$1\n";
        close(F);
    } elsif (/(X-DSPAM-Signature: [a-f0-9]+)/o) {
        open(F, "|/usr/bin/dspam --source=error --class=\$class --user \$user");
        print F "\$subj\n\$1\n";
        close(F);
    }
}

# We are done
exit 0;
EOT
chown dspam /etc/dspam/dspam-retrain
chmod +x /etc/dspam/dspam-retrain

# Tune "dspam" default settings
if [ "T$(dspam_admin list pref default | awk -F= '/^signatureLocation/ {print $2}')" != 'Theaders' ]
then
    # Set the correct default location for DSPAM signatures
    dspam_admin ch pref default signatureLocation headers
fi
if [ "T$(dspam_admin list pref default | awk -F= '/^spamAction/ {print $2}')" != 'Ttag' ]
then
    # Set the correct default location for DSPAM signatures
    dspam_admin ch pref default spamAction tag
fi
service dspam restart
                        
##########
# postfix
##########
apt-get install postfix-pcre

# Ensure we use the correct postfix config_directory
PF_CD=$(postconf -h config_directory)

# Setup a correct master file
[ -s $PF_CD/master.cf.ORIG ] || cp $PF_CD/master.cf $PF_CD/master.cf.ORIG
cat << EOT > $PF_CD/master.cf
#
# Postfix master process configuration file.  For details on the format
# of the file, see the master(5) manual page (command: "man 5 master").
#
# ==========================================================================
# service type  private unpriv  chroot  wakeup  maxproc command + args
#               (yes)   (yes)   (yes)   (never) (100)
# ==========================================================================
# See http://www.postfix.org/POSTSCREEN_README.html
smtp      inet  n       -       -       -       -       smtpd
#smtpd     pass  -        -       n       -       -       smtpd
#smtp      inet  n       -       -       -       1       postscreen
#dnsblog   unix  -       -       n       -       0       dnsblog
submission inet n       -       -       -       -       smtpd
        -o content_filter=
        -o receive_override_options=no_unknown_recipient_checks,no_header_body_checks
        -o smtpd_helo_restrictions=
        -o smtpd_client_restrictions=
        -o smtpd_sender_restrictions=
        -o smtpd_recipient_restrictions=permit_mynetworks,reject
        -o mynetworks_style=host
        -o smtpd_authorized_xforward_hosts=192.168.1.12
# For injecting mail back into postfix from "clamsmtpd"
127.0.0.1:10026 inet  n -       n       -       16      smtpd
        -o content_filter=
        -o receive_override_options=no_unknown_recipient_checks,no_header_body_checks
        -o smtpd_helo_restrictions=
        -o smtpd_client_restrictions=
        -o smtpd_sender_restrictions=
        -o smtpd_recipient_restrictions=permit_mynetworks,reject
        -o mynetworks_style=host
        -o smtpd_authorized_xforward_hosts=127.0.0.0/8
# Training "dspam"
dspam-retrain   unix    -       n       n       -       10      pipe
	flags=Ru user=dspam argv=/etc/dspam/dspam-retrain $nexthop $sender $recipient
#
smtps     inet  n       -       -       -       -       smtpd
        -o smtpd_tls_security_level=encrypt
        -o smtpd_tls_wrappermode=yes
        -o smtpd_sasl_auth_enable=yes
        -o smtpd_tls_auth_only=yes
        -o smtpd_sasl_type=cyrus
        -o smtpd_client_restrictions=permit_sasl_authenticated,reject
#628      inet  n       -       -       -       -       qmqpd
pickup    fifo  n       -       -       60      1       pickup
cleanup   unix  n       -       -       -       0       cleanup
qmgr      fifo  n       -       n       300     1       qmgr
#qmgr     fifo  n       -       -       300     1       oqmgr
tlsmgr    unix  -       -       -       1000?   1       tlsmgr
rewrite   unix  -       -       -       -       -       trivial-rewrite
bounce    unix  -       -       -       -       0       bounce
defer     unix  -       -       -       -       0       bounce
trace     unix  -       -       -       -       0       bounce
verify    unix  -       -       -       -       1       verify
flush     unix  n       -       -       1000?   0       flush
proxymap  unix  -       -       n       -       -       proxymap
smtp      unix  -       -       -       -       -       smtp
# When relaying mail as backup MX, disable fallback_relay to avoid MX loops
relay     unix  -       -       -       -       -       smtp
        -o fallback_relay=
#       -o smtp_helo_timeout=5 -o smtp_connect_timeout=5
showq     unix  n       -       -       -       -       showq
error     unix  -       -       -       -       -       error
discard   unix  -       -       -       -       -       discard
local     unix  -       n       n       -       -       local
virtual   unix  -       n       n       -       -       virtual
lmtp      unix  -       -       -       -       -       lmtp
anvil     unix  -       -       -       -       1       anvil
scache    unix  -       -       -       -       1       scache
#
# ====================================================================
# Interfaces to non-Postfix software. Be sure to examine the manual
# pages of the non-Postfix software to find out what options it wants.
#
# Many of the following services use the Postfix pipe(8) delivery
# agent.  See the pipe(8) man page for information about \${recipient}
# and other message envelope options.
# ====================================================================
#
# maildrop. See the Postfix MAILDROP_README file for details.
# Also specify in main.cf: maildrop_destination_recipient_limit=1
#
maildrop  unix  -       n       n       -       -       pipe
  flags=DRhu user=vmail argv=/usr/bin/maildrop -d \${recipient}
#
# See the Postfix UUCP_README file for configuration details.
#
uucp      unix  -       n       n       -       -       pipe
  flags=Fqhu user=uucp argv=uux -r -n -z -a\$sender - \$nexthop!rmail (\$recipient)
#
# Other external delivery methods.
#
ifmail    unix  -       n       n       -       -       pipe
  flags=F user=ftn argv=/usr/lib/ifmail/ifmail -r \$nexthop (\$recipient)
bsmtp     unix  -       n       n       -       -       pipe
  flags=Fq. user=bsmtp argv=/usr/lib/bsmtp/bsmtp -t\$nexthop -f\$sender \$recipient
scalemail-backend unix  -       n       n       -       2       pipe
  flags=R user=scalemail argv=/usr/lib/scalemail/bin/scalemail-store \${nexthop} \${user} \${extension}
mailman   unix  -       n       n       -       -       pipe
  flags=FR user=list argv=/usr/lib/mailman/bin/postfix-to-mailman.py \${nexthop} \${user}
retry     unix  -       -       -       -       -       error
EOT

# Setup postfix transport table (recipient based routing)
postconf -e 'transport_maps = hash:'$PF_CD/transport
touch $PF_CD/transport
postmap $PF_CD/transport

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
postconf -e 'relay_recipient_maps = '

# Send email directly to other Internet servers
postconf -e 'relayhost = '

# Who we relay for
postconf -e 'relay_domains = hash:'$PF_CD/relays
touch $PF_CD/relays
postmap $PF_CD/relays

# Avoild mail loops for secondary MX
EIP=''
while [ -z "$EIP" ]
do
    read -p "External IP for this backup MX host [default=$LOCALIP] ? " EIP
    if [ -z "$EIP" ]
    then
        EIP="$LOCALIP"
        break
    fi
    is_validip $EIP
    [ $? -eq 0 ] && break
    EIP=''
done
postconf -e "proxy_interfaces = $EIP"

# Enable useful rejections for unknown clients
# - Allow everything from legitimate networks
# - Check 'sender_access' for rejected IPs or addresses
# - Reject IPs listed by spamhaus
# - Run email through DSPAM
postconf -e "smtpd_client_restrictions = permit_mynetworks,check_client_access hash:$PF_CD/sender_access,reject_rbl_client zen.spamhaus.org=127.0.0.2,reject_rbl_client zen.spamhaus.org=127.0.0.3,reject_rbl_client zen.spamhaus.org=127.0.0.4,reject_rbl_client zen.spamhaus.org=127.0.0.5,reject_rbl_client zen.spamhaus.org=127.0.0.6,reject_rbl_client zen.spamhaus.org=127.0.0.7,reject_rbl_client zen.spamhaus.org=127.0.0.8,check_client_access pcre:/etc/postfix/dspam_filter_access,permit"

# DSPAM specifics
cat << EOT > $PF_CD/dspam_filter_access
/./   FILTER lmtp:[127.0.0.1]:11124
EOT

[ -z "$(grep ^ham $PF_CD/transport)" ] && echo "ham@${LOCALDOMAIN} dspam-retrain:innocent" >> $PF_CD/transport
[ -z "$(grep ^spam $PF_CD/transport)" ] && echo "spam@${LOCALDOMAIN} dspam-retrain:spam" >> $PF_CD/transport
postmap $PF_CD/transport

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
# - Let ppolicyd check for restrictions (port 2522)
postconf -e "smtpd_recipient_restrictions = permit_mynetworks,reject_unauth_destination,reject_unauth_pipelining,reject_unknown_recipient_domain,check_recipient_mx_access hash:$PF_CD/mx_access,check_policy_service inet:127.0.0.1:2522"
postconf -e 'address_verify_map = btree:$data_directory/verify_cache'

# Enable useful rejections for data phase
# - Reject unauthorized pipelining
postconf -e 'smtpd_data_restrictions = reject_unauth_pipelining,permit'

# Disable some unnecessary commands
postconf -e 'smtpd_discard_ehlo_keywords=vrfy,etrn'
postconf -e 'disable_vrfy_command = yes'

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
postmap $PF_CD/mx_access

touch $PF_CD/sender_access
postmap $PF_CD/sender_access

# Ensure that the header and body checks are perl regex tables
postconf -e 'header_checks = pcre:'$PF_CD/header_checks
postconf -e 'mime_header_checks = pcre:'$PF_CD/header_checks
postconf -e 'nested_header_checks = pcre:'$PF_CD/header_checks
postconf -e 'body_checks = pcre:'$PF_CD/body_checks
postconf -e 'body_checks_size_limit = 51200'

cat << EOT > $PF_CD/header_checks
!/^\S+/ REJECT Invalid header syntax
/^Received:.*localhost/ IGNORE 
/^Received:.*127.0.0.1/ IGNORE 
/[^[:print:]]{8}/       REJECT Your email program is not RFC 2057 compliant
/^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.(386|ad[ept]|app|as[dpx]|ba[st]|bin|btm|cab|cb[lt]|cgi|chm|cil|cla(ss)?|cmd|cp[el]|crt|cs[chs]|cvp|dll|dot|drv)"?(;|$)/      REJECT ".$2" file attachment not allowed
/^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.(em(ai)?l|ex[_e]|fon|fxp|hlp|ht[ar]|in[fips]|isp|jar|jse?|keyreg|ksh|lib|lnk|md[abetw]|mht(m|ml)?|mp3|ms[ciopt])"?(;|$)/     REJECT ".$2" file attachment not allowed
/^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.(nte|nws|obj|ocx|ops|ov.|pcd|pgm|pif|p[lm]|pot|pps|prg|reg|sc[rt]|sh[bs]?|slb|smm|sw[ft]|sys|url|vb[esx]?|vir])"?(;|$)/      REJECT ".$2" file attachment not allowed
/^Content-(Disposition|Type):\s+.+?(?:file)?name="?.+?\.(vmx|vxd|wm[dsz]|ws[cfh]|xl[^s]|xms|{[da-f]{8}(?:-[da-f]{4}){3}-[da-f]{12}})"?(;|$)/ REJECT ".$2" file attachment types not allowed. Please zip and resend.
/^Content-(Disposition|Type):\s+.+?(file)?name="?.+?\.com(\.\S{2,4})?(\?=)?"?(;|$)/     REJECT ".com" file attachment types not allowed. Please zip and resend.
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

# Postfix tuning
postconf -e 'queue_run_delay = 6m'
postconf -e 'bounce_queue_lifetime = 3h'
postconf -e 'bounce_size_limit = 512'
postconf -e 'minimal_backoff_time = 6m'
postconf -e 'maximal_backoff_time = 60m'
postconf -e "smtpd_banner = mx.$MDOMAIN ESMTP UCE"
postconf -e 'biff = no'
postconf -e 'address_verify_negative_refresh_time = 60m'

# Postfix anti-DOS settings
postconf -e 'smtpd_client_connection_rate_limit = 100'
postconf -e 'smtpd_client_new_tls_session_rate_limit = 20'
postconf -e 'smtpd_client_message_rate_limit = 100'
postconf -e 'smtpd_client_recipient_rate_limit = 100'

# See: http://www.postfix.org/postconf.5.html#in_flow_delay
in_flow_delay = 1s
# Postfix TLS settings
postconf -e 'smtp_tls_session_cache_database = btree:${data_directory}/smtp_scache'

postconf -e 'smtp_enforce_tls = no'
postconf -e 'smtp_starttls_timeout = 300s'
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
postconf -e 'smtp_tls_mandatory_protocols = TLSv1'
postconf -e 'smtp_tls_note_starttls_offer = no'
postconf -e 'smtp_tls_policy_maps ='
postconf -e 'smtp_tls_scert_verifydepth = 5'
postconf -e 'smtp_tls_secure_cert_match = nexthop, dot-nexthop'
postconf -e 'smtp_tls_security_level ='
postconf -e 'smtp_tls_session_cache_timeout = 3600s'
postconf -e 'smtp_tls_verify_cert_match = hostname'
postconf -e 'smtp_tls_exclude_ciphers = aNULL, MD5, DES, DES+MD5, RC4'
postconf -e 'smtp_tls_ciphers = high'
postconf -e 'smtp_use_tls = yes'

postconf -e 'smtpd_enforce_tls = no'
postconf -e 'smtpd_starttls_timeout = 300s'
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
postconf -e 'smtpd_tls_mandatory_protocols = TLSv1'
postconf -e 'smtpd_tls_received_header = yes'
postconf -e 'smtpd_tls_req_ccert = no'
postconf -e 'smtpd_tls_security_level ='
postconf -e 'smtpd_tls_session_cache_database = btree:${data_directory}/smtpd_scache'
postconf -e 'smtpd_tls_session_cache_timeout = 3600s'
postconf -e 'smtpd_tls_wrappermode = no'
postconf -e 'smtpd_tls_exclude_ciphers = aNULL, MD5, DES, DES+MD5'
postconf -e 'smtpd_use_tls = yes'

postconf -e 'tls_daemon_random_bytes = 32'
postconf -e 'tls_export_cipherlist = ALL:+RC4:@STRENGTH'
postconf -e 'tls_high_cipherlist = ALL:!EXPORT:!LOW:!MEDIUM:+RC4:@STRENGTH'
postconf -e 'tls_low_cipherlist = ALL:!EXPORT:+RC4:@STRENGTH'
postconf -e 'tls_medium_cipherlist = ALL:!EXPORT:!LOW:+RC4:@STRENGTH'
postconf -e 'tls_null_cipherlist = !aNULL:eNULL+kRSA'
postconf -e 'tls_random_bytes = 32'
postconf -e 'tls_random_exchange_name = ${data_directory}/prng_exch'
postconf -e 'tls_random_prng_update_period = 3600s'
postconf -e 'tls_random_reseed_period = 3600s'
postconf -e 'tls_random_source = dev:/dev/urandom'

# Setup useful names
postconf -e 'myorigin = mail.'$LOCALDOMAIN
postconf -e 'smtp_helo_name = mail.'$LOCALDOMAIN
postconf -e 'mydomain = '$LOCALDOMAIN
postconf -e 'mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 '$LOCALNET/$CIDRMASK

# Postfix per-recipient domain TLS settings
postconf -e 'smtp_tls_per_site = pcre:'$PF_CD/smtp_tls_per_site
# Create some dummy settings if necessary
if [ ! -s $PF_CD/smtp_tls_per_site ]
then
    cat << EOT > $PF_CD/smtp_tls_per_site
# TLS settings for specific destinations in pcre format
# Examples:
# do.ma.in  <action>
#  where <action> is one of these:
#  none    - no encryption, use clear text transmission
#  may     - use encryption when possible (default) 
#  encrypt - only deliver over encrypted connection
# For details see: http://www.postfix.org/TLS_README.html
EOT
fi

cat << EOT > $PF_CD/make
#!/bin/bash

cd $PF_CD
RELOAD=0

# Process databases
for DBF in \$(awk -F: '/hash:/ {print \$2}' main.cf | sed -e 's/,/ /g')
do
    [ -f \$DBF ] || touch \$DBF
    [ "T\$DBF" = 'T/etc/aliases' ] && continue
    if [ \$DBF -nt \${DBF}.db ]
    then
        postmap \$DBF
        RELOAD=\$((\$RELOAD + 1))
    fi
done

# Process aliases
if [ /etc/aliases -nt /etc/aliases.db ]
then
    postalias /etc/aliases
    RELOAD=\$((\$RELOAD + 1))
fi

[ \$RELOAD -gt 0 ] && postfix reload 2> /dev/null

# We are done
exit 0
EOT
chmod 755 $PF_CF/make

# Refresh aliases and restart postfix
newaliases
postfix start || service postfix restart
