local basic_serializer = require "kong.plugins.http-log-extended.serializer"
local BasePlugin = require "kong.plugins.base_plugin"
local cjson = require "cjson"
local url = require "socket.url"
local inspect = require "inspect"

local HttpLogExtendedHandler = BasePlugin:extend()

HttpLogExtendedHandler.PRIORITY = 4
HttpLogExtendedHandler.VERSION = "1.0"

local HTTP = "http"
local HTTPS = "https"

local function get_request_body()
  ngx.req.read_body()
  return ngx.req.get_body_data()
end 

-- Generates the raw http message.
-- @param `method` http method to be used to send data
-- @param `content_type` the type to set in the header
-- @param `parsed_url` contains the host details
-- @param `body`  Body of the message as a string (must be encoded according to the `content_type` parameter)
-- @return raw http message
local function generate_post_payload(method, parsed_url, body)
  local url
  if parsed_url.query then
    url = parsed_url.path .. "?" .. parsed_url.query
  else
    url = parsed_url.path
  end
  local headers = string.format(
    "%s %s HTTP/1.1\r\nHost: %s\r\nConnection: Keep-Alive\r\nContent-Type: application/json\r\nContent-Length: %s\r\n",
    method:upper(), url, parsed_url.host, #body)

  if parsed_url.userinfo then
    local auth_header = string.format(
      "Authorization: Basic %s\r\n",
      ngx.encode_base64(parsed_url.userinfo)
    )
    headers = headers .. auth_header
  end

  return string.format("%s\r\n%s", headers, body)
end

-- Parse host url.
-- @param `url` host url
-- @return `parsed_url` a table with host details like domain name, port, path etc
local function parse_url(host_url)
  local parsed_url = url.parse(host_url)
  if not parsed_url.port then
    if parsed_url.scheme == HTTP then
      parsed_url.port = 80
     elseif parsed_url.scheme == HTTPS then
      parsed_url.port = 443
     end
  end
  if not parsed_url.path then
    parsed_url.path = "/"
  end
  return parsed_url
end

-- Log to a Http end point.
-- This basically is structured as a timer callback.
-- @param `premature` see openresty ngx.timer.at function
-- @param `conf` plugin configuration table, holds http endpoint details
-- @param `body` raw http body to be logged
-- @param `name` the plugin name (used for logging purposes in case of errors etc.)
local function log(premature, conf, body, name)
  if premature then
    return
  end
  name = "[" .. name .. "] "

  local ok, err
  local parsed_url = parse_url(conf.http_endpoint)
  local host = parsed_url.host
  local port = tonumber(parsed_url.port)

  local sock = ngx.socket.tcp()
  sock:settimeout(conf.timeout)

  ok, err = sock:connect(host, port)
  if not ok then
    ngx.log(ngx.ERR, name .. "failed to connect to " .. host .. ":" .. tostring(port) .. ": ", err)
    return
  end

  if parsed_url.scheme == HTTPS then
    local _, err = sock:sslhandshake(true, host, false)
    if err then
      ngx.log(ngx.ERR, name .. "failed to do SSL handshake with " .. host .. ":" .. tostring(port) .. ": ", err)
    end
  end

  ok, err = sock:send(generate_post_payload("POST", parsed_url, body))
  if not ok then
    ngx.log(ngx.ERR, name .. "failed to send data to " .. host .. ":" .. tostring(port) .. ": ", err)
  end

  ok, err = sock:setkeepalive(conf.keepalive)
  if not ok then
    ngx.log(ngx.ERR, name .. "failed to keepalive to " .. host .. ":" .. tostring(port) .. ": ", err)
    return
  end
end

-- Only provide `name` when deriving from this class. Not when initializing an instance.
function HttpLogExtendedHandler:new()
  HttpLogExtendedHandler.super.new(self, "http-log-extended")
end

function HttpLogExtendedHandler:access(conf) 
  HttpLogExtendedHandler.super.access(self)
  ngx.ctx.http_log_extended = { req_body = "", res_body = "" }
  
  if (conf.log_request_body) then 
    ngx.ctx.http_log_extended = { req_body = get_request_body() }
  end 
end 

function HttpLogExtendedHandler:body_filter(conf) 
  HttpLogExtendedHandler.super.body_filter(self)
  if (conf.log_response_body) then 
    local chunk = ngx.arg[1]
    local ctx = ngx.ctx
    local res_body = ctx.http_log_extended and ctx.http_log_extended.res_body or ""
    res_body = res_body .. (chunk or "")
    if (ctx.http_log_extended) then 
      ctx.http_log_extended.res_body = res_body
    else
      ctx.http_log_extended = { res_body = res_body }
    end 
  end 
end 

-- serializes context data into an html message body.
-- @param `ngx` The context table for the request being logged
-- @param `conf` plugin configuration table, holds http endpoint details
-- @return html body as string
function HttpLogExtendedHandler:serialize(ngx)
  return cjson.encode(basic_serializer.serialize(ngx))
end

function HttpLogExtendedHandler:log(conf)
  HttpLogExtendedHandler.super.log(self)

  local ok, err = ngx.timer.at(0, log, conf, self:serialize(ngx), self._name)
  if not ok then
    ngx.log(ngx.ERR, "[" .. self._name .. "] failed to create timer: ", err)
  end
end

return HttpLogExtendedHandler
