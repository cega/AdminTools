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
use Getopt::Std;

#--------------------------------------------------------------------
# Globals
#--------------------------------------------------------------------
$ENV{PATH} = '/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin';

# The list of addresses found in the netstat output(s)
my %Address = ();

# Program options
our $opt_d = 0;
our $opt_h = 0;

# Any return code other that '0' indicates a problem
my $RetCode = 0;

#--------------------------------------------------------------------
# Display the usage
#--------------------------------------------------------------------
sub ShowUsage()
{
    print "Usage: $ProgName [options]\n",
        "       -h                 Show this help [default=no]\n",
        "       -d                 Show some debug info on STDERR [default=no]\n";

    exit 0;
} ## end sub ShowUsage

#--------------------------------------------------------------------
# Main function
#--------------------------------------------------------------------
$|++;
print "$ProgName\n$CopyRight\n\n";

# Get possible options
getopts('d') or ShowUsage();
ShowUsage() if ($opt_h);

# Look for possible overall DDos attacks
open( NS, "-|", "netstat -anp --ip" )
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
    warn "Prot = $Fields[0], Source IP = $IPAddr\n" if ($opt_d);
    $Address{$IPAddr}++;
} ## end while ( my $Line = <NS> )
close(NS);

# Different threshold for debug and production
my $Threshold = ($opt_d) ? 5 : 500;
foreach my $IPAddr (%Address)
{
    # Ignore any host with less than "threshold" connections
    next unless ( $Address{$IPAddr} >= $Threshold );
    print
        "Possible DDos attack from '$IPAddr' ($Address{$IPAddr} connections)\n";
    $RetCode = 1;
} ## end foreach my $IPAddr (%Address...)

# Look for possible DDos attacks on the web server
open( NS, "-|", "netstat -n --ip" )
    or die "ERROR: Can not find or start 'netstat': $!";
%Address = ();
while ( my $Line = <NS> )
{
    # We are only interested in SYN attacks
    next unless ( $Line =~ /SYN_/o );

    # Get the invidual fields of the line
    my @Fields = split( /\s+/, $Line );

    # We only want to know about TCP and UDP connections
    next unless ( $Fields[0] =~ /tcp|udp/o );
    warn "Prot = $Fields[0], IP/Port = $Fields[3]\n" if ($opt_d);

    # We need the foreign IP of the connection
    my ($IPAddr) = split( /:/, $Fields[4] );
    # but ignore localhost
    next if ( $IPAddr eq '127.0.0.1' );
    warn "Prot = $Fields[0], Source IP = $IPAddr\n" if ($opt_d);
    $Address{$IPAddr}++;
} ## end while ( my $Line = <NS> )
close(NS);

# Different threshold for debug and production
$Threshold = ($opt_d) ? 1 : 100;
foreach my $IPAddr (%Address)
{
    # Ignore any host with less than "threshold" connections
    next unless ( $Address{$IPAddr} >= $Threshold );
    print
        "Possible SYN attack from '$IPAddr' ($Address{$IPAddr} connections)\n";
    $RetCode = 1;
} ## end foreach my $IPAddr (%Address...)

# We are done
exit $RetCode;
__END__
