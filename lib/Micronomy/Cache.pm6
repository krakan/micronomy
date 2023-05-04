unit module Micronomy::Cache;

use JSON::Fast;
use Micronomy::Common;

sub get-cache($employeeNumber) is export {
    my $dir = $*PROGRAM-NAME;
    $dir ~~ s/<-[^/]>* $//;
    $dir ||= '.';
    my $cacheFile = "$dir/resources/$employeeNumber.json";
    if $cacheFile.IO.e {
        given $cacheFile.IO.open {
            .lock: :shared;
            my $cache = .slurp;
            .close;
            return from-json $cache if $cache;
        }
    }
}

sub cached-week(Date $date, %cache) is export {
    trace "sub cached-week $date";

    my ($week-name, $periodStart, $year, $month, $mday) = get-current-week($date);
    if (
        not %cache<weeks> or
        $year lt %cache<weeks>.keys.all or
        (%cache<weeks>{$year} and $month lt %cache<weeks>{$year}.keys.all) or
        (%cache<weeks>{$year}{$month} and $mday lt %cache<weeks>{$year}{$month}.keys.all)
    ) {
        return (
            name => $week-name,
            state => -1,
            rows => {},
        );
    }

    my $week = %cache<weeks>{$year}{$month}{$mday};
    return $week if $week;

    my %week = cached-week($periodStart.earlier(days => 1), %cache);

    if %week {
        %week = from-json to-json %week;
        %week<name> = $week-name;
        if %cache<employeeNumber> ne "demo" {
            %week<state> = -1;
            %week<synched>:delete;
            %week<totals>:delete;
            for @(%week<rows>) -> %row {
                %row<hours>:delete;
            }
        }
    }
    return %week;
}

sub set-cache(%cache) is export {
    my $employeeNumber = %cache<employeeNumber>;
    my %output = (
        employeeName => %cache<employeeName>,
        employeeNumber => $employeeNumber,
    );

    %output<jobs> = %cache<jobs>;

    for %cache<weeks>.keys -> $year {
        for %cache<weeks>{$year}.keys -> $month {
            for %cache<weeks>{$year}{$month}.keys -> $mday {
                my %week = %cache<weeks>{$year}{$month}{$mday};
                %output<weeks>{$year}{$month}{$mday} = %week;
            }
        }
    }

    my $dir = $*PROGRAM-NAME;
    $dir ~~ s/<-[^/]>* $//;
    $dir ||= '.';
    my $cacheFile = "$dir/resources/$employeeNumber.json";
    given $cacheFile.IO.open: :w {
        .lock;
        .spurt(to-json(%output, :sorted-keys));
        .close;
    }
}

sub cache-session($token, $employeeNumber, $employeeName) is export {
    my $basedir = IO::Path.new($*PROGRAM-NAME).dirname || '.';
    my $sessionsFile = "$basedir/resources/sessions.json";

    given $sessionsFile.IO.open(:rw) {
        .lock;
        my $data = .slurp;
        my %sessions = from-json $data if $data;
        for %sessions.keys -> $tk {
            %sessions{$tk}:delete if %sessions{$tk}<number> eq $employeeNumber;
        }
        %sessions{$token} =
            {
                name => $employeeName,
                number => $employeeNumber,
            };
        # rewrite file while holding lock
        spurt $sessionsFile, to-json(%sessions);
        .close;
    }
}

sub uncache-session($token) is export {
    my $basedir = IO::Path.new($*PROGRAM-NAME).dirname || '.';
    my $sessionsFile = "$basedir/resources/sessions.json";
    given $sessionsFile.IO.open(:rw) {
        .lock;
        my $data = .slurp;
        my %sessions = from-json $data if $data;
        %sessions{$token}:delete;
        # rewrite file while holding lock
        spurt $sessionsFile, to-json(%sessions);
        .close;
    }
}

sub get-session($token) is export {
    my $basedir = IO::Path.new($*PROGRAM-NAME).dirname || '.';
    my $sessionsFile = "$basedir/resources/sessions.json";

    given $sessionsFile.IO.open {
        .lock: :shared;
        my $data = .slurp;
        my %sessions = from-json $data if $data;
        .close;
        return %sessions{$token};
    }
}
