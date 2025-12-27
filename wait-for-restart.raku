# Helper service to let Nginx wait for restarts

use Cro::HTTP::Router;
use Cro::HTTP::Log::File;
use Cro::HTTP::Server;

my Cro::Service $http = Cro::HTTP::Server.new(
    http => <1.1>,
    host => "localhost",
    port => 8888,
    application => wait-for-backend(),
    after => [
        Cro::HTTP::Log::File.new(logs => $*OUT, errors => $*ERR)
    ]
);
$http.start;
say "Listening at http://localhost:8888";
react {
    whenever signal(SIGINT) {
        say "Shutting down...";
        $http.stop;
        done;
    }
}

sub wait-for-backend() is export {
    route {
        before {
            my @netstat = <sudo netstat -an>;
            # Wait for main process listening on port 8080
            WAIT: for ^10 -> $i {
                my $netstat = run @netstat, :out;
                for $netstat.out.lines -> $line {
                    if $line ~~ /":8080 " .* " LISTEN" \s* $/ {
                        last WAIT;
                    }
                }
                say "waiting for main process ...";
                sleep 1;
            }
            response.status = 502;
        }
    }
}
