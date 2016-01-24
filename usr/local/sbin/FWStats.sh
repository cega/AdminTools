#!/bin/bash
#--------------------------------------------------------------------
# (c) CopyRight 2015 B-LUC Consulting and Thomas Bullinger
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
#--------------------------------------------------------------------

trap "rm -f /tmp/$$*" EXIT

DESIRED_DAY=${1-yesterday}

# First extract the logs for desired day
YESTERDAY=$(date +'%b %_d' -d "$DESIRED_DAY")
zegrep -a "^$YESTERDAY .*IN=.*OUT=" /var/log/kern.log* > /tmp/$$

# Get numbers
TOTAL=$(sed -n '$=' /tmp/$$)
GEO_REJ=$(grep -c 'Geo-based rejection' /tmp/$$)
BLOCKED_GEN=$(grep -c '] BLOCKED:' /tmp/$$)
BLOCKED_SH=$(grep -c 'SPAMHAUS BLOCKED:' /tmp/$$)
BLOCKED_ETBL=$(grep -c 'ETBL BLOCKED:' /tmp/$$)
BLOCKED_DSHIELD=$(grep -c 'DSHIELD BLOCKED:' /tmp/$$)
BLOCKED=$(($BLOCKED_GEN + $BLOCKED_SH + $BLOCKED_ETBL + $BLOCKED_DSHIELD))
FLOOD=$(grep -c 'FLOOD' /tmp/$$)
MALFORMED=$(grep -c 'MALFORMED ' /tmp/$$)
FRAGMENTS=$(grep -c 'FRAGMENTS ' /tmp/$$)
NOSYN=$(grep -c 'NEW TCP w/o SYN' /tmp/$$)
BANNED=$(grep -c 'fail2ban' /tmp/$$)
PORTSCAN=$(grep -c 'Portscan' /tmp/$$)
GEN_ISP_REJ=$(egrep -c 'IN-(external|ISP):' /tmp/$$)
GEN_LAN_REJ=$(egrep -c 'IN-(internal|LAN):' /tmp/$$)
GEN_DMZ_REJ=$(grep -c 'IN-DMZ:' /tmp/$$)
GEN_REJ=$(egrep '(Rejected (TCP|UDP)|(IN|OUT)-)' /tmp/$$ | egrep -cv '\-((in|ex)ternal|DMZ|Portscan)')
OTHER=$(($TOTAL - $GEO_REJ - $BLOCKED - $FLOOD - $MALFORMED - $FRAGMENTS - $NOSYN - $BANNED - $PORTSCAN - $GEN_ISP_REJ - $GEN_LAN_REJ - $GEN_DMZ_REJ - $GEN_REJ))
[ $OTHER -lt 0 ] && OTHER=0

# Nicely report the numbers
cat << EOT > /tmp/$$.out
 Firewall rejection statistics for `date +%F -d "$DESIRED_DAY"`

 Total number of log entries : `echo $TOTAL | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'`

 Blocked by geography        : `echo $GEO_REJ | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $GEO_REJ | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
EOT
if [ $GEO_REJ -gt 0 ]
then
    # Show the actual countries being blocked (along with their count)
    grep -o ' [A-Z][A-Z] ' /tmp/$$ | sort | grep -v ' DF ' | uniq -c | \
      awk '{printf "  Blocked from %-14s: %d\n",$2,$1}' | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta' >> /tmp/$$
fi
cat << EOT >> /tmp/$$.out
 Blocked by blocklists       : `echo $BLOCKED | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $BLOCKED | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
  Blocked by Spamhaus        : `echo $BLOCKED_SH | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $BLOCKED_SH | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
  Blocked by DShield         : `echo $BLOCKED_DSHIELD | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $BLOCKED_DSHIELD | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
  Blocked by EmergingThreads : `echo $BLOCKED_ETBL | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $BLOCKED_ETBL | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
  Blocked generically        : `echo $BLOCKED_GEN | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $BLOCKED_GEN | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
 Blocked malformed traffic   : `echo $MALFORMED | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $MALFORMED | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
 Blocked fragmented traffic  : `echo $FRAGMENTS | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $FRAGMENTS | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
 Blocked by flood protections: `echo $FLOOD | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $FLOOD | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
 Blocked by TCP w/o SYN      : `echo $NOSYN | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $NOSYN | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
 Blocked port scan           : `echo $PORTSCAN | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $PORTSCAN | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
 Blocked by 'fail2ban'       : `echo $BANNED | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $BANNED | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
 Blocked generically from ISP: `echo $GEN_ISP_REJ | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $GEN_ISP_REJ | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
 Blocked generically from LAN: `echo $GEN_LAN_REJ | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $GEN_LAN_REJ | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
 Blocked generically from DMZ: `echo $GEN_DMZ_REJ | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $GEN_DMZ_REJ | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
 Blocked generically         : `echo $GEN_REJ | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $GEN_REJ | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
 Other                       : `echo $OTHER | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $OTHER | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
EOT
cat /tmp/$$.out

# We are done
exit 0
