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

# First extract the logs for yesterday
YESTERDAY=$(date +'%b %_d' -d yesterday)
egrep "^$YESTERDAY .*IN=.*OUT=" /var/log/kern.log > /tmp/$$

# Get numbers
TOTAL=$(sed -n '$=' /tmp/$$)
GEO_REJ=$(grep -c 'Geo-based rejection' /tmp/$$)
BLOCKED=$(grep -c 'BLOCKED:' /tmp/$$)
FLOOD=$(grep -c 'FLOOD' /tmp/$$)
MALFORMED=$(grep -c 'MALFORMED ' /tmp/$$)
FRAGMENTS=$(grep -c 'FRAGMENTS ' /tmp/$$)
NOSYN=$(grep -c 'NEW TCP w/o SYN' /tmp/$$)
BANNED=$(grep -c 'fail2ban' /tmp/$$)
PORTSCAN=$(grep -c 'Portscan' /tmp/$$)
GEN_ISP_REJ=$(grep -c 'IN-ISP:' /tmp/$$)
GEN_LAN_REJ=$(grep -c 'IN-LAN:' /tmp/$$)
GEN_DMZ_REJ=$(grep -c 'IN-DMZ:' /tmp/$$)
GEN_REJ=$(egrep '(Rejected (TCP|UDP)|(IN|OUT)-)' /tmp/$$ | egrep -cv '\-(LAN|DMZ|ISP|Portscan)')
OTHER=$(($TOTAL - $GEO_REJ - $BLOCKED - $FLOOD - $MALFORMED - $FRAGMENTS - $NOSYN - $BANNED - $PORTSCAN - $GEN_ISP_REJ - $GEN_LAN_REJ - $GEN_DMZ_REJ - $GEN_REJ))

# Nicely report the numbers
cat << EOT
 Firewall rejection statistics for `date +%F -d yesterday`

 Total number of log entries : `echo $TOTAL | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'`

 Blocked by geography        : `echo $GEO_REJ | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $GEO_REJ | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
 Blocked by blocklists       : `echo $BLOCKED | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'` (`echo $TOTAL $BLOCKED | awk '{ printf("%.2f%%\n", $2/($1/100)) }'`)
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

# We are done
exit 0
