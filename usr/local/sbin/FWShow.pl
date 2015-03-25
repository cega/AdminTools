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

# The rules
my %Ruleset;

# Program options
our $opt_d = 0;
our $opt_h = 0;

# External programs
my $IPTABLES = '/sbin/iptables';

# Prototypes
sub ShowUsage();
sub GetTable($);
sub BeautifyRule($);
sub ShowSubChainRules($$$$);
sub ShowRules($);

#--------------------------------------------------------------------
# Display the usage
#--------------------------------------------------------------------
sub ShowUsage()
{

    print "Usage: $ProgName [options]\n",
        "       -h       Show this help [default=no]\n",
        "       -d       Show some debug info on STDERR [default=no]\n";

    exit 0;
} ## end sub ShowUsage

#--------------------------------------------------------------------
# Get a table, its chains and rules
#--------------------------------------------------------------------
sub GetTable($)
{
    my ($Table) = @_;
    my $Chain = '';
    %Ruleset = ();

    open( VMS, "-|", "$IPTABLES -t $Table -nvL" )
        or die "ERROR: Can not find or start 'iptables': $!";

    while ( my $Line = <VMS> )
    {
        chomp($Line);
        if ( $Line =~ /^Chain (\S+)/o )
        {
            $Chain = "$1";
            warn "DEBUG: '$Table' new chain = '$Chain'\n" if ($opt_d);
            next;
        } ## end if ( $Line =~ /^Chain (\S+)/o...)

        if ( $Line =~ /^\s*(\d\S*\s+.*)/o )
        {
            my $Rule = "$1";
            $Rule =~ s/^\s*//;
            warn "DEBUG: '$Table' '$Chain' new rule = '$Rule'\n" if ($opt_d);
            # Save the info
            push( @{ $Ruleset{$Chain} }, "$Rule" );
            next;
        } ## end if ( $Line =~ /^\s*(\S+\s+.*)/o...)
    } ## end while ( my $Line = <VMS> ...)
    close(VMS);
} ## end sub GetTable($)

#--------------------------------------------------------------------
# Beautify a rule
#--------------------------------------------------------------------
sub BeautifyRule($)
{
    my ($Rule) = @_;

    my @Ruleparts = split( /\s+/, $Rule );
    # Blank out the counters
    $Ruleparts[0] = '';
    $Ruleparts[1] = '';

    # The target
    $Ruleparts[2] = "action:$Ruleparts[2]";
    # The protocol
    $Ruleparts[3] = "prot:$Ruleparts[3]";
    # The options
    $Ruleparts[4] =~ s/--/none/;
    $Ruleparts[4] = "opt:$Ruleparts[4]";
    # The "in" interface
    $Ruleparts[5] =~ s/^\*$/any/;
    $Ruleparts[5] = "in:$Ruleparts[5]";
    # The "out" interface
    $Ruleparts[6] =~ s/^\*$/any/;
    $Ruleparts[6] = "out:$Ruleparts[6]";
    # The source
    $Ruleparts[7] =~ s/^0.0.0.0\/0$/any/;
    $Ruleparts[7] = "from:$Ruleparts[7]";
    # The destination
    $Ruleparts[8] =~ s/^0.0.0.0\/0$/any/;
    $Ruleparts[8] = "to:$Ruleparts[8]";
    # The parameters
    my $newRule = join( ' ', @Ruleparts );
    $newRule =~ s/^\s+//;
    return ($newRule);
} ## end sub BeautifyRule($)

