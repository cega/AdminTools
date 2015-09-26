#!/bin/bash
################################################################
# (c) Copyright 2012 B-LUC Consulting Thomas Bullinger
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

PROG=${0##*/}
if [ $EUID -ne 0 ]
then
        echo 'You need be root to run this script!'
        exit 1
fi

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/zimbra/bin

# The accounts need to be restored
ACCTLIST=''
# Do not force "skip" by default
FORCE_SKIP=0
# By default show any differences between backup and local config
IGNORE_DIFFS=0
# By default recover everything
RECOVER=1
# Be quiet
VERBOSE=0

# The logs files
LOG_OUT='/tmp/zos-restore.STDOUT'
LOG_ERR='/tmp/zos-restore.STDERR'
> $LOG_OUT
> $LOG_ERR

# Get possible options
while getopts A:shiv OPTION
do
        case ${OPTION} in
        A)      # Use specified accounts
                ACCTLIST=$(echo "$OPTARG" | sed -e 's/^ *//g' -e 's/ *$//g')
                RECOVER=0
                ;;
        s)      # Force a "skip" when restoring accounts
                FORCE_SKIP=1
                ;;
        i)      IGNORE_DIFFS=1
                ;;
        v)      VERBOSE=1
                ;;
        h|\?)
                echo "$0 [-i|-s|-A] [backup_directory]"
                echo '  -A 'name[ name]'  Restore only these accounts'
                echo '  -i                Ignore differences between backup and current configs'
                echo '  -s                Skip existing item in accounts'
                echo '  -v                Show what is being restored'
                echo ''
                echo "  'backup_directory' - where the backup files are"
                exit 1
        ;;
        esac
done
shift $(($OPTIND - 1))

trap "rm -f /tmp/$$*" EXIT

