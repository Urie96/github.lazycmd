local config = require 'github.config'

local M = {}

local USER_AGENT = 'lazycmd-github-plugin'
local API_VERSION = '2022-11-28'
local CACHE_NAMESPACE = 'github.api'

local session = {
  viewer = nil,
  users = {},
  repos = {},
  issues = {},
  pulls = {},
  discussions = {},
  readmes = {},
  languages = {},
  contents = {},
  trending = nil,
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

local function graphql_request(query, variables)
  return request({
    url = tostring(config.get().base_url or 'https://api.github.com') .. '/graphql',
    method = 'POST',
    auth_required = true,
    body = lc.json.encode({
      query = query,
      variables = variables or {},
    }),
  }):next(function(payload)
    local data = payload.data or {}
    if type(data.errors) == 'table' and #data.errors > 0 then
      local first = data.errors[1] or {}
      return Promise.reject(tostring(first.message or 'GraphQL request failed'))
    end
    return data.data or {}
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
  session.issues = {}
  session.pulls = {}
  session.discussions = {}
  session.readmes = {}
  session.languages = {}
  session.contents = {}
  session.trending = nil
  viewer_promise = nil
end

local function normalize_space(value)
  value = tostring(value or '')
  value = value:gsub('%s+', ' ')
  return trim(value)
end

local function parse_count(value)
  value = tostring(value or ''):gsub(',', '')
  local matched = value:match '(%d+)'
  return tonumber(matched or '') or 0
end

local function fetch_html(url, headers)
  return Promise.new(function(resolve, reject)
    lc.http.request({
      url = url,
      method = 'GET',
      headers = headers or {},
      timeout = 30000,
    }, function(response)
      if not response or not response.success or (response.status or 0) >= 400 then
        reject(request_error(response))
        return
      end
      resolve(response.body or '')
    end)
  end)
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
  return remember(cache_key { 'notifications_v2', tostring(page or 1), tostring(config.get().per_page) }, cache_ttl 'notifications', function()
    return request({
      path = '/notifications' .. paged_suffix(page, { 'all=true', 'participating=false' }),
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
      local items = type(payload.data) == 'table' and payload.data.items or {}
      if item_kind == 'pr' then
        for _, item in ipairs(items) do
          local pr_meta = (item or {}).pull_request or {}
          if item.merged_at == nil and pr_meta.merged_at ~= nil then
            item.merged_at = pr_meta.merged_at
          end
        end
      end
      return {
        items = items,
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

local function parse_trending_repo(article)
  local title_link = article:first 'h2 a'
  local href = title_link and title_link:attr 'href' or ''
  local full_name = normalize_space(title_link and title_link:text() or '')
  full_name = full_name:gsub('%s*/%s*', '/')

  if full_name == '' and href ~= '' then
    full_name = tostring(href):gsub('^/', '')
  end

  local owner, repo = full_name:match '^([^/]+)/(.+)$'
  if not owner or not repo then return nil end

  local description_node = article:first 'p'
  local language_node = article:first '[itemprop="programmingLanguage"]'
  local stars_node = article:first('a[href$="/stargazers"]')
  local forks_node = article:first('a[href$="/forks"]')
  local today_node = article:first 'span.d-inline-block.float-sm-right'

  local description = normalize_space(description_node and description_node:text() or '')
  local language = normalize_space(language_node and language_node:text() or '')
  local stars_today = normalize_space(today_node and today_node:text() or '')

  return {
    owner = {
      login = owner,
    },
    name = repo,
    full_name = full_name,
    html_url = 'https://github.com/' .. owner .. '/' .. repo,
    description = description ~= '' and description or nil,
    language = language ~= '' and language or nil,
    stargazers_count = parse_count(stars_node and stars_node:text() or ''),
    forks_count = parse_count(forks_node and forks_node:text() or ''),
    trending_stars_today = stars_today,
  }
end

function M.list_trending(period)
  period = trim(period)
  if period == '' then period = 'daily' end
  if period ~= 'daily' and period ~= 'weekly' and period ~= 'monthly' then
    return Promise.reject('Unsupported trending period: ' .. tostring(period))
  end

  session.trending = session.trending or {}
  if session.trending[period] then return Promise.resolve(session.trending[period]) end

  return remember(cache_key { 'trending_v3', period, 'any' }, cache_ttl 'trending', function()
    return fetch_html('https://github.com/trending?since=' .. period, {
      Accept = 'text/html,application/xhtml+xml',
      ['User-Agent'] = USER_AGENT,
    }):next(function(body)
      local doc = lc.html.parse(body)
      local articles = (doc:select 'article.Box-row'):to_table()
      local items = {}

      for _, article in ipairs(articles) do
        local item = parse_trending_repo(article)
        if item then table.insert(items, item) end
      end

      return items
    end)
  end):next(function(items)
    session.trending[period] = items or {}
    return session.trending[period]
  end)
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

function M.get_issue(owner, repo, number)
  owner = trim(owner)
  repo = trim(repo)
  number = tostring(number or '')
  local key = table.concat({ owner, repo, number }, '/')

  if session.issues[key] then return Promise.resolve(session.issues[key]) end

  return remember(cache_key { 'issue', key }, cache_ttl 'repo_issues', function()
    return request({
      path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/issues/' .. encode_path_segment(number),
    }):next(function(payload) return payload.data end)
  end):next(function(data)
    session.issues[key] = data
    return data
  end)
end

function M.list_issue_comments(owner, repo, number, page)
  owner = trim(owner)
  repo = trim(repo)
  number = tostring(number or '')

  return remember(cache_key {
    'issue_comments',
    owner,
    repo,
    number,
    tostring(page or 1),
    tostring(config.get().per_page),
  }, cache_ttl 'repo_issues', function()
    return request({
      path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/issues/' .. encode_path_segment(number)
        .. '/comments' .. paged_suffix(page),
    }):next(function(payload)
      return {
        items = payload.data or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end)
end

function M.list_repo_issues(owner, repo, page, state)
  owner = trim(owner)
  repo = trim(repo)
  state = trim(state)

  local qualified_query = string.format('repo:%s/%s is:issue', owner, repo)
  if state ~= '' then qualified_query = qualified_query .. ' state:' .. state end

  return remember(cache_key {
    'repo_issues',
    owner,
    repo,
    state,
    tostring(page or 1),
    tostring(config.get().per_page),
  }, cache_ttl 'repo_issues', function()
    return request({
      path = '/search/issues' .. paged_suffix(page, {
        'q=' .. lc.url.encode(qualified_query),
        'sort=created',
        'order=desc',
      }),
    }):next(function(payload)
      return {
        items = type(payload.data) == 'table' and payload.data.items or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end)
end

function M.list_repo_pulls(owner, repo, page, state)
  owner = trim(owner)
  repo = trim(repo)
  state = trim(state)

  local qualified_query = string.format('repo:%s/%s is:pr', owner, repo)
  if state ~= '' then qualified_query = qualified_query .. ' state:' .. state end

  return remember(cache_key {
    'repo_pulls',
    owner,
    repo,
    state,
    tostring(page or 1),
    tostring(config.get().per_page),
  }, cache_ttl 'repo_pulls', function()
    return request({
      path = '/search/issues' .. paged_suffix(page, {
        'q=' .. lc.url.encode(qualified_query),
        'sort=created',
        'order=desc',
      }),
    }):next(function(payload)
      local items = type(payload.data) == 'table' and payload.data.items or {}
      for _, item in ipairs(items) do
        local pr_meta = (item or {}).pull_request or {}
        if item.merged_at == nil and pr_meta.merged_at ~= nil then
          item.merged_at = pr_meta.merged_at
        end
      end
      return {
        items = items,
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end)
end

function M.get_pull(owner, repo, number)
  owner = trim(owner)
  repo = trim(repo)
  number = tostring(number or '')
  local key = table.concat({ owner, repo, number }, '/')

  if session.pulls[key] then return Promise.resolve(session.pulls[key]) end

  return remember(cache_key { 'pull', key }, cache_ttl 'repo_pulls', function()
    return request({
      path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/pulls/' .. encode_path_segment(number),
    }):next(function(payload) return payload.data end)
  end):next(function(data)
    session.pulls[key] = data
    return data
  end)
end

function M.list_pull_issue_comments(owner, repo, number, page)
  return M.list_issue_comments(owner, repo, number, page)
end

function M.list_pull_review_comments(owner, repo, number, page)
  owner = trim(owner)
  repo = trim(repo)
  number = tostring(number or '')

  return remember(cache_key {
    'pull_review_comments',
    owner,
    repo,
    number,
    tostring(page or 1),
    tostring(config.get().per_page),
  }, cache_ttl 'repo_pulls', function()
    return request({
      path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/pulls/' .. encode_path_segment(number)
        .. '/comments' .. paged_suffix(page),
    }):next(function(payload)
      return {
        items = payload.data or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end)
end

function M.list_pull_reviews(owner, repo, number, page)
  owner = trim(owner)
  repo = trim(repo)
  number = tostring(number or '')

  return remember(cache_key {
    'pull_reviews',
    owner,
    repo,
    number,
    tostring(page or 1),
    tostring(config.get().per_page),
  }, cache_ttl 'repo_pulls', function()
    return request({
      path = '/repos/' .. encode_path_segment(owner) .. '/' .. encode_path_segment(repo) .. '/pulls/' .. encode_path_segment(number)
        .. '/reviews' .. paged_suffix(page),
    }):next(function(payload)
      return {
        items = payload.data or {},
        has_next = has_next_page(payload.response and payload.response.headers),
      }
    end)
  end)
end

local function normalize_discussion_author(author)
  if type(author) ~= 'table' then return {} end
  return {
    login = author.login,
  }
end

local function normalize_discussion_category(category)
  if type(category) ~= 'table' then return nil end
  return {
    name = category.name,
    emoji = category.emoji or category.emojiHTML,
  }
end

local function normalize_discussion_item(item, owner, repo)
  item = item or {}
  return {
    id = item.id,
    number = item.number,
    title = item.title,
    body = item.body or '',
    html_url = item.url,
    created_at = item.createdAt,
    updated_at = item.updatedAt,
    closed_at = item.closedAt,
    state = item.closed and 'closed' or 'open',
    closed = item.closed == true,
    is_answered = item.isAnswered == true,
    answer_chosen_at = item.answerChosenAt,
    comments = ((item.comments or {}).totalCount) or 0,
    upvote_count = item.upvoteCount or 0,
    author = normalize_discussion_author(item.author),
    user = normalize_discussion_author(item.author),
    category = normalize_discussion_category(item.category),
    owner = owner,
    repo_name = repo,
  }
end

local function normalize_discussion_comment(item, discussion)
  item = item or {}
  return {
    id = item.databaseId or item.id,
    node_id = item.id,
    body = item.body or '',
    html_url = item.url,
    created_at = item.createdAt,
    updated_at = item.updatedAt,
    is_answer = item.isAnswer == true,
    author = normalize_discussion_author(item.author),
    user = normalize_discussion_author(item.author),
    discussion_number = discussion and discussion.number or nil,
    owner = discussion and discussion.owner or nil,
    repo_name = discussion and discussion.repo_name or nil,
  }
end

function M.list_repo_discussions(owner, repo, after)
  owner = trim(owner)
  repo = trim(repo)
  after = trim(after)

  if owner == '' or repo == '' then return Promise.reject('Repository path is required') end

  local cache_id = cache_key({
    'repo_discussions',
    owner,
    repo,
    after,
    tostring(config.get().per_page),
  })

  return remember(cache_id, cache_ttl 'repo_discussions', function()
    return graphql_request([[
      query($owner: String!, $repo: String!, $first: Int!, $after: String) {
        repository(owner: $owner, name: $repo) {
          discussions(first: $first, after: $after, orderBy: {field: UPDATED_AT, direction: DESC}) {
            nodes {
              id
              number
              title
              url
              createdAt
              updatedAt
              closed
              closedAt
              isAnswered
              answerChosenAt
              upvoteCount
              author {
                login
              }
              category {
                name
                emoji
              }
              comments {
                totalCount
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      }
    ]], {
      owner = owner,
      repo = repo,
      first = tonumber(config.get().per_page) or 20,
      after = after ~= '' and after or nil,
    }):next(function(data)
      local repository = data.repository
      if not repository then return Promise.reject('Repository not found or discussions unavailable') end

      local connection = repository.discussions or {}
      local items = {}
      for _, item in ipairs(connection.nodes or {}) do
        table.insert(items, normalize_discussion_item(item, owner, repo))
      end

      return {
        items = items,
        has_next = ((connection.pageInfo or {}).hasNextPage) == true,
        cursor = (connection.pageInfo or {}).endCursor,
      }
    end)
  end)
end

function M.get_repo_discussion(owner, repo, number)
  owner = trim(owner)
  repo = trim(repo)
  number = tonumber(number)
  if owner == '' or repo == '' then return Promise.reject('Repository path is required') end
  if not number then return Promise.reject('Discussion number is required') end

  local key = table.concat({ owner, repo, tostring(number) }, '/')
  if session.discussions[key] then return Promise.resolve(session.discussions[key]) end

  return remember(cache_key { 'repo_discussion', key }, cache_ttl 'repo_discussions', function()
    return graphql_request([[
      query($owner: String!, $repo: String!, $number: Int!) {
        repository(owner: $owner, name: $repo) {
          discussion(number: $number) {
            id
            number
            title
            body
            url
            createdAt
            updatedAt
            closed
            closedAt
            isAnswered
            answerChosenAt
            upvoteCount
            author {
              login
            }
            category {
              name
              emoji
            }
            comments {
              totalCount
            }
          }
        }
      }
    ]], {
      owner = owner,
      repo = repo,
      number = number,
    }):next(function(data)
      local repository = data.repository
      local discussion = repository and repository.discussion or nil
      if not discussion then return Promise.reject('Discussion not found') end
      return normalize_discussion_item(discussion, owner, repo)
    end)
  end):next(function(data)
    session.discussions[key] = data
    return data
  end)
end

function M.list_discussion_comments(owner, repo, number, after)
  owner = trim(owner)
  repo = trim(repo)
  number = tonumber(number)
  after = trim(after)

  if owner == '' or repo == '' then return Promise.reject('Repository path is required') end
  if not number then return Promise.reject('Discussion number is required') end

  local cache_id = cache_key({
    'discussion_comments',
    owner,
    repo,
    tostring(number),
    after,
  })

  return remember(cache_id, cache_ttl 'repo_discussions', function()
    return graphql_request([[
      query($owner: String!, $repo: String!, $number: Int!, $after: String) {
        repository(owner: $owner, name: $repo) {
          discussion(number: $number) {
            number
            comments(first: 100, after: $after) {
              nodes {
                id
                databaseId
                body
                url
                createdAt
                updatedAt
                isAnswer
                author {
                  login
                }
                replies(first: 100) {
                  nodes {
                    id
                    databaseId
                    body
                    url
                    createdAt
                    updatedAt
                    author {
                      login
                    }
                  }
                }
              }
              pageInfo {
                hasNextPage
                endCursor
              }
            }
          }
        }
      }
    ]], {
      owner = owner,
      repo = repo,
      number = number,
      after = after ~= '' and after or nil,
    }):next(function(data)
      local repository = data.repository
      local discussion_node = repository and repository.discussion or nil
      if not discussion_node then return Promise.reject('Discussion not found') end

      local discussion = {
        owner = owner,
        repo_name = repo,
        number = number,
      }
      local connection = discussion_node.comments or {}
      local items = {}

      for _, item in ipairs(connection.nodes or {}) do
        local normalized = normalize_discussion_comment(item, discussion)
        normalized.kind = 'discussion_comment'
        table.insert(items, normalized)

        for _, reply in ipairs((((item or {}).replies or {}).nodes) or {}) do
          local normalized_reply = normalize_discussion_comment(reply, discussion)
          normalized_reply.kind = 'discussion_reply'
          table.insert(items, normalized_reply)
        end
      end

      return {
        items = items,
        has_next = ((connection.pageInfo or {}).hasNextPage) == true,
        cursor = (connection.pageInfo or {}).endCursor,
      }
    end)
  end)
end

return M
