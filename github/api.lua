local config = require 'github.config'

local M = {}

local USER_AGENT = 'lazycmd-github-plugin'
local API_VERSION = '2022-11-28'
local CACHE_NAMESPACE = 'github.api'

local session = {
  viewer = nil,
  users = {},
  repos = {},
  readmes = {},
  languages = {},
  contents = {},
}

local viewer_promise = nil

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

local function request(opts)
  opts = opts or {}
  local token = M.get_token()
  return Promise.new(function(resolve, reject)
    if opts.auth_required and (not token or token == '') then
      reject('GitHub token not configured')
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
        reject(request_error(response))
        return
      end

      if opts.raw then
        resolve({
          data = response.body or '',
          response = response,
        })
        return
      end

      local ok, data = pcall(lc.json.decode, response.body or '')
      if not ok then
        reject('Failed to decode GitHub API response')
        return
      end

      resolve({
        data = data,
        response = response,
      })
    end)
  end)
end

local function encode_path_segment(value) return lc.url.encode(tostring(value or '')) end

local function cache_key(parts) return table.concat(parts, '::') end

local function cache_get(key)
  local ok, value = pcall(lc.cache.get, CACHE_NAMESPACE, key)
  if ok then return value end
  return nil
end

local function cache_set(key, value, ttl)
  pcall(lc.cache.set, CACHE_NAMESPACE, key, value, { ttl = ttl })
end

local function cache_ttl(name)
  local ttl = (((config.get() or {}).cache_ttl or {})[name])
  ttl = tonumber(ttl)
  return ttl and ttl >= 0 and ttl or 0
end

local function remember(key, ttl, producer)
  local cached = cache_get(key)
  if cached ~= nil then return Promise.resolve(cached) end

  return producer():next(function(value)
    cache_set(key, value, ttl)
    return value
  end)
end

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
  session.contents = {}
  viewer_promise = nil
end

local function encode_path(value)
  local raw = tostring(value or '')
  if raw == '' then return '' end

  local parts = {}
  for part in raw:gmatch '[^/]+' do
    table.insert(parts, encode_path_segment(part))
  end
  return table.concat(parts, '/')
end

local function ensure_viewer_promise()
  if session.viewer then return Promise.resolve(session.viewer) end

  if viewer_promise then return viewer_promise end

  viewer_promise = remember(cache_key { 'viewer' }, cache_ttl 'viewer', function()
    return request({
      path = '/user',
      auth_required = true,
    }):next(function(payload) return payload.data end)
  end):next(function(data)
    session.viewer = data
    if data and data.login then session.users[tostring(data.login)] = data end
    return data
  end, function(err)
    viewer_promise = nil
    return Promise.reject(err)
  end)

  return viewer_promise
end

function M.prime_viewer()
  if not M.is_authenticated() then return Promise.resolve(nil) end
  return ensure_viewer_promise()
end

function M.get_viewer() return ensure_viewer_promise() end

function M.get_user(username)
  username = trim(username)
  if username == '' then return Promise.reject('Username is required') end

  if session.users[username] then return Promise.resolve(session.users[username]) end

  return remember(cache_key { 'user', username }, cache_ttl 'user', function()
    return request({
      path = '/users/' .. encode_path_segment(username),
    }):next(function(payload) return payload.data end)
  end):next(function(data)
    session.users[username] = data
    return data
  end)
end

