local M = {}

local cfg = {
  base_url = 'https://api.github.com',
  token = nil,
  per_page = 20,
  readme_max_chars = 50000,
  keymap = {
    search = 's',
    open_user = 'u',
    open_in_browser = 'o',
  },
}

function M.setup(opt)
  local global_keymap = lc.config.get().keymap or {}
  cfg = lc.tbl_deep_extend('force', cfg, { keymap = global_keymap }, opt or {})
end

function M.get() return cfg end

return M
