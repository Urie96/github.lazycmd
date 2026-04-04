local action = require 'github.action'
local api = require 'github.api'
local config = require 'github.config'

local M = {}

local runtime = {
  paginations = {},
}

local load_page

local function span(text, color)
  local s = lc.style.span(tostring(text or ''))
  if color and color ~= '' then s = s:fg(color) end
  return s
end

local function line(parts) return lc.style.line(parts) end

local function path_key(path) return table.concat(path or {}, '\x1f') end

local function encode_repo_ref(owner, repo) return lc.url.encode(tostring(owner or '') .. '/' .. tostring(repo or '')) end

local function decode_repo_ref(value)
  value = tostring(value or '')
  if value == '' then return nil, nil end

  local decoded = lc.url.decode(value)
  local owner, repo = decoded:match '^([^/]+)/(.+)$'
  if not owner or not repo then return nil, nil end
  return owner, repo
end

local function language_style(language)
  local map = {
    Rust = { icon = '', color = '#dea584' },
    Lua = { icon = '', color = '#000080' },
    Go = { icon = '', color = '#00ADD8' },
    Python = { icon = '', color = '#3572A5' },
    JavaScript = { icon = '', color = '#f1e05a' },
    TypeScript = { icon = '', color = '#3178c6' },
    TSX = { icon = '', color = '#3178c6' },
    JSX = { icon = '', color = '#f1e05a' },
    Shell = { icon = '', color = '#89e051' },
    Bash = { icon = '', color = '#89e051' },
    Zig = { icon = '', color = '#ec915c' },
    Nix = { icon = '', color = '#7e7eff' },
    C = { icon = '', color = '#555555' },
    ['C++'] = { icon = '', color = '#f34b7d' },
    ['C#'] = { icon = '󰌛', color = '#178600' },
    ['F#'] = { icon = '', color = '#b845fc' },
    Java = { icon = '', color = '#b07219' },
    Kotlin = { icon = '', color = '#A97BFF' },
    Swift = { icon = '', color = '#F05138' },
    PHP = { icon = '', color = '#4F5D95' },
    Ruby = { icon = '', color = '#701516' },
    Haskell = { icon = '', color = '#5e5086' },
    Elixir = { icon = '', color = '#6e4a7e' },
    Erlang = { icon = '', color = '#B83998' },
    OCaml = { icon = '', color = '#ef7a08' },
    Dart = { icon = '', color = '#00B4AB' },
    R = { icon = '󰟔', color = '#198CE7' },
    Scala = { icon = '', color = '#c22d40' },
    Perl = { icon = '', color = '#0298c3' },
    ['Vim Script'] = { icon = '', color = '#199f4b' },
    Clojure = { icon = '', color = '#db5855' },
    HCL = { icon = '󱁢', color = '#844FBA' },
    Astro = { icon = '', color = '#ff5a03' },
    HTML = { icon = '', color = '#e34c26' },
    CSS = { icon = '', color = '#663399' },
    SCSS = { icon = '', color = '#c6538c' },
    Vue = { icon = '󰡄', color = '#41b883' },
    Svelte = { icon = '', color = '#ff3e00' },
    Dockerfile = { icon = '', color = '#384d54' },
    Makefile = { icon = '', color = '#427819' },
    Markdown = { icon = '', color = '#083fa1' },
    JSON = { icon = '', color = '#292929' },
    YAML = { icon = '', color = '#cb171e' },
    Toml = { icon = '', color = '#9c4221' },
  }

  return map[tostring(language or '')] or { icon = '󰈔', color = 'darkgray' }
end

local function clone_entries(entries)
  local copied = {}
  for _, entry in ipairs(entries or {}) do
    table.insert(copied, entry)
  end
  return copied
end

local function build_open_keymap(callback, open_desc, browser_desc)
  local plugin_keymap = config.get().keymap or {}
  local keymap = {
    [plugin_keymap.open] = { callback = callback, desc = open_desc or 'open' },
    [plugin_keymap.enter] = { callback = callback, desc = open_desc or 'open' },
  }

  if browser_desc then
    keymap[plugin_keymap.open_in_browser] = { callback = action.open_in_browser, desc = browser_desc }
  end

  return keymap
end

