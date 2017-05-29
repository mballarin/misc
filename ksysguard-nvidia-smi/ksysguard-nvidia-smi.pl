#!/usr/bin/perl

use 5.010;
use strict;
use warnings;
use utf8;
use open qw( :encoding(UTF-8) :std );
use List::Util qw(max);
use IPC::Open2;

=pod

=encoding utf8

=head1 DESCRIPTION

A script that implements the KSysGuard protocol described at 
L<https://techbase.kde.org/Development/Tutorials/Sensors> and interfaces with 
Nvidia's nvidia-smi tool
L<https://developer.nvidia.com/nvidia-system-management-interface>.

It should support an arbitrary number of GPUs.

By default, this script will fetch new data at most every two seconds. It is 
possible, this needs to be increased, if many GPUs are installed.

=head1 USAGE

Save this script somewhere - let's assume /usr/local/bin.

In KSysGuard, go to File->Monitor Remote Machine. Enter nvidia-smi (or something 
else, but not localhost) as host, then  select "Custom command" as 
"Connection Type" and enter "perl /usr/local/bin/ksysguard-nvidia-smi.pl" 
(without the quotation marks) as command. Replace /usr/local/bin with wherever
you placed the script. 

Note that KSysGuard will not expand ~ to your home folder!

=head1 BUGS AND LIMITATIONS

I do not know how (or if) errors can be reported via the KSysGuard protocol.

If this does not work, try running the script manually in a shell.
You should get the following prompt:
    ksysguardd 1.2.0
    ksysguardd>

Possible error: Syntax error. I tried to avoid features from "newer" Perl versions,
but something might have slipped in. Try "perl -v" and check if your version is
smaller than 5.14. If it is at leat 5.10 report a bug. Older versions are not
supported.

At the prompt, enter "monitors" and you should get the following:
    ksysguardd> monitors
    clocks.current.graphics0        integer
    clocks.current.memory0  integer
    clocks.current.sm0      integer
    ...

Possible error: ...failed: No such file or directory at 
./ksysguard-nvidia-smi.pl line ...
Check if nvidia-smi is really available at the location pounted to by 
$NVIDIA_SMI below.

=head1 LICENSE

Copyright 2017 Marc Ballarin

Permission is hereby granted, free of charge, to any person obtaining a copy 
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation  the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell 
copies of the Software, and to permit persons to whom the Software is furnished
to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL 
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut

my $CACHE_SECONDS = 2;
my $NVIDIA_SMI    = '/usr/bin/nvidia-smi';
# as per KSysGuard's spec
my $RE_INPUT      = qr/^ ([\w.]+?) (\d+) (\?)? $/x;

# the fields to be queried. At minimum, only the field name is added as key,
# with an empty hash ref as value.
# - If this hash ref contains no key, the unit will be determined
# automatically, only default transformations will be applied and the maximum
# will be set to the maximum of 100 or the current value.
# - If transform points to a code ref, this code ref will be called with the
# original value as parameter and its return value used as new value.
# - If max points to a code ref, this code ref will be called with the
# complete per-GPU data (Hashref) as argument, and the fields maximum will be
# set to its return value.
# - If max is a scalar, the fields maximum will be set to this value.
# - If unit is a scalar, the auto-detected unit will be overriden by this value
# - If type is a scalar, this value will be used instead of integer.
my %QUERIED_FIELDS = (
    'clocks.current.graphics' => {
        max => sub { $_[0]->{'clocks.max.graphics'} }
    },
    'clocks.current.memory' => {
        max => sub { $_[0]->{'clocks.max.memory'} }
    },
    'clocks.current.sm' => {
        max => sub { $_[0]->{'clocks.max.sm'} }
    },
    'clocks.current.video' => {},
    'clocks.max.graphics'  => {},
    'clocks.max.memory'    => {},
    'clocks.max.sm'        => {},
    'clocks_throttle_reasons.applications_clocks_setting' =>
      { max => 1, transform => \&map_bool },
    'clocks_throttle_reasons.gpu_idle' =>
      { max => 1, transform => \&map_bool },
    'clocks_throttle_reasons.hw_slowdown' =>
      { max => 1, transform => \&map_bool },
    'clocks_throttle_reasons.sw_power_cap' =>
      { max => 1, transform => \&map_bool },
    'clocks_throttle_reasons.sync_boost' =>
      { max => 1, transform => \&map_bool },
    'clocks_throttle_reasons.unknown' =>
      { max => 1, transform => \&map_bool },
    'fan.speed'                       => {},
    'memory.used'                     => {
        max => sub { $_[0]->{'memory.total'} }
    },
    'memory.total'          => {},
    'pcie.link.gen.current' => {
        max => sub { $_[0]->{'pcie.link.gen.max'} }
    },
    'pcie.link.gen.max'       => {},
    'pcie.link.width.current' => {
        max => sub { $_[0]->{'pcie.link.width.max'} }
    },
    'pcie.link.width.max' => {},
    'power.draw'          => {
        max  => sub { $_[0]->{'power.limit'} },
        type => 'float',
    },
    'power.limit' => {},
    'pstate'      => {
        max       => 12,
        transform => sub {
            my $s = shift;
            $s =~ s/P(\d+)/$1/x;
            return $s;
          }
    },
    'temperature.gpu' => { unit => '°C' },
    'utilization.gpu' => {},
);

