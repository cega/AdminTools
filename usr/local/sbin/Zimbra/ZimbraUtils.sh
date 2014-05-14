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

# This script must be run as "root"
[ "T$EUID" = 'T0' ] || exit

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/zimbra/bin

RED='\e[00;31m'
BLUE='\e[01;34m'
CYAN='\e[01;36m'
NC='\e[0m' # No Color
DOUBLE="\033#6"

ionice -c 2 -n 7 -p $$

while [ 1 ]
do
        clear
        echo
        echo -e "${DOUBLE} ZIMBRA UTILITIES"
        echo $(hostname -f)', '$(date)
        echo
        echo -e " ${CYAN} 1${NC} - Show current sessions     ${CYAN} 2${NC} - Optimize database"
        echo -e " ${CYAN} 3${NC} - Show folders for a user   ${CYAN} 4${NC} - Empty a user's folder"
        echo -e " ${CYAN} 5${NC} - Delete emails from a user's folder"
        echo -e " ${CYAN} 6${NC} - Expand all distribution lists"
        echo -e " ${CYAN}10${NC} - Set the password for an account"
        echo
        echo -e " ${RED}0${NC} - Return to prompt"
        echo
        read -p 'Please enter a choice: ' CHOICE

        case $CHOICE in
        0)      exit
                ;;

	1)	# Show active sessions
		timeout 600 zmsoap -z -v DumpSessionsRequest @groupByAccount=1 @listSessions=1 | \
			egrep '(\<(soap|imap|admin|synclistener) active|name=|folder)' | more
		read -p 'Press ENTER to continue'
		;;

	2)	# Optimize database
		echo 'This will impact performance and user expirence profoundly.'
		read -p 'Are you sure to do this [y/N] ? ' YN
		[ -z "$YN" ] && YN="N"
		if [ "T${YN^^}" = 'TY' ]
		then
			cat << EOT > /tmp/$$
#!/bin/bash
#
source ~zimbra/bin/zmshutil || exit 1
zmsetvars zimbra_home mysql_directory mysql_socket mysql_root_password
#echo \${mysql_root_password}
\${mysql_directory}/bin/mysqlcheck --all-databases --optimize -h localhost -P 7306 --protocol=tcp \
  --user=root --password=\${mysql_root_password} \$*
EOT
			su - zimbra -c "bash /tmp/$$"
			rm -f /tmp/$$
                fi
		;;

	3)	# Show a user's folder
		read -p 'What user/email address ? ' EADDR
		if [ ! -z "$EADDR" ]
		then
			(echo -n "Mailbox size for $EADDR: "; \
			zmmailbox -z -m $EADDR gms; \
			echo; \
			zmmailbox -z -m $EADDR gaf) | more
			read -p 'Press ENTER to continue'
		fi
		;;

	4)	# Empty a folder
		read -p 'What user/email address ? ' EADDR
		if [ ! -z "$EADDR" ]
		then
			read -p 'Folder name ? ' FOLDER
			if [ ! -z "$FOLDER" ]
			then
				read -p "Are you sure to empty folder '$FOLDER' for user '$EADDR' [y/N] ? " YN
				[ -z "$YN" ] || YN=${YN^^}
				if [ "T$YN" = 'TY' ]
				then
					su - zimbra -c "zmmailbox -z -m $EADDR emptyFolder /$FOLDER"
					read -p 'Press ENTER to continue'
				fi
			fi
		fi
		;;

	5)	# Delete emails in a user's folder
		read -p 'What user/email address ? ' EADDR
		if [ ! -z "$EADDR" ]
		then
			read -p 'Search query ? ' QUERY
			if [ ! -z "$QUERY" ]
			then
				while [ 1 ]
				do
				        # Get at most 100 messages
				        nice zmmailbox -z -m $EADDR search -t message -l 100 "$QUERY" > /tmp/MB
			        	FLines=$(sed -n '$=' /tmp/MB)
				        [ $FLines -le 2 ] && break

				        CMD="zmmailbox -z -m $EADDR deleteItem "$(sed -e 's/^[ ]*//' /tmp/MB | awk 'BEGIN{M=0};/mess/{M++;printf"%d,",$2};END{exit M}')
				        echo "Deleting $? messages based on '$QUERY'..."
				        su - zimbra -c "$CMD"
					[ $? -ne 0 ] && break
			        	echo "...done"
					rm -f /tmp/MB
				        sleep 1
				done
			fi
		fi
		;;

	6)	# Expand all distribution lists
		TEMPDIR=$(mktemp -d)

		# Get all distribution lists
		zmprov -l gadl > $TEMPDIR/all-dl.txt
		[ -s $TEMPDIR/all-dl.txt ] || exit 0

		# Expand each distibution list
		> /tmp/DL.txt
		for DL in $(< $TEMPDIR/all-dl.txt)
		do
		        echo "Distribution list: $DL" >> /tmp/DL.txt
		        [ -s $TEMPDIR/dl-$DL.txt ] || zmprov -l gdl $DL | grep 'zimbraMailForwardingAddress' > $TEMPDIR/dl-$DL.txt
		        cut -d: -f2  $TEMPDIR/dl-$DL.txt >> /tmp/DL.txt
		        echo >> /tmp/DL.txt
		done
		nice rm -rf $TEMPDIR &
		more /tmp/DL.txt
		read -p 'Press ENTER to continue'
		;;

	10)	# Set the password for an account
		read -p 'What user/email address ? ' EADDR
		if [ ! -z "$EADDR" ]
		then
			read -p 'New password ? ' NP
			[ -z "$NP" ] || su - zimbra -c "zmprov sp $EADDR $NP"
			read -p 'Press ENTER to continue'
		fi
		;;
	esac
done

# We are done
exit 0