local function info_entry(key, title, message, color, detail)
  return {
    key = key,
    kind = 'info',
    title = title,
    message = message,
    detail = detail,
    color = color,
    display = line {
      span(title, color or 'darkgray'),
      message and message ~= '' and span('  ' .. message, 'darkgray') or '',
    },
    preview = action.info_preview,
  }
end

local function route_entry(key, title, detail, color, opts)
  opts = opts or {}
  local plugin_keymap = config.get().keymap
  local label = opts.label or key
  local icon = opts.icon or ''

  return {
    key = key,
    kind = 'route',
    title = title,
    detail = detail,
    color = color,
    display = line {
      icon ~= '' and span(icon .. ' ', color or 'white') or '',
      span(label, color or 'white'),
      span('  ' .. title, 'darkgray'),
    },
    keymap = {
      [plugin_keymap.search] = { callback = action.search_repo_input, desc = 'search repositories' },
    },
    preview = action.route_preview,
  }
end

local function build_user_entry(user)
  local username = tostring(user.login or '')
  local title = user.name and user.name ~= '' and (' (' .. tostring(user.name) .. ')') or ''
  return {
    key = username,
    kind = 'user',
    username = username,
    login = username,
    user = user,
    html_url = user.html_url,
    display = line {
      span('@' .. username, 'green'),
      span(title, 'darkgray'),
    },
    keymap = build_open_keymap(action.go_to_user, 'open repositories', 'open in browser'),
    preview = action.user_preview,
  }
end

local function build_repo_entry(repo, opts)
  opts = opts or {}
  local owner = repo.owner and repo.owner.login or ''
  local name = repo.name or ''
  local key = opts.key or name
  local full_name = owner ~= '' and (owner .. '/' .. name) or name
  local lang = language_style(repo.language)
  local stars = tonumber(repo.stargazers_count or 0) or 0
  local star_text = tostring(stars)
  if stars >= 1000 then
    local value = stars / 1000
    if stars >= 100000 then
      star_text = string.format('%.0fk', value)
    else
      star_text = string.format('%.1fk', value)
    end
  end
  return {
    key = key,
    kind = 'repo',
    owner = owner,
    repo_name = name,
    repo = repo,
    html_url = repo.html_url,
    web_url = repo.html_url,
    display = line {
      span(lang.icon, lang.color),
      span(' ', 'white'),
      span(full_name, 'white'),
      span('   ', '#f1e05a'),
      span(star_text, '#f1e05a'),
    },
    keymap = build_open_keymap(action.go_to_repo, 'open repository', 'open in browser'),
    preview = action.repo_preview,
  }
end

local function build_notification_entry(notification)
  local repository = notification.repository or {}
  local subject = notification.subject or {}
  local owner, repo = '', ''
  local full_name = tostring(repository.full_name or '')
  if full_name ~= '' then
    owner, repo = full_name:match '^([^/]+)/(.+)$'
    owner = owner or ''
    repo = repo or ''
  end

  return {
    key = full_name ~= '' and encode_repo_ref(owner, repo)
      or tostring(notification.id or tostring(subject.title or 'notification')),
    kind = 'notification',
    notification = notification,
    repo_full_name = full_name,
    owner = owner,
    repo_name = repo,
    repo = repository,
    html_url = repository.html_url,
    web_url = repository.html_url,
    display = line {
      span('[' .. tostring(notification.reason or 'notice') .. ']', 'blue'),
      span(' ' .. full_name, 'green'),
      span('  ' .. tostring(subject.title or subject.type or 'notification'), 'white'),
    },
    keymap = build_open_keymap(action.go_to_repo, 'open repository', 'open repository in browser'),
    preview = action.notification_preview,
  }
end

local function build_readme_entry(owner, repo, repo_info)
  return {
    key = 'readme',
    kind = 'readme',
    owner = owner,
    repo_name = repo,
    repo = repo_info,
    html_url = repo_info and repo_info.html_url or nil,
    web_url = repo_info and repo_info.html_url or nil,
    display = line {
      span('readme', 'cyan'),
      span('  preview repository README', 'darkgray'),
    },
    keymap = build_open_keymap(action.open_in_browser, 'open repository in browser', 'open repository in browser'),
    preview = action.readme_preview,
  }
end