#--------------------------------------------------------------------
# Show rules in a subchain
#--------------------------------------------------------------------
sub ShowSubChainRules($$$$)
{
    my ( $Table, $Chain, $SubChain, $indent ) = @_;

    my $local_indent = $indent + 1;

    # Skip non-existent chains
    next unless ( exists $Ruleset{$SubChain} );

    # Show each rule inside a chain
    foreach my $Rule ( @{ $Ruleset{$SubChain} } )
    {
        # See http://ipset.netfilter.org/iptables-extensions.man.html
        if ( $Rule
            =~ /^\S+\s+\S+\s+\b(ACCEPT|DROP|RETURN|QUEUE|REDIRECT|AUDIT|CHECKSUM|CLUSTERIP|CONNMARK|CONNSECMARK|CT|DNAT|DSCP|ECN|HL|HMARK|IDLETIMER|LED|LOG|MARK|MASQUERADE|MIRROR|NETMAP|NFLOG|NFQUEUE|NOTRACK|RATEEST|REDIRECT|REJECT|SAME|SECMARK|SET|SNAT|TCPMSS|TCPOPTSTRIP|TEE|TOS|TPROXY|TRACE|TTL|ULOG)\b/o
            )
        {
            # Simple rule
            print ' ' x $local_indent;
            print "$Table::$Chain::$SubChain: ", BeautifyRule($Rule), "\n";
        } elsif ( $Rule =~ /^\S+\s+\S+\s+(\S+)/o )
        {
            # Goto another chain
            my $newSubChain = "$1";
            warn "DEBUG: SubChain = $SubChain\n" if ($opt_d);
            print "$Table::$Chain::$SubChain ", BeautifyRule($Rule), "\n";
            ShowSubChainRules( $Table, $Chain, $newSubChain, $local_indent );
        } else
        {
            # Unknown rule format
            warn "ERROR: Unknown rule format for '$Rule'\n";
        } ## end else [ if ( $Rule =~ ...)]
    } ## end foreach my $Rule ( @{ $Ruleset...})
} ## end sub ShowSubChainRules($$$$)

#--------------------------------------------------------------------
# Show rules in hierarchical order in a table
#--------------------------------------------------------------------
sub ShowRules($)
{
    my ($Table) = @_;
    my $indent = 0;

    foreach my $Chain ( 'PREROUTING', 'INPUT', 'FORWARD', 'OUTPUT',
        'POSTROUTING' )
    {
        # Skip non-existent chains
        next unless ( exists $Ruleset{$Chain} );

        # Show each rule inside a chain
        foreach my $Rule ( @{ $Ruleset{$Chain} } )
        {
            # See http://ipset.netfilter.org/iptables-extensions.man.html
            if ( $Rule
                =~ /^\S+\s+\S+\s+\b(ACCEPT|DROP|RETURN|QUEUE|REDIRECT|AUDIT|CHECKSUM|CLUSTERIP|CONNMARK|CONNSECMARK|CT|DNAT|DSCP|ECN|HL|HMARK|IDLETIMER|LED|LOG|MARK|MASQUERADE|MIRROR|NETMAP|NFLOG|NFQUEUE|NOTRACK|RATEEST|REDIRECT|REJECT|SAME|SECMARK|SET|SNAT|TCPMSS|TCPOPTSTRIP|TEE|TOS|TPROXY|TRACE|TTL|ULOG)\b/o
                )
            {
                # Simple rule
                print "$Table::$Chain: ", BeautifyRule($Rule), "\n";
            } elsif ( $Rule =~ /^\S+\s+\S+\s+(\S+)\s+(.*)/o )
            {
                # Goto another chain
                my $SubChain = "$1";
                warn "DEBUG: SubChain = $SubChain\n" if ($opt_d);
                print "$Table::$Chain: ", BeautifyRule($Rule), "\n";
                ShowSubChainRules( $Table, $Chain, $SubChain, $indent );
            } else
            {
                # Unknown rule format
                warn "ERROR: Unknown rule format for '$Rule'\n";
            } ## end else [ if ( $Rule =~ ...)]
        } ## end foreach my $Rule ( @{ $Ruleset...})
    } ## end foreach my $Chain ( 'PREROUTING'...)
    print "\n";
} ## end sub ShowRules($)

#--------------------------------------------------------------------
# Main function
#--------------------------------------------------------------------
$|++;
print "$ProgName\n$CopyRight\n\n";

# Get possible options
getopts('dh') or ShowUsage();
ShowUsage() if ($opt_h);

# Capture the current rules and show them (per table)
foreach my $Table ( 'nat', 'mangle', 'filter' )
{
    warn "DEBUG: Getting table '$Table'\n" if ($opt_d);
    GetTable($Table);

    # Show rules in hierarchical order
    ShowRules($Table);
} ## end foreach my $Table ( 'nat', ...)

# We are done
exit 0;
__END__
