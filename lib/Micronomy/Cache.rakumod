unit module Micronomy::Cache;

use JSON::Fast;
use Micronomy::Common;

my %locks;
my $locks-mutex = Lock.new;

# One Lock per employee number, so a caller can hold a lock across a whole
# get-cache -> mutate -> set-cache sequence for one employee, without
# blocking cache access for any other employee.
sub cache-lock(Str() $employeeNumber --> Lock) is export {
    $locks-mutex.protect: {
        %locks{$employeeNumber} //= Lock.new;
    }
}

sub cache-file($employeeNumber) {
    my $dir = $*PROGRAM-NAME;
    $dir ~~ s/<-[^/]>* $//;
    $dir ||= '.';
    "$dir/resources/$employeeNumber.json";
}

sub get-cache($employeeNumber) is export {
    my $cacheFile = cache-file($employeeNumber);
    my $cache = slurp $cacheFile if $cacheFile.IO.e;
    return from-json $cache if $cache;
}

sub set-cache(%cache) is export {
    my $employeeNumber = %cache<employeeNumber>;
    # only cache approved weeks
    my %output = (
        employeeName => %cache<employeeName>,
        employeeNumber => $employeeNumber,
        enabled => %cache<enabled>,
    );

    if %cache<enabled> or $employeeNumber eq "demo" {
        %output<jobs> = %cache<jobs>;

        for %cache<weeks>.keys -> $year {
            for %cache<weeks>{$year}.keys -> $month {
                for %cache<weeks>{$year}{$month}.keys -> $mday {
                    my %week = %cache<weeks>{$year}{$month}{$mday};
                    %output<weeks>{$year}{$month}{$mday} = %week if %week<state> == 2 or $employeeNumber eq "demo";
                }
            }
        }
    }

    spurt cache-file($employeeNumber), to-json(%output, :sorted-keys);
}