local function build_load_more_entry(route_key_value, loading)
  local function trigger_load_more()
    local state = runtime.paginations[route_key_value]
    if not state or state.loading or state.done then return end
    load_page(state)
  end
  local plugin_keymap = config.get().keymap or {}

  return {
    key = '__load_more__',
    kind = 'load_more',
    route_key = route_key_value,
    loading = loading == true,
    keymap = {
      [plugin_keymap.open] = { callback = trigger_load_more, desc = 'load more' },
      [plugin_keymap.enter] = { callback = trigger_load_more, desc = 'load more' },
    },
    preview = action.load_more_preview,
    display = line {
      span(loading and 'Loading more...' or 'Load more...', 'yellow'),
    },
  }
end

local function build_search_prompt_entry(kind)
  local plugin_keymap = config.get().keymap or {}
  local callback = kind == 'user' and action.search_user_input or action.search_repo_input
  return {
    key = kind,
    kind = 'search_pormpt',
    search_kind = 'search_prompt',
    display = line {
      span(kind, kind == 'user' and 'green' or 'yellow'),
      span('  input a query', 'darkgray'),
    },
    keymap = {
      [plugin_keymap.open] = { callback = callback, desc = 'open' },
      [plugin_keymap.enter] = { callback = callback, desc = 'open' },
    },
    preview = action.search_prompt_preview,
  }
end

local function align_repo_entry_columns(entries)
  local lines = {}

  for _, entry in ipairs(entries or {}) do
    if entry.kind == 'repo' and entry.display then table.insert(lines, entry.display) end
  end

  if #lines > 1 then lc.style.align_columns(lines) end
end

local function current_path_equals(path) return lc.deep_equal(path or {}, lc.api.get_current_path() or {}) end

local function materialize_pagination(state)
  local entries = clone_entries(state.prefix or {})
  for _, item in ipairs(state.items or {}) do
    table.insert(entries, item)
  end

  if state.loading then
    table.insert(entries, build_load_more_entry(state.route_key, true))
  elseif not state.done then
    table.insert(entries, build_load_more_entry(state.route_key, false))
  end

  if #entries == 0 and state.empty_entry then table.insert(entries, state.empty_entry()) end

  align_repo_entry_columns(entries)
  return entries
end

local function refresh_state(state)
  if current_path_equals(state.path) then lc.api.page_set_entries(materialize_pagination(state)) end
end

load_page = function(state, initial_cb)
  if state.loading or state.done then
    if initial_cb then initial_cb(materialize_pagination(state)) end
    return
  end

  state.loading = true
  if not initial_cb then refresh_state(state) end

  local next_page = state.page + 1
  state.fetch_page(next_page, function(items, has_next, err)
    state.loading = false

    if err then
      if state.page == 0 then
        state.done = true
        state.items = {
          info_entry('error', 'GitHub request failed', err, 'red'),
        }
      else
        lc.notify(err)
        state.done = true
      end

      if initial_cb then
        initial_cb(materialize_pagination(state))
      else
        refresh_state(state)
      end
      return
    end

    items = items or {}

    if #items == 0 then
      if state.page == 0 and #state.items == 0 and state.empty_entry then state.items = { state.empty_entry() } end
      state.done = true
    else
      for _, item in ipairs(items) do
        table.insert(state.items, item)
      end
      state.page = next_page
      state.done = has_next ~= true
    end

    if initial_cb then
      initial_cb(materialize_pagination(state))
    else
      refresh_state(state)
    end
  end)
end

local function list_paginated(path, cb, opts)
  local key = path_key(path)
  local state = runtime.paginations[key]

  if not state then
    state = {
      route_key = key,
      path = { table.unpack(path) },
      page = 0,
      loading = false,
      done = false,
      prefix = clone_entries(opts.prefix or {}),
      items = {},
      fetch_page = opts.fetch_page,
      empty_entry = opts.empty_entry,
    }
    runtime.paginations[key] = state
  end

  if state.page > 0 or state.done or #state.items > 0 then
    cb(materialize_pagination(state))
    return
  end

  load_page(state, cb)
end

local function list_root(_, cb)
  local authed = api.is_authenticated()
  local entries = {
    route_entry(
      'notifications',
      'Unread notifications',
      authed and 'Requires token, paginated.' or 'Requires token.',
      'yellow',
      { label = 'Notifications', icon = '󰜘' }
    ),
    route_entry(
      'repo',
      'My account, following users and repositories',
      authed and 'Includes followed users; use u for any username.' or 'Use u to open any username.',
      'green',
      { label = 'Repo', icon = '󰳏' }
    ),
    route_entry(
      'starred',
      'Repositories you starred',
      authed and 'Requires token, paginated.' or 'Requires token.',
      'cyan',
      { label = 'Starred', icon = '' }
    ),
    route_entry('search', 'Search repositories and users', 'Public API, paginated.', 'blue', {
      label = 'Search',
      icon = '󰍉',
    }),
  }
  cb(entries)
