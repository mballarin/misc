#!/usr/bin/perl
use 5.014;
use warnings;
use utf8;
use open qw( :encoding(UTF-8) :std );
use IPC::Open2;
use Data::Dumper;

=pod

=encoding utf8

=head1 DESCRIPTION

A script that implements the KSysGuard protocol described at 
L<https://github.com/KDE/ksysguard/blob/master/ksysguardd/Porting-HOWTO>
and interfaces with Nvidia's nvidia-smi tool
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

Errors are reported via the KSysGuard protocol, but I do not how they can be seen.

If this does not work, try running the script manually in a shell.
You should get the following prompt:
    ksysguardd 1.2.0
    ksysguardd>

Possible error: Perl v5.14.0 required => speaks for itself.

At the prompt, enter "monitors" and you should get the following:
    ksysguardd> monitors

    gpu0/clocks/current/graphics    integer
    gpu0/clocks/current/memory      integer
    ...

Possible error: open2: exec of /usr/bin/nvidia-smi ...failed: No such file or directory at
./ksysguard-nvidia-smi.pl line ...
Check if nvidia-smi is installed at the location pointed to by
$NVIDIA_SMI below.

Possible error: Field "..." is not a valid field to query. nvidia-smi failed with exit code 2
nvidia-smi does not know one or more of the requested field names. You can try removing the offending
field from %FIELD_SPEC below.
This was tested with nvidia-smi vesion 375.39.

=head1 LICENSE AND COPYRIGHT

Copyright 2017 Marc Ballarin

Permission is hereby granted, free of charge, to any person obtaining a copy 
of this software and associated documentation files (the "Software"}, to deal
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
my $ERROR_MARK = "\027";

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
# - If generator points to a code ref, this field will not be passed to nvidia-smi.
# Instead, the code ref will be called with the data of all non-generated fields as
# argument. The code ref must return a tuple (<output for metadata>, <output for query>)
my %FIELD_SPEC = (
    'clocks.current.graphics' => {
        max => sub { $_[0]->{'clocks.max.graphics'} }
    },
    'clocks.current.memory' => {
        max => sub {
            $_[0]->{'clocks.max.memory'};
          }
    },
    'clocks.current.sm' => {
        max => sub {
            $_[0]->{'clocks.max.sm'};
          }
    },
    'clocks.current.video' => {
        # a guess
        max => sub {
            $_[0]->{'clocks.max.graphics'};
          }
    },
    'clocks.max.graphics' => {},
    'clocks.max.memory'   => {},
    'clocks.max.sm'       => {},
    'fan.speed'           => {},
    'memory.used'         => {
        max => sub { $_[0]->{'memory.total'} }
    },
    'memory.total'          => {},
    'pcie.link.gen.current' => {
        max => sub {
            $_[0]->{'pcie.link.gen.max'};
          }
    },
    'pcie.link.gen.max'       => {},
    'pcie.link.width.current' => {
        max => sub {
            $_[0]->{'pcie.link.width.max'};
          }
    },
    'pcie.link.width.max' => {},
    'power.draw'          => {
        max => sub {
            $_[0]->{'power.limit'};
        },
        type => 'float'
    },
    'power.limit'     => {},
    'temperature.gpu' => { unit => '°C' },
    'utilization.gpu' => {},
    'throttling'      => { generator => \&get_throttle_reasons, type => 'listview' },
    'clocks_throttle_reasons.applications_clocks_setting' => { max => 1, transform => \&map_bool },
    'clocks_throttle_reasons.gpu_idle'     => { max => 1, transform => \&map_bool },
    'clocks_throttle_reasons.hw_slowdown'  => { max => 1, transform => \&map_bool },
    'clocks_throttle_reasons.sw_power_cap' => { max => 1, transform => \&map_bool },
    'clocks_throttle_reasons.sync_boost'   => { max => 1, transform => \&map_bool },
    'clocks_throttle_reasons.unknown'      => { max => 1, transform => \&map_bool },
    'pstate'                               => {
        max       => 12,
        transform => sub {
            return $_[0] =~ s/P(\d+)/$1/rx;
        },
    },
);