# auto-detected units are stored here
my %UNITS;

sub trim {
    my $string = shift;

    return unless defined $string;
    $string =~ s/^\s+|\s+$//xg;
    return $string;
}

# maps boolean values returned by nvidia-smi to something 
# that is true or false in Perl
sub map_bool {
    my ($string) = @_;

    if ($string eq 'Active') {
        return 1;
    } elsif ($string eq 'Not Active') {
        return 0;
    } else {
        die "Unexpected boolean input: '$string'\n";
    }
}

sub remove_unit {
    my ($string) = @_;

    $string =~ s/(.+?)(?:\s+\S+)?/$1/xg;
    return $string;
}

sub transform_value {
    my ($value, $header) = @_;

    $value = trim($value);
    if (my $transform = $QUERIED_FIELDS{$header}->{transform}) {
        $value = $transform->($value);
    }
    $value = remove_unit($value);
    return $value;
}

sub collect_data_real {
    my ($in, $out);
    my $pid = open2($out, $in, $NVIDIA_SMI, '--format=csv',
        '--query-gpu=' . join(',', keys %QUERIED_FIELDS));
    waitpid($pid, 0);

    # the following would be much saner and readable with CPAN modules.
    # But I want to avoid non-core dependencies.
    my (@gpus, $headers);
    while (<$out>) {
        chomp;
        my $columns = [ split /,/x, $_ ];
        if (defined $headers) {
            push @gpus, parse_data($columns, $headers);
        } else {
            $headers = parse_headers($columns);
        }
    }
    return \@gpus;
}

sub parse_data {
    my ($columns, $headers) = @_;
    
    my %gpu_data;
    my $pos = 0;
    for my $h (@{$headers}) {
        $gpu_data{$h} = transform_value($columns->[$pos++], $h);
    }
    return \%gpu_data;
}

sub parse_headers {
    my ($columns) = @_;

    # header name, followed by optional unit in []
    my $re_header = qr/^(.+?) (?: \[ (.+) \] )?$/x;
    my @headers;
    for my $field (@{$columns}) {
        if ($field =~ $re_header) {
            my $header = trim($1);
            $UNITS{$header} = $QUERIED_FIELDS{$header}->{unit} // trim($2);
            push @headers, $header;
        } else {
            die "unparsable header: '$field'\n";
        }
    }
    return \@headers;
}

{
    my $data;
    my $last_checked = 0;

    sub collect_data {
        if ($last_checked < time() - $CACHE_SECONDS) {
            $last_checked = time();
            $data         = collect_data_real();
        }
        return $data;
    }
}

sub print_monitors {
    my ($data) = @_;

    my $gpu_id = 0;
    for my $gpu_data (@{$data}) {
        for my $field_name (sort keys %{$gpu_data}) {
            printf(
                "%s%d\t%s\n", $field_name, $gpu_id, 
                $QUERIED_FIELDS{$field_name}->{type} // 'integer',
            );
        }
        $gpu_id++;
    }
    return;
}

sub print_field_on_gpu {
    my ($data, $field_name, $gpu_id, $do_meta) = @_;

    if (my $gpu_data = $data->[$gpu_id]) {
        if ($do_meta) {
            printf("%s\t0\t%d\t%s\n",
                $field_name,
                get_max($field_name, $gpu_data),
                $UNITS{$field_name} // '',
            );
        } else {
            print "$gpu_data->{$field_name}\n";
        }
    }
    return;
}

sub get_max {
    my ($field_name, $gpu_data) = @_;

    if (my $explicit = $QUERIED_FIELDS{$field_name}->{max}) {
        if (ref $explicit eq 'CODE') {
            return $explicit->($gpu_data);
        } else {
            return $explicit;
        }
    } else {
        return max($gpu_data->{$field_name}, 100);
    }
}

local $| = 1;
print "ksysguardd 1.2.0\n";
print "ksysguardd> ";
while (my $input = <STDIN>) {
    chomp $input;
    if ($input eq 'monitors') {
        print_monitors(collect_data());
    } elsif (my ($field_name, $gpu_id, $do_meta) = $input =~ $RE_INPUT) {
        print_field_on_gpu(collect_data(), $field_name, $gpu_id, $do_meta);
    } else {
        die "Invalid input: '$input'\n";
    }
    print "ksysguardd> ";
}