end

local function list_notifications(path, cb)
  if not api.is_authenticated() then
    cb {
      info_entry(
        'auth',
        'Token required',
        'Notifications require a GitHub token.',
        'yellow',
        "Pass token in require('github').setup { token = ... }."
      ),
    }
    return
  end

  list_paginated(path, cb, {
    fetch_page = function(page, done)
      api.list_notifications(page, function(items, has_next, err)
        local entries = {}
        for _, item in ipairs(items or {}) do
          table.insert(entries, build_notification_entry(item))
        end
        done(entries, has_next, err)
      end)
    end,
    empty_entry = function()
      return info_entry('empty', 'No notifications', 'GitHub returned an empty list.', 'darkgray')
    end,
  })
end

local function list_repo_root(path, cb)
  local plugin_keymap = config.get().keymap or {}
  local prefix = {
    {
      key = 'open-user',
      kind = 'info',
      title = 'Open any user',
      color = 'cyan',
      display = line {
        span('Open User', 'cyan'),
        span('  input a username', 'darkgray'),
      },
      keymap = {
        [plugin_keymap.open] = { callback = action.open_user_input, desc = 'open' },
        [plugin_keymap.enter] = { callback = action.open_user_input, desc = 'open' },
      },
      preview = action.info_preview,
    },
  }

  if not api.is_authenticated() then
    table.insert(
      prefix,
      info_entry('auth', 'Token optional here', 'Current user and following list need a token.', 'yellow')
    )
    cb(prefix)
    return
  end

  list_paginated(path, cb, {
    prefix = prefix,
    fetch_page = function(page, done)
      api.list_following(page, function(items, has_next, err)
        if err then
          done(nil, nil, err)
          return
        end

        local following_entries = {}
        for _, item in ipairs(items or {}) do
          table.insert(following_entries, build_user_entry(item))
        end

        if page ~= 1 then
          done(following_entries, has_next, nil)
          return
        end

        api.get_viewer(function(viewer, viewer_err)
          if viewer_err then
            done(nil, nil, viewer_err)
            return
          end

          local entries = {}
          if viewer then table.insert(entries, build_user_entry(viewer)) end
          for _, item in ipairs(following_entries) do
            table.insert(entries, item)
          end
          done(entries, has_next, nil)
        end)
      end)
    end,
    empty_entry = function()
      return info_entry('empty', 'No users', 'No viewer or following users were returned.', 'darkgray')
    end,
  })
end

local function list_user_repos(path, cb)
  local username = path[3]
  list_paginated(path, cb, {
    fetch_page = function(page, done)
      api.list_user_repos(username, page, function(items, has_next, err)
        if err then
          done(nil, nil, err)
          return
        end

        local entries = {}
        for _, item in ipairs(items or {}) do
          table.insert(entries, build_repo_entry(item, { key = item.name }))
        end
        done(entries, has_next, nil)
      end)
    end,
    empty_entry = function()
      return info_entry('empty', 'No repositories', 'This user has no repositories in the current scope.', 'darkgray')
    end,
  })
end

local function list_repo_detail(path, cb)
  local owner = path[3]
  local repo_name = path[4]
  api.get_repo(owner, repo_name, function(repo, err)
    if err then
      cb {
        info_entry('error', 'Failed to load repository', err, 'red'),
      }
      return
    end

    cb {
      build_readme_entry(owner, repo_name, repo),
    }
  end)
end

local function list_starred(path, cb)
  if not api.is_authenticated() then
    cb {
      info_entry(
        'auth',
        'Token required',
        'Starred repositories require a GitHub token.',
        'yellow',
        "Pass token in require('github').setup { token = ... }."
      ),
    }
    return
  end

  list_paginated(path, cb, {
    fetch_page = function(page, done)
      api.list_starred(page, function(items, has_next, err)
        if err then
          done(nil, nil, err)
          return
        end

        local entries = {}
        for _, item in ipairs(items or {}) do
          local owner = item.owner and item.owner.login or ''
          local repo_name = item.name or ''
          table.insert(entries, build_repo_entry(item, { key = encode_repo_ref(owner, repo_name) }))
        end
        done(entries, has_next, nil)
      end)
    end,
    empty_entry = function()
      return info_entry('empty', 'No starred repositories', 'GitHub returned an empty list.', 'darkgray')
    end,
  })
