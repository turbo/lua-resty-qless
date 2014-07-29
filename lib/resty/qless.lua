local ffi = require "ffi"
local redis_mod = require "resty.redis"
local cjson = require "cjson"

local qless_luascript = require "resty.qless.luascript"
local qless_queue = require "resty.qless.queue"
local qless_job = require "resty.qless.job"
local qless_recurring_job = require "resty.qless.recurring_job"

local ngx_var = ngx.var
local ngx_now = ngx.now
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_worker_pid = ngx.worker.pid
local math_floor = math.floor
local ffi_cdef = ffi.cdef
local ffi_new = ffi.new
local ffi_string = ffi.string
local C = ffi.C
local cjson_encode = cjson.encode
local cjson_decode = cjson.decode
local tbl_insert = table.insert
local tbl_concat = table.concat
local str_sub = string.sub
local str_len = string.len


ffi_cdef[[
typedef unsigned char u_char;
u_char * ngx_hex_dump(u_char *dst, const u_char *src, size_t len);
int RAND_pseudo_bytes(u_char *buf, int num);
int gethostname (char *name, size_t size);
]]


local function random_hex(len)
    local len = math_floor(len / 2)

    local bytes = ffi_new("uint8_t[?]", len)
    C.RAND_pseudo_bytes(bytes, len)
    if not bytes then
        ngx_log(ngx_ERR, "error getting random bytes via FFI")
        return nil
    end

    local hex = ffi_new("uint8_t[?]", len * 2)
    C.ngx_hex_dump(hex, bytes, len)
    return ffi_string(hex, len * 2)
end


local function gethostname()
    local name = ffi_new("char[?]", 255)
    C.gethostname(name, 255)
    return ffi_string(name)
end


local DEFAULT_REDIS_PARAMS = {
    redis = nil, -- Used for passing an already established connection
    host = "127.0.0.1",
    port = 6379,
    connect_timeout = 100,
    read_timeout = 5000,
    keepalive_timeout = nil,
    keepalive_poolsize = nil,
}


local function redis_connect(params)
    local redis = redis_mod:new()
    redis:set_timeout(params.connect_timeout)
    local ok, err = redis:connect(params.host, params.port)
    if not ok then
        ngx_log(ngx_ERR, err)
        return nil, err
    else
        redis:select(params.database)
        redis:set_timeout(params.read_timeout)
        return redis
    end
end


-- Jobs, to be accessed via qless.jobs.
local _jobs = {}
local _jobs_mt = { __index = _jobs }


function _jobs.new(client)
    return setmetatable({
        client = client,
    }, _jobs_mt)
end


function _jobs.complete(self, offset, count)
    self.client:call("jobs", "complete", offset or 0, count or 25)
end


function _jobs.tracked(self)
    local res = self.client:call("track")
    res = cjson_decode(res)

    local tracked_jobs = {}
    for k,v in pairs(res.jobs) do
        tracked_jobs[k] = qless_job.new(self.client, v)
    end
    res.jobs = tracked_jobs
    return res
end


function _jobs.tagged(self, tag, offset, count)
    local tagged = self.client:call("tag", "get", tag, offset or 0, count or 25)
    if tagged then
        return cjson_decode(tagged)
    end
end


function _jobs.failed(self, tag, offset, count)
    if not tag then
        local failed = self.client:call("failed")
        return cjson_decode(failed)
    else
        local results = cjson_decode(self.client:call("failed", tag, offset or 0, count or 25))
        results["jobs"] = self:multiget(results["jobs"])
        return results
    end
end


function _jobs.get(self, jid)
    local results = self.client:call("get", jid)
    if results == ngx.null then
        -- Perhaps this jid is a recurring job.
        results = self.client:call("recur.get", jid)
            if results ~= ngx.null then
            return qless_recurring_job.new(self.client, cjson_decode(results))
        end
    else
        return qless_job.new(self.client, cjson_decode(results))
    end
end


function _jobs.multiget(self, ...)
    local res = self.client:call("multiget", ...)
    res = cjson_decode(res)
    local jobs = {}
    for _,data in ipairs(res) do
        tbl_insert(jobs, qless_job.new(self.client, data))
    end
    return jobs
