# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 5) + 2;

my $pwd = cwd();

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
$ENV{TEST_REDIS_PORT} ||= 6379;
$ENV{TEST_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;
    init_by_lua '
        cjson = require "cjson"
        redis_params = {
            host = "127.0.0.1",
            port = $ENV{TEST_REDIS_PORT},
            database = $ENV{TEST_REDIS_DATABASE},
        }
    ';

    init_worker_by_lua '
        local subscribe = function(premature)
            if not premature then
                local qless = require "resty.qless"
                local events = qless.events(params)

                events:listen({ "log", "canceled" }, function(channel, message)
                    if channel == "log" then
                        message = cjson.decode(message)
                        ngx.log(ngx.DEBUG, channel, " ", message.event)
                    else
                        ngx.log(ngx.DEBUG, channel, " ", message)
                    end
                end)

                local ok, err = ngx.timer.at(0, subscribe)
                if not ok then ngx.log(ngx.ERR, err) end
            end
        end

        local ok, err = ngx.timer.at(0, subscribe)
        if not ok then ngx.log(ngx.ERR, err) end
    ';
};

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Listen for events
--- http_config eval: $::HttpConfig
--- config
    location = /1 {
        content_by_lua '
            local qless = require "resty.qless"
            local q = qless.new(redis_params)

            local jid = q.queues["queue_19"]:put("testjob")

            q.jobs:get(jid):track()
            q.jobs:get(jid):cancel()
        ';
    }
--- request
GET /1
--- response_body
--- no_error_log
[warn]
[error]
--- error_log eval
["log put",
"log canceled",
"canceled"]