end

local function list_search_root(_, cb)
  cb {
    build_search_prompt_entry 'repo',
    build_search_prompt_entry 'user',
  }
end

local function list_search_kind(path, cb)
  local plugin_keymap = config.get().keymap or {}
  local kind = path[3] or 'repo'
  local callback = kind == 'user' and action.search_user_input or action.search_repo_input
  cb {

    {
      key = 'prompt',
      kind = 'search_prompt',
      search_kind = 'search_prompt',
      display = line {
        span(kind, kind == 'user' and 'green' or 'yellow'),
        span('  input a query', 'darkgray'),
      },
      keymap = {
        [plugin_keymap.open] = { callback = callback, desc = 'open' },
        [plugin_keymap.enter] = { callback = callback, desc = 'open' },
      },
      preview = action.search_prompt_preview,
    },
  }
end

local function list_search_results(path, cb)
  local kind = path[3]
  local query = path[4]

  list_paginated(path, cb, {
    fetch_page = function(page, done)
      local handler = kind == 'user' and api.search_users or api.search_repositories
      handler(query, page, function(items, has_next, err)
        if err then
          done(nil, nil, err)
          return
        end

        local entries = {}
        for _, item in ipairs(items or {}) do
          if kind == 'user' then
            table.insert(entries, build_user_entry(item))
          else
            local owner = item.owner and item.owner.login or ''
            local repo_name = item.name or ''
            table.insert(entries, build_repo_entry(item, { key = encode_repo_ref(owner, repo_name) }))
          end
        end
        done(entries, has_next, nil)
      end)
    end,
    empty_entry = function() return info_entry('empty', 'No search results', 'Try another query.', 'darkgray') end,
  })
end

local function list_repo_dispatch(path, cb)
  if #path == 2 then
    list_repo_root(path, cb)
    return
  end

  if #path == 3 then
    list_user_repos(path, cb)
    return
  end

  if #path == 4 then
    list_repo_detail(path, cb)
    return
  end

  cb {}
end

local function list_search_dispatch(path, cb)
  if #path == 2 then
    list_search_root(path, cb)
    return
  end

  if #path == 3 then
    list_search_kind(path, cb)
    return
  end

  if #path == 4 then
    list_search_results(path, cb)
    return
  end

  cb {}
end

function M.setup(opt)
  config.setup(opt or {})
  api.reset()
  runtime.paginations = {}

  lc.api.append_hook_pre_reload(function()
    api.reset()
    runtime.paginations = {}
  end)
end

function M.list(path, cb)
  if path[2] == 'notifications' and #path == 3 then
    local owner, repo = decode_repo_ref(path[3])
    if owner and repo then
      lc.api.go_to { 'github', 'repo', owner, repo }
      cb {
        info_entry('redirect', 'Redirecting', 'Opening repository...', 'yellow'),
      }
      return
    end
  end

  if path[2] == 'starred' and #path == 3 then
    local owner, repo = decode_repo_ref(path[3])
    if owner and repo then
      lc.api.go_to { 'github', 'repo', owner, repo }
      cb {
        info_entry('redirect', 'Redirecting', 'Opening repository...', 'yellow'),
      }
      return
    end
  end

  if path[2] == 'search' and path[3] == 'repo' and #path == 5 then
    local owner, repo = decode_repo_ref(path[5])
    if owner and repo then
      lc.api.go_to { 'github', 'repo', owner, repo }
      cb {
        info_entry('redirect', 'Redirecting', 'Opening repository...', 'yellow'),
      }
      return
    end
  end

  if #path == 1 then
    list_root(path, cb)
    return
  end

  local route = path[2]
  if route == 'notifications' then
    list_notifications(path, cb)
    return
  end

  if route == 'repo' then
    list_repo_dispatch(path, cb)
    return
  end

  if route == 'starred' then
    list_starred(path, cb)
    return
  end

  if route == 'search' then
    list_search_dispatch(path, cb)
    return
  end

  cb {}
end

return M
