-- This script extends wrk2 to handle multiple server addresses
-- as well as multiple paths (endpoints) per server
--
-- Intermediate status output is added in a format suitable for consumption via
-- the Prometheus push gateway

require "socket"

-- NOTE: This script requires a file "endpoints.lua" to be present in CWD.
-- "endpoints.lua" is generated by the wrapper script and contains the list
-- of endpoints to benchmark against. Generating a LUA file and including it
-- here significantly speeds up the thread start-up if many threads/ endpoints
-- are used.

-- load pre-generated array of list of endpoints
require "endpoints"

-----------------
-- main() context

-- main() globals
local threads = {}
local counter = 1

local global_endpoints = {}

function xtract(str, match, default, err_msg)
    local ret, count = string.gsub(str, match, "%1", 1)
    if count == 0 then
        if not default then
            print(string.format("Error parsing URL '%s': %s",str,err_msg))
            os.exit(1)
        end
        ret = default
    end
    return ret
end

function setup(thread)
    -- Fill global threads table with thread handles so done()
    -- can process per-thread data
    table.insert(threads, thread)
    thread:set("id",counter)
    if counter == 1 then
        -- initialise endpoint_addrs here so we don't call (costly)
        -- wrk.lookup() per thread
        local prev_endpoint = {}
        for i,e in pairs(input_endpoints) do
            local proto = xtract(e,
                    "^(http[s]?)://.*", nil, "missing or unsupported  protocol")
            local host  = xtract(
                    e, "^http[s]?://([^/:]+)[:/]?.*", nil, "missing host")

            if proto == "http" then
                def_port=80
            else if proto == "https" then
                    def_port=443
                else
                    print(string.format("Unsupported protocol '%s'",proto))
                    os.exit(1)
                end
            end
            local port  = xtract(e, "^http[s]?://[^/:]+:(%d+).*", def_port)
            local path  = xtract(e, "^http[s]?://[^/]+(/.*)","/")

            -- get IP addr(s) from hostname, validate by connecting
            -- only connect if we did not connect before
            local addr = nil
            if      prev_endpoint[1] == proto
                and prev_endpoint[2] == host
                and prev_endpoint[3]  == port then
                    addr = prev_endpoint[0]
                else
                    for k, v in ipairs(wrk.lookup(host, port)) do
                        if wrk.connect(v) then
                            addr = v
                            break
                        end
                    end
                    if not addr then
                        print(string.format(
                            "Thread %d Error: Failed to connect to %s:%d",
                            counter, host, port))
                        os.exit(2)
                    end
            end

            global_endpoints[i] = {}
            global_endpoints[i][0] = addr
            global_endpoints[i][1] = proto
            global_endpoints[i][2] = host
            global_endpoints[i][3] = port
            global_endpoints[i][4] = string.format(
                                    "GET %s HTTP/1.1\r\nHost:%s:%s\r\n\r\n",
                                                            path, host, port)
            global_endpoints[i][5] = e
            prev_endpoint = global_endpoints[i]
        end
        input_endpoints=nil
        collectgarbage()
    end

    for i, ep in pairs(global_endpoints) do
        thread:set("ep_addr_" .. i, ep[0])
        thread:set("ep_host_" .. i, tostring(ep[2]))
        thread:set("ep_get_req_" .. i, tostring(ep[4]))
        thread:set("ep_url_"  .. i, tostring(ep[5]))
    end
    counter = counter +1
end

-----------------
-- Thread context

function micro_ts()
    return 1000 * socket.gettime()
end

function prom(mname, value)
    return string.format(
                   "wrk2_benchmark_%s{thread=\"thread-%s\"} %f\n",mname,id,value)
end

function busysleep(microseconds)
    -- no sleep() or delay() in lua
    s = micro_ts()
    n = s
    while s + microseconds > n do
        n = micro_ts()
    end
end

function write_metrics(req, resp, avg, curr, avg_reconn, curr_reconn)
    w = prom("requests", req) .. prom("responses", resp) 
    w = w .. prom("average_rps", avg) .. prom("current_rps", curr)
    w = w .. prom("average_tcp_reconnect_rate", avg_reconn)
    w = w .. prom("run_average_tcp_reconnect_rate", avg_reconn)
    w = w .. prom("current_tcp_reconnect_rate", curr_reconn)
    f=io.open(string.format("thread-%d_seq-%d.txt", id, write_iter), "w+")
    f:write(w)
    f:flush()
    f:close()
    write_iter = write_iter + 1
