local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_sha1_bin = ngx.sha1_bin
local str_gsub = string.gsub
local str_format = string.format
local str_byte = string.byte


local _M = {
    _VERSION = '0.01',
}

local mt = { __index = _M }


-- Load the qless scripts and generate the sha1 digest.
local f = assert(io.open("/home/jhurst/prj/lua-resty-qless/qless-core/qless.lua", "r")) 
local qless_script = f:read("*all")
local qless_script_sha1 = ngx_sha1_bin(qless_script)
local qless_script_sha1_sum = str_gsub(qless_script_sha1, "(.)",
    function (c)
        return str_format("%02x%s", str_byte(c), "")
    end)


function _M.new(name, redis)
    return setmetatable({ 
        name = name, 
        redis = redis,
        sha = qless_script_sha1_sum,
    }, mt)
end


function _M.reload(self)
    self.sha = self.redis:script("load", qless_script)
end


function _M.call(self, ...)
    local res, err = self.redis:evalsha(self.sha, 0, select(1, ...))
    if not res and err == "NOSCRIPT No matching script. Please use EVAL." then
        self:reload()
        res, err = self.redis:evalsha(self.sha, 0, select(1, ...))
    end
    return res, err
end


return _M
