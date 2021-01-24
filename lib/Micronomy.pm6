use Cro::HTTP::Router;
use Cro::HTTP::Client;
use Cro::WebApp::Template;
use Cro::HTTP::Cookie;
use URI::Encode;
use JSON::Fast;
use Digest::MD5;

class Micronomy {
    my $server = "https://b3iaccess.deltekenterprise.com";
    my $registration-path = "containers/v1/b3/timeregistration/data;any";
    my $instances-path = "maconomy-api/containers/b3/timeregistration/instances";
    my $employee-path = "containers/v1/b3/api_currentemployee/";
    my $favorites-path = "containers/v1/b3/jobfavorites";
    my $tasks-path = "maconomy-api/containers/b3/timeregistration/search/table;foreignkey=taskname_tasklistline?fields=taskname,description&limit=100";
    my @days = <Sön Mån Tis Ons Tor Fre Lör Sön>;
    my @months = <Dec Jan Feb Mar Apr Maj Jun Jul Aug Sep Okt Nov Dec>;
    template-location 'resources/templates/';

    sub trace($message, $token = '') {
        my $now = DateTime.now(
            formatter => { sprintf "%4d-%02d-%02d %02d:%02d:%06.3f",
                           .year, .month, .day, .hour, .minute, .second });
        my $session = $token ?? Digest::MD5.md5_hex($token).substr(24) !! '-';
        say "$now  $session  $message";
    }

    sub get-header($response, $header) {
        for $response.headers -> $key {
            return $key.value if $key.name.lc eq $header.lc;
        }
    }

    sub show-week($token, %cache, :$error) {
        trace "show-week", $token;

        my $periodStart = Date.new(%cache<currentWeek>);
        $periodStart ~~ /(\d+)"-"(\d+)"-"(\d+)/;
        my ($year, $month, $mday) = ($0, $1, $2);
        my %week = %cache<weeks>{$year}{$month}{$mday};
        my $week = %week<name>;
        %week<rows> //= ();

        my @weekStatus = <Öppen Avlämnad Godkänd>;
        my $weekStatus = @weekStatus[%week<state>];

        my $today = Date.today;
        my $previous = $periodStart.earlier(days => 1);
        my $next = $periodStart.later(days => 7);
        $next = $next.truncated-to('month') if $periodStart.month != $next.month;

        my $fmt = {sprintf "%s %02d/%02d", @days[.day-of-week], .day, .month};
        my $previousSunday = $periodStart.clone(formatter => $fmt).truncated-to('week').earlier(days => 1);

        my %data = (
            period => "vecka $week",
            action => "/",
            date-action => "/",
            state => ", $weekStatus",
            next => $next,
            previous => $previous,
            today => $today.gist,
            error => $error // '',
            concurrency => %cache<concurrency>,
            employee => %cache<employeeName>,
            date => %cache<currentDate>,
            total => %week<totals><reported>,
            fixed => %week<totals><fixed>,
            overtime => %week<totals><overtime>,
            invoiceable => %week<totals><invoiceable>,
            filler => -1,
            rows => [],
        );

        for ^%week<rows> -> $row {
            %data<filler> = $row if %cache<jobs>{%week<rows>[$row]<job>}<tasks>{%week<rows>[$row]<task>} eq "Tjänstledig mot RAM";
        }

        for 1..7 -> $wday {
            my %day = (number => $wday);
            %day<date> = $previousSunday.later(days => $wday).Str;
            %day<total> = %week<totals><days>{$wday}<reported> // 0;
            %day<fixed> = %week<totals><days>{$wday}<fixed> // 0;
            %day<overtime> = %week<totals><days>{$wday}<overtime> // 0;
            %day<invoiceable> = %week<totals><days>{$wday}<invoiceable> // 0;
            %data<days>.push(%day);
        }

        my @rows;
        for ^%week<rows> -> $row {
            my %rowData = %week<rows>[$row];
            my $status = %rowData<state>;
            $status = "approved" if $status eq "nil" and %week<state> == 2;
            given $status {
                when "nil" {
                    $status = "";
                }
                when "approved" {
		    # #31d23b = bright green
                    $status = '<div class="status" style="color:#31d23b;">✔</div>';
                }
                when "denied" {
		    # #ff4646 = bright red
                    $status = '<div class="status" style="color:#ff4646;">✘</div>';
                }
                default {
		    # #ff4646 = bright red same as the above
                    $status = '<div class="status" style="color:#ff4646;">' ~ $status ~ '</div>';
                }
            }

            my %row = (
                number => $row,
                title => title(%cache<jobs>{%rowData<job>}<name>, %cache<jobs>{%rowData<job>}<tasks>{%rowData<task>}),
                concurrency => %rowData<concurrency>,
                weektotal => %rowData<total> // 0,
                status => $status,
                disabled => $row == %data<filler>,
            );

            my @rowdays = [];
            for 1..7 -> $wday {
                my $disabled = $periodStart.month ne $previousSunday.later(days => $wday).month;
                $disabled ||= %row<disabled>;
                my $classes = "hour-box input__text";
                $classes ~= $disabled ?? " input__text--disabled" !! " nav-field";
                @rowdays.push(
                    {
                        number => $wday,
                        disabled => $disabled,
                        classes => $classes,
                        hours => %rowData<hours>{$wday} || "",
                    }
                );
            }
            %row<days> = @rowdays;
            @rows.push(%row);
        }

        if %cache<last-target> and %cache<last-target> ~~ / "hours-" $<row> = (\d+) "-" $<day> = (\d+) / {
            my $day = $<day> - 1;;
            for |($day ... 6), |($day ... 0) -> $wday {
                trace "day: $wday";
                unless @rows[$<row>]<days>[$wday]<disabled> {
                    @rows[$<row>]<days>[$wday]<id> = "focus-target";
                    last;
                }
            }
        } else {
            for 1..7 -> $wday {
                if $previousSunday.later(days => $wday) == $today and
                    not @rows[0]<days>[$wday-1]<disabled> {
                    @rows[0]<days>[$wday-1]<id> = "focus-target";
                }
            }
        }
        %data<rows> = @rows;

        trace "sending timesheet", $token;
        template 'timesheet.html.tmpl', %data;

        CATCH {
            warn "error: invalid data";
            my %content = get-week($token, Date.today.gist);
            show-week($token, %content, error => 'invalid data');
            return {};
        }
    }

