unit module Micronomy::Cache;

use JSON::Fast;
use Micronomy::Common;

sub get-cache($employeeNumber) is export {

    my $dir = $*PROGRAM-NAME;
    $dir ~~ s/<-[^/]>* $//;
    $dir ||= '.';
    my $cacheFile = "$dir/resources/$employeeNumber.json";
    return from-json slurp $cacheFile if $cacheFile.IO.e;
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

    my $dir = $*PROGRAM-NAME;
    $dir ~~ s/<-[^/]>* $//;
    $dir ||= '.';
    my $cacheFile = "$dir/resources/$employeeNumber.json";
    spurt $cacheFile, to-json(%output, :sorted-keys);
}
