unit module Micronomy::Sync;

use JSON::Fast;
use Micronomy::Cache;
use Micronomy::Common;
use Micronomy::Demo;

my (%lock, %syncing);

sub sync($employee, $token, %parameters) is export {
    trace "sub sync %parameters<week>", $token;
    if %parameters<data> {
        %syncing{%parameters<week>} = %parameters<data>;
    } else {
        %syncing{%parameters<week>}++;
    }
    unless %lock{$token} {
        %lock{$token} = True;
        start {
            sync-loop($token);
        }
    }
}

sub sync-loop($token) {
    trace "sub sync-loop", $token;
    my %concurrency;
    while True {
        sleep 1 unless %syncing;
        for %syncing.keys.sort -> $week {
            # sync item
            if %syncing{$week}.^name eq "Int" {
                trace "sub sync get $week", $token;
                %concurrency = get-week($token, $week, :%concurrency);
            } elsif %syncing{$week}.^name eq "Hash" {
                trace "sub sync put $week", $token;
                my %data = %syncing<queue>{$week};
                sleep 3; # FIXME
            }
            %syncing{$week}:delete;
        }
    }
}

my $server = "https://b3iaccess.deltekenterprise.com";
my $auth-path = "maconomy-api/auth/b3";
my $instances-path = "maconomy-api/containers/b3/timeregistration/instances";
my $environment-path = "/maconomy-api/environment/b3?variables";
my $favorites-path = "maconomy-api/containers/b3/jobfavorites/instances";
my $tasks-path = "maconomy-api/containers/b3/timeregistration/search/table;foreignkey=taskname_tasklistline?fields=taskname,description&limit=100";

sub get-week($token, $date, :%concurrency) is export {
    trace "sub get-week $date", $token;

    return get-demo($date) if $token eq "demo";

    my $containerInstanceId = %concurrency<containerInstanceId>;
    my $concurrency = %concurrency<concurrency>;

    unless $containerInstanceId and $concurrency {
        ($containerInstanceId, $concurrency) = get-concurrency($token, $date);
    }

    my $url = "$server/$instances-path/$containerInstanceId/data/panes/card/0";
    trace "sub get-week request", $token;
    my $response = call-url(
        $url,
        headers => {
            Authorization => "X-Reconnect $token",
            Content-Type => "application/json",
            Maconomy-Concurrency-Control => "$concurrency",
        },
        body => '{"data": {"datevar": "' ~ $date ~ '"}}',
    );
    return {} unless $response;
    return parse-week($response);

    CATCH {
        when X::Cro::HTTP::Error {
            error $_, $token;
            return get-week($token, $date) if .response.status == (404, 409, 422).any;
            die $_;
        }
        default {
            error $_, $token;
            die $_;
        }
    }
}

sub get-concurrency($token, $date) is export {
    trace "get concurrency", $token;
    return '"card"="demo", "table"="demo"' if $token eq "demo";

    # get card id
    my $url = "$server/$instances-path";
    my $response = call-url(
        $url,
        headers => {
            Authorization => "X-Reconnect $token",
            Content-Type => "application/json",
        },
        body => '{"panes":{}}',
    );

    my %content = await $response.body;
    my $containerInstanceId = %content<meta><containerInstanceId>;
    my $concurrency = get-header($response, 'maconomy-concurrency-control');
    my $employeeNumber = 0;

    trace "get concurrency employeeNumber", $token;
    # refresh concurrency (sic!)
    $response = call-url(
        "$url/$containerInstanceId/data;any",
        headers => {
            Authorization => "X-Reconnect $token",
            Maconomy-Concurrency-Control => $concurrency,
            Content-Type => "application/json",
            Content-Length => 0,
        },
    );
    $concurrency = get-header($response, 'maconomy-concurrency-control');
    %content = await $response.body;
    $employeeNumber = %content<panes><card><records>[0]<data><employeenumber>;

    trace "get concurrency concurrency", $token;
    $response = call-url(
        "$url/$containerInstanceId/data/panes/card/0",
        headers => {
            Authorization => "X-Reconnect $token",
            Maconomy-Concurrency-Control => $concurrency,
            Content-Type => "application/json",
        },
        body => '{"data":{"datevar":"' ~ $date ~ '","employeenumbervar":"' ~ $employeeNumber ~ '"}}',
    );
    $concurrency = get-header($response, 'maconomy-concurrency-control');
    %content = await $response.body;

    return $containerInstanceId, $concurrency;

    CATCH {
        when X::Cro::HTTP::Error {
            if .response.status == 409 {
                return get-concurrency($token, $date);
            } else {
                die $_;
            }
        }
    }
}

