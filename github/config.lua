local M = {}

local cfg = {
  base_url = 'https://api.github.com',
  token = nil,
  per_page = 20,
  readme_max_chars = 50000,
  code_max_chars = 80000,
  code_max_lines = 1200,
  cache_ttl = {
    viewer = 300,
    user = 1800,
    following = 300,
    notifications = 60,
    starred = 300,
    user_repos = 180,
    search_repositories = 300,
    search_users = 300,
    search_repo_issues = 120,
    search_repo_pulls = 120,
    repo = 900,
    repo_branches = 300,
    repo_tags = 300,
    repo_contents = 300,
    repo_languages = 21600,
    repo_readme = 21600,
    repo_issues = 120,
    repo_pulls = 120,
  },
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