function M.list_following(page)
  return remember(cache_key { 'following', tostring(page or 1), tostring(config.get().per_page) }, cache_ttl 'following', function()
    return request({
      path = '/user/following' .. paged_suffix(page),
      auth_required = true,
    }):next(function(payload)
      return {
        items = payload.data or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end)
end

function M.list_notifications(page)
  return remember(cache_key { 'notifications', tostring(page or 1), tostring(config.get().per_page) }, cache_ttl 'notifications', function()
    return request({
      path = '/notifications' .. paged_suffix(page, { 'all=false', 'participating=false' }),
      auth_required = true,
    }):next(function(payload)
      return {
        items = payload.data or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end)
end

function M.list_starred(page)
  return remember(cache_key { 'starred', tostring(page or 1), tostring(config.get().per_page) }, cache_ttl 'starred', function()
    return request({
      path = '/user/starred' .. paged_suffix(page, { 'sort=created', 'direction=desc' }),
      auth_required = true,
    }):next(function(payload)
      return {
        items = payload.data or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end)
end

function M.list_user_repos(username, page)
  username = trim(username)
  if username == '' then return Promise.reject('Username is required') end

  local path = '/users/' .. encode_path_segment(username) .. '/repos'
  local extra = { 'sort=updated', 'direction=desc', 'type=owner' }
  local cache_mode = 'user'

  if M.is_authenticated() then
    return M.get_viewer():next(function(viewer)
      if viewer and viewer.login == username then
        path = '/user/repos'
        extra = { 'sort=updated', 'direction=desc', 'affiliation=owner' }
        cache_mode = 'viewer'
      end

      return remember(cache_key {
        'user_repos',
        cache_mode,
        username,
        tostring(page or 1),
        tostring(config.get().per_page),
      }, cache_ttl 'user_repos', function()
        return request({
          path = path .. paged_suffix(page, extra),
        }):next(function(payload)
          return {
            items = payload.data or {},
            has_next = has_next_page(payload.response and payload.response.headers),
          }
        end)
      end):next(function(payload)
        for _, repo in ipairs(payload.items or {}) do
          if repo and repo.full_name then session.repos[tostring(repo.full_name)] = repo end
        end
        return payload
      end)
    end)
  end

  return remember(cache_key {
    'user_repos',
    cache_mode,
    username,
    tostring(page or 1),
    tostring(config.get().per_page),
  }, cache_ttl 'user_repos', function()
    return request({
      path = path .. paged_suffix(page, extra),
    }):next(function(payload)
      return {
        items = payload.data or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end):next(function(payload)
    for _, repo in ipairs(payload.items or {}) do
      if repo and repo.full_name then session.repos[tostring(repo.full_name)] = repo end
    end
    return payload
  end)
end

function M.search_repositories(query, page)
  query = trim(query)
  if query == '' then return Promise.resolve({ items = {}, has_next = false }) end

  return remember(cache_key {
    'search_repositories',
    query,
    tostring(page or 1),
    tostring(config.get().per_page),
  }, cache_ttl 'search_repositories', function()
    return request({
      path = '/search/repositories' .. paged_suffix(page, {
        'q=' .. lc.url.encode(query),
      }),
    }):next(function(payload)
      return {
        items = type(payload.data) == 'table' and payload.data.items or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end):next(function(payload)
    local items = payload.items or {}
    for _, repo in ipairs(items or {}) do
      if repo and repo.full_name then session.repos[tostring(repo.full_name)] = repo end
    end
    return payload
  end)
end

function M.search_users(query, page)
  query = trim(query)
  if query == '' then return Promise.resolve({ items = {}, has_next = false }) end

  return remember(cache_key {
    'search_users',
    query,
    tostring(page or 1),
    tostring(config.get().per_page),
  }, cache_ttl 'search_users', function()
    return request({
      path = '/search/users' .. paged_suffix(page, {
        'q=' .. lc.url.encode(query),
        'sort=followers',
        'order=desc',
      }),
    }):next(function(payload)
      return {
        items = type(payload.data) == 'table' and payload.data.items or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end):next(function(payload)
    local items = payload.items or {}
    for _, user in ipairs(items or {}) do
      if user and user.login then session.users[tostring(user.login)] = user end
    end
    return payload
  end)
end

local function search_repo_items(owner, repo, query, item_kind, page, cache_name)
  owner = trim(owner)
  repo = trim(repo)
  query = trim(query)

  if owner == '' or repo == '' then return Promise.reject('Repository path is required') end
  if query == '' then return Promise.resolve({ items = {}, has_next = false }) end

  local qualified_query = string.format('repo:%s/%s is:%s %s', owner, repo, item_kind, query)

  return remember(cache_key {
    cache_name,
    owner,
    repo,
    query,
    tostring(page or 1),
    tostring(config.get().per_page),
  }, cache_ttl(cache_name), function()
    return request({
      path = '/search/issues' .. paged_suffix(page, {
        'q=' .. lc.url.encode(qualified_query),
      }),
    }):next(function(payload)
      return {
        items = type(payload.data) == 'table' and payload.data.items or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end)
end

function M.search_repo_issues(owner, repo, query, page)
  return search_repo_items(owner, repo, query, 'issue', page, 'search_repo_issues')
end

function M.search_repo_pulls(owner, repo, query, page)
  return search_repo_items(owner, repo, query, 'pr', page, 'search_repo_pulls')
end

function M.list_repo_branches(owner, repo, page)
  owner = trim(owner)
  repo = trim(repo)

  return remember(cache_key {
    'repo_branches',
    owner,
    repo,
    tostring(page or 1),
    tostring(config.get().per_page),
  }, cache_ttl 'repo_branches', function()
    return request({
      path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/branches'
        .. paged_suffix(page),
    }):next(function(payload)
      return {
        items = payload.data or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end)
end

function M.list_repo_tags(owner, repo, page)
  owner = trim(owner)
  repo = trim(repo)

  return remember(cache_key {
    'repo_tags',
    owner,
    repo,
    tostring(page or 1),
    tostring(config.get().per_page),
  }, cache_ttl 'repo_tags', function()
    return request({
      path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/tags'
        .. paged_suffix(page),
    }):next(function(payload)
      return {
        items = payload.data or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end)
end

function M.get_repo_contents(owner, repo, ref, content_path)
  owner = trim(owner)
  repo = trim(repo)
  ref = trim(ref)
  content_path = trim(content_path or '')

  if owner == '' or repo == '' then return Promise.reject('Repository path is required') end
  if ref == '' then return Promise.reject('Repository ref is required') end

  local cache_id = table.concat({ owner, repo, ref, content_path }, '\x1f')
  if session.contents[cache_id] ~= nil then return Promise.resolve(session.contents[cache_id]) end

  local api_path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/contents'
  if content_path ~= '' then api_path = api_path .. '/' .. encode_path(content_path) end

  return remember(cache_key {
    'repo_contents',
    owner,
    repo,
    ref,
    content_path,
  }, cache_ttl 'repo_contents', function()
    return request({
      path = api_path .. '?ref=' .. lc.url.encode(ref),
    }):next(function(payload)
      local data = payload.data
      if type(data) == 'table' and data.type == 'file' then
        local content = tostring(data.content or '')
        if content ~= '' then
          local ok, decoded = pcall(lc.base64.decode, content:gsub('%s', ''))
          if ok then data.decoded_content = decoded end
        end
      end
      return data
    end)
  end):next(function(data)
    session.contents[cache_id] = data
    return data
  end)
end

function M.get_repo(owner, repo)
  owner = trim(owner)
  repo = trim(repo)
  local full_name = owner .. '/' .. repo

  if session.repos[full_name] then return Promise.resolve(session.repos[full_name]) end

  return remember(cache_key { 'repo', full_name }, cache_ttl 'repo', function()
    return request({
      path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo),
    }):next(function(payload) return payload.data end)
  end):next(function(data)
    session.repos[full_name] = data
    return data
  end)
end

function M.get_repo_languages(owner, repo)
  owner = trim(owner)
  repo = trim(repo)
  local key = owner .. '/' .. repo

  if session.languages[key] ~= nil then return Promise.resolve(session.languages[key]) end

  return remember(cache_key { 'repo_languages', key }, cache_ttl 'repo_languages', function()
    return request({
      path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/languages',
    }):next(function(payload) return payload.data or {} end)
  end):next(function(data)
    session.languages[key] = data or {}
    return session.languages[key]
  end)
end

function M.get_repo_readme(owner, repo)
  owner = trim(owner)
  repo = trim(repo)
  local key = owner .. '/' .. repo

  if session.readmes[key] ~= nil then return Promise.resolve(session.readmes[key]) end

  return remember(cache_key { 'repo_readme', key }, cache_ttl 'repo_readme', function()
    return request({
      path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/readme',
    }):next(function(payload)
      local data = payload.data or {}
      local content = tostring(data and data.content or '')
      if content == '' then
        return ''
      end

      content = content:gsub('%s', '')
      local ok, decoded = pcall(lc.base64.decode, content)
      if not ok then return Promise.reject('Failed to decode README content') end
      return decoded
    end)
  end):next(function(content)
    session.readmes[key] = content
    return content
  end)
end

function M.list_repo_issues(owner, repo, page)
  owner = trim(owner)
  repo = trim(repo)

  return remember(cache_key {
    'repo_issues',
    owner,
    repo,
    tostring(page or 1),
    tostring(config.get().per_page),
  }, cache_ttl 'repo_issues', function()
    return request({
      path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/issues'
        .. paged_suffix(page, { 'state=all' }),
    }):next(function(payload)
      local items = {}
      for _, item in ipairs(payload.data or {}) do
        if not item.pull_request then
          table.insert(items, item)
        end
      end

      return {
        items = items,
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end)
end

function M.list_repo_pulls(owner, repo, page)
  owner = trim(owner)
  repo = trim(repo)

  return remember(cache_key {
    'repo_pulls',
    owner,
    repo,
    tostring(page or 1),
    tostring(config.get().per_page),
  }, cache_ttl 'repo_pulls', function()
    return request({
      path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/pulls'
        .. paged_suffix(page, { 'state=all' }),
    }):next(function(payload)
      return {
        items = payload.data or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end)
end

return M
