#!/bin/bash
################################################################
# (c) Copyright 2014 B-LUC Consulting and Thomas Bullinger
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

DEBUG='-q'
[[ $- = *x* ]] && DEBUG='-v'

# This host and domain
THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
THISDOMAIN=${THISHOST#*.}

# Default setting for options
DATE2CHECK='yesterday'

# Get possible program options
while getopts hd: OPTION
do
    case ${OPTION} in
    d)  DATE2CHECK="$OPTARG"
        ;;
    *)  cat << EOT
Usage: $PROG [options] [logfile]
       -d daterange  Specify the date range to check [default=$DATE2CHECK]

       If no "logfile" is specified, /var/log/mail.log is used
EOT
        exit 0
        ;;
    esac
done
shift $((OPTIND - 1))

# The logs file to check
LOGFILE=${1-/var/log/mail.log}

# Get the mail logs for date to check
DATERANGE=$(date '+%b %_d' -d "$DATE2CHECK")
zgrep --no-filename "^$DATERANGE" $LOGFILE* > /tmp/$$

# Get the number of remote smtpd connections
grep 'smtpd.*: connect from' /tmp/$$ | \
  grep -v '127.0.0.1' > /tmp/$$.Smtpd.AllConnects
# Get all connections from remote hosts
ALL_CONS=$(sed -n '$=' /tmp/$$.Smtpd.AllConnects)
if [ -z "$ALL_CONS" ]
then
   echo "No connections for'$DATERANGE'"
   exit 0
fi

# Get the number of smtpd rejections
grep 'smtpd.*NOQUEUE' /tmp/$$ | grep -v ' filter:' > /tmp/$$.Smtpd.Noqueues
# Get the number of greylisted rejections
GL_REJ=$(grep -c 'Greylisting is active' /tmp/$$.Smtpd.Noqueues)
[ -z "$GL_REJ" ] && GL_REJ=0
# Get the number of NON-PPolicyd rejections
grep -v 'Greylisting is active' /tmp/$$.Smtpd.Noqueues > /tmp/$$.Smtpd.Noqueues.NoGreylist
RBL_REJ=$(grep -v ' 450 ' /tmp/$$.Smtpd.Noqueues.NoGreylist | grep -c 'blocked using')
[ -z "$RBL_REJ" ] && RBL_REJ=0
ADDR_REJ=$(grep -v ' 450 ' /tmp/$$.Smtpd.Noqueues.NoGreylist | grep -c ' address rejected')
[ -z "$ADDR_REJ" ] && ADDR_REJ=0
RELAY_REJ=$(grep -v ' 450 ' /tmp/$$.Smtpd.Noqueues.NoGreylist | grep -c 'Relay access denied')
[ -z "$RELAY_REJ" ] && RELAY_REJ=0
OTHER_REJ=$(grep -vc ' 450 ' /tmp/$$.Smtpd.Noqueues.NoGreylist)
if [ -z "$OTHER_REJ" ]
then
    OTHER_REJ=0
else
    OTHER_REJ=$(($OTHER_REJ - $RBL_REJ - $ADDR_REJ - $RELAY_REJ))
fi

# Get the number of PPolicyd rejections
grep 'ppolicyd.*blocked' /tmp/$$ > /tmp/$$.PPolicyd
PP_REJ=$(sed -n '$=' /tmp/$$.PPolicyd)
[ -z "$PP_REJ" ] && PP_REJ=0
PP_COUNTRY_REJ=$(grep -c ' country ' /tmp/$$.PPolicyd)
if [ -z "$PP_COUNTRY_REJ" ]
then
    PP_COUNTRY_REJ=0
else
    PP_COUNTRY_LIST=$(grep ' country ' /tmp/$$.PPolicyd | \
      mawk -F\' '{c[$12]++}END{for(j in c) print "                                  country",j,"("c[j]")"}' | \
      sed 's/;//' | sort -k2 -n)
fi

# Get the amavis results
grep 'amavis.*Message-ID' /tmp/$$ | grep -v ' Passed ' > /tmp/$$.Amavis.Rejects
# Get the number of amavis-based rejections
AM_REJ=$(sed -n '$='  /tmp/$$.Amavis.Rejects)
[ -z "$AM_REJ" ] && AM_REJ=0

# Finally show the stats
cat << EOT

                    Anti-Spam statistics for '$DATERANGE'

 Total SMTP connections from remote hosts     : $ALL_CONS

 Rejections based on DNS-based blacklists     : $RBL_REJ ($(echo $(($RBL_REJ * 100)) $ALL_CONS | mawk '{printf("%.2f%%",$1/$2) }'))
 Rejections based on sender/recipient address : $ADDR_REJ ($(echo $(($ADDR_REJ * 100)) $ALL_CONS | mawk '{printf("%.2f%%",$1/$2) }'))
 Rejections based on relay access             : $RELAY_REJ ($(echo $(($RELAY_REJ * 100)) $ALL_CONS | mawk '{printf("%.2f%%",$1/$2) }'))
 Rejections based on other criteria           : $OTHER_REJ ($(echo $(($OTHER_REJ * 100)) $ALL_CONS | mawk '{printf("%.2f%%",$1/$2) }'))
 Rejections based on PPolicyD findings        : $PP_REJ ($(echo $(($PP_REJ * 100)) $ALL_CONS | mawk '{printf("%.2f%%",$1/$2) }'))
EOT

if [ $PP_COUNTRY_REJ -gt 0 ]
then
    cat << EOT
   based on geographical blocks               : $PP_COUNTRY_REJ
$PP_COUNTRY_LIST
EOT
fi
cat << EOT
 Total outright rejections                    : $(($RBL_REJ + $ADDR_REJ + $RELAY_REJ + $OTHER_REJ  + $PP_REJ)) ($(echo $(($RBL_REJ * 100 + $ADDR_REJ * 100 + $RELAY_REJ * 100 + $OTHER_REJ * 100 + $PP_REJ * 100)) $ALL_CONS | mawk '{printf("%.2f%%",$1/$2) }'))

 Rejections based on Amavis findings          : $AM_REJ ($(echo $(($AM_REJ * 100)) $ALL_CONS | mawk '{printf("%.2f%%",$1/$2) }'))

 Holdups based on GreyListing                 : $GL_REJ ($(echo $(($GL_REJ * 100)) $ALL_CONS | mawk '{printf("%.2f%%",$1/$2) }'))
EOT

# We are done
exit 0
