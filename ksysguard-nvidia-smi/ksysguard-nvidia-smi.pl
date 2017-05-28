#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use open qw( :encoding(UTF-8) :std );
use List::Util qw(reduce);

=pod

=encoding utf8

=head1 DESCRIPTION

A script that implements the KSysGuard protocol described at 
https://techbase.kde.org/Development/Tutorials/Sensors and interfaces with 
Nvidia's nvidia-smi tool
(https://developer.nvidia.com/nvidia-system-management-interface).

It should support an arbitrary number of GPUs and provides the following 
values:
fan speed (%), temperature (°C), performance level, power usage (W),
power_cap (W), memory usage (MiB), memory total (MiB), GPU utilization (%).

By default, this script will fetch new data at most every two seconds. It is 
possible, this needs to be increased, if many GPUs are installed.

=head1 USAGE

Save this script somewhere - let's assume /usr/local/bin.

In KSysGuard, go to File->Monitor Remote Machine. Enter nvidia-smi as host, then 
select "Custom command" as "Connection Type" and enter 
"perl /usr/local/bin/ksysguard-nvidia-smi.pl" (without the quotation marks) as
command. Replace /usr/local/bin with wherever you placed the script. 

Note that KSysGuard does not expand ~ to your home folder.

=head1 ISSUES

This script really doesn't care about error handling. I don't even know, If
the KSysGuard protocol supports error reporting.

If it does not work, start by running the command indicated by $NVIDIA_SMI 
below manually and check if this outputs at least one line like the following:

    |  0%   49C    P8    14W / 240W |    309MiB /  8110MiB |      0%      Default |

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

my $NVIDIA_SMI    = '/usr/bin/nvidia-smi';
my $CACHE_SECONDS = 2;

# final field name will be 'name' with GPU ID appended, i.e. fan_speed0, fan_speed1, ...
# 'max' is a coderef that will be called with a hashref of per-GPU data as argument
my @FIELD_SPEC = (
    {
        name => 'fan_speed',
        desc => 'Fan speed',
        unit => '%',
        re   => qr/.+?(\d+)%/x,
        max  => sub { 100 }
    },
    {
        name => 'temp',
        desc => 'GPU temperature',
        unit => '°C',
        re   => qr/\s+(\d+)C/x,
        max  => sub { 100 }
    },
    {
        name => 'perf_level',
        desc => 'Performance level',
        unit => '',
        re   => qr/\s+P(\d+)/x,
        max  => sub { 10 }
    },
    {
        name => 'pwr_usage',
        desc => 'Power usage',
        unit => 'W',
        re   => qr/\s+(\d+)W/x,
        max  => sub { $_[0]->{pwr_cap} }
    },
    {
        name => 'pwr_cap',
        desc => 'Power cap',
        unit => 'W',
        re   => qr/\s+\/\s+(\d+)W/x,
        max  => sub { $_[0]->{pwr_cap} }
    },
    {
        name => 'mem_usage',
        desc => 'Memory usage',
        unit => 'MiB',
        re   => qr/.+?(\d+)MiB/x,
        max  => sub { $_[0]->{mem_total} }
    },
    {
        name => 'mem_total',
        desc => 'Memory total',
        unit => 'MiB',
        re   => qr/.+?(\d+)MiB/x,
        max  => sub { $_[0]->{mem_total} }
    },
    {
        name => 'util',
        desc => 'Utilization',
        unit => '%',
        re   => qr/.+?(\d+)%/x,
        max  => sub { 100 }
    },
);

my %fields_by_name = map { ($_->{name}, $_) } @FIELD_SPEC;
my $re_fields = reduce { qr/$a $b/x } map { $_->{re} } @FIELD_SPEC;
my $re_input = qr/^(\w+?)(\d+)(\?)?$/x;

sub print_monitors {
    my ($data) = @_;

    my $gpu_id = 0;
    for my $gpu_data (@{$data}) {
        for my $field_name (sort keys %{$gpu_data}) {
            printf "%s%d\t%s\n", $field_name, $gpu_id, 'integer';
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
                $fields_by_name{$field_name}->{desc},
                get_max($field_name, $gpu_data),
                $fields_by_name{$field_name}->{unit},
            );
        } else {
            print "$gpu_data->{$field_name}\n";
        }
    }
    return;
}

sub get_max {
    my ($field_name, $gpu_data) = @_;

    return $fields_by_name{$field_name}->{max}->($gpu_data);
}

# only fetch data, if existing data is older than $CACHE_SECONDS seconds
{
    my $cached_data;
    my $last_checked = 0;

    sub collect_data {
        if ($last_checked < time() - $CACHE_SECONDS) {
            my @gpu_data;
            for my $line (split /\R/x, qx($NVIDIA_SMI)) {
                my %per_gpu_data;
                if (my @captures = $line =~ $re_fields) {
                    @per_gpu_data{ map { $_->{name} } @FIELD_SPEC } = @captures;
                    push @gpu_data, \%per_gpu_data;
                }
            }
            $cached_data  = \@gpu_data;
            $last_checked = time();
            return \@gpu_data;
        } else {
            return $cached_data;
        }
    }
}

local $| = 1;
print "ksysguardd 1.2.0\n";
print "ksysguardd> ";
while (my $input = <STDIN>) {
    chomp $input;
    if ($input eq 'monitors') {
        print_monitors(collect_data());
    } elsif (my ($field_name, $gpu_id, $do_meta) = $input =~ $re_input) {
        print_field_on_gpu(collect_data(), $field_name, $gpu_id, $do_meta);
    }
    print "ksysguardd> ";
}
