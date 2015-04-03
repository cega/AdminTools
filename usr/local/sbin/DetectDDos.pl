#!/usr/bin/perl -Tw
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
# Based on https://www.hivelocity.net/kb/how-to-check-if-your-linux-server-is-under-ddos-attack
use 5.0010;

# Constants
my $ProgName = '';
( $ProgName = $0 ) =~ s%.*/%%;
my $CopyRight = "(c) CopyRight 2015 B-LUC Consulting Thomas Bullinger";

# Common sense options:
use strict qw(vars subs);
no warnings;
use warnings qw(FATAL closed threads internal debugging pack
    portable prototype inplace io pipe unpack malloc
    glob digit printf layer reserved taint closure
    semicolon);
no warnings qw(exec newline unopened);

#--------------------------------------------------------------------
# Needed packages
#--------------------------------------------------------------------
use Sys::Syslog qw(:macros :standard);
use Sys::Hostname;
use POSIX qw(setsid strftime);
use Getopt::Std;

#--------------------------------------------------------------------
# Globals
#--------------------------------------------------------------------
$ENV{PATH} = '/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin';

# Host to monitor
my $MHOST = hostname;
unless ( $MHOST =~ /\./ )
{
    if ( open( HOSTNAME, '-|', 'hostname -f' ) )
    {
        $MHOST = <HOSTNAME>;
        close(HOSTNAME);
        chomp($MHOST);
    } ## end if ( open( HOSTNAME, '-|'...))
} ## end unless ( $MHOST =~ /\./ )

# The list of addresses found in the netstat output(s)
my %DOS_Address = ();
my %SYN_Address = ();

# Program options
our $opt_D = 0;
our $opt_d = 0;
our $opt_h = 0;

# Any return code other that '0' indicates a problem
my $RetCode = 0;

#--------------------------------------------------------------------
# Become a daemon process
#--------------------------------------------------------------------
sub Daemonize()
{

    # pretty command line in ps
    $0 = join( ' ', $0, @ARGV ) unless ($opt_d);

    chdir '/' or die "Can't chdir to '/': $!";

    # Redirect STDIN and STDOUT
    open( STDIN,  '<', '/dev/null' ) or die "Can't read '/dev/null': $!";
    open( STDOUT, '>', '/dev/null' ) or die "Can't write '/dev/null': $!";
    defined( my $pid = fork ) or die "Can't fork: $!";

    if ($pid)
    {

        # The parent can die now
        print "DEBUG: Parent dies" if ($opt_d);
        exit;
    } ## end if ($pid)

    setsid or die "Can't start new session: $!";
    open STDERR, '>&STDOUT' or die "Can't duplicate stdout: $!";
} ## end sub Daemonize

#--------------------------------------------------------------------
# Display the usage
#--------------------------------------------------------------------
sub ShowUsage()
{
    print "Usage: $ProgName [options]\n",
        "       -D sec  Check every 'sec' seconds [default=no]\n",
        "       -h      Show this help [default=no]\n",
        "       -d      Show some debug info on STDERR [default=no]\n";

    exit 0;
} ## end sub ShowUsage

#--------------------------------------------------------------------
# Main function
#--------------------------------------------------------------------
$|++;
print "$ProgName\n$CopyRight\n\n";

# Get possible options
getopts('dD:h') or ShowUsage();
ShowUsage() if ($opt_h);

# Open connection to syslog
openlog( "$ProgName", LOG_PID, LOG_DAEMON );

# Become a daemon process (if specified)
Daemonize if ($opt_D);

while (1)
{
    # Record the start time
    my $StartTime = time();

    # Look for possible overall and SYN DOS attacks
    open( NS, "-|", "netstat -an --ip" )
        or die "ERROR: Can not find or start 'netstat': $!";
    while ( my $Line = <NS> )
    {
        # Get the invidual fields of the line
        my @Fields = split( /\s+/, $Line );

        # We only want to know about TCP and UDP connections
        next unless ( $Fields[0] =~ /tcp|udp/o );

        # We need the foreign IP of the connection
        my ($IPAddr) = split( /:/, $Fields[4] );
        # but ignore localhost
        next if ( $IPAddr eq '127.0.0.1' );
        # also ignore any connections without status
        next unless ( scalar @Fields > 5 );
        warn
            "DEBUG: Prot = $Fields[0], foreign IP = $IPAddr, status = $Fields[5]\n"
            if ($opt_d);

        # We have a host which is somehow connected
        $DOS_Address{$IPAddr}++;
        if ( $Line =~ /SYN_/o )
        {
            # We have a foreign host which sent or received a SYN packet
            $SYN_Address{$IPAddr}++;
        } ## end if ( $Line =~ /SYN_/o ...)
    } ## end while ( my $Line = <NS> )
    close(NS);

    # Different threshold for debug and production
    my $Threshold = ($opt_d) ? 5 : 500;
    foreach my $IPAddr ( keys %DOS_Address )
    {
        # Ignore any host with less than "threshold" connections
        warn
            "DEBUG: DOS IPAddr = $IPAddr ($DOS_Address{$IPAddr}, $Threshold)\n"
            if ($opt_d);
        next unless ( $DOS_Address{$IPAddr} >= $Threshold );
        print
            "Possible DOS attack from '$IPAddr' ($DOS_Address{$IPAddr} connections)\n";
        syslog( LOG_CRIT,
            "critical %s %s Possible DOS attack from '%s' (%d connections)",
            POSIX::ctime(time),
            $MHOST,
            $IPAddr,
            $DOS_Address{$IPAddr}
        );
        $RetCode = 1;
    } ## end foreach my $IPAddr ( keys %DOS_Address...)

    # Different threshold for debug and production
    $Threshold = ($opt_d) ? 1 : 100;
    foreach my $IPAddr ( keys %SYN_Address )
    {
        # Ignore any host with less than "threshold" connections
        warn
            "DEBUG: SYN IPAddr = $IPAddr ($DOS_Address{$IPAddr}, $Threshold)\n"
            if ($opt_d);
        next unless ( $SYN_Address{$IPAddr} >= $Threshold );
        print
            "Possible SYN attack from '$IPAddr' ($SYN_Address{$IPAddr} connections)\n";
        syslog( LOG_CRIT,
            "critical %s %s Possible SYN attack from '%s' (%d connections)",
            POSIX::ctime(time),
            $MHOST,
            $IPAddr,
            $SYN_Address{$IPAddr}
        );
        $RetCode = 1;
    } ## end foreach my $IPAddr ( keys %SYN_Address...)

    # We are done unless we run as a daemon
    last unless ($opt_D);

    # Wait for at most $opt_D seconds
    my $EndTime = time();
    my $WaitTime = $opt_D - ( $EndTime - $StartTime );
    warn "DEBUG: Wait time = $WaitTime, start = $StartTime, end = $EndTime\n"
        if ($opt_d);
    sleep($WaitTime) if ($WaitTime);
} ## end while (1)

# We are done
exit $RetCode;
__END__
