#! /usr/bin/perl

# Copyright (c) 2019-2020, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2013-2015 Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

use strict;
use warnings;

use Getopt::Long;
use JSON qw( decode_json encode_json );

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Dataplane;
use Vyatta::Misc qw(getInterfaces);

my ( $dp_ids, $dp_conns, $local_controller );

sub show_arp {
    my ( $intf, $addr ) = @_;

    printf( "%-20s %-10s %-17s %s\n",
        "IP Address", "Flags", "HW address", "Device" )
      unless defined($intf) && defined($addr);

    for my $dp_id ( @{$dp_ids} ) {
        my $sock = ${$dp_conns}[$dp_id];

        next unless $sock;

        my $response = $sock->execute( "arp show " . ( $intf // '' ) );
        next unless defined($response);
        my $decoded = decode_json($response);
        my @entries = @{ $decoded->{arp} };
        foreach my $entry (@entries) {
            next if defined($addr) && $addr ne $entry->{ip};

            my $mac = sprintf "%02s:%02s:%02s:%02s:%02s:%02s",
              split /\:/, $entry->{mac};
            if ( !defined($intf) || !defined($addr) ) {
                printf "%-20s %-10s %-17s %s\n", $entry->{ip},
                  $entry->{flags}, $mac, $entry->{ifname};
            } else {
                printf "%s %s\n", $entry->{ip}, $entry->{ifname};
                printf "    Flags: %s\n",      $entry->{flags};
                printf "    HW Address: %s\n", $mac;
                if ( defined( $entry->{platform_state} ) ) {
                    printf "    Platform state:\n";
                    print $sock->format_platform_state( 'ip-neigh',
                        encode_json($entry) );
                }
            }
        }
    }
}

sub show_arp_all {
    my ( $intf, $addr ) = @_;
    my %kernel_arp   = ();
    my $format       = "%-18s %-17s %-10s %-10s %s\n";
    my $zero_mac     = "00:00:00:00:00:00";
    my %kernel_flags = (
        'REACHABLE' => 'VALID',
        'STALE'     => 'VALID',
        'DELAY'     => 'VALID',
        'PROBE'     => 'VALID',
        'PERMANENT' => 'STATIC',
        'NOARP'     => 'STATIC'
    );
    my $kernel_flags_re = join( '|', keys %kernel_flags );

    open( my $arp_output, '-|', "ip -4 neigh " ) or die "show arp failed ";
    while (<$arp_output>) {
        chomp;
        /([^ ]+) dev ([^ ]+) lladdr ([^ ]+) ($kernel_flags_re)/
          and $kernel_arp{$1} = [ $2, $3, $kernel_flags{$4}, 1 ], next;
        /([^ ]+) dev ([^ ]+)  FAILED/
          and $kernel_arp{$1} = [ $2, $zero_mac, "FAILED", 1 ], next;
        /([^ ]+) dev ([^ ]+)  INCOMPLETE/
          and $kernel_arp{$1} = [ $2, $zero_mac, "PENDING", 1 ], next;
    }
    close($arp_output);

    printf( $format,
        "IP Address", "HW address", "Dataplane", "Controller", "Device" );

    foreach my $dp_id ( @{$dp_ids} ) {
        my $sock = ${$dp_conns}[$dp_id];
        if ($sock) {
            my $response = $sock->execute( "arp show " . ( $intf // '' ) );
            next unless defined($response);

            my $decoded = decode_json($response);
            my @entries = @{ $decoded->{arp} };
            foreach my $entry (@entries) {
                next if defined($addr) && $addr ne $entry->{ip};

                my $mac = sprintf "%02s:%02s:%02s:%02s:%02s:%02s",
                  split /\:/, $entry->{mac};
                my $kentry = $kernel_arp{ $entry->{ip} };
                if ( $kentry
                    && ( $kentry->[1] eq $mac || $kentry->[1] eq $zero_mac ) )
                {
                    printf $format, $entry->{ip}, $mac, $entry->{flags},
                      $kentry->[2], $entry->{ifname};
                    $kentry->[3] = 0;
                } else {
                    printf $format, $entry->{ip},
                      $mac, $entry->{flags}, "", $entry->{ifname};
                }
            }
        }
    }

    for my $ip ( keys %kernel_arp ) {
        next if ( defined($intf) && $kernel_arp{$ip}[0] ne $intf );
        next unless $kernel_arp{$ip}[3];

        printf $format, $ip, $kernel_arp{$ip}[1], "", $kernel_arp{$ip}[2],
          $kernel_arp{$ip}[0];
    }
}

sub usage {
    print "Usage: $0 [--fabric=N] <CMD>
$0 [--show-all] <CMD>
$0 [--show-intf=s] [--addr=s] <CMD>\n";
    exit 1;
}

my $fabric;
my $intf;
my $addr;
my %show_func = (
    'arp'     => \&show_arp,
    'arp-all' => \&show_arp_all,
);

GetOptions(
    'fabric=s'    => \$fabric,
    'show-intf=s' => \$intf,
    'addr=s'      => \$addr,
) or usage();

if ( defined($intf) ) {
    die "interface $intf does not exist on system\n"
      unless grep { $intf eq $_ } getInterfaces();
}

my $decoded;
( $dp_ids, $dp_conns, $local_controller ) =
  Vyatta::Dataplane::setup_fabric_conns($fabric);

foreach my $arg (@ARGV) {
    my $func = $show_func{$arg};

    &$func( $intf, $addr );
}
Vyatta::Dataplane::close_fabric_conns( $dp_ids, $dp_conns );