end


-- Workers, to be accessed via qless.workers.
local _workers = {}

function _workers.new(client)
    return setmetatable({ 
        client = client,
        counts = _workers.counts,
    }, {
        __index = function(t, k)
            return t.client:call("workers", k)
        end,
    })
end

function _workers.counts(self)
    local res = self.client:call("workers") 
    return cjson_decode(res)
end



-- Queues, to be accessed via qless.queues etc.
local _queues = {}

function _queues.new(client)
    return setmetatable({ 
        client = client,
        counts = _queues.counts,
    }, { 
        __index = function(t, k)
            local q = qless_queue.new(k, t.client)
            rawset(t, k, q)
            return q
        end,
    })
end

function _queues.counts(self)
    local res = self.client:call("queues") 
    return cjson_decode(res)
end


-- Events, to be accessed via qless.events etc.
local _events = {}
local _events_mt = { __index = _events }


function _events.new(params)
    if not params then params = {} end
    setmetatable(params, { __index = DEFAULT_REDIS_PARAMS })

    local redis, err = redis_connect(params)
    if not redis then
        return nil, err
    else
        return setmetatable({
            redis = redis,
        }, _events_mt)
    end
end


function _events.listen(self, events, callback)
    local ql_ns = "ql:"
    for i, ev in ipairs(events) do
        local ok, err = self.redis:subscribe(ql_ns .. ev)
        if not ok then ngx_log(ngx_ERR, err) end
    end

    repeat
        local reply, err = self.redis:read_reply()
        if not reply then
            ngx_log(ngx_ERR, err)
        else
            local channel = str_sub(reply[2], str_len(ql_ns) + 1)
            local message = reply[3]
            callback(channel, message)
        end
    until not reply
end


function _events.stop(self)
    return self.redis:unsubscribe()
end


local _M = {
    _VERSION = '0.01',
}

local mt = { __index = _M }



function _M.new(params)
    if not params then params = {} end
    setmetatable(params, { __index = DEFAULT_REDIS_PARAMS })

    local redis = params.redis
    if not redis then
        redis = redis_mod:new()
        redis:set_timeout(params.connect_timeout)
        local ok, err = redis:connect(params.host, params.port)
        if not ok then
            ngx_log(ngx_ERR, err)
        else
            redis:select(params.database)
            redis:set_timeout(params.read_timeout)
        end
    end

    local self = setmetatable({ 
        redis = redis,
        worker_name = gethostname() .. "-nginx-" .. ngx_worker_pid() .. "-" .. random_hex(4),
        luascript = qless_luascript.new("qless", redis),
    }, mt)

    self.workers = _workers.new(self)
    self.queues = _queues.new(self)
    self.jobs = _jobs.new(self)

    return self
end


function _M.events(params)
    return _events.new(params)
end


function _M.redis_close(self)
    self.redis:set_keepalive() 
end


function _M.generate_jid(self)
    return random_hex(32)
end


function _M.call(self, command, ...)
    local res, err = self.luascript:call(command, ngx_now(), select(1, ...))
    if not res then
        ngx_log(ngx_ERR, err)
    end
    return res, err
end


function _M.config_set(self, k, v)
    return self:call("config.set", k, v)
end


function _M.config_get(self, k)
    return self:call("config.get", k)
end


function _M.config_get_all(self)
    local res, err = self:call("config.get")
    return cjson_decode(res)
end


function _M.config_clear(self, k)
    return self:call("config.unset", k)
end


function _M.track(self, jid)
    return self:call("track", "track", jid)
end


function _M.untrack(self, jid)
    return self:call("track", "untrack", jid)
end


function _M.tags(self, offset, count)
    return cjson_decode(self:call("tag", "top", offset or 0, count or 100))
end


function _M.deregister_workers(self, worker_names)
    return self:call("worker.deregister", unpack(worker_names))
end


function _M.bulk_cancel(self, jids)
    return self:call("cancel", jids)
end


return _M
