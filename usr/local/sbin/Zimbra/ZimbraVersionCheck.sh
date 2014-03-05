#!/bin/bash
################################################################
# (c) Copyright 2013 B-LUC Consulting and Thomas Bullinger
################################################################

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/zimbra/bin

# We must run on a 64-bit OS
[ "T$(uname -p)" = 'Tx86_64' ] || exit 1

# We must have a valid account 'zimbra'
[ -z "$(getent passwd zimbra)" ] && exit 0

# Determine the currently installed version
CURVERS='zcs-'$(dpkg -l zimbra-core | awk '/core/ {print $3}' | sed -e 's/\.UBUNTU.*//')
if [ "T$CURVERS" = 'Tzcs-' ]
then
    CUR_MAJVERS='8'
else
    CUR_MAJVERS=${CURVERS:0:5}
fi

# Get the current Ubuntu release
UBUNTU_RELEASE=$(awk -F= '/_RELEASE/{print int($2)}' /etc/lsb-release)

# Ex.: http://files2.zimbra.com/downloads/6.0.12_GA/zcs-6.0.12_GA_2883.UBUNTU8_64.20110306010840.tgz
trap "rm -f /tmp/$$.*" EXIT
wget 'http://www.zimbra.com/downloads/os-downloads.html' -qO - > /tmp/$$.ZIMBRA
awk -F/ '/zcs-.*UBUNTU.*\.tgz"/ {print $6}' /tmp/$$.ZIMBRA | cut -d\" -f1 |sort -rn > /tmp/$$.AVAIL
NEWVERS=$(awk -F/ "/$CUR_MAJVERS"'.*UBUNTU'"$UBUNTU_RELEASE"'_64\.[0-9]*\.tgz/ {print $6}' /tmp/$$.ZIMBRA | cut -d\" -f1)
#NEWVERS=$(wget 'http://www.zimbra.com/downloads/os-downloads.html' -qO - | awk -F/ '/h.yimg.com.*zcs-6.*UBUNTU8\./ {print $7}' | cut -d\" -f1)
NEWVERS=$(echo $NEWVERS | sed -e 's/\.UBUNTU.*//')

# Some variables needed in the emails
THISHOST=$(hostname -f)
THISDOMAIN=$(hostname -d)
NOW="$(date -R)"

if [ -z "$NEWVERS" ]
then
    if [[ $- = *x* ]]
    then
        cat << EOT
Current Zimbra version '$CURVERS' is no longer available, the available packages are:
`cat /tmp/$$.AVAIL`
EOT
    else
        # Send a notification to the administrator
        sendmail -t << EOT
From: admin@$THISDOMAIN
To: admin
Cc: consult@btoy1.net
Subject: Zimbra version check $THISHOST
Date: $NOW

Current Zimbra '$CURVERS' version is no longer available, the available packages are:
`cat /tmp/$$.AVAIL`
EOT
    fi
elif [ "T${NEWVERS//./_}" != "T${CURVERS//./_}" ]
then
    if [[ $- = *x* ]]
    then
        echo "Newer Zimbra version is available: $NEWVERS"
    else
        # Send a notification to the administrator
        sendmail -t << EOT
From: admin@$THISDOMAIN
To: admin
Cc: consult@btoy1.net
Subject: Zimbra version check $THISHOST
Date: $NOW

Newer Zimbra version is available: $NEWVERS
EOT
    fi
fi

# Get the list of locked or closed accounts
cat << EOT > /tmp/$$
From: admin@$THISDOMAIN
To: admin
Subject: Zimbra locked or closed accounts
Date: $NOW

           account                          status             created       last logon
------------------------------------   -----------     ---------------  ---------------
EOT
su - zimbra -c 'zmaccts' | egrep '^[a-z].*(lockout|closed)' | sort >> /tmp/$$
sendmail -t < /tmp/$$
rm -f /tmp/$$

# Get the top 20 "diskhogs"
ZIMBRA_HOSTNAME=$(zmhostname)
cat << EOT > /tmp/$$
From: admin@$THISDOMAIN
To: admin
Subject: Zimbra top 20 "diskhogs" on $THISHOST
Date: $NOW

EOT
zmprov gqu $ZIMBRA_HOSTNAME | sort -k 3 -nr | awk '{print $3" "$1}'  | \
  grep -v '^0 ' | head -n 20 | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta' >> /tmp/$$
sendmail -t < /tmp/$$
rm -f /tmp/$$

# We are done
exit 0
