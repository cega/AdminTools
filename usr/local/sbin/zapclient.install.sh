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

#--------------------------------------------------------------------
# Specifying "-x" to the bash invocation = DEBUG
DEBUG='-q'
[[ $- = *x* ]] && DEBUG='-v'

#--------------------------------------------------------------------
# This host and domain
THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
THISDOMAIN=${THISHOST#*.}

#--------------------------------------------------------------------
# Install necessary python packages
apt-get install python-setuptools

#--------------------------------------------------------------------
# Determine the download link for the newest client tarball
wget $DEBUG -o /tmp/$$.log -O /tmp/$$.html \
  http://sourceforge.net/projects/zaproxy/files/client-api/
if [ $? -ne 0 ]
then
    echo "Can't determine download link for ZAP"
    cat /tmp/$$.log
    exit 1
fi

TARBALL=$(grep -m 1 'python-owasp-zap.*tar.gz' /tmp/$$.html | sed -e 's/^.*"py/py/;s/gz".*/gz/')
if [ -z "$TARBALL" ]
then
    echo "Can't determine download link for ZAP"
    less /tmp/$$.html
    exit 1
fi

#VERSION=${DNLINK##*/}
# Example:
#  http://sourceforge.net/projects/zaproxy/files/client-api/python-owasp-zap-v2-0.0.9.tar.gz/download
URL="http://sourceforge.net/projects/zaproxy/files/client-api/$TARBALL/download"

# Download the newest tarball
wget $DEBUG -o /tmp/$$.log --no-check-certificate \
  -O /usr/local/src/$TARBALL "$URL"
if [ $? -ne 0 ]
then
    echo "ZAP download failed"
    cat /tmp/$$.log
    exit 1
fi

# Untar it
cd /tmp
tar $DEBUG -xzf /usr/local/src/$TARBALL

# Build and install the client
# As per https://code.google.com/p/zaproxy/wiki/ApiPython
cd python*
cd api/
python setup.py build
python setup.py install

# Create a sample script
# As per https://code.google.com/p/zaproxy/wiki/ApiPython
#    and https://code.google.com/p/zaproxy/issues/detail?id=1210
LOCALIP=$(ifconfig eth0 | sed -n "s/.*inet addr:\([0-9.]*\).*/\1/p")
cat << EOT > /usr/local/bin/zapclient-sample.py
#!/usr/bin/env python

import getopt
import sys
import os
import time
import uuid
import tempfile
import json
from zapv2 import ZAPv2

# Uniquify a list of lists
# As per http://www.peterbe.com/plog/uniqifiers-benchmark/uniqifiers_benchmark.py
def uniquify_list(seq): # Dave Kirby
    # Order preserving
    seen = set()
    return [x for x in seq if x not in seen and not seen.add(x)]


# Uniquify a list of dicts
# As per http://stackoverflow.com/questions/9427163/remove-duplicate-dict-in-list-in-python
def uniquify_dict(seq):
    seen = set()
    results = []
    for d in seq:
        t = tuple(sorted(d.items()))
        if t not in seen:
            seen.add(t)
            results.append(d)
    return results

# Define the target (can also be passed in as option)
target = 'http://www.btoy1.net'
options, remainder = getopt.getopt(sys.argv[1:], 'ht:', ['help','target='])
for opt, arg in options:
    if opt in ('-t', '--target'):
        target = arg
    if opt in ('-h', '--help'):
        print '%s: [-h|-t URL]' % os.path.basename(__file__)
        sys.exit()

zap = ZAPv2(proxies={'http': 'http://192.168.1.226:8080', 'https': 'http://192.168.1.226:8080'})

# Create a new session
session_id = str(uuid.uuid4())
os.chdir(tempfile.gettempdir())
zap.core.new_session(name=session_id)

# Access the target URL
print 'Accessing target', target
# try have a unique enough session...
zap.urlopen(target)
# Give the sites tree a chance to get updated
time.sleep(2)

# Spider the web site
print 'Spidering target', target
zap.spider.scan(target)
# Give the Spider a chance to start
time.sleep(2)
while (int(zap.spider.status) < 100):
    print 'Spider progress %:', zap.spider.status
    time.sleep(2)

print 'Spider completed'
# Give the passive scanner a chance to finish
time.sleep(5)

# Scan the site
print 'Scanning target', target, 'with these scanners:'
print json.dumps(uniquify_dict(zap.ascan.scanners()),separators=(',',':'),indent=3)
zap.ascan.scan(target)
while (int(zap.ascan.status) < 100):
    print 'Scan progress %:', zap.ascan.status
    time.sleep(5)

print 'Scan completed'

# Save this session
zap.core.save_session(name=session_id)

# Report the results
#print 'Hosts: ' + ', '.join(zap.core.hosts)
#print 'Sites: ' + ', '.join(zap.core.sites)

# Print the spider results in JSON format
print 'Spider results:'
print json.dumps(uniquify_list(zap.spider.results),separators=(',',':'),indent=3)

# Print the alerts as a pretty-printed JSON structure
print int(zap.core.number_of_alerts(baseurl=target)), "alert(s) for target", target
print json.dumps(uniquify_dict(zap.core.alerts(baseurl=target)),separators=(',',':'),indent=3)
EOT
chmod 755 /usr/local/bin/zapclient-sample.py

#--------------------------------------------------------------------
# We are done
exit 0
