#!/bin/bash                                                     
################################################################
# (c) Copyright 2012 Thomas Bullinger          
################################################################ 

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# We must have a valid account 'zimbra'
[ -z "$(getent passwd zimbra)" ] && exit 0

ZIMBRA_HOME=$(awk -F: '/^zimbra/ {print $6}' /etc/passwd)

# Create the charts for yesterday
YESTERDAY=$(date +%Y-%m-%d -d yesterday)
if [ -d $ZIMBRA_HOME/zmstat/$YESTERDAY ]
then                                    
        # Uncompress the saved csv files
        mkdir -p /tmp/zmstat
        cp $ZIMBRA_HOME/zmstat/$YESTERDAY/*gz /tmp/zmstat
        gunzip -f /tmp/zmstat/*gz
        chmod 0644 /tmp/zmstat/*.csv

        # Finally create the charts themselves
        mkdir -p $ZIMBRA_HOME/jetty/webapps/zimbra/charts/$YESTERDAY
        chown -R zimbra:zimbra $ZIMBRA_HOME/jetty/webapps/zimbra/charts/$YESTERDAY
        su - zimbra -c "zmstat-chart -s /tmp/zmstat -d $ZIMBRA_HOME/jetty/webapps/zimbra/charts/$YESTERDAY" > /dev/null
        chown -R zimbra:zimbra $ZIMBRA_HOME/jetty/webapps/zimbra/charts/$YESTERDAY
        rm -rf /tmp/zmstat

        cat << EOT | sendmail -t
From: admin@`hostname -d`
To: admin
Subject: Zimbra charts on `hostname -f`
Date: `date -R`

The Zimbra performance charts for $YESTERDAY are now available:
https://`hostname -f`/charts/index.html
EOT
fi

# Delete directories older than one month
for D in zmstat jetty/webapps/zimbra/charts
do
        find ${ZIMBRA_HOME}/$D -type d -mtime +30 -print0 | xargs -0 rm -rf
done

# Recreate the index file for all charts
cd ${ZIMBRA_HOME}/jetty/webapps/zimbra/charts
echo '<ul>' > index.html
for D in 2*
do
        [ -d $D ] || continue
        echo "<li><a href=${D}/index.html>$D</a>" >> index.html
done
echo '</ul>' >> index.html
chmod 0644 index.html

# We are done
exit 0