# Bail out unless we have the backup directory
if [ $# -ge 1 ]
then
        BKP_DIR="$1"
else
        read -p 'Specify directory for the backup files: ' BKP_DIR
        [ -z "$BKP_DIR" ] && exit 0
fi
if [ ! -d $BKP_DIR ]
then
        echo "No backup directory '$BKP_DIR' found"
        exit 1
else
        # Uncompress individual files, BUT NOT
        #  the account data files (they end in ".tgz")
        gunzip -f $BKP_DIR/*.gz
        if [ ! -s $BKP_DIR/localconfig ]
        then
                echo "Directory '$BKP_DIR' is not a backup directory"
                exit 1
        fi
fi

# Run the rest of the script in "ionice" mode
ionice -c2 -n7 -p $$

# Make a directory for the current settings
BKP_LDIR=/backup/.localbackups
mkdir -p $BKP_LDIR

# Determine whether we are on a "Network Edition" server or not
SESSIONS_DIR="$BKP_DIR"
if [ -x /opt/zimbra/bin/zmlicense -a -x /opt/zimbra/bin/zmrestore -a -s /opt/zimbra/backup/accounts.xml ]
then
	ZIMBRA_NE=1
	# Find the "sessions" directory
	while [ 1 ]
	do
		[ "T$SESSIONS_DIR" = 'T/' ] && break
		[ -d $SESSIONS_DIR/sessions ] && break
		SESSIONS_DIR=${SESSIONS_DIR%/*}
	done
	if [ "T$SESSIONS_DIR" = 'T/' ]
	then
		echo "ERROR: Could not restore account '$ACCOUNT' since no 'sessions' directory was found" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
		exit
	fi
else
	ZIMBRA_NE=0
fi

#-------------------------------------------------------------------------
# Restore one account at a time
#-------------------------------------------------------------------------
function RestoreAcct() {

        local ACCOUNT="$1"
        local STEP="$2"
        local RESOLUTION='skip'
	local RetCode=1
	local Loop=0

        # Passwords
        local password=$(awk '/^userPassword/ {print $2}' $BKP_DIR/account.$ACCOUNT)
	if [ -z "$password" ]
	then
		password='password'
		MUST_CHANGE_PW='zimbraPasswordMustChange TRUE'
	else
		MUST_CHANGE_PW=''
	fi
	su - zimbra -c "zmprov ma $ACCOUNT userPassword $password"

	if [ $ZIMBRA_NE -ne 0 ]
	then
		# We are on a "Network Edition" server
	        if [ $STEP -eq 1 ]
	        then
			while [ $RetCode -ne 0 -a $Loop -lt 3 ]
			do
				# Try to restore this account
				su - zimbra -c "zmrestore -ra -a $ACCOUNT -t $SESSIONS_DIR"
				RetCode=$?
				# We are done with this account if the restore was successful
				[ $RetCode -eq 0 ] && break

				# Try to delete this account
				su - zimbra -c "zmprov -l da $ACCOUNT"
				RetCode=$?
				if [ $RetCode -eq 0 ]
				then
					# Try again to restore this account
					su - zimbra -c "zmrestore -ra -a $ACCOUNT -t $SESSIONS_DIR"
					RetCode=$?
					# We are done with this account if the restore was successful
					[ $RetCode -eq 0 ] && break
				fi
				Loop=$(($Loop+1))
			done
		fi
	else

	        if [ -s /tmp/$$.CurrentAccounts ]
        	then
	                ACCOUNT_EXIST=$(grep $ACCOUNT /tmp/$$.CurrentAccounts)
        	else
                	ACCOUNT_EXIST=$(zmprov ga $ACCOUNT 2>>$LOG_ERR | head -n 1)
	        fi
	        if [ -z "$ACCOUNT_EXIST" ]
	        then
	                # Create the account
	                local firstname=$(awk '/^givenName/ {print $2}' $BKP_DIR/account.$ACCOUNT)
	                local lastname=$(awk '/^sn/ {print $2}' $BKP_DIR/account.$ACCOUNT)
	                local userid=$(awk '/^cn/ {print $2}' $BKP_DIR/account.$ACCOUNT)
	                local description=$(awk '/^description/ {$1="";print}' $BKP_DIR/account.$ACCOUNT | sed -e "s/'/\\'/")
			local zimbraArchiveEnabled=$(awk '/^zimbraArchiveEnabled/ {$1="";print}' $BKP_DIR/account.$ACCOUNT | sed -e "s/'/\\'/")
			local zimbraArchiveAccount=$(awk '/^zimbraArchiveAccount/ {$1="";print}' $BKP_DIR/account.$ACCOUNT | sed -e "s/'/\\'/")
			local amavisArchiveQuarantineTo=$(awk '/^amavisArchiveQuarantineTo/ {$1="";print}' $BKP_DIR/account.$ACCOUNT | sed -e "s/'/\\'/")
	                local NOW=$(date)

	                > /tmp/$$.CreateAccount
	                if [ -x /opt/zimbra/bin/zmlicense ]
	                then
				# Always update the license counter first
				echo 'flushcache license' >> /tmp/$$.CreateAccount
	                fi
	                echo "ca $ACCOUNT '$password'" > /tmp/$$.CreateAccount
	                echo "ma $ACCOUNT givenName '$firstname' sn '$lastname'" >> /tmp/$$.CreateAccount
	                echo "ma $ACCOUNT cn '$userid' displayName '$firstname $lastname'" >> /tmp/$$.CreateAccount
	                echo "ma $ACCOUNT description $description" >> /tmp/$$.CreateAccount
	                echo "ma $ACCOUNT zimbraNotes Migrated $NOW" >> /tmp/$$.CreateAccount
	                [ -z "$MUST_CHANGE_PW" ] || echo "ma $ACCOUNT $MUST_CHANGE_PW" >> /tmp/$$.CreateAccount
			if [ "T${zimbraArchiveEnabled^^}" = 'TTRUE' ]
			then
				echo "ma $ACCOUNT zimbraArchiveEnabled $zimbraArchiveEnabled" >> /tmp/$$.CreateAccount
				echo "ma $ACCOUNT amavisArchiveQuarantineTo  $amavisArchiveQuarantineTo" >> /tmp/$$.CreateAccount
				echo "ma $ACCOUNT zimbraArchiveAccount  $zimbraArchiveAccount" >> /tmp/$$.CreateAccount
			fi
	                su - zimbra -c "zmprov < /tmp/$$.CreateAccount" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
	                [ $FORCE_SKIP -eq 0 ] && RESOLUTION='reset'
	        fi
	fi

        if [ $STEP -eq 1 ]
        then
                # Create the aliases for it
                for ALIAS in $(awk '/^zimbraMailAlias/ {print $2}' $BKP_DIR/account.$ACCOUNT)
                do
                        echo "aaa $ACCOUNT $ALIAS" >> /tmp/$$.RestoreAccts_1
                done

                # Update the quota for it
                for QUOTA in $(awk '/^zimbraMailQuota/ {print $2}' $BKP_DIR/account.$ACCOUNT)
                do
                        echo "ma $ACCOUNT zimbraMailQuota $QUOTA" >> /tmp/$$.RestoreAccts_1
                done

                # Set the account status (other than maintenance)
                ACCTSTATUS=$(awk -F: '/^zimbraAccountStatus/ {$1="";gsub(/^ +/,"");print}' $BKP_DIR/account.$ACCOUNT)
                [ "T$ACCTSTATUS" = 'Tmaintenance' ] || echo "ma $ACCOUNT zimbraAccountStatus $ACCTSTATUS" >> /tmp/$$.RestoreAccts_1

                if [ $IGNORE_DIFFS -eq 0 ]
                then
                        if [ -s /tmp/$$.RestoreAccts_1 ]
                        then
                                # Do the updates/settings now
                                chmod 644 /tmp/$$.RestoreAccts_1
                                su - zimbra -c "zmprov < /tmp/$$.RestoreAccts_1" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
                        fi
                        > /tmp/$$.RestoreAccts_1
               fi
        else
		# On "Network Edition" servers we are done
        	[ $ZIMBRA_NE -ne 0 ] && return
	
                PR=$(ps -fu zimbra | grep -c 'zmmailbox.*postRestUR[L]')
		while [ $PR -ge 2 ]
		do
                        # Wait for other processes to finish
                        sleep 3
                        PR=$(ps -fu zimbra | grep -c 'zmmailbox.*postRestUR[L]')
                done

                # Check usage on /opt/zimbra/redolog
                if [ $(df -Ph /opt/zimbra/redolog | awk '/dev/ {print int($5)}') -gt 70 ]
                then
                        # Let's remove old redologs and check again
                        [ -d /opt/zimbra/redolog/archive ] && rm -f /opt/zimbra/redolog/archive/redo*
                fi

                set $(df -P -BM /opt/zimbra/redolog | awk '/dev/{print int($4)" "int($5)}')
                if [ $2 -gt 75 -a $1 -lt 20480 ]
                then
                        # More than 75% occupied and less than 20GB space left =>
                        #  let's restart zimbra as soon as no more
                        #    zmmailbox processes are running
                        PR=$(ps -fu zimbra | grep -c 'zmmailbox.*postRestUR[L]')
                        while [ $PR -gt 0 ]
                        do
                                # Wait for processes to finish
                                sleep 3
                                PR=$(ps -fu zimbra | grep -c 'zmmailbox.*postRestUR[L]')
                        done
                        su - zimbra -c 'zmcontrol stop; sleep 2; rm -f /opt/zimbra/redolog/redo.log; zmcontrol start' >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
                fi

                # Restore the account data from full and incremental backups
                (for F in $BKP_DIR/account-data.${ACCOUNT}.f*.tgz; \
                do \
                        # First from full backups \
                        [ $VERBOSE -ne 0 ] && echo "==> Checking data for '$ACCOUNT' from full backup"; \
                        if [ -s $F ]; then \
                          [ $VERBOSE -ne 0 ] && echo "===> Restoring data for '$ACCOUNT' from full backup"; \
                          su - zimbra -c "nice zmmailbox -z -m $ACCOUNT postRestURL '//?fmt=tgz&resolve='$RESOLUTION $F"  >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2); \
                        fi; \
                        [ $VERBOSE -ne 0 ] && echo; \
                done; \
                sleep 2; \
                for F in $BKP_DIR/account-data.${ACCOUNT}.i*.tgz; \
                do \
                        # Then from incremental backups \
                        [ $VERBOSE -ne 0 ] && echo "==> Checking data for '$ACCOUNT' from incremental backup"; \
                        if [ -s $F ]; then \
                          [ $VERBOSE -ne 0 ] && echo "===> Restoring data for '$ACCOUNT' from incremental backup"; \
                          su - zimbra -c "nice zmmailbox -z -m $ACCOUNT postRestURL '//?fmt=tgz&resolve=skip' $F" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2); \
                        fi; \
                        [ $VERBOSE -ne 0 ] && echo; \
                done) &

                # Wait for the background job to start
                sleep 3

                # We are done with this account
                return
        fi

        # Filters
        if [ -s $BKP_DIR/account.filters.$ACCOUNT ]
        then
                cat $BKP_DIR/account.filters.$ACCOUNT | while read line
                do
                        su - zimbra -c "nice zmmailbox -z -m $ACCOUNT modifyFilterRule $line" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
                        [ $? -ne 0 ] && su - zimbra -c "nice zmmailbox -z -m $ACCOUNT addFilterRule $line" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
                done
        fi

        if [ ! -z "$ACCOUNT_EXIST" -a $FORCE_SKIP -eq 1 ]
        then
            # Skip the rest of the settings for existing accounts
            return
        fi

        # Set some interesting values
        local ACCTPAR
        local ACCTVAL

        # Preferences
        > /tmp/$$
        for ACCTPAR in $(grep '^zimbraPref' $BKP_DIR/account.$ACCOUNT | cut -d: -f1)
        do
                ACCTVAL=$(awk -F: "/^$ACCTPAR/"' {$1="";gsub(/^ +/,"");print}' $BKP_DIR/account.$ACCOUNT)
                [ -z "$ACCTVAL" ] || echo "ma $ACCOUNT $ACCTPAR '$ACCTVAL'" >> /tmp/$$
        done
        if [ -s /tmp/$$ ]
        then
                echo "ma $ACCOUNT zimbraPrefMailInitialSearch in:inbox" >> /tmp/$$
                chmod 644 /tmp/$$
                su - zimbra -c "zmprov < /tmp/$$" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
        fi
        rm -f /tmp/$$

        if [ $IGNORE_DIFFS -eq 0 ]
        then
                echo "# Zimbra Account: $ACCOUNT" > $BKP_LDIR/account.$ACCOUNT
                zmprov ga $ACCOUNT >> $BKP_LDIR/account.$ACCOUNT
                rm -f /tmp/$$
                diff -u $BKP_LDIR/account.$ACCOUNT $BKP_DIR/account.$ACCOUNT &> /tmp/$$
                if [ $? -eq 0 ]
                then
                        echo "Account '$ACCOUNT' is identical to backup"
                        continue
                fi
                more /tmp/$$
                read -p 'Inspect the differences and press ENTER to continue' P
        fi
}

#-------------------------------------------------------------------------
# Recover all data
#-------------------------------------------------------------------------
function RecoverAll() {

        if [ $IGNORE_DIFFS -eq 0 ]
        then
                # Local config/passwords
                echo "# Zimbra Local Configuration" > $BKP_LDIR/localconfig
                su - zimbra -c 'zmlocalconfig -s' >> $BKP_LDIR/localconfig
                grep pass $BKP_LDIR/localconfig > /$BKP_LDIR/passwords
                diff -u $BKP_LDIR/passwords $BKP_DIR/passwords &> /tmp/$$
                if [ $? -eq 0 ]
                then
                        echo "Passwords are identical to backup"
                else
                        more /tmp/$$
                        read -p 'Inspect the differences and press ENTER to continue' P
                fi
        fi

        # Reset admin password?
        read -p 'Reset password for master admin [y/N] ? ' P
        if [ "T${P,,}" = 'Ty' ]
        then
                read -p 'New password: ' NEWPASS
                su - zimbra -c "zmprov sp admin@$(hostname -d) '$NEWPASS'" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
        fi

        rm -f /tmp/$$
        if [ $IGNORE_DIFFS -eq 0 ]
        then
                diff -u $BKP_LDIR/localconfig $BKP_DIR/localconfig &> /tmp/$$
                if [ $? -eq 0 ]
                then
                        echo "Local configuration is identical to backup"
                else
                        more /tmp/$$
                        read -p 'Inspect the differences and press ENTER to continue' P
                fi
        fi

        # All COS data
        for F in $BKP_DIR/cos.*
        do
                [ -f $F ] || continue

                COS=${F##*cos.}
                COS_EXIST=$(zmprov gc $COS 2>>$LOG_ERR  | head -n 1)
                [ $VERBOSE -ne 0 ] && echo "=> Restoring class of service '$COS'"
                if [ -z "$COS_EXIST" ]
                then
                        # Create the server
                        su - zimbra -c "zmprov cc $COS" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
                fi

                # Adapt the timezone
                TIMEZONE=$(awk -F: '/zimbraPrefTimeZoneId/ {$1="";gsub(/^ +/,"");print}' $BKP_DIR/cos.$COS)
                su - zimbra -c "zmprov mc $COS zimbraPrefTimeZoneId \"$TIMEZONE\"" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)

                if [ $IGNORE_DIFFS -eq 0 ]
                then
                        echo "# Zimbra Class of Service: $COS" > $BKP_LDIR/cos.$COS
                        zmprov gc $COS >> $BKP_LDIR/cos.$COS
                        rm -f /tmp/$$
                        diff -u $BKP_LDIR/cos.$COS $BKP_DIR/cos.$COS &> /tmp/$$
                        if [ $? -eq 0 ]
                        then
                                echo "Class of service '$COS' is identical to backup"
                                continue
                        fi
                        more /tmp/$$
                        read -p 'Inspect the differences and press ENTER to continue' P
                fi
                [ $VERBOSE -ne 0 ] && echo
        done

        # All servers
        for F in $BKP_DIR/server.*
        do
                [ -f $F ] || continue

                SERVER=${F##*server.}
                SERVER_EXIST=$(zmprov gs $SERVER 2>>$LOG_ERR  | head -n 1)
                [ $VERBOSE -ne 0 ] && echo "=> Restoring server '$SERVER'"
                if [ -z "$SERVER_EXIST" ]
                then
                        # Create the server
                        su - zimbra -c "zmprov cs $SERVER" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
                fi

                # Correct the postfix "mynetworks" parameter
                MYNETWORKS=$(awk -F: '/zimbraMtaMyNetworks/ {$1="";gsub(/^ +/,"");print}' $BKP_DIR/server.$SERVER)
                su - zimbra -c "zmprov ms $SERVER zimbraMtaMyNetworks \"$MYNETWORKS\"" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)

                if [ $IGNORE_DIFFS -eq 0 ]
                then
                        echo "# Zimbra Server: $SERVER" > $BKP_LDIR/server.$SERVER
                        zmprov gs $SERVER >> $BKP_LDIR/server.$SERVER
                        rm -f /tmp/$$
                        diff -u $BKP_LDIR/server.$SERVER $BKP_DIR/server.$SERVER &> /tmp/$$
                        if [ $? -eq 0 ]
                        then
                                echo "Server '$SERVER' is identical to backup"
                                continue
                        fi
                        more /tmp/$$
                        read -p 'Inspect the differences and press ENTER to continue' P
                fi
                [ $VERBOSE -ne 0 ] && echo
        done

        # All domains
        zmprov -l gad > /tmp/$$.CurrentDomains
        ls -1 $BKP_DIR/domain.* > /tmp/$$.BackedUpDomains
        > /tmp/$$
        for F in $(< /tmp/$$.BackedUpDomains)
        do
                DOMAIN=${F##*domain.}

                [ $VERBOSE -ne 0 ] && echo "=> Checking domain '$DOMAIN'"
                DOMAIN_EXIST=$(grep ^$DOMAIN /tmp/$$.CurrentDomains)
                [ -s $BKP_DIR/domain.$DOMAIN ] || continue
                if [ -z "$DOMAIN_EXIST" ]
                then
                        # Create the domain
                        [ $VERBOSE -ne 0 ] && echo "==> Creating domain '$DOMAIN'"
                        su - zimbra -c "zmprov cd $DOMAIN" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
                fi

                # Set the authentication method and params
                grep '^zimbraAuth' $BKP_DIR/domain.$DOMAIN | sort -r | while read ZAP
                do
                        [ -z "$ZAP" ] && continue
                        echo "md $DOMAIN $(echo $ZAP | sed -e 's/://')" >> /tmp/$$
                done

                # Set the domain status
                DOMSTATUS=$(awk -F: '/^zimbraDomainStatus/ {$1="";gsub(/^ +/,"");print}' $BKP_DIR/domain.$DOMAIN)
                [ -z "$DOMSTATUS" ] || echo "md $DOMAIN zimbraDomainStatus $DOMSTATUS" >> /tmp/$$

                if [ $IGNORE_DIFFS -eq 0 ]
                then
                        # Do the updates for this domain now
                        if [ -s /tmp/$$ ]
                        then
                                chmod 644 /tmp/$$
                                su - zimbra -c "zmprov < /tmp/$$" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
                        fi
                        rm -f /tmp/$$

                        echo "# Zimbra Domain: $DOMAIN" > $BKP_LDIR/domain.$DOMAIN
                        zmprov gd $DOMAIN >> $BKP_LDIR/domain.$DOMAIN
                        rm -f /tmp/$$
                        diff -u $BKP_LDIR/domain.$DOMAIN $BKP_DIR/domain.$DOMAIN &> /tmp/$$
                        if [ $? -eq 0 ]
                        then
                                echo "Domain '$DOMAIN' is identical to backup"
                                continue
                        fi
                        more /tmp/$$
                        read -p 'Inspect the differences and press ENTER to continue' P
                fi
                [ $VERBOSE -ne 0 ] && echo
        done
        if [ -s /tmp/$$ ]
        then
                # Do all domain updates now
                chmod 644 /tmp/$$
                su - zimbra -c "zmprov < /tmp/$$" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
        fi
        rm -f /tmp/$$

        # All accounts
        for F in $BKP_DIR/account.*
        do
                # Ignore filter and empty files
                [[ $F = *.filters.* ]] && continue
                [ -s $F ] || continue

                ACCOUNT=${F##*account.}
                ACCTLIST="$ACCOUNT $ACCTLIST"
        done

        # All distribution lists
        zmprov -l gadl > /tmp/$$.CurrentDL
        ls -1 $BKP_DIR/list.* > /tmp/$$.BackedUpDL
        for F in $(< /tmp/$$.BackedUpDL)
        do
                LIST=${F##*list.}
                [ $VERBOSE -ne 0 ] && echo "=> Checking distribution list '$LIST'"
                LIST_EXIST=$(grep "^$LIST" /tmp/$$.CurrentDL)
                [ -s $BKP_DIR/list.$LIST ] || continue
                if [ -z "$LIST_EXIST" ]
                then
                        # Create the distribution list
                        [ $VERBOSE -ne 0 ] && echo "==> Restoring distribution list '$LIST'"
                        echo "cdl $LIST" > /tmp/$$

                        # Add its members
                        for MEMBER in $(awk '/^zimbraMailForwardingAddress/ {print $2}' $BKP_DIR/list.$LIST)
                        do
                                echo "adlm $LIST $MEMBER" >> /tmp/$$
                        done
                fi
                if [ -s /tmp/$$ ]
                then
                        chmod 644 /tmp/$$
                        su - zimbra -c "zmprov < /tmp/$$" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
                fi
                rm -f /tmp/$$

                if [ $IGNORE_DIFFS -eq 0 ]
                then
                        echo "# Zimbra Distribution List: $LIST" > $BKP_LDIR/list.$LIST
                        zmprov gdl $LIST >> $BKP_LDIR/list.$LIST
                        rm -f /tmp/$$
                        diff -u $BKP_LDIR/list.$LIST $BKP_DIR/list.$LIST &> /tmp/$$
                        if [ $? -eq 0 ]
                        then
                                echo "Distribution list '$LIST' is identical to backup"
                                continue
                        fi
                        more /tmp/$$
                        read -p 'Inspect the differences and press ENTER to continue' P
                fi
                [ $VERBOSE -ne 0 ] && echo
        done

        # All calendars
        for F in $BKP_DIR/calendar.*
        do
                [ -f $F ] || continue

                CAL=${F##*calendar.}
                CAL_EXIST=$(zmprov gcr $CAL 2>>$LOG_ERR  | head -n 1)
                [ $VERBOSE -ne 0 ] && echo "=> Restoring calendar '$CAL'"
                if [ -z "$CAL_EXIST" ]
                then
                        DisplayName=$(awk '/^displayName/ {print $2}' $F)
                        CalResType=$(awk '/^zimbraCalResType/ {print $2}' $F)

                        # Create the calendar with the values from the backup
                        su - zimbra -c "zmprov ccr $CAL 'password' displayName '$DisplayName' zimbraCalResType '$CalResType' zimbraNotes 'Migrated $NOW' zimbraPasswordMustChange TRUE" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2) 
                fi

                if [ $IGNORE_DIFFS -eq 0 ]
                then
                        echo "# Zimbra Calendar: $CAL" > $BKP_LDIR/calendar.$CAL
                        zmprov gcr $CAL >> $BKP_LDIR/calendar.$CAL
                        rm -f /tmp/$$
                        diff -u $BKP_LDIR/calendar.$CAL $BKP_DIR/calendar.$CAL &> /tmp/$$
                        if [ $? -eq 0 ]
                        then
                                echo "Calendar '$CAL' is identical to backup"
                                continue
                        fi
                        read -p 'Inspect the differences and press ENTER to continue' P
                        more /tmp/$$
                fi
                [ $VERBOSE -ne 0 ] && echo
        done

        # Some misc. files
        if [ -s $BKP_DIR/LocalHealthCheck.sh ]
        then
                diff -u $BKP_DIR/LocalHealthCheck.sh /usr/local/sbin/LocalHealthCheck.sh &> /tmp/$$
                if [ $? -ne 0 ]
                then
                        cat $BKP_DIR/LocalHealthCheck.sh > /usr/local/sbin/LocalHealthCheck.sh
                        echo '/usr/local/sbin/LocalHealthCheck.sh updated'
                        read -t 10 -p 'Press ENTER to continue' P
                fi
        fi
        
        if [ -f $BKP_DIR/zos-MailRouting.cfg ]
        then
                diff -u $BKP_DIR/zos-MailRouting.cfg /usr/local/etc/zos-MailRouting.cfg &> /tmp/$$
                if [ $? -ne 0 ]
                then
                        cat $BKP_DIR/zos-MailRouting.cfg > /usr/local/etc/zos-MailRouting.cfg
                        echo '/usr/local/etc/zos-MailRouting.cfg updated'
                        read -t 10 -p 'Press ENTER to continue' P
                fi
        fi
}

#-------------------------------------------------------------------------
# Main function
#-------------------------------------------------------------------------
[ $RECOVER -ne 0 ] && RecoverAll

if [ ! -z "$ACCTLIST" ]
then
        zmprov -l gaa > /tmp/$$.CurrentAccounts
        > /tmp/$$.RestoreAccts_1
        for ACCOUNT in $(echo "$ACCTLIST")
        do
                # Create account etc. (if needed)
                [ $VERBOSE -ne 0 ] && echo "=> Restoring account '$ACCOUNT' (step 1)"
                RestoreAcct $ACCOUNT 1
                [ $VERBOSE -ne 0 ] && echo
        done
        if [ -s /tmp/$$.RestoreAccts_1 ]
        then
                # Do the updates/settings now
                chmod 644 /tmp/$$.RestoreAccts_1
                su - zimbra -c "zmprov < /tmp/$$.RestoreAccts_1" >> >(tee $LOG_OUT) 2>> >(tee $LOG_ERR >&2)
        fi

        for ACCOUNT in $(echo "$ACCTLIST")
        do
                # Restore account contents (if present)
                [ $VERBOSE -ne 0 ] && echo "=> Restoring account '$ACCOUNT' (step 2)"
                RestoreAcct $ACCOUNT 2
                [ $VERBOSE -ne 0 ] && echo
        done
fi

# Write some parting works in big fat letters :)
DOUBLE="\033#6"
RED='\e[00;31m'
NC='\e[0m' # No Color
echo
echo -e "${DOUBLE}${RED}      WORD of CAUTION${NC}"
cat << EOW

This script tries its best to restore the original configuration, domains,
accounts along with their emails, calendar and address book entries, and
tasks, and email distribution lists.

However, that does NOT relieve you of the responsibility to thoroughly check
the new server configuration, its domains, accounts along with their emails,
calendar and address book entries, and tasks, and email distribution lists.

EOW
echo -e "${DOUBLE}=> You have been warned <="
echo
echo "Logs are in '$LOG_OUT' and '$LOG_ERR'"

# We are done
exit 0
