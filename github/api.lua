local config = require 'github.config'

local M = {}

local USER_AGENT = 'lazycmd-github-plugin'
local API_VERSION = '2022-11-28'

local session = {
  viewer = nil,
  users = {},
  repos = {},
  readmes = {},
  languages = {},
}

local function trim(s)
  s = tostring(s or '')
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function header_value(headers, key)
  headers = headers or {}
  if headers[key] ~= nil then return headers[key] end

  local lower = tostring(key):lower()
  for name, value in pairs(headers) do
    if tostring(name):lower() == lower then return value end
  end

  return nil
end

local function has_next_page(headers)
  local link = tostring(header_value(headers, 'link') or '')
  return link:match 'rel="next"' ~= nil
end

local function request_error(response)
  local fallback = response and response.error or 'Request failed'
  local body = response and response.body or ''
  if body ~= '' then
    local ok, data = pcall(lc.json.decode, body)
    if ok and type(data) == 'table' and data.message and data.message ~= '' then return tostring(data.message) end
  end

  local status = response and response.status or nil
  if status then return 'HTTP ' .. tostring(status) .. ': ' .. tostring(fallback) end
  return tostring(fallback)
end

local function build_headers(extra_headers, include_token)
  local headers = {
    Accept = 'application/vnd.github+json',
    ['User-Agent'] = USER_AGENT,
    ['X-GitHub-Api-Version'] = API_VERSION,
  }

  for key, value in pairs(extra_headers or {}) do
    headers[key] = value
  end

  if include_token then
    local token = M.get_token()
    if token and token ~= '' then headers.Authorization = 'Bearer ' .. token end
  end

  return headers
end

local function request(opts, cb)
  opts = opts or {}
  local token = M.get_token()

  if opts.auth_required and (not token or token == '') then
    cb(nil, 'GitHub token not configured')
    return
  end

  local url = opts.url or (config.get().base_url .. tostring(opts.path or ''))
  lc.http.request({
    url = url,
    method = opts.method or 'GET',
    headers = build_headers(opts.headers, opts.include_token ~= false),
    body = opts.body,
    timeout = opts.timeout or 30000,
  }, function(response)
    if not response or not response.success or (response.status or 0) >= 400 then
      cb(nil, request_error(response), response)
      return
    end

    if opts.raw then
      cb(response.body or '', nil, response)
      return
    end

    local ok, data = pcall(lc.json.decode, response.body or '')
    if not ok then
      cb(nil, 'Failed to decode GitHub API response', response)
      return
    end

    cb(data, nil, response)
  end)
end

local function encode_path_segment(value) return lc.url.encode(tostring(value or '')) end

local function paged_suffix(page, extra)
  local parts = {
    'per_page=' .. tostring(config.get().per_page),
    'page=' .. tostring(page or 1),
  }

  for _, item in ipairs(extra or {}) do
    table.insert(parts, item)
  end

  return '?' .. table.concat(parts, '&')
end

function M.get_token()
  return trim((config.get() or {}).token)
end

function M.is_authenticated()
  local token = M.get_token()
  return token ~= nil and token ~= ''
end

function M.reset()
  session.viewer = nil
  session.users = {}
  session.repos = {}
  session.readmes = {}
  session.languages = {}
end

function M.get_viewer(cb)
  if session.viewer then
    cb(session.viewer, nil)
    return
  end

  request({
    path = '/user',
    auth_required = true,
  }, function(data, err)
    if err then
      cb(nil, err)
      return
    end

    session.viewer = data
    if data and data.login then session.users[tostring(data.login)] = data end
    cb(data, nil)
  end)
end

function M.get_user(username, cb)
  username = trim(username)
  if username == '' then
    cb(nil, 'Username is required')
    return
  end

  if session.users[username] then
    cb(session.users[username], nil)
    return
  end

  request({
    path = '/users/' .. encode_path_segment(username),
  }, function(data, err)
    if err then
      cb(nil, err)
      return
    end

    session.users[username] = data
    cb(data, nil)
  end)
end

function M.list_following(page, cb)
  request({
    path = '/user/following' .. paged_suffix(page),
    auth_required = true,
  }, function(data, err, response)
    if err then
      cb(nil, nil, err)
      return
    end

    cb(data or {}, has_next_page(response and response.headers), nil)
  end)
end

function M.list_notifications(page, cb)
  request({
    path = '/notifications' .. paged_suffix(page, { 'all=false', 'participating=false' }),
    auth_required = true,
  }, function(data, err, response)
    if err then
      cb(nil, nil, err)
      return
    end

    cb(data or {}, has_next_page(response and response.headers), nil)
  end)
