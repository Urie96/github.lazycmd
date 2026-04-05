local api = require 'github.api'
local config = require 'github.config'
local router = require 'github.router'

local M = {}

function M.setup(opt)
  config.setup(opt or {})
  lc.plugin.load 'file'
  api.reset()
  router.reset()
  api.prime_viewer()

  lc.hook.pre_reload(function()
    api.reset()
    router.reset()
    api.prime_viewer()
  end)
end

function M.list(path, cb) router.list(path, cb) end

return M
