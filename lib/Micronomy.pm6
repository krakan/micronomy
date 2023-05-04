use Cro::HTTP::Router;
use Cro::WebApp::Template;
use Cro::HTTP::Cookie;
use URI::Encode;

use Micronomy::Cache;
use Micronomy::Calendar;
use Micronomy::Common;
use Micronomy::Demo;
use Micronomy::Sync;

class Micronomy {
    my $server = "https://b3iaccess.deltekenterprise.com";
    my $auth-path = "maconomy-api/auth/b3";
    my $instances-path = "maconomy-api/containers/b3/timeregistration/instances";
    my $environment-path = "/maconomy-api/environment/b3?variables";
    my $favorites-path = "maconomy-api/containers/b3/jobfavorites/instances";
    my $tasks-path = "maconomy-api/containers/b3/timeregistration/search/table;foreignkey=taskname_tasklistline?fields=taskname,description&limit=100";
    my @days = <Sön Mån Tis Ons Tor Fre Lör Sön>;
    my @months = <Dec Jan Feb Mar Apr Maj Jun Jul Aug Sep Okt Nov Dec>;
    my $retries = 10;
    template-location 'resources/templates/';

    sub show-week($token, %cache, :$error) {
        my $date = %cache<currentWeek> || Date.today;
        trace "show-week $date", $token;

        my ($week-name, $periodStart) = get-current-week($date);
        my %week = cached-week($periodStart, %cache) || {};
        if not %week or not %week<synched> or DateTime.new(%week<synched>) < DateTime.now.earlier(minutes => 5) {
            %week<state> = -1;
            sync(%cache<employeeNumber>, $token, {week => $periodStart});
        }

        my $week = %week<name>;
        %week<rows> //= ();

        my $weekStatus = "Laddar ...";
        my @weekStatus = <Öppen Avlämnad Godkänd>;
        $weekStatus = @weekStatus[%week<state>] if %week<state>:exists and %week<state> >= 0;;

        my $today = Date.today;
        my $previous = $periodStart.earlier(days => 1);
        my $next = $periodStart.later(days => 7);
        $next = $next.truncated-to('month') if $periodStart.month != $next.month;

        my $fmt = {sprintf "%s %02d/%02d", @days[.day-of-week], .day, .month};
        my $previousSunday = $periodStart.truncated-to('week').earlier(days => 1);

        my %data = (
            period => "vecka $week",
            year => $periodStart.year,
            action => "/",
            is-week => True,
            date-action => "/",
            status => ", $weekStatus",
            state => %week<state>,
            next => $next,
            previous => $previous,
            today => $today.gist,
            last-of-month => $today.truncated-to('month').later(months => 1).pred,
            error => $error // '',
            employee => %cache<employeeName>,
            date => $date,
            total => %week<totals><reported> // 0,
            fixed => %week<totals><fixed> // 0,
            overtime => %week<totals><overtime> // 0,
            invoiceable => %week<totals><invoiceable> // 0,
            filler => -1,
            rowCount => +%week<rows>,
            rows => [],
        );

        for ^%week<rows> -> $row {
            my $jobId = %week<rows>[$row]<job>;
            my $taskId = %week<rows>[$row]<task>;
            %data<filler> = $row if %cache<jobs>{$jobId}<tasks>{$taskId} eq "Tjänstledig mot RAM";
        }

        for 1..7 -> $wday {
            my %day = (number => $wday);
            %day<date> = $previousSunday.later(days => $wday).clone(formatter => $fmt).Str;
            %day<total> = %week<totals><days>{$wday}<reported> // 0;
            %day<fixed> = %week<totals><days>{$wday}<fixed> // 0;
            %day<overtime> = %week<totals><days>{$wday}<overtime> // 0;
            %day<invoiceable> = %week<totals><days>{$wday}<invoiceable> // 0;
            %data<days>.push(%day);
        }

        my @rows;
        for ^%week<rows> -> $row {
            my %rowData = %week<rows>[$row];
            my $status = %rowData<state> // "nil";
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
        header "X-Frame-Options: DENY";
        template 'timesheet.html.tmpl', %data;

        CATCH {
            error $_, $token;
            #my %content = get-week($token, Date.today.gist);
            #show-week($token, %content, error => 'okänt fel');
            return {};
        }
    }

    method get-month(:$token is copy, :$date) {
        $token = fix-token($token);
        trace "get-month $date", $token;
        my $start-date = $date ?? Date.new($date) !! Date.today;
        $start-date .= truncated-to('month');
        my $end-date = $start-date.later(months => 1).pred;

        Micronomy.get-period(:$token, :$start-date, :$end-date);

        CATCH {
            default {
                error $_, $token;
                return Micronomy.get-login(reason => "okänt fel");
            }
        }
    }

    method get-period(Str :$token is copy, Date :$start-date, Date :$end-date, Int :$hours-cache is copy = 0) {
        my $timeout = DateTime.now.later(minutes => 5);
        $token = fix-token($token);
        trace "get-period $start-date", $token;

        my %employee = get-session($token);
        my $employee = %employee<name>;
        my $employeeNumber = %employee<number>;
        my %cache = get-cache($employeeNumber);

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
        my $containerInstanceId = "";
        my $error = "";
        my $status = "";
        for 0..* -> $week {
            my $bucket = $current.truncated-to($bucketSize);

            my ($week-name, $week-start, $year, $month, $mday) = get-current-week($current);
            if (
                (%cache<weeks>{$year}{$month}{$mday}:exists) and
                (
                    (
                        %cache<weeks>{$year}{$month}{$mday}<state> == 2
                    ) or (
                        %cache<weeks>{$year}{$month}{$mday}<synched> and
                        DateTime.new(%cache<weeks>{$year}{$month}{$mday}<synched>) >
                        DateTime.now.earlier(minutes => 5)
                    )
                )
            ) {
                # cached week is Approved or recently synched
                trace "using cached week $current", $token;
            } else {
                if $current lt '2019-05-01' {
                    trace "ignoring week before 2019-05-01", $token;
                } else {
                    $status = ", Laddar ...";
                    sync($employeeNumber, $token, {week => $week-start});
                }
                %cache<weeks>{$year}{$month}{$mday}<totals><reported> = 0;
                %cache<weeks>{$year}{$month}{$mday}<totals><fixed> = 0;
                %cache<weeks>{$year}{$month}{$mday}<totals><overtime> = 0;
                %cache<weeks>{$year}{$month}{$mday}<totals><invoiceable> = 0;
                %cache<weeks>{$year}{$month}{$mday}<rows> = ();
            }

            %totals<reported>{$bucket} += %cache<weeks>{$year}{$month}{$mday}<totals><reported> // 0;
            %totals<fixed>{$bucket} += %cache<weeks>{$year}{$month}{$mday}<totals><fixed> // 0;
            %totals<overtime>{$bucket} += %cache<weeks>{$year}{$month}{$mday}<totals><overtime> // 0;;
            %totals<invoiceable>{$bucket} += %cache<weeks>{$year}{$month}{$mday}<totals><invoiceable> // 0;;

            for @(%cache<weeks>{$year}{$month}{$mday}<rows>) -> $row {
                last unless $row;
                my $job = $row<job>;
                my $task = $row<task>;
                for $row<hours>.keys -> $wday {
                    my $date = $current.later(days => $wday - 1).gist;
                    next if $date lt $start-date.gist;
                    last if $date gt $end-date.gist;

                    my $hours = $row<hours>{$wday};
                    unless %sums{$job}{$task}<title>:exists {
                        %sums{$job}{$task}<title> = title(%cache<jobs>{$job}<name>, %cache<jobs>{$job}<tasks>{$task});
                    }
                    %sums{$job}{$task}<bucket>{$bucket} += $hours;
                }
            }

            my $next = $current.later(weeks => 1).truncated-to("week");
            if $next.month != $current.month and $next.day > 1 {
                $current = $next.earlier(days => 1).truncated-to('month');
            } else {
                $current = $next;
            }
            last if $next gt $end-date;
            if DateTime.now > $timeout {
                $error = "datainsamling tog för lång tid";
                trace $error, $token;
                last;
            }
        }

        my @buckets = %totals<reported>.keys.sort;
        for @buckets -> $bucket {
            %totals<reported><sum> += %totals<reported>{$bucket};
            %totals<fixed><sum> += %totals<fixed>{$bucket};
            %totals<overtime><sum> += %totals<overtime>{$bucket};
            %totals<invoiceable><sum> += %totals<invoiceable>{$bucket};
        }

        my $today = Date.today;
        my %data = (
            period => "$start-date - {$current.pred}",
            action => "/month",
            is-week => False,
            date-action => "/period",
            status => $status,
            next => $next,
            previous => $previous,
            today => $today.gist,
            last-of-month => $today.truncated-to('month').later(months => 1).pred,
            error => $error,
            containerInstanceId => $containerInstanceId,
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
            rowCount => 0,
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
        %data<rowCount> = +%data<rows>;

        trace "sending timesheet", $token;
        header "X-Frame-Options: DENY";
        template 'timesheet.html.tmpl', %data;

        CATCH {
            when X::Cro::HTTP::Error {
                error $_, $token;
                return Micronomy.get-login(reason => "Vänligen logga in!") if .response.status == 401;
                return Micronomy.get-login(reason => "felstatus {.response.status}");
            }
            default {
                error $_, $token;
                return Micronomy.get-login(reason => "okänt fel");
            }
        }
    }

    sub fix-token(Str $token) {
        return $token if $token eq 'demo';
        return "bm90IGxvZ2dlZCBpbg==" unless $token;
        given $token.split(":")[1].chars % 4 {
            # add mysteriously stripped padding
            when 3 {return "$token="}
            when 2 {return "$token=="}
            default {return $token}
        }
    }

    method get(:$token is copy, :$date = '') {
        $token = fix-token($token);
        trace "get $date", $token;
        my %employee = get-session($token);
        my %content = get-cache(%employee<number>);
        %content<currentWeek> = $date;
        %content<employeeName> //= %employee<name>;
        show-week($token, %content);

        trace "get method done", $token;
        CATCH {
            when X::Cro::HTTP::Error {
                return Micronomy.get-login(reason => "Vänligen logga in!") if .response.status == 401;
                error $_, $token;
                return Micronomy.get-login(reason => "felstatus {.response.status}");
            }
            default {
                error $_, $token;
                return Micronomy.get-login(reason => "okänt fel");
            }
        }
    }

    sub get-favorites($token) {
        trace "sub get-favorites", $token;
        return get-cache("demo-faves") if $token eq "demo";

        my $url = "$server/$favorites-path";
        my $response = call-url(
            $url,
            headers => {
                Authorization => "X-Reconnect $token",
                Content-Type => "application/json",
            },
            body => '{"panes": {}}',
        );
        my $body = await $response.body;

        my $containerInstanceId = $body<meta><containerInstanceId>;
        my $concurrency = get-header($response, 'maconomy-concurrency-control');

        $url = "$server/$favorites-path/$containerInstanceId/data;any";
        $response = call-url(
            $url,
            headers => {
                Authorization => "X-Reconnect $token",
                Content-Type => "application/json",
                Content-Length => 0,
                Maconomy-Concurrency-Control => $concurrency,
            },
        );
        $body = await $response.body;

        return $body;
    }

    sub get-tasks($token, $jobnumber) {
        trace "sub get-tasks for $jobnumber", $token;

        if $token eq "demo" {
            my %tasks = get-cache("demo-tasks");
            return %tasks{$jobnumber};
        }

        my $url = "$server/$tasks-path";
        my $response = call-url(
            $url,
            headers => {
                Authorization => "X-Reconnect $token",
                Content-Type => "application/json",
            },
            body => '{"data": {"jobnumber":"' ~ $jobnumber ~ '"}}',
        );
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
    }

    sub upsert-row($action, $token, $source, $target, %parameters) {
        return add-demo-data($action, $source, $target, %parameters) if $token eq "demo";

        trace "$action data [$source -> $target] " ~ %parameters{"position-$source"}, $token;
        my $numberOfLines = %parameters<rows>;
        (%parameters<containerInstanceId>, %parameters<concurrency>) =
            get-concurrency($token, %parameters<date>)
                           unless %parameters<containerInstanceId> and %parameters<concurrency>;

        my $url = "$server/$instances-path/%parameters<containerInstanceId>/data/panes/table";
        if ($target < $numberOfLines) {
            if $action eq "add" {
                $url ~= "?row=" ~ $target;
            } else {
                $url ~= "/$target";
            }
        }

        # populate row
        my @data = ();
        @data.push('"jobnumber": "' ~ %parameters{"job-$source"} ~ '"') if %parameters{"job-$source"};
        @data.push('"taskname": "' ~  %parameters{"task-$source"} ~ '"') if %parameters{"task-$source"};
        if %parameters{"position-$source"} ne $source and %parameters{"hours-$source"}:exists {
            my $day = 0;
            for %parameters{"hours-$source"}.split(";") -> $hours {
                $day++;
                @data.push("\"numberday{$day}\": $hours") if $hours ne "0";
            }
        }
        my $data = '{"data": {' ~ @data.join(",") ~ '}}';
        trace "setting row $target to $data", $token;

        my $response = call-url(
            $url,
            timeout => 3,
            headers => {
                Authorization => "X-Reconnect $token",
                Maconomy-Concurrency-Control => %parameters<concurrency>,
                Content-Type => "application/json",
            },
            body => $data,
        );
        %parameters<concurrency> = get-header($response, 'maconomy-concurrency-control');
        return %parameters;

        CATCH {
            when X::Cro::HTTP::Error {
                if .response.status == 409 {
                    %parameters<concurrency>:delete;
                    return upsert-row($action, $token, $source, $target, %parameters);
                } else {
                    error $_, $token;
                    return {};
                }
            }
            default {
                error $_, $token;
                return {};
            }
        }
    }

    sub update-permanence($token, $source, $target, %parameters) {
        return if $token eq "demo";
        trace "sub update-permanence", $token;
        (%parameters<containerInstanceId>, %parameters<concurrency>) =
            get-concurrency($token, %parameters<date>)
                           unless %parameters<containerInstanceId> and %parameters<concurrency>;

        # update permanence
        my $kept = (%parameters{"was-kept-$source"} // "True") eq "True"; # "True"/"False"
        my $keep = %parameters{"keep-$source"} == 2; # 0=remove/1=temporary/2=permanent
        if $kept != $keep {
            my $permanent = $keep.lc;
            my $url = "$server/$instances-path/%parameters<containerInstanceId>/data/panes/table/$target";
            trace "set permanence for row $target to $permanent", $token;
            my $response = call-url(
                $url,
                timeout => 3,
                headers => {
                    Authorization => "X-Reconnect $token",
                    Maconomy-Concurrency-Control => %parameters<concurrency>,
                    Content-Type => "application/json",
                },
                body => '{"data": {"permanentline":' ~ " $permanent}}",
            );
            %parameters<concurrency> = get-header($response, 'maconomy-concurrency-control');
        }
        return %parameters;

        CATCH {
            when X::Cro::HTTP::Error {
                if .response.status == 409 {
                    %parameters<concurrency>:delete;
                    return update-permanence($token, $source, $target, %parameters);
                } else {
                    error $_, $token;
                    return {};
                }
            }
            default {
                error $_, $token;
                return {};
            }
        }
    }

    sub delete-row($token, $target, %parameters) {
        return delete-demo-row($target, %parameters) if $token eq "demo";
        trace "sub delete-row", $token;

        (%parameters<containerInstanceId>, %parameters<concurrency>) =
            get-concurrency($token, %parameters<date>)
                           unless %parameters<containerInstanceId> and %parameters<concurrency>;

        my $url = "$server/$instances-path/%parameters<containerInstanceId>/data/panes/table/$target";

        # delete row
        trace "delete row $target", $token;
        my $response = call-url(
            $url,
            method => 'delete',
            headers => {
                Authorization => "X-Reconnect $token",
                Maconomy-Concurrency-Control => %parameters<concurrency>,
            },
        );
        %parameters<concurrency> = get-header($response, 'maconomy-concurrency-control');
        return $%parameters;

        CATCH {
            when X::Cro::HTTP::Error {
                if .response.status == 409 {
                    %parameters<concurrency>:delete;
                    return delete-row($token, $target, %parameters);
                } else {
                    error $_, $token;
                    return {};
                }
            }
            default {
                error $_, $token;
                return {};
            }
        }
    }

    sub edit($token, %parameters) {
        trace "sub edit", $token;
        my $numberOfLines = %parameters<rows>;
        my @currentPosition = ^$numberOfLines;
        my @errors = ();

        # delete, update or move lines
        for ^$numberOfLines -> $row {
            trace "positions[$row] "~@currentPosition;
            my $target = @currentPosition[$row];
            my $was-kept = %parameters{"was-kept-$row"} eq "True" ?? 2 !! 1;
            %parameters{"task-$row"} = %parameters{"set-task-$row"} if %parameters{"set-task-$row"};

            # delete line
            if %parameters{"keep-$row"} == 0 {
                # remove permanence
                trace "prepare row $target for deletion", $token;
                my %result = update-permanence($token, $row, $target, %parameters);
                if %result {
                    %parameters<containerInstanceId> = %result<containerInstanceId>;
                    %parameters<concurrency> = %result<concurrency>;
                }
                %result = delete-row($token, $target, %parameters);
                if %result {
                    # mark index as deleted in position array
                    @currentPosition[$row] = -1;
                    for ^@currentPosition -> $position {
                        @currentPosition[$position]-- if @currentPosition[$position] > $target;
                    }
                    %parameters<containerInstanceId> = %result<containerInstanceId>;
                    %parameters<concurrency> = %result<concurrency>;
                } else {
                    @errors.push("borttagning av rad $target misslyckades");
                }
                next;
            }

            # move line
            my $newTarget = %parameters{"position-$row"};
            if $newTarget != $row and $newTarget != $target {
                trace "move row $row from $target to $newTarget", $token;
                if $newTarget < $target {
                    my %result = upsert-row('add', $token, $row, $newTarget, %parameters);
                    if %result {
                        %parameters<containerInstanceId> = %result<containerInstanceId>;
                        %parameters<concurrency> = %result<concurrency>;
                        %result = update-permanence($token, $row, $newTarget, %parameters) ||
                                                   @errors.push("uppdatering av rad $target misslyckades");
                        %parameters<concurrency> = %result<concurrency> if %result;
                        %result = delete-row($token, $target+1, %parameters) ||
                                            @errors.push("borttagning av rad {$target+1} misslyckades");
                        %parameters<concurrency> = %result<concurrency> if %result;
                    } else {
                        @errors.push("tilläggning av rad $newTarget misslyckades");
                    }
                } else {
                    my %result = upsert-row('add', $token, $row, $newTarget+1, %parameters);
                    if %result {
                        %parameters<containerInstanceId> = %result<containerInstanceId>;
                        %parameters<concurrency> = %result<concurrency>;
                        %result = update-permanence($token, $row, $newTarget+1, %parameters) ||
                                             @errors.push("uppdatering av rad $target misslyckades");
                        %parameters<concurrency> = %result<concurrency> if %result;
                        %result = delete-row($token, $target, %parameters) ||
                                            @errors.push("borttagning av rad $target misslyckades");
                        %parameters<concurrency> = %result<concurrency> if %result;
                    } else {
                        @errors.push("tilläggning av rad {$newTarget+1} misslyckades");
                    }
                }
                # move indexes in position array
                @currentPosition[$row] = $newTarget;
                for ^@currentPosition -> $position {
                    next if $position == $row;
                    my $other = @currentPosition[$position];
                    @currentPosition[$position]-- if $newTarget >= $other > $target;
                    @currentPosition[$position]++ if $newTarget <= $other < $target;
                }
            } else {
                # update line without moving
                if %parameters{"set-task-$row"} {
                    my %result = upsert-row('update', $token, $row, $target, %parameters) ||
                                           @errors.push("uppdatering av rad $target misslyckades");
                    if %result {
                        %parameters<containerInstanceId> = %result<containerInstanceId>;
                        %parameters<concurrency> = %result<concurrency>;
                    }
                }
                if %parameters{"keep-$row"} != $was-kept {
                    my %result = update-permanence($token, $row, $target, %parameters) ||
                                                  @errors.push("uppdatering av rad $target misslyckades");
                    if %result {
                        %parameters<containerInstanceId> = %result<containerInstanceId>;
                        %parameters<concurrency> = %result<concurrency>;
                    }
                }
            }
        }
        trace "positions[*] "~@currentPosition;

        # add new line
        my $row = $numberOfLines;
        if %parameters{"job-$row"} ne "" {
            %parameters{"keep-$row"} = 1;
            my $task = %parameters{"job-$row"}.split("/")[1];
            %parameters{"task-$row"} = %parameters{"job-$row"}.split("/")[1] if $task;
            %parameters{"job-$row"} = %parameters{"job-$row"}.split("/")[0];
            upsert-row('add', $token, $row, %parameters{"position-$row"}, %parameters) ||
            @errors.push("den nya raden är inte tillåten");
        }
        return @errors.join('<br>');
    }

    method edit(:$token is copy, :%parameters) {
        $token = fix-token($token);
        trace "edit", $token;
        my $date = %parameters<date>;
        $date ||= DateTime.now.earlier(hours => 12).yyyy-mm-dd;

        trace "parameters:", $token;
        for %parameters.keys.sort -> $key {
            trace "$key: %parameters{$key}";
        }
        my $errorMessage = edit($token, %parameters) if %parameters<rows>:exists;

        my %favorites = get-favorites($token) || return;
        my %cache = get-week($token, $date);
        my $week = %cache<currentWeek>;

        my %data = (
            week => $week,
            error => $errorMessage // "",
            concurrency => %cache<concurrency>,
            employee => %cache<employeeName>,
            date => $date,
        );

        my ($week-name, $start-date, $year, $month, $mday) = get-current-week($week);
        my (@rows, %rows);
        my $row = 0;
        for @(%cache<weeks>{$year}{$month}{$mday}<rows>) -> %row {
            my $jobNumber = %row<job>;
            my $jobName = %cache<jobs>{%row<job>}<name>;
            my $taskNumber = %row<task> // "";
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
            my $taskNumber = %favorites<panes><table><records>[$row]<data><taskname> // "";
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

        header "X-Frame-Options: DENY";
        template 'edit.html.tmpl', %data;

        CATCH {
            when X::Cro::HTTP::Error {
                error $_, $token;
                return Micronomy.get-login(reason => "Vänligen logga in!") if .response.status == 401;
                return Micronomy.get-login(reason => "felstatus {.response.status}");
            }
            default {
                error $_, $token;
                return Micronomy.get-login(reason => "okänt fel");
            }
        }
    }

    sub set(%parameters, $row, $token) {
        return set-demo(%parameters, $row) if $token eq "demo";

        $retries = 2 if %parameters<state> > 1;
        my @changes;
        for 1..7 -> $day  {
            my $hours = %parameters{"hours-$row-$day"} || "0";
            $hours = +$hours.subst(",", ".");
            $hours ~~ s:g/<-[\d.]>//;
            $hours ||= 0;
            my $previous = %parameters{"hidden-$row-$day"} || 0;
            if $hours ne $previous {
                @changes.push('"numberday' ~ $day ~ '": ' ~ $hours);
            }
        }
        if @changes {
            trace "setting row $row", $token;
            my $concurrency = %parameters<concurrency>;
            my $containerInstanceId = %parameters<containerInstanceId>;
            my $url = "$server/$instances-path/$containerInstanceId/data/panes/table/$row";

            for 0..$retries -> $wait {
                sleep $wait/10;
                try {
                    my $response = call-url(
                        $url,
                        headers => {
                            Authorization => "X-Reconnect $token",
                            Content-Type => "application/json",
                            Maconomy-Concurrency-Control => $concurrency,
                        },
                        body => '{"data":{' ~ @changes.join(", ") ~ '}}',
                    );
                    return parse-week($response);
                }

                if $! ~~ X::Cro::HTTP::Error and $!.response.status == 409 and $wait < $retries {
                    ($containerInstanceId, $concurrency) = get-concurrency($token, %parameters<date>);
                    $url = "$server/$instances-path/$containerInstanceId/data/panes/table/$row";
                    trace "set received {$!.response.status} - retrying [{$wait+1}/$retries]", $token;
                } else {
                    die $!;
                }
            }
        }
    }

    method set(:$token is copy, :%parameters) {
        $token = fix-token($token);
        trace "set", $token;
        for %parameters.keys.sort({.split('-', 2)[1]//$_}) -> $key {
            my $value =  %parameters{$key};
            unless $key ~~ / ^ <alpha> <[\w-]>+ $ / {
                trace "  $key: $value [ERROR BAD KEY]", $token;
                return 406;
            }
            trace "  $key: $value", $token if $value;
        }

        my $filler = %parameters<filler> // -1;
        my %content;
        if (%parameters<rowCount>) {
            for ^%parameters<rowCount> -> $row {
                next if $row == $filler;
                my %result = set(%parameters, $row, $token);
                if %result {
                    %parameters<concurrency> = %result<concurrency>;
                    %content = %result;
                }
            }
            if $token eq "demo" {
                set-demo-filler(%parameters);
            } elsif set-filler(%content, %parameters, $filler) {
                my %result = set(%parameters, $filler, $token);
                if %result {
                    %parameters<concurrency> = %result<concurrency>;
                    %content = %result;
                }
            }
        }

        my %employee = get-session($token);
        %content = get-cache(%employee<number>);
        %content<currentWeek> = %parameters<date>;
        %content<employeeName> //= %employee<name>;
        show-week($token, %content);

        return;

        CATCH {
            when X::Cro::HTTP::Error {
                if .response.status == 401 {
                    return Micronomy.get-login(reason => "Vänligen logga in!");
                } else {
                    error $_, $token;
                    %parameters<concurrency>:delete;
                    %content = get-week($token, %parameters<date>, previous => %parameters) unless %content;
                    show-week($token, %content, error => "{$_.response.status} - servern tillät inte uppdateringen");
                }
            }
            default {
                error $_, $token;
                %parameters<concurrency>:delete;
                %content = get-week($token, %parameters<date>, previous => %parameters) unless %content;
                show-week($token, %content, error => "okänt fel");
            }
        }
    }

    method submit(:%parameters, :$token is copy) {
        $token = fix-token($token);
        trace "submit %parameters<date>", $token;
        for %parameters.keys.sort({.split('-', 2)[1]//$_}) -> $key {
            my $value =  %parameters{$key};
            trace "  $key: $value", $token if $value;
        }

        my %content;
        if $token ne "demo" {
            my $reason = %parameters<reason>;
            my $containerInstanceId = %parameters<containerInstanceId>;
            my $concurrency = %parameters<concurrency>;
            my $url = "$server/$instances-path/$containerInstanceId/data/panes/card/0/action;name=submittimesheet";
            $url ~= "?card.resubmissionexplanationvar=$reason" if $reason;
            trace "submit $url", $token;
            my $response = call-url(
                $url,
                headers => {
                    Authorization => "X-Reconnect $token",
                    Content-Type => "application/json",
                    Maconomy-Concurrency-Control => $concurrency,
                    Content-Length => 0,
                },
            );

            %content = parse-week($response);
        } else {
            %content = get-demo(%parameters<date>);
        }
        show-week($token, %content);

        CATCH {
            when X::Cro::HTTP::Error {
                my $body = await .response.body;
                warn "error: [" ~ .response.status ~ "]:\n    " ~ $body.join("\n    ");
                error $_, $token;
                if .response.status == 401 {
                    Micronomy.get-login(reason => "Vänligen logga in!");
                } else {
                    %content = get-week($token, %parameters<date>);
                    show-week($token, %content, error => $body<errorMessage>);
                }
            }
            default {
                error $_, $token;
                %content = get-week($token, %parameters<date>);
                show-week($token, %content, error => 'okänt fel');
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
                   http-only => True,
                   expires => DateTime.now(),
                  );
        header "X-Frame-Options: DENY";
        template 'login.html.tmpl', %data;
        trace "sent login page";
        return {};
    }

    method login(:$username = '', :$password) {
        my ($token, $status);
        if $username and $password {
            trace "login $username ***";
            if $username eq $password eq "demo" {
                $token = "demo";
            } else {
                my $url = "$server/$auth-path";
                for 0..$retries -> $wait {
                    sleep $wait/10;

                    my $response = call-url(
                        $url,
                        timeout => 3,
                        auth => {
                            username => $username,
                            password => $password
                        },
                        headers => {
                            Maconomy-Authentication => 'X-Reconnect',
                        },
                    );

                    $token = get-header($response, 'maconomy-reconnect');
                    trace "logged in $username", $token;
                    last;

                    CATCH {
                        when X::Cro::HTTP::Error {
                            my $error = (await .response.body)<errorMessage>;
                            $error = $error ?? '[' ~ .response.status ~ '] ' ~ $error !! .message();
                            $status = uri_encode_component($error);

                            if $status eq "[401] An internal error occurred." and $wait < 9 {
                                trace "login received '$status' - retrying [{$wait+1}/9]", $token;
                                next;
                            } elsif .response.status == 401 {
                                return Micronomy.get-login(reason => "fel användarnamn eller lösenord");
                            } elsif .response.status == 500 {
                                trace "login failed '$status' - restarting", $token;
                                Micronomy.get-login(reason => "$status - försök igen om ett tag");
                                sleep 2;
                                exit 1;
                            } else {
                                return Micronomy.get-login(reason => "$status");
                            }
                        }
                        default {
                            error $_, $token;
                            trace "login failed - restarting", $token;
                            Micronomy.get-login(reason => "okänt fel - försök igen om ett tag");
                            sleep 2;
                            exit 1;
                        }
                    }
                }
            }
        }

        if $token {
            if $token eq "demo" {
                cache-session("demo", "demo", "Nils Nilsson");
            } else {
                my $url = "$server/$environment-path=user.employeeinfo.name1,user.info.employeenumber";
                my $response = call-url(
                    $url,
                    headers => {
                        Authorization => "X-Reconnect $token",
                        Content-Type => "application/json",
                    },
                );
                my %content = await $response.body;
                my $employeeName = %content<user><employeeinfo><name1><string><value>;
                my $employeeNumber = %content<user><info><employeenumber><string><value>;
                cache-session($token, $employeeNumber, $employeeName);
            }

            set-cookie("sessionToken", $token,
                       same-site => Cro::HTTP::Cookie::SameSite::Strict,
                       http-only => True,
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

    method logout(:$token is copy) {
        $token = fix-token($token);
        trace "logout", $token;
        uncache-session($token);
        my $status;
        if $token and $token ne "demo" {
            my $url = "$server/$auth-path";
            my $response = call-url(
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
                   http-only => True,
                   expires => DateTime.now(),
                  );
        redirect "/login?reason=Utloggad!", :see-other;
    }

    method calendar(:$date,:$token is copy,) {
        if $date.Str.chars != 4 { #if date is not given provided "correctly" or if loading first page.
            trace "no calendar set date: ", $date;
            header "X-Frame-Options: DENY";
            template 'calendar.html.tmpl', {
                ics => "",
                date => "",
            }
        } else { #if we have four characters not safe but working future fix.
            trace "getting calendar ", $date;
            my $datestring = $date.Str ~"-01-01";
            my $querydate = Date.new($datestring);
            my $data = calendargenerator($querydate);
            header "X-Frame-Options: DENY";
            template 'calendar.html.tmpl', {
                ics => $data,
                date => $querydate.year,
            }
        }
    }
}