    sub parse-week(%content) {
        my %card = %content<panes><card><records>[0]<data>;
        my %meta = %content<panes><card><records>[0]<meta>;
        my @records = @(%content<panes><table><records>);
        my $rowCount = %content<panes><table><meta><rowCount>;

        my $weekstatus = 0;
        $weekstatus = 1 if @records[0]<data><submitted>;
        $weekstatus = 2 if %card<approvedvar>;

        my %cache = get-cache(%card<employeenumber>);

        %cache<employeeName> = %card<employeenamevar>;
        %cache<employeeNumber> = %card<employeenumber>;

        my %weekData = (
            name => %card<weeknumbervar> ~ %card<partvar>,
            state => $weekstatus,
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

        %card<periodstartvar> ~~ /(\d+)"-"(\d+)"-"(\d+)/;
        my ($year, $month, $mday) = ($0, $1, $2);
        %cache<weeks>{$year}{$month}{$mday} = %weekData;

        set-cache(%cache);

        %cache<currentWeek> = %card<periodstartvar>;
        %cache<currentDate> = %card<datevar>;
        %cache<concurrency> = %meta<concurrencyControl>;
        for ^$rowCount -> $row {
            my %rowData = @records[$row]<data>;
            %cache<weeks>{$year}{$month}{$mday}<rows>[$row]<state> = %rowData<approvalstatus>;
            %cache<weeks>{$year}{$month}{$mday}<rows>[$row]<concurrency> = @records[$row]<meta><concurrencyControl>;
        }

        return %cache;
    }

    sub title(Str $job, Str $task --> Str) {
        "$task / $job";
    }

    method get-month(:$token, :$date) {
        trace "get-month $date", $token;
        my $start-date = $date ?? Date.new($date) !! Date.today;
        $start-date .= first-date-in-month;
        my $end-date = $start-date.last-date-in-month;

        Micronomy.get-period(:$token, :$start-date, :$end-date);
    }

    method get-period(Str :$token, Date :$start-date, Date :$end-date, Int :$hours-cache is copy = 0) {
        trace "get-period $start-date", $token;

        my ($employee, $employeeNumber, %cache);
        if $token ne "demo" {
            my $url = "$server/$employee-path/data;any";
            my $request = Cro::HTTP::Client.get(
                $url,
                headers => {
                    Authorization => "X-Reconnect $token",
                    Content-Type => "application/json",
                    Content-Length => 0,
                },
            );
            my $response = await $request;
            my %content = await $response.body;
            $employee = %content<panes><card><records>[0]<data><name1>;
            $employeeNumber = %content<panes><card><records>[0]<data><employeenumber>;
            %cache = get-cache($employeeNumber);
        } else {
            %cache = get-demo($start-date);
            $employee = %cache<employeeName>;
            $employeeNumber = %cache<employeeNumber>;
        }

        if $hours-cache == 1 {
            %cache<employeeName> = $employee;
            %cache<employeeNumber> = $employeeNumber;
            %cache<enabled> = True;
            set-cache(%cache);
        } elsif $hours-cache == -1 {
            %cache = (
                employeeName => $employee,
                employeeNumber => $employeeNumber,
                enabled => False,
            );
            set-cache(%cache);
            %cache = get-demo($start-date) if $token eq "demo";
        } else {
            $hours-cache = %cache<enabled> // False;
        }

        my $bucketSize = 'week';
        my $previous = $start-date.earlier(days => 1);
        my $next = $end-date.later(days => 1);

        if $start-date.truncated-to('year') != $end-date.truncated-to('year') {
            $bucketSize = 'year';
        } elsif $start-date.truncated-to('month') != $end-date.truncated-to('month') {
            $bucketSize = 'month';
        }

        my (%sums, %totals);

        my $current = $start-date;
        for 0..* -> $week {
            my $bucket = $current.truncated-to($bucketSize);
            $current ~~ /(\d+)"-"(\d+)"-"(\d+)/;
            my ($year, $month, $mday) = ($0, $1, $2);
            if %cache<weeks>{$year}{$month}{$mday}:exists {
                trace "using cached week $current", $token;
            } elsif $current lt '2019-05-01' {
                trace "ignoring week before 2019-05-01", $token;
                %cache<weeks>{$year}{$month}{$mday}<totals><reported> = 0;
                %cache<weeks>{$year}{$month}{$mday}<totals><fixed> = 0;
                %cache<weeks>{$year}{$month}{$mday}<totals><overtime> = 0;
                %cache<weeks>{$year}{$month}{$mday}<totals><invoiceable> = 0;
                %cache<weeks>{$year}{$month}{$mday}<rows> = ();
            } elsif $token eq "demo" {
                %cache = get-demo($current);
            } else {
                %cache = get-week($token, $current.gist);
            }

            %totals<reported>{$bucket} += %cache<weeks>{$year}{$month}{$mday}<totals><reported> // 0;
            %totals<fixed>{$bucket} += %cache<weeks>{$year}{$month}{$mday}<totals><fixed> // 0;
            %totals<overtime>{$bucket} += %cache<weeks>{$year}{$month}{$mday}<totals><overtime> // 0;;
            %totals<invoiceable>{$bucket} += %cache<weeks>{$year}{$month}{$mday}<totals><invoiceable> // 0;;

            for @(%cache<weeks>{$year}{$month}{$mday}<rows>) -> %row {
                my $job = %row<job>;
                my $task = %row<task>;
                for %row<hours>.keys -> $wday {
                    my $date = $current.later(days => $wday - 1).gist;
                    next if $date lt $start-date.gist;
                    last if $date gt $end-date.gist;

                    my $hours = %row<hours>{$wday};
                    unless %sums{$job}{$task}<title>:exists {
                        %sums{$job}{$task}<title> = title(%cache<jobs>{$job}<name>, %cache<jobs>{$job}<tasks>{$task});
                    }
                    %sums{$job}{$task}<bucket>{$bucket} += $hours;
                }
            }

            my $next = $current.later(weeks => 1).truncated-to("week");
            last if $next gt $end-date;
            if $next.month != $current.month and $next.day > 1 {
                $current = $next.earlier(days => 1).first-date-in-month;
            } else {
                $current = $next;
            }
        }

        my @buckets = %totals<reported>.keys.sort;
        for @buckets -> $bucket {
             %totals<reported><sum> += %totals<reported>{$bucket};
             %totals<fixed><sum> += %totals<fixed>{$bucket};
             %totals<overtime><sum> += %totals<overtime>{$bucket};
             %totals<invoiceable><sum> += %totals<invoiceable>{$bucket};
        }

        my %data = (
            period => "$start-date - $end-date",
            action => "/month",
            date-action => "/period",
            state => "",
            next => $next,
            previous => $previous,
            today => Date.today.gist,
            error => "",
            concurrency => 'read-only',
            employee => $employee,
            date => $start-date.gist,
            end-date => $end-date.gist,
            total => %totals<reported><sum>,
            fixed => %totals<fixed><sum>,
            overtime => %totals<overtime><sum>,
            invoiceable => %totals<invoiceable><sum>,
            filler => -1,
            rows => [],
            hours-cache => $hours-cache == 1,
        );

        my $fmt = {sprintf "v%02d", .week-number};
        $fmt = {sprintf "%s", @months[.month]} if $bucketSize eq "month";
        $fmt = {sprintf "%4d", .year} if $bucketSize eq "year";
        for @buckets -> $bucket {
            my %day = (number => $bucket);
            my $suffix = "";
            my $bucketDate = Date.new($bucket);
            my $bucketStart = $start-date > $bucketDate ?? $start-date !! $bucketDate;
            if $bucketSize eq "week" {
                $suffix = "B" if $bucketDate < $start-date;
                $suffix = "A" if $bucketDate.later(days => 6) > $end-date;
                %day<url> = "/?date=$bucketStart";
            } elsif $bucketSize eq "month" {
                %day<url> = "/month?date=$bucketStart";
            } elsif $bucketSize eq "year" {
                my $bucketEnd = $bucketStart.year ~ "-12-31";
                $bucketEnd = $end-date if $end-date.gist lt $bucketEnd;
                %day<url> = "/period?date=$bucketStart&end-date=$bucketEnd";
            }
            %day<date> = Date.new($bucket, formatter => $fmt).Str ~ $suffix;
            %day<total> = %totals<reported>{$bucket};
            %day<fixed> = %totals<fixed>{$bucket};
            %day<overtime> = %totals<overtime>{$bucket};
            %day<invoiceable> = %totals<invoiceable>{$bucket};
            %data<days>.push(%day);
        }
        %data<font-size> = "8pt" if @buckets > 7;

        my $row = 0;
        for %sums.keys.sort -> $job {
            for %sums{$job}.keys.sort -> $task {
                my @rowbuckets;
                for @buckets -> $bucket {
                    %sums{$job}{$task}<sum> += %sums{$job}{$task}<bucket>{$bucket} // 0;
                    @rowbuckets.push(
                        {
                            number => $bucket,
                            disabled => "disabled",
                            classes => "hour-box input__text input__text--disabled",
                            hours => %sums{$job}{$task}<bucket>{$bucket} || "",
                        }
                    );
                }

                my %row = (
                    number => $row++,
                    title => %sums{$job}{$task}<title>,
                    concurrency => 'read-only',
                    weektotal => %sums{$job}{$task}<sum>,
                    disabled => True,
                    status => "",
                    days => @rowbuckets,
                );
                %data<rows>.push(%row);
            }
        }

        trace "sending timesheet", $token;
        template 'timesheet.html.tmpl', %data;
    }

    sub get-cache($employeeNumber) {
        my $dir = $*PROGRAM-NAME;
        $dir ~~ s/<-[^/]>* $//;
        $dir ||= '.';
        my $cacheFile = "$dir/resources/$employeeNumber.json";
        return from-json slurp $cacheFile if $cacheFile.IO.e;
    }

    sub set-cache(%cache) {
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

    sub get-current-week($date is copy) {
        $date = Date.new($date);
        my $week = $date.week-number;
        my $monday = $date.truncated-to("week");
        my $sunday = $monday.later(days => 6);
        my $start-date = $monday;
        if $monday.month == $date.month != $sunday.month {
            $week ~= "A";
        } elsif $monday.month != $date.month == $sunday.month {
            $week ~= "B";
            $start-date = $date.truncated-to("month");
        }

        my $year = sprintf "%4d", $start-date.year;
        my $month = sprintf "%02d", $start-date.month;
        my $mday = sprintf "%02d", $start-date.day;

        return $week, $start-date, $year, $month, $mday;
    }

    sub get-demo($date) {
        trace "sub get-demo $date";
        my %cache = get-cache("demo");
        %cache<currentDate> = $date;
        %cache<concurrency> = '"card"="demo"';

        my ($week, $start-date, $year, $month, $mday) = get-current-week($date);
        %cache<currentWeek> = $start-date.yyyy-mm-dd;

        if not %cache<weeks>{$year}{$month}{$mday}:exists {
            %cache<weeks>{$year}{$month}{$mday} = from-json to-json %cache<weeks><2019><05><06>;
            if $week ~~ /<[AB]>/ {
                %cache = sum-up-demo(%cache<currentWeek>, %cache);
            }
        }

        %cache<weeks>{$year}{$month}{$mday}<name> = $week;
        return %cache;
    }

    sub easter(Int $year, Int $diff = 0) {
        # Meeus/Jones/Butcher
        my $a = $year mod 19;
        my $b = $year div 100;
        my $c = $year mod 100;
        my $d = $b div 4;
        my $e = $b mod 4;
        my $f = ($b + 8) div 25;
        my $g = ($b - $f + 1) div 3;
        my $h = (19*$a + $b - $d - $g + 15) mod 30;
        my $i = $c div 4 ;
        my $k = $c mod 4 ;
        my $l = (32 + 2*$e + 2*$i - $h - $k) mod 7 ;
        my $m = ($a + 11*$h + 22*$l) div 451 ;
        my $month = ($h + $l - 7*$m + 114) div 31 ;
        my $day = (($h + $l - 7*$m + 114) mod 31) + 1;

        my $fmt = { sprintf "%02d%02d", .month, .day };
        my $date = Date.new($year, $month, $day, formatter => $fmt).later(days => $diff);
        return $date.Str;
    }

    sub floating-date(Int $year, Int $month, Int $mday, Int $wday, Int :$count = 1, Int :$diff = 0) {
        # $diff days after $count:th $wday on or after $year-$month-$mday
        my $fmt = { sprintf "%02d%02d", .month, .day };
        my $origin = Date.new(sprintf("%d-%02d-%02d", $year, $month, $mday), formatter => $fmt);
        my $oday = $origin.day-of-week;
        my $later = (7 - ($oday - $wday) % 7) % 7;
        $later += ($count - 1) * 7;
        $later += $diff;
        return  $origin.later(days => $later + $diff).Str;
    }
    sub midsummer($year, $diff = 0) {
        # 1st Sat on/after 20 June
        return floating-date $year, 6, 20, 6, :$diff;
    }
    sub allsaints($year, $diff = 0) {
        # 1st Sat on/after 31 Oct
        return floating-date $year, 10, 31, 6, :$diff;
    }

    sub expected($day) {
        return 0 if $day.day-of-week > 5;
        given sprintf "%02d%02d", $day.month, $day.day {
            when "0101"                   { return 0; }  # Nyårsdagen
            when "0105"                   { return 6; }  # 12-dag Jul
            when "0106"                   { return 0; }  # 13-dag Jul
            when easter($day.year, -3)    { return 4; }  # Skärtorsdag
            when easter($day.year, -2)    { return 0; }  # Långfredag
            when easter($day.year, -1)    { return 0; }  # Påskafton
            when easter($day.year)        { return 0; }  # Påskdagen
            when easter($day.year,  1)    { return 0; }  # Annandag Påsk
            when "0430"                   { return 4; }  # Valborg
            when "0501"                   { return 0; }  # 1:a Maj
            when easter($day.year, 39)    { return 0; }  # Kristi Himmelfärdsdag
            when easter($day.year, 40)    { return 0; }  # klämdag
            when easter($day.year, 48)    { return 0; }  # Pingstafton
            when easter($day.year, 49)    { return 0; }  # Pingstdagen
            when "0606"                   { return 0; }  # Nationaldagen
            when midsummer($day.year, -1) { return 0; }  # Midsommarafton
            when midsummer($day.year)     { return 0; }  # Midsommardagen
            when allsaints($day.year, -1) { return 4; }  # Allhelgonaafton
            when allsaints($day.year)     { return 0; }  # Alla Helgons Dag
            when "1223"                   { return 6; }  # dan före dopparedan
            when "1224"                   { return 0; }  # Julafton
            when "1225"                   { return 0; }  # Juldagen
            when "1226"                   { return 0; }  # Annandag Jul
            when "1227"                   { return 0; }  # mellandag
            when "1228"                   { return 0; }  # mellandag
            when "1229"                   { return 0; }  # mellandag
            when "1230"                   { return 0; }  # mellandag
            when "1231"                   { return 0; }  # Nyårsafton
            default { return 8; }
        }
    }

    sub sum-up-demo(Str $date, %cache, $filler = -1) {
        trace "sub sum-up-demo $date, $filler";
        my ($week-name, $start-date, $year, $month, $mday) = get-current-week($date);
        my $start-day = $start-date.day-of-week;

        %cache<weeks>{$year}{$month}{$mday}<totals><fixed> = 0;
        %cache<weeks>{$year}{$month}{$mday}<totals><invoiceable> = 0;
        %cache<weeks>{$year}{$month}{$mday}<totals><overtime> = 0;
        %cache<weeks>{$year}{$month}{$mday}<totals><reported> = 0;

        for 1..7 -> $wday {
            my $fixed;
            my $skipped = False;
            my $day = $start-date.later(days => $wday - $start-day);
            if $wday < $start-day or $day.month != $start-date.month {
                # skip out of week data
                $skipped = True;
                %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}:delete;
            } else {
                $fixed = expected($day);
                %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}<fixed> = $fixed;
            }

            my $rowNum = -1;
            my $invoiceable = 0;
            my $reported = 0;
            for @(%cache<weeks>{$year}{$month}{$mday}<rows>) -> %row {
                if ($skipped or not %row<hours>{$wday}) {
                    # skip out of week data or zero hours
                    %row<hours>{$wday}:delete;
                } elsif %row<task> ne "102" { # don't sum "Beredskap"
                    $invoiceable += %row<hours>{$wday} if %row<job> eq <12020002 12020003>.any;
                    $reported += %row<hours>{$wday};
                }
            }
            next if $skipped;

            %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}<reported> = $reported;
            %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}<invoiceable> = $invoiceable;
            my $overtime = $reported - $fixed;
            %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}<overtime> = $overtime;

            %cache<weeks>{$year}{$month}{$mday}<totals><fixed> += $fixed;
            %cache<weeks>{$year}{$month}{$mday}<totals><invoiceable> += $invoiceable;
            %cache<weeks>{$year}{$month}{$mday}<totals><reported> += $reported;
            %cache<weeks>{$year}{$month}{$mday}<totals><overtime> += $overtime;
        }
        for @(%cache<weeks>{$year}{$month}{$mday}<rows>) -> %row {
            %row<total> = 0;
            for 1..7 -> $wday {
                %row<total> += %row<hours>{$wday} // 0;
            }
        }

        if $filler >= 0 {
            my %parameters;
            set-filler(%cache, %parameters, $filler);
            for 1..7 -> $wday {
                my $previous = %cache<weeks>{$year}{$month}{$mday}<rows>[$filler]<hours>{$wday} // 0;
                my $compensation = %parameters{"hours-$filler-$wday"};
                %cache<weeks>{$year}{$month}{$mday}<rows>[$filler]<hours>{$wday} = $compensation;
                if $compensation != $previous {
                    $compensation -= $previous;
                    %cache<weeks>{$year}{$month}{$mday}<rows>[$filler]<total> += $compensation;
                    %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}<reported> += $compensation;
                    %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}<overtime> += $compensation;
                    %cache<weeks>{$year}{$month}{$mday}<totals><reported> += $compensation;
                    %cache<weeks>{$year}{$month}{$mday}<totals><overtime> += $compensation;
                }
            }
        }
        return %cache;
    }

    sub get-week($token, $date is copy = '', Bool :$raw = False) {
        $date ||= DateTime.now.earlier(hours => 12).yyyy-mm-dd;
        trace "sub get-week $date", $token;

        if $token ne "demo" {
            my $url = "$server/$registration-path?card.datevar=$date";

            my $request = Cro::HTTP::Client.get(
                $url,
                headers => {
                    Authorization => "X-Reconnect $token",
                },
            );
            my $response = await $request;
            my $body = await $response.body;
            return $body if $raw;
            return parse-week($body);

            CATCH {
                when X::Cro::HTTP::Error {
                    warn "error: " ~ .response.status;
                    Micronomy.get-login() if .response.status == 401;
                    return {};
                }
                Micronomy.get-login(reason => "Ogiltig session! ")
            }
        } else {
            return get-demo($date);
        }
    }

    method get(:$token, :$date = '') {
        trace "get $date", $token;
        my %content = get-week($token, $date) and
            show-week($token, %content);

        trace "get method done", $token;
    }

    sub get-favorites($token) {
        trace "sub get-favorites", $token;
        my $body;
        if $token ne "demo" {
            my $url = "$server/$favorites-path/data;any";
            my $request = Cro::HTTP::Client.get(
                $url,
                headers => {
                    Authorization => "X-Reconnect $token",
                    Content-Type => "application/json",
                    Content-Length => 0,
                },
            );
            my $response = await $request;
            $body = await $response.body;
            return $body;
        } else {
            return get-cache("demo-faves");
        }

        CATCH {
            when X::Cro::HTTP::Error {
                warn "error: [" ~ .response.status ~ "]:\n    " ~ $body.join("\n    ");
                Micronomy.get-login() if .response.status == 401;
                return {};
            }
            Micronomy.get-login(reason => "Ogiltig session! ")
        }
    }

    sub get-tasks($token, $jobnumber) {
        trace "sub get-tasks for $jobnumber", $token;

        if $token ne "demo" {
            my $url = "$server/$tasks-path";
            my $request = Cro::HTTP::Client.post(
                $url,
                headers => {
                    Authorization => "X-Reconnect $token",
                    Content-Type => "application/json",
                },
                body => '{"data": {"jobnumber":"' ~ $jobnumber ~ '"}}',
            );
            my $response = await $request;
            my $body = await $response.body;

            my @tasks;
            for @($body<panes><filter><records>) -> $record {
                @tasks.push(
                    {
                        number => $record<data><taskname>,
                        name => $record<data><description>,
                    }
                );
            }
            return @tasks;
        } else {
            my %tasks = get-cache("demo-tasks");
            return %tasks{$jobnumber};
        }
    }

    sub get-concurrency($token, $date) {
        trace "get concurrency", $token;
        return "demo", "demo" if $token eq "demo";

        # get card id
        my $url = "$server/$instances-path";
        my $response = await Cro::HTTP::Client.post(
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

        my $retries = 10;
        for 0 .. $retries -> $wait {
            try {
                sleep $wait/10;
                # refresh data? (seems to be required)
                $response = await Cro::HTTP::Client.post(
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

                last;
            }

            if $! ~~ X::Cro::HTTP::Error and $!.response.status == 404 and $wait < $retries {
                trace "get-concurrency (data;any) received 404 - retrying [{$wait+1}/$retries]", $token;
            } else {
                die $!;
            }
        }

        for 0 .. $retries -> $wait {
            try {
                sleep $wait/10;
                $response = await Cro::HTTP::Client.post(
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
            }

            if $! ~~ X::Cro::HTTP::Error and $!.response.status == 404 and $wait < $retries {
                trace "get-concurrency (datevar) received 404 - retrying [{$wait+1}/$retries]", $token;
            } else {
                die $!;
            }
        }
    }

    sub add-data($action, $token, $source, $target, %parameters) {
        trace "add data [$source -> $target] " ~ %parameters{"position-$source"}, $token;
        my $numberOfLines = %parameters<rows>;
        my ($containerInstanceId, $concurrency) = get-concurrency($token, %parameters<date>);

        my $url = "$server/$instances-path/$containerInstanceId/data/panes/table";
        if (%parameters{"position-$source"} < $numberOfLines) {
            if $action eq "add" {
                $url ~= "?row=" ~ $target;
            } else {
                $url ~= "/$target";
            }
        }

        my $retries = 9;
        for 0 .. $retries -> $wait {
            sleep $wait/10;
            try {
                # populate row
                my @data = ();
                @data.push('"jobnumber": "' ~ %parameters{"job-$source"} ~ '"') if %parameters{"job-$source"};
                @data.push('"taskname": "' ~  %parameters{"task-$source"} ~ '"') if %parameters{"task-$source"};
                @data.push('"permanentline": ' ~ (%parameters{"keep-$source"} == 1 ?? "false" !! "true"));
                if %parameters{"position-$source"} ne $source and %parameters{"hours-$source"}:exists {
                    my $day = 0;
                    for %parameters{"hours-$source"}.split(";") -> $hours {
                        $day++;
                        @data.push("\"numberday{$day}\": $hours") if $hours ne "0";
                    }
                }
                my $data = '{"data": {' ~ @data.join(",") ~ '}}';
                trace "$url $data";

                my $response = await Cro::HTTP::Client.post(
                    "$url",
                    headers => {
                        Authorization => "X-Reconnect $token",
                        Maconomy-Concurrency-Control => $concurrency,
                        Content-Type => "application/json",
                    },
                    body => $data,
                );

                return get-header($response, 'maconomy-concurrency-control');
            }

            if $! ~~ X::Cro::HTTP::Error and $!.response.status == 404 and $wait < $retries {
                trace "add-data received 404 - retrying [{$wait+1}/$retries]", $token;
            } else {
                die $!;
            }
        }
    }

    sub delete-row($token, $target, %parameters) {
        trace "delete row $target", $token;
        my ($containerInstanceId, $concurrency) = get-concurrency($token, %parameters<date>);

        # delete row
        if $token ne "demo" {
            my $url = "$server/$instances-path";
            for ^10 -> $wait {
                sleep $wait/10;
                try {
                    my $response = await Cro::HTTP::Client.delete(
                        "$url/$containerInstanceId/data/panes/table/$target",
                        headers => {
                            Authorization => "X-Reconnect $token",
                            Maconomy-Concurrency-Control => $concurrency,
                        },
                    );
                    return get-header($response, 'maconomy-concurrency-control');
                }

                if $! ~~ X::Cro::HTTP::Error and $!.response.status == 404 and $wait < 9 {
                    trace "delete-row received 404 - retrying [{$wait+1}/9]", $token;
                } else {
                    die $!;
                }
            }
        } else {
            my ($week-name, $start-date, $year, $month, $mday) = get-current-week(%parameters<date>);
            my %cache = get-demo($start-date);
            %cache<weeks>{$year}{$month}{$mday}<rows>.splice($target, 1);
            set-cache(%cache);
        }
    }

    sub edit($token, %parameters) {
        my $numberOfLines = %parameters<rows>;
        my @currentPosition = ^$numberOfLines;

        # delete, update or move lines
        for (^$numberOfLines).sort({@currentPosition[$_]}) -> $row {
            trace "positions "~@currentPosition;
            my $target = @currentPosition[$row];
            my $was-kept = %parameters{"was-kept-$row"} eq "True" ?? 2 !! 1;
            if %parameters{"keep-$row"} == 0 {
                delete-row($token, $target, %parameters);

                # mark index as deleted in position array
                @currentPosition[$row] = -1;
                for ^@currentPosition -> $position {
                    @currentPosition[$position]-- if @currentPosition[$position] > $target;
                }
                next;

            } elsif %parameters{"set-task-$row"} or %parameters{"keep-$row"} != $was-kept {
                %parameters{"task-$row"} = %parameters{"set-task-$row"};
                add-data('update', $token, $row, $target, %parameters);
            }

            # move lines
            my $newTarget = %parameters{"position-$row"};
            if $newTarget != $row and $newTarget != $target {
                trace "move row $row from $target to $newTarget", $token;
                if $newTarget < $target {
                    add-data('add', $token, $row, $newTarget, %parameters);
                    delete-row($token, $target+1, %parameters);
                } else {
                    add-data('add', $token, $row, $newTarget+1, %parameters);
                    delete-row($token, $target, %parameters);
                }
                # move indexes in position array
                @currentPosition[$row] = $newTarget;
                for ^@currentPosition -> $position {
                    my $other = @currentPosition[$position];
                    @currentPosition[$position]-- if $newTarget > $other > $target;
                    @currentPosition[$position]++ if $newTarget < $other < $target;
                }
            }
        }
        trace "positions "~@currentPosition;

        # add new line
        my $row = $numberOfLines;
        if %parameters{"job-$row"} ne "" {
            %parameters{"keep-$row"} = 2;
            my $task = %parameters{"job-$row"}.split("/")[1];
            %parameters{"task-$row"} = %parameters{"job-$row"}.split("/")[1] if $task;
            %parameters{"job-$row"} = %parameters{"job-$row"}.split("/")[0];
            add-data('add', $token, $row, %parameters{"position-$row"}, %parameters);
        }
    }

    method edit(:$token, :%parameters) {
        trace "edit", $token;
        my $date = %parameters<date>;
        $date ||= DateTime.now.earlier(hours => 12).yyyy-mm-dd;

        trace "parameters:", $token;
        for %parameters.keys.sort -> $key {
            trace "$key: %parameters{$key}";
        }
        edit($token, %parameters) if %parameters<rows>:exists;

        my %favorites = get-favorites($token) || return;
        my %cache = get-week($token, $date);
        my $week = %cache<currentWeek>;

        my %data = (
            week => $week,
            error => '',
            concurrency => %cache<concurrency>,
            employee => %cache<employeeName>,
            date => $date,
        );

        $week ~~ /(\d+)"-"(\d+)"-"(\d+)/;
        my ($year, $month, $mday) = ($0, $1, $2);
        my (@rows, %rows);
        my $row = 0;
        for @(%cache<weeks>{$year}{$month}{$mday}<rows>) -> %row {
            my $jobNumber = %row<job>;
            my $jobName = %cache<jobs>{%row<job>}<name>;
            my $taskNumber = %row<task>;
            my $taskName = %cache<jobs>{%row<job>}<tasks>{$taskNumber};
            %rows{$jobNumber}{$taskNumber} = 1;
            my @hours;
            for 1..7 -> $wday {
                @hours.push(%row<hours>{$wday} || 0);
            }
            my %rowData = (
                number => $row++,
                jobnumber   => $jobNumber,
                jobname     => $jobName,
                tasknumber  => $taskNumber,
                taskname    => $taskName,
                concurrency => %row<concurrency>,
                keep        => not %row<temp>,
                hours       => @hours.join(";"),
            );
            if not $taskNumber {
                %rowData<tasks> = get-tasks($token, $jobNumber);
            }
            @rows.push(%rowData);
        }
        %data<rows> = @rows;
        %data<next> = @rows.elems;

        my @favorites;
        for ^%favorites<panes><table><meta><rowCount> -> $row {
            my $jobNumber = %favorites<panes><table><records>[$row]<data><jobnumber>;
            my $taskNumber = %favorites<panes><table><records>[$row]<data><taskname>;
            next if %rows{$jobNumber}{$taskNumber};
            my %favorite = (
                favorite   => %favorites<panes><table><records>[$row]<data><favorite>,
                jobnumber  => $jobNumber,
                jobname    => %favorites<panes><table><records>[$row]<data><jobnamevar>,
                tasknumber => $taskNumber,
                taskname   => %favorites<panes><table><records>[$row]<data><tasktextvar>,
            );
            @favorites.push(%favorite);
        }
        %data<favorites> = @favorites;

        template 'edit.html.tmpl', %data;

        #CATCH {
        #    when X::Cro::HTTP::Error {
        #        warn "error: " ~ .response.status;
        #        Micronomy.get-login() if .response.status == 401;
        #        return {};
        #    }
        #    Micronomy.get-login(reason => "Ogiltig session! ")
        #}
    }

    sub set-filler(%content, %parameters, $filler --> Bool) {
        trace "set-filler $filler";
        return False if $filler < 0;
        return False unless %content<weeks>:exists;

        my ($week, $start-date, $year, $month, $mday) = get-current-week(%content<currentWeek>);

        my $previous = %content<weeks>{$year}{$month}{$mday}<rows>[$filler]<total> // 0;
        my $fixed = %content<weeks>{$year}{$month}{$mday}<totals><fixed> // 0;
        my $reported = %content<weeks>{$year}{$month}{$mday}<totals><reported> // 0;
        my $total = $fixed - $reported + $previous;

        for (1..7).sort(
            {
                (%content<weeks>{$year}{$month}{$mday}<totals><days>{$_}<overtime> // 0)
                -
                (%content<weeks>{$year}{$month}{$mday}<rows>[$filler]<hours>{$_} // 0)
            }
        ) -> $day  {
            my $previous = %content<weeks>{$year}{$month}{$mday}<rows>[$filler]<hours>{$day} // 0;
            my $overtime = %content<weeks>{$year}{$month}{$mday}<totals><days>{$day}<overtime> // 0;

            $overtime = $previous - $overtime;
            $overtime = $total if $overtime > $total;
            $overtime = 0 if $overtime < 0;

            trace "filling day $day with $overtime";
            %parameters{"hours-$filler-$day"} = $overtime;
            $total -= $overtime;
        }
        return True;
    }

    sub set(%parameters, $row, $token) {
        if $token ne "demo" {
            my @changes;
            for 1..7 -> $day  {
                my $hours = %parameters{"hours-$row-$day"} || "0";
                $hours = +$hours.subst(",", ".");
                my $previous = %parameters{"hidden-$row-$day"} || 0;
                if $hours ne $previous {
                    @changes.push("\"numberday$day\": " ~ $hours);
                }
            }
            if @changes {
                trace "setting row $row", $token;
                my $concurrency = %parameters{"concurrency-$row"};
                my $url = "$server/$registration-path/table/$row?card.datevar=%parameters<date>";
                my $response = await Cro::HTTP::Client.post(
                    $url,
                    headers => {
                        Authorization => "X-Reconnect $token",
                        Content-Type => "application/json",
                        Accept => "application/json",
                        Maconomy-Concurrency-Control => $concurrency,
                    },
                    body => '{"data":{' ~ @changes.join(", ") ~ '}}',
                );
                return parse-week(await $response.body);
            }
        } else {
            my %cache = get-demo(%parameters<date>);

            my ($week-name, $start-date, $year, $month, $mday) = get-current-week(%parameters<date>);

            for 1..7 -> $wday  {
                my $hours = %parameters{"hours-$row-$wday"} || "0";
                $hours = +$hours.subst(",", ".");
                %cache<weeks>{$year}{$month}{$mday}<rows>[$row]<hours>{$$wday} = $hours;;
            }
            set-cache(%cache);
            return %cache;
        }
    }

    method set(:$token, :%parameters) {
        trace "set", $token;
        for %parameters.keys.sort({.split('-', 2)[1]//''}) -> $key {
            next if $key ~~ /concurrency/;
            my $value =  %parameters{$key};
            trace "  $key: $value", $token if $value;
        }

        my $filler = %parameters<filler> // -1;
        my %content;
        if (%parameters<concurrency>) {
 	    for 0..* -> $row {
 	        last unless %parameters{"concurrency-$row"};
 	        next if $row == $filler;
 	        my %result = set(%parameters, $row, $token);
 	        %content = %result if %result;
 	    }
 	    if $token eq "demo" {
                %content = get-demo(%parameters<date>);
 	        %content = sum-up-demo(%parameters<date>, %content, $filler);
                set-cache(%content);
 	    } elsif set-filler(%content, %parameters, $filler) {
 	        my %result = set(%parameters, $filler, $token);
 	        %content = %result if %result;
 	    }
 	}

        %content = get-week($token, %parameters<date>);
        %content<last-target> =  %parameters<last-target>;

        show-week($token, %content);

        return;

        CATCH {
            when X::Cro::HTTP::Error {
                warn "error: " ~ .response.status;
                if .response.status == 401 {
                    Micronomy.get-login(reason => "Var vänlig och logga in!");
                    return;
                }
            }
            Micronomy.get-login(reason => "Ogiltig session! ")
        }
    }

    method submit(:$token, :$date = '', :$reason, :$concurrency) {
        trace "submit $date", $token;
        my %content;
        if $token ne "demo" {
            my $url = "$server/$registration-path/card/0/action;name=submittimesheet?card.datevar=$date";
            $url ~= "&card.resubmissionexplanationvar=$reason" if $reason;
            my $response = await Cro::HTTP::Client.post(
                $url,
                headers => {
                    Authorization => "X-Reconnect $token",
                    Content-Type => "application/json",
                    Accept => "application/json",
                    Maconomy-Concurrency-Control => $concurrency,
                    Content-Length => 0,
                },
            );

            %content = await $response.body;
            %content = parse-week(%content);
        } else {
            %content = get-demo($date);
        }
        show-week($token, %content);

        CATCH {
            when X::Cro::HTTP::Error {
                my $body = await .response.body;
                warn "error: [" ~ .response.status ~ "]:\n    " ~ $body.join("\n    ");
                if .response.status == 401 {
                    Micronomy.get-login(reason => "Var vänlig och logga in!");
                } else {
                    %content = get-week($token, $date);
                    show-week($token, %content, error => $body<errorMessage>);
                }
                return {};
            }
        }
    }

    method get-login(:$username = '', :$reason = '') {
        trace "get-login $username $reason";
        my %data = (
            username => $username,
            reason => $reason,
        );
        set-cookie("sessionToken", "login",
                   same-site => Cro::HTTP::Cookie::SameSite::Strict,
                   expires => DateTime.now(),
                  );
        template 'login.html.tmpl', %data;
        trace "sent login page";
    }

    method login(:$username = '', :$password) {
        my ($token, $status);
        if $username and $password {
            trace "login $username ***";
            if $username eq $password eq "demo" {
                $token = "demo";
            } else {
                my $url = "$server/$employee-path/data;any";
                my $response = await Cro::HTTP::Client.get(
                    $url,
                    auth => {
                        username => $username,
                        password => $password
                    },
                    headers => {
                        Maconomy-Authentication => 'X-Reconnect',
                        Set-Cookie => 'sessionToken=',
                    },
                );
                $token = get-header($response, 'maconomy-reconnect');
                trace "logged in $username", $token;

                CATCH {
                    when X::Cro::HTTP::Error {
                        my $error = (await .response.body)<errorMessage>;
                        $error = $error ?? '[' ~ .response.status ~ '] ' ~ $error !! .message();
                        $status = uri_encode_component($error);
                    }
                }
            }
        }
        if $token {
            trace "$username logged in", $token;
            set-cookie("sessionToken", $token,
                       same-site => Cro::HTTP::Cookie::SameSite::Strict,
                      );
            redirect "/", :see-other;
            trace "redirected from login to get", $token;
        } else {
            trace "$username login failed";
            $status //= '';
            redirect "/login?username=$username&reason=$status", :see-other;
            trace "redirected from login to login";
        }
    }

    method logout(:$token) {
        trace "logout", $token;
        my $status;
        if $token and $token ne "demo" {
            my $url = "$server/$employee-path/data;any";
            my $response = await Cro::HTTP::Client.get(
                $url,
                headers => {
                    Authorization => "X-Reconnect $token",
                    Maconomy-Authentication => "X-Log-Out",
                },
            );

            CATCH {
                when X::Cro::HTTP::Error {
                    # ignore errors
                }
            }
        }
        set-cookie("sessionToken", "logout",
                   same-site => Cro::HTTP::Cookie::SameSite::Strict,
                   expires => DateTime.now(),
                  );
        redirect "/login?reason=Utloggad!", :see-other;
    }
}