sub get_throttle_reasons {
    my ($gpu_data) = @_;
    my %names = (
        'clocks_throttle_reasons.applications_clocks_setting' => 'application',
        'clocks_throttle_reasons.gpu_idle'                    => 'idle',
        'clocks_throttle_reasons.hw_slowdown'                 => 'hardware',
        'clocks_throttle_reasons.sw_power_cap'                => 'power cap',
        'clocks_throttle_reasons.sync_boost'                  => 'sli',
        'clocks_throttle_reasons.unknown'                     => 'other',
    );
    my $reasons = join "\n", sort map { $names{$_} } grep { $gpu_data->{$_} } keys %names;
    return ("Throttling Reasons\ns", $reasons || 'none');
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

sub collect_data_real {
    my ($in, $out);
    my $pid = open2($out, $in, $NVIDIA_SMI, '--format=csv',
        '--query-gpu=' . join(',', grep { !$FIELD_SPEC{$_}->{generator} } keys %FIELD_SPEC));
    waitpid($pid, 0);
    if (my $exit_code = $? >> 8) {
        say STDERR do { local $/ = undef; <$out> };
        die "nvidia-smi failed with exit code $exit_code\n";
    }

    my (@gpus, @headers);
    while (my $line = <$out>) {
        chomp $line;
        my @columns = split /,/x, $line;
        if (scalar @headers) {
            my %fields;
            @fields{@headers} = @columns;
            push @gpus, parse_fields(%fields);
        } else {
            @headers = parse_headers(@columns);
        }
    }
    return \@gpus;
}

sub parse_fields {
    my (%fields) = @_;
    while (my ($field_name, $args) = each %FIELD_SPEC) {
        $fields{$field_name} = Field->new(
            %{$args},
            name     => $field_name,
            value    => $fields{$field_name},
            gpu_data => \%fields,
        );
    }
    return \%fields;
}

sub parse_headers {
    my (@columns) = @_;

    # header name, followed by optional unit in []
    my $re_header = qr/^(.+?) (?: \[ .+ \] )?$/x;
    my @headers;
    for my $field (@columns) {
        if ($field =~ $re_header) {
            push @headers, $1 =~ s/^\s+|\s+$//xarg;
        } else {
            die "unparsable header: '$field'\n";
        }
    }
    return @headers;
}

sub collect_data {
    state $data;
    state $last_checked = 0;
    if ($last_checked < time() - $CACHE_SECONDS) {
        $last_checked = time();
        $data         = collect_data_real();
    }
    return $data;
}

sub print_monitors {
    my ($data) = @_;
    my $gpu_id = 0;
    my $tpl    = "gpu%d/%s\t%s\n";
    for my $gpu_data (@{$data}) {
        for my $field_name (sort keys %{$gpu_data}) {
            my $path_field = $field_name =~ s(\.)(/)xgr;
            printf($tpl, $gpu_id, $path_field, $gpu_data->{$field_name}->{type});
        }
        $gpu_id++;
    }
    return;
}

sub print_field_on_gpu {
    my ($data, $input) = @_;
    my @components = split /\//x, $input;
    if (scalar @components >= 2 && (shift @components) =~ /^gpu(\d+)$/xa) {
        my $gpu_id     = $1;
        my $do_meta    = $components[-1] =~ s/\?$//x;
        my $field_name = join '.', @components;
        if (my $gpu_data = $data->[$gpu_id]) {
            my $field = $gpu_data->{$field_name};
            if ($do_meta) {
                print $field->get_meta;
                return;
            } else {
                if (my $result = $gpu_data->{$field_name}) {
                    print $result;
                    return;
                } else {
                    die "Unknown field '$field_name'\n";
                }
            }
        } else {
            die "Unknown gpu id: $gpu_id\n";
        }
    } else {
        die "Invalid input '$input'\n";
    }
}
local $| = 1;
print 'ksysguardd 1.2.0';
print "\nksysguardd> ";
while (my $input = <STDIN>) {
    chomp $input;
    if ($input eq 'monitors') {
        print_monitors(collect_data());
    } elsif ($input eq 'quit') {
        exit;
    } else {
        eval {
            print_field_on_gpu(collect_data(), $input);
            1;
        } or do {
            print "${ERROR_MARK}error:${@}${ERROR_MARK}";
        };
    }
    print "\nksysguardd> ";
}

package Field {
    use List::Util qw(max);
    use Scalar::Util qw(weaken);
    use overload '""' => sub { shift->get_value };

    sub new {
        my ($class, %args) = @_;
        my $self = bless {%args}, $class;
        $self->{type} = $args{type} // 'integer';
        weaken($self->{gpu_data});
        $self->{needs_generation} = $self->_set_value_and_unit(%args);
        return $self;
    }

    sub _run_generation {
        my ($self) = @_;
        ($self->{meta}, $self->{value}) = $self->{generator}->($self->{gpu_data});
        $self->{needs_generation} = 0;
        return;
    }

    sub _set_value_and_unit {
        my ($self, %args) = @_;
        if ($args{generator}) {
            return 1;
        } else {
            my ($value, $unit);
            $value = $args{value} =~ s/^\s+|\s+$//xarg;
            if ($args{transform}) {
                $value = $args{transform}->($value);
            }
            ($self->{value}, $unit) = $value =~ /^(.+?) (?:\s+ (\S+) )?$/xag;
            $self->{unit} = $args{unit} // $unit // '';
            return 0;
        }
    }

    sub get_unit {
        my ($self) = @_;
        return $self->{unit};
    }

    sub get_meta {
        my ($self) = @_;
        if ($self->{needs_generation}) {
            $self->_run_generation();
        }
        return $self->{meta} // sprintf("%s\t0\t%d\t%s", $self->{name}, $self->get_max, $self->get_unit,);
    }

    sub get_max {
        my ($self) = @_;
        if (my $max = $self->{max}) {
            if (ref $max eq 'CODE') {
                my $result = $max->($self->{gpu_data});
                return $result;
            } else {
                return $max;
            }
        } else {
            return max($self->{value}, 100);
        }
    }

    sub get_value {
        my ($self) = @_;
        if ($self->{needs_generation}) {
            $self->_run_generation();
        }
        return $self->{value};
    }
}
