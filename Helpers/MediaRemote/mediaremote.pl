# Loads CoolDock's MediaRemote helper library into this (Apple-signed) perl and runs its stream loop.
# Usage: /usr/bin/perl mediaremote.pl /path/to/libCoolDockMediaRemote.dylib
use strict;
use warnings;
use DynaLoader;

my $path = shift @ARGV or die "usage: mediaremote.pl <library>\n";
my $lib = DynaLoader::dl_load_file($path, 0) or die "cannot load $path: " . DynaLoader::dl_error() . "\n";
my $entry = DynaLoader::dl_find_symbol($lib, "cdmr_stream") or die "cdmr_stream not found\n";
DynaLoader::dl_install_xsub("main::stream", $entry);
stream();