sub parse-week($response) is export {
    trace "parse-week";
    my %content = await $response.body;

    my %card = %content<panes><card><records>[0]<data>;
    my @records = @(%content<panes><table><records>);
    my $rowCount = %content<panes><table><meta><rowCount>;

    my $weekstatus = 0;
    $weekstatus = 1 if @records[0]<data><submitted>;
    $weekstatus = 2 if %card<approvedvar>;

    my %cache = get-cache(%card<employeenumber>);

    %cache<employeeName> = %card<employeenamevar>;
    %cache<employeeNumber> = %card<employeenumber>;
    %cache<concurrency> = get-header($response, 'maconomy-concurrency-control');
    %cache<containerInstanceId> = %content<meta><containerInstanceId>;

    my %weekData = (
        name => %card<weeknumbervar> ~ %card<partvar>,
        state => $weekstatus,
        synched => DateTime.now,
        totals => {
            reported => %card<totalnumberofweekvar>,
            fixed => %card<fixednumberweekvar>,
            overtime => %card<overtimenumberweekvar>,
            invoiceable => %card<invoiceabletimedayweekvar>,
        },
    );

    for 1..7 -> $wday {
        my %day;
        %day<reported> = %card{"totalnumberday{$wday}var"} if %card{"totalnumberday{$wday}var"};
        %day<fixed> = %card{"fixednumberday{$wday}var"} if %card{"fixednumberday{$wday}var"};
        %day<overtime> = %card{"overtimenumberday{$wday}var"} if %card{"overtimenumberday{$wday}var"};
        %day<invoiceable> = %card{"invoiceabletimeday{$wday}var"} if %card{"invoiceabletimeday{$wday}var"};
        %weekData<totals><days>{$wday} = %day if %day.keys;
    }

    for ^$rowCount -> $row {
        my %rowData = @records[$row]<data>;
        my $jobName = %rowData<jobnamevar>;
        my $jobNumber = %rowData<jobnumber>;
        my $taskNumber = %rowData<taskname>;
        my $taskName = %rowData<entrytext>;

        %cache<jobs>{$jobNumber}<name> = $jobName;
        %cache<jobs>{$jobNumber}<tasks>{$taskNumber} = $taskName;

        my $total = @records[$row]<data><weektotal>;

        %weekData<rows>[$row] = {
            job => $jobNumber,
            task => $taskNumber,
        };
        %weekData<rows>[$row]<temp> = True unless @records[$row]<data><permanentline>;
        %weekData<rows>[$row]<total> = $total if $total;
        for 1..7 -> $wday {
            my $hours = @records[$row]<data>{"numberday{$wday}"};
            %weekData<rows>[$row]<hours>{$wday} = $hours if $hours;
        }
    }

    my ($week-name, $periodStart, $year, $month, $mday) = get-current-week(%card<periodstartvar>);
    %cache<weeks>{$year}{$month}{$mday} = %weekData;

    set-cache(%cache);

    %cache<currentWeek> = %card<periodstartvar>;
    %cache<currentDate> = %card<datevar>;
    for ^$rowCount -> $row {
        my %rowData = @records[$row]<data>;
        %cache<weeks>{$year}{$month}{$mday}<rows>[$row]<state> = %rowData<approvalstatus>;
        %cache<weeks>{$year}{$month}{$mday}<rows>[$row]<concurrency> = @records[$row]<meta><concurrencyControl>;
    }

    return %cache;
}