end

function M.list_starred(page, cb)
  request({
    path = '/user/starred' .. paged_suffix(page, { 'sort=created', 'direction=desc' }),
    auth_required = true,
  }, function(data, err, response)
    if err then
      cb(nil, nil, err)
      return
    end

    cb(data or {}, has_next_page(response and response.headers), nil)
  end)
end

function M.list_user_repos(username, page, cb)
  username = trim(username)
  if username == '' then
    cb(nil, nil, 'Username is required')
    return
  end

  local path = '/users/' .. encode_path_segment(username) .. '/repos'
  local extra = { 'sort=updated', 'direction=desc', 'type=owner' }

  if M.is_authenticated() then
    M.get_viewer(function(viewer)
      if viewer and viewer.login == username then
        path = '/user/repos'
        extra = { 'sort=updated', 'direction=desc', 'affiliation=owner' }
      end

      request({
        path = path .. paged_suffix(page, extra),
      }, function(data, err, response)
        if err then
          cb(nil, nil, err)
          return
        end

        for _, repo in ipairs(data or {}) do
          if repo and repo.full_name then session.repos[tostring(repo.full_name)] = repo end
        end
        cb(data or {}, has_next_page(response and response.headers), nil)
      end)
    end)
    return
  end

  request({
    path = path .. paged_suffix(page, extra),
  }, function(data, err, response)
    if err then
      cb(nil, nil, err)
      return
    end

    for _, repo in ipairs(data or {}) do
      if repo and repo.full_name then session.repos[tostring(repo.full_name)] = repo end
    end
    cb(data or {}, has_next_page(response and response.headers), nil)
  end)
end

function M.search_repositories(query, page, cb)
  query = trim(query)
  if query == '' then
    cb({}, false, nil)
    return
  end

  request({
    path = '/search/repositories' .. paged_suffix(page, {
      'q=' .. lc.url.encode(query),
    }),
  }, function(data, err, response)
    if err then
      cb(nil, nil, err)
      return
    end

    local items = type(data) == 'table' and data.items or {}
    for _, repo in ipairs(items or {}) do
      if repo and repo.full_name then session.repos[tostring(repo.full_name)] = repo end
    end
    cb(items or {}, has_next_page(response and response.headers), nil)
  end)
end

function M.search_users(query, page, cb)
  query = trim(query)
  if query == '' then
    cb({}, false, nil)
    return
  end

  request({
    path = '/search/users' .. paged_suffix(page, {
      'q=' .. lc.url.encode(query),
      'sort=followers',
      'order=desc',
    }),
  }, function(data, err, response)
    if err then
      cb(nil, nil, err)
      return
    end

    local items = type(data) == 'table' and data.items or {}
    cb(items or {}, has_next_page(response and response.headers), nil)
  end)
end

function M.get_repo(owner, repo, cb)
  owner = trim(owner)
  repo = trim(repo)
  local full_name = owner .. '/' .. repo

  if session.repos[full_name] then
    cb(session.repos[full_name], nil)
    return
  end

  request({
    path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo),
  }, function(data, err)
    if err then
      cb(nil, err)
      return
    end

    session.repos[full_name] = data
    cb(data, nil)
  end)
end

function M.get_repo_languages(owner, repo, cb)
  owner = trim(owner)
  repo = trim(repo)
  local key = owner .. '/' .. repo

  if session.languages[key] ~= nil then
    cb(session.languages[key], nil)
    return
  end

  request({
    path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/languages',
  }, function(data, err)
    if err then
      cb(nil, err)
      return
    end

    session.languages[key] = data or {}
    cb(session.languages[key], nil)
  end)
end

function M.get_repo_readme(owner, repo, cb)
  owner = trim(owner)
  repo = trim(repo)
  local key = owner .. '/' .. repo

  if session.readmes[key] ~= nil then
    cb(session.readmes[key], nil)
    return
  end

  request({
    path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/readme',
  }, function(data, err)
    if err then
      cb(nil, err)
      return
    end

    local content = tostring(data and data.content or '')
    if content == '' then
      session.readmes[key] = ''
      cb('', nil)
      return
    end

    content = content:gsub('%s', '')
    local ok, decoded = pcall(lc.base64.decode, content)
    if not ok then
      cb(nil, 'Failed to decode README content')
      return
    end

    session.readmes[key] = decoded
    cb(decoded, nil)
  end)
end

return M
