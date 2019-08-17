use Cro::HTTP::Router;
use Cro::HTTP::Client;
use Cro::WebApp::Template;
use URI::Encode;
use JSON::Fast;

class Micronomy {
    my $server = "https://b3iaccess.deltekenterprise.com";
    my $registration = "containers/v1/b3/timeregistration/data;any";
    my @days = <Mån Tis Ons Tor Fre Lör Sön>;

    sub show($token, %content) {
        my %card = %content<panes><card><records>[0]<data>;
        my %meta = %content<panes><card><records>[0]<meta>;
        my %table = %content<panes><table>;

        my $state = 'Öppen';
        $state = 'Avlämnad' if %table<records>[0]<data><submitted>;
        $state = 'Godkänd' if %card<approvedvar>;
        my $periodStart = Date.new(%table<records>[0]<data><periodstart>);
        my $previous = $periodStart.earlier(days => 1);
        my $next = $periodStart.later(days => 7);
        $next = $next.truncated-to('month') if $periodStart.month != $next.month;

        my $week = %card<weeknumbervar>;
        if $periodStart.day-of-week != 1 {
            $week ~= 'B';
        } elsif $periodStart.month != $periodStart.later(days => 6).month {
            $week ~= 'A';
        }

        my %data = (
            week => $week,
            state => $state,
            next => $next,
            previous => $previous,
            card => %card,
            meta => %meta,
            table => %table,
            days => @days,
        );

        for 1..7 -> $day {
            my $shortDate = substr(%card{"dateday{$day}var"}, 5);
            %data<dates>.push($shortDate);
            %data<total>.push(%card{"totalnumberday{$day}var"});
            %data<fixed>.push(%card{"fixednumberday{$day}var"});
            %data<overtime>.push(%card{"overtimenumberday{$day}var"});
            %data<invoiceable>.push(%card{"invoiceabletimeday{$day}var"});
        }

        my @rows;
        for ^%table<meta><rowCount> -> $row {
            my $status = %table<records>[$row]<data><approvalstatus>;
            $status = "" if $status eq "nil";
            my %row = (
                number => $row,
                title => title($row, %table),
                concurrency => %table<records>[$row]<meta><concurrencyControl>,
                weektotal => %table<records>[$row]<data><weektotal>,
                status => $status,
            );
            my @days;
            for 1..7 -> $day {
                @days.push(
                    {
                        number => $day,
                        hours => %table<records>[$row]<data>{"numberday{$day}"},
                    }
                );
            }
            %row<days> = @days;
            @rows.push(%row);
        }
        %data<rows> = @rows;

        template 'resources/templates/timesheet.html.tmpl', %data;
    }

    sub title(Int $row, %table --> Str) {
        my %row = %table<records>[$row]<data>;
        my $title = %row<entrytext>;
        my $len = chars $title;
        $title ~= ' / ' ~ %row<jobnamevar>;
    }

    sub get($token, $date is copy) {
        $date ||= DateTime.now.earlier(hours => 12).yyyy-mm-dd;
        my $uri = "$server/$registration?card.datevar=$date";

        if $date ~~ / '.json' $/ {
            # offline
            $date = %*ENV<HOME> ~ "/micronomy/micronomy-$date" unless $date.IO.e;
            return from-json slurp $date;
        }

        my $resp = await Cro::HTTP::Client.get(
            $uri,
            headers => {
                Authorization => "X-Reconnect $token",
            },
        );

        return await $resp.body;

        #CATCH {
        #    when X::Cro::HTTP::Error {
        #        my $error = (await .response.body)<errorMessage>;
        #        $error = $error ?? '[' ~ .response.status ~ '] ' ~ $error !! .message();
        #        my $status = uri_encode_component($error);
        #    }
        #}
    }

    method get(:$token, :$date) {
        my %content = get($token, $date);
        show($token, %content);
    }

    method set(:$token, :%parameters) {
        my %content;
        for 0..* -> $row {
            last unless %parameters{"concurrency-$row"};
            my @changes;
            for 1..7 -> $day  {
                if %parameters{"hours-$row-$day"} ne %parameters{"hidden-$row-$day"} {
                    @changes.push("\"numberday$day\": " ~ (%parameters{"hours-$row-$day"} || 0));
                }
            }
            if @changes {
                my $concurrency = %parameters{"concurrency-$row"};
                my $uri = "$server/$registration/table/$row?card.datevar=%parameters<date>";
                my $response = await Cro::HTTP::Client.post(
                    $uri,
                    headers => {
                        Authorization => "X-Reconnect $token",
                        Content-Type => "application/json",
                        Accept => "application/json",
                        Maconomy-Concurrency-Control => $concurrency,
                    },
                    body => '{"data":{' ~ @changes.join(", ") ~ '}}',
                );
                %content = await $response.body;
            }
        }

        %content ||= get($token, %parameters<date>);
        show($token, %content);
    }

    method submit(:$token, :$date, :$reason) {...}

    method get-login(:$username, :$reason) {
        my %data = (
            username => $username,
            reason => $reason,
        );
        template 'resources/templates/login.html.tmpl', %data;
    }

    method login(:$username, :$password) {
        my ($token, $status);
        if $username and $password {
            my $uri = "$server/containers/v1/b3/api_currentemployee/data;any";
            my $resp = await Cro::HTTP::Client.get(
                $uri,
                auth => {
                    username => $username,
                    password => $password
                },
                headers => {
                    Maconomy-Authentication => 'X-Reconnect',
                },
            );

            my @headers = $resp.headers;
            for @headers -> $header {
                next if $header.name ne 'Maconomy-Reconnect';
                $token = $header.value;
                last;
            }

            CATCH {
                when X::Cro::HTTP::Error {
                    my $error = (await .response.body)<errorMessage>;
                    $error = $error ?? '[' ~ .response.status ~ '] ' ~ $error !! .message();
                    $status = uri_encode_component($error);
                }
            }
        }
        if $token {
            set-cookie "sessionToken", $token;
            redirect "/", :see-other;
        } else {
            $status //= '';
            redirect "/login?username=$username&reason=$status", :see-other;
        }
    }

    method logout(:$username, :$token) {
        my $status;
        if $token {
            my $uri = "$server/containers/v1/b3/api_currentemployee/data;any";
            my $resp = await Cro::HTTP::Client.get(
                $uri,
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
        set-cookie "sessionToken", "";
        redirect "/login?username=$username&reason=Logged%20out", :see-other;
    }
}