end

function init(args)
    -- Thread globals used by done()
    url_call_count = ""

    -- URL list variables
    --   Thread globals used by request(), response()
    idx = 0
    endpoints = {}

    -- reporting variables
    report_every=1 --seconds
    responses=0
    requests=0
    reconnects=0
    reconnects=0
    prev_reconnects=0
    start_msec = nil
    prev_call_count = 0
    print_report=0

    -- parse command line URLs and prepare requests
    local prev_srv = {}
    for i,e in pairs(input_endpoints) do

        -- store the endpoint
        endpoints[i] = {}
        endpoints[i][0] = _G["ep_addr_" .. i]
        endpoints[i][1] = _G["ep_host_" .. i]
        endpoints[i][2] = _G["ep_url_"  .. i]
        endpoints[i][3] = _G["ep_get_req_"  .. i]
        endpoints[i][4] = 0
        endpoints[i][5] = e
    end

    input_endpoints=nil
    collectgarbage()

    -- initialize idx, assign req and addr
    idx = 0
    wrk.thread.addr = endpoints[idx][0]

    -- write first metric - all 0, to reset counters
    write_iter = 0
    write_metrics(0,0,0,0,0,0)
end

function request()
    if nil == start_msec then
        start_msec = micro_ts()
        prev_msec = start_msec
    end
    local ret = endpoints[idx][3]
    requests = requests + 1
    return ret
end

function response(status, headers)
    -- Pick the next endpoint in the list of endpoints, for the next request
    -- Also, update the thread's remote server addr if endpoint
    -- is on a different server.

    local prev_srv = endpoints[idx][1]
    endpoints[idx][4] = endpoints[idx][4] + 1
    idx = (idx + 1) % (#endpoints + 1)

    if prev_srv ~= endpoints[idx][1] then
        -- Re-setting the thread's server address forces a reconnect
        wrk.thread.addr = endpoints[idx][0]
        reconnects = reconnects + 1
    end

    -- write out report and update callend endpoints string in configured
    -- interval
    responses = responses + 1
    local now_msec = micro_ts()
    if (now_msec - prev_msec) > report_every * 1000 then
        local diff_msec = now_msec - prev_msec
        local sdiff_msec = now_msec - start_msec

        write_metrics(requests, responses,
                      responses / (sdiff_msec / 1000),
                      (responses - prev_call_count) / (diff_msec / 1000),
                      reconnects / (sdiff_msec / 1000),
                      (reconnects-prev_reconnects) / (diff_msec / 1000))

        prev_reconnects = reconnects
        prev_msec = now_msec
        prev_call_count = responses
        collectgarbage()
   end
end


function teardown()
    local now_msec = micro_ts()
    local called_arr = {}

    local diff_msec = now_msec - prev_msec
    local sdiff_msec = now_msec - start_msec

    write_metrics(requests, responses,
                  responses / (sdiff_msec / 1000),
                  (responses - prev_call_count) / (diff_msec / 1000),
                  reconnects / (sdiff_msec / 1000),
                  (reconnects-prev_reconnects) / (diff_msec / 1000))

    for i=0, #endpoints, 1 do
        called_arr[i+1] = endpoints[i][5] .. " " .. endpoints[i][4]
    end
    url_call_count = table.concat(called_arr, ";")
end

-----------------
-- main() context

function done(summary, latency, requests)
    print(string.format("Total Requests: %d", summary.requests))
    print(string.format("HTTP errors: %d", summary.errors.status))
    print(string.format("Requests timed out: %d", summary.errors.timeout)) 
    print(string.format("Bytes received: %d", summary.bytes))
    print(string.format("Socket connect errors: %d", summary.errors.connect))
    print(string.format("Socket read errors: %d", summary.errors.read))
    print(string.format("Socket write errors: %d", summary.errors.write))

    -- extract individual URL call counts from threads, sum up
    local t = unpack(threads,1,2)
    local urls = {}

    for i, t in ipairs(threads) do
        local url_call_count = t:get("url_call_count")
        for entry in string.gmatch(url_call_count, "([^;]+)") do
            local url = string.match(entry,"^([^ ]+) .*")
            local count = string.match(entry,".* ([^ ]+)")
            if urls[url] then
                urls[url] = urls[url] + count
            else
                urls[url] = count
            end
        end
    end

    print("\nURL call count")
    for url, count in pairs(urls) do
        print(string.format("%s : %d", url, count))
    end
end
