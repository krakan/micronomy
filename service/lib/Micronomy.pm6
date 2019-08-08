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
        my $prev = $periodStart.earlier(days => 1);
        my $next = $periodStart.later(days => 7);
        $next = $next.truncated-to('month') if $periodStart.month != $next.month;

        my $response = qq:to/HTML/;
        <html>
          <body>
            <h1>micronomy @ B3</h1>
            <h2>
              %card<employeenamevar>,
              vecka %card<weeknumbervar>,
              $state
            </h2>
            <form action="/" method="POST">
              <input type="submit" name="date" value="$prev">
              <input type="submit" name="date" value="$next">
            </form>
            <div class="days">
        HTML

        for @days -> $day {
            $response ~= qq:to/HTML/;
                  <div>{$day}</div>
            HTML
        }

        $response ~= qq:to/HTML/;
            </div>
            <div class="dates">
        HTML

        for 1..7 -> $day {
            my $shortDate = substr(%card{"dateday{$day}var"}, 5);
            $response ~= qq:to/HTML/;
                    <div>{$shortDate}</div>
            HTML
        }

        $response ~= qq:to/HTML/;
            </div>
            <form action='/' method='POST'>
              <input type='hidden' name='concurrency' value='%meta<concurrencyControl>' />
              <input type='hidden' name='date' value='%card<datevar>' />
        HTML

        for ^%table<meta><rowCount> -> $row {
            my $title = title($row, %table);
            $response ~= qq:to/HTML/;
                  <div class='row'>
                    <div class='title'>{$title}</div>
                    <input type='hidden' name='concurrency-{$row}' value='%table<records>[$row]<meta><concurrencyControl>' />
            HTML
            for 1..7 -> $day {
                $response ~= qq:to/HTML/;
                        <input type='hidden' name='hidden-{$row}-{$day}' value='%table<records>[$row]<data>{"numberday{$day}"}' />
                        <input class='hours' type='text' size='2' name='hours-{$row}-{$day}' value='%table<records>[$row]<data>{"numberday{$day}"}' />
                HTML
            }
            $response ~= qq:to/HTML/;
                  </div>
            HTML
        }

        $response ~= qq:to/HTML/;
              <input class='submit' type='submit' value='Spara' />
            </form>
          </body>
        </html>
        HTML

        content 'text/html', $response;
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
        my @responses;
        for 0..* -> $row {
            last unless %parameters{"concurrency-$row"};
            my @changes;
            for 1..7 -> $day  {
                if %parameters{"hours-$row-$day"} ne %parameters{"hidden-$row-$day"} {
                    @changes.push("\"numberday$day\": " ~ %parameters{"hours-$row-$day"});
                }
            }
            if @changes {
                my $uri = "$server/$registration/table/$row?card.datevar=%parameters<date>";
                my $response = await Cro::HTTP::Client.post(
                    $uri,
                    headers => {
                        Authorization => "X-Reconnect $token",
                        Content-Type => "application/json",
                        Accept => "application/json",
                        Maconomy-Concurrency-Control => %parameters{"concurrency-$row"},
                    },
                    body => '{"data":{' ~ @changes.join(", ") ~ '}}',
                );
                @responses.push($response);
            }
        }

        my %content;
        for @responses -> $response {
            %content = await $response.body;
        }
         %content ||= get($token, %parameters<date>);

         show($token, %content);
    }

    method submit(:$token, :$date, :$reason) {...}

    method get-login(:$username, :$reason) {
        my $message = $reason ?? "<div class='message'>{$reason}</div>\n" !! "";

        content 'text/html', $message ~ qq:to/HTML/;
          <form method="POST" action="/login">
            <div>
              Username: <input type="text" name="username" value="$username" />
            </div>
            <div>
              Password: <input type="password" name="password" />
            </div>
            <input type="submit" value="Log In" />
          </form>
          HTML
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
