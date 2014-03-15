#!/bin/bash
################################################################
# (c) Copyright 2013 B-LUC Consulting and Thomas Bullinger
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

# Ensure we use the correct postfix config_directory
PF_CD=$(postconf -h config_directory)

# Define some colours
RED='\e[00;31m'
BLUE='\e[01;34m'
CYAN='\e[01;36m'
NC='\e[0m' # No Color

# Sanity checks
if [[ $(postconf -h local_transport) != error:* ]]
then
    echo 'This is NOT a backup MX server'
    exit 1
fi
if [ ! -z "$(postconf -h mydestination)" ]
then
    echo 'This is NOT a backup MX server'
    exit 1
fi

#####################################################################
# Add a new MX domain
#####################################################################
AddMX() {
    echo
    echo -ne " ${BLUE}What is the name of the new MX domain${NC}"
    read -p '? ' MXD
    [ -z "$MXD" ] && return

    if [ -z "$(grep ^$MXD $PF_CD/relays)" ]
    then
        local NOW=$(date)

        echo "# $MXD added ${NOW}:" >> $PF_CD/relays
        echo "$MXD OK" >> $PF_CD/relays

        echo "# $MXD added ${NOW}:" >> $PF_CD/relay_recipients
        echo "@${MXD} OK" >> $PF_CD/relay_recipients

        (cd $PF_CD; ./make)
    else
        echo -e "${RED}Domain '$MXD' already exists${NC}"
    fi
    read -p 'Press <ENTER> to continue'
}

#####################################################################
# Delete a new MX domain
#####################################################################
DelMX() {
    echo
    echo -ne " ${BLUE}What is the name of the MX domain to delete${NC}"
    read -p '? ' MXD
    [ -z "$MXD" ] && return
    if [ -z "$(grep ^$MXD $PF_CD/relays)" ]
    then
        echo -e "${RED}Domain '$MXD' does not exist${NC}"
    else
        for F in relays relay_recipients
        do
            sed -e "/$MXD/d" $PF_CD/$F > /tmp/$$
            cat /tmp/$$ > $PF_CD/$F
        done
        [ -f /tmp/$$ ] && rm -f /tmp/$$
        (cd $PF_CD; ./make)
    fi
        
    read -p 'Press <ENTER> to continue'
}

#####################################################################
# List MX domains
#####################################################################
ListMX() {
    echo
    echo -e "${BLUE}List of defined MX email domains:${NC}"
    echo
    for D in $(grep 'OK' $PF_CD/relays)
    do
        [ "T$D" = 'TOK' ] && continue

        # Show the domain and possible specific mail routing
        echo "Domain '$D':"
        MR=$(awk "/$D.*relay/"'{print $2}' $PF_CD/transport | sort -u)
        if [ -z "$MR" ]
        then
            # Show the specific mail routing
            host -t mx $D
        else
            # Look up the MX record(s) for the domain
            echo "$D mail is forced to use $MR"
        fi
        echo
    done
    read -p 'Press <ENTER> to continue'
}

#####################################################################
# Execute given option
#####################################################################
ExecOption() {
    UI=$1

    case $UI in
    0)     exit 0
           ;;
    1)     AddMX
           ;;
    2)     DelMX
           ;;
    3)     ListMX
           ;;
    esac
}

#####################################################################
# Main loop
#####################################################################
# Create the "make" file in the postfix config directory
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
chmod 755 $PF_CD/make

while [ 1 ]
do
    clear
    echo
    echo -e "      ${BLUE}MX Maintenance${NC}"
    echo
    echo -e "   ${CYAN}0${NC} - Exit program"
    echo
    echo -e "   ${CYAN}1${NC} - Add MX domain"
    echo -e "   ${CYAN}2${NC} - Delete MX domain"
    echo -e "   ${CYAN}3${NC} - List MX domains"
    echo
    read -p '  Please select your choice : ' UI
    ExecOption $UI
done

# We are done
exit 0
