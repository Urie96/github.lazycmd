local action = require 'github.action'
local api = require 'github.api'
local config = require 'github.config'
local entries = require 'github.entries'
local Provider = require 'github.provider'

local M = {}

local runtime = {
  paginations = {},
  browsers = {},
}

local function file_module()
  return require 'file'
end

local load_page

local function path_key(path) return table.concat(path or {}, '\x1f') end

local function encode_repo_ref(owner, repo) return tostring(owner or '') .. '/' .. tostring(repo or '') end

local function decode_repo_ref(value)
  value = tostring(value or '')
  if value == '' then return nil, nil end

  local owner, repo = value:match '^([^/]+)/(.+)$'
  if not owner or not repo then return nil, nil end
  return owner, repo
end

local function clone_entries(items)
  local copied = {}
  for _, item in ipairs(items or {}) do
    table.insert(copied, item)
  end
  return copied
end

local function current_path_equals(path) return lc.deep_equal(path or {}, lc.api.get_current_path() or {}) end

local function browser_key(owner, repo, ref_kind, ref_name)
  return table.concat({ owner, repo, ref_kind, ref_name }, '\x1f')
end

local function browser_options()
  return {
    preview_max_chars = (config.get() or {}).code_max_chars,
    keymap = {
      new_file = false,
      new_dir = false,
      edit = false,
      rename = false,
      select = false,
      toggle_hidden = false,
      yank = false,
      cut = false,
      delete = false,
      paste = false,
    },
  }
end

local function get_repo_browser(owner, repo, ref_kind, ref_name)
  local key = browser_key(owner, repo, ref_kind, ref_name)
  if runtime.browsers[key] then return runtime.browsers[key] end

  runtime.browsers[key] = file_module().new(Provider.new(owner, repo, ref_kind, ref_name), browser_options())
  return runtime.browsers[key]
end

local function decorate_repo_browser_entries(items)
  local keymap = (config.get() or {}).keymap or {}
  local browser_key_name = keymap.open_in_browser
  local out = {}

  for _, entry in ipairs(items or {}) do
    if entry.handle then
      entry.owner = entry.handle.owner
      entry.repo_name = entry.handle.repo_name
      entry.ref_kind = entry.handle.ref_kind
      entry.ref_name = entry.handle.ref_name
      entry.html_url = entry.handle.html_url
      entry.web_url = entry.handle.web_url

      if browser_key_name and browser_key_name ~= '' and entry.web_url then
        local maps = lc.tbl_extend('force', {}, entry.keymap or {})
        maps[browser_key_name] = { callback = action.open_in_browser, desc = 'open in browser' }
        entry.keymap = maps
      end
    end
    table.insert(out, entry)
  end

  return out
end

local function decorate_repo_item_search_keymap(path, items)
  path = path or {}
  items = items or {}

  if #path < 5 or path[2] ~= 'repo' then return end

  local plugin_keymap = config.get().keymap or {}
  local search_key = plugin_keymap.search
  if not search_key or search_key == '' then return end

  local callback
  local desc

  if path[5] == 'issues' then
    callback = action.search_repo_issues_input
    desc = 'search issues'
  elseif path[5] == 'pulls' then
    callback = action.search_repo_pulls_input
    desc = 'search pull requests'
  else
    return
  end

  for _, entry in ipairs(items) do
    entry.keymap = entry.keymap or {}
    if entry.keymap[search_key] == nil then
      entry.keymap[search_key] = { callback = callback, desc = desc }
    end
  end
end

local function materialize_pagination(state)
  local items = clone_entries(state.prefix or {})
  for _, item in ipairs(state.items or {}) do
    table.insert(items, item)
  end

  local function trigger_load_more()
    local current = runtime.paginations[state.route_key]
    if not current or current.loading or current.done then return end
    load_page(current)
  end

  if state.loading then
    table.insert(items, entries.load_more_entry(state.route_key, true, trigger_load_more))
  elseif not state.done then
    table.insert(items, entries.load_more_entry(state.route_key, false, trigger_load_more))
  end

  if #items == 0 and state.empty_entry then
    table.insert(items, state.empty_entry())
  end

  decorate_repo_item_search_keymap(state.path, items)
  entries.align_repo_entry_columns(items)
  return items
end

local function refresh_state(state)
  if current_path_equals(state.path) then lc.api.set_entries(nil, materialize_pagination(state)) end
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
          entries.info_entry('error', 'GitHub request failed', err, 'red'),
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
      if state.page == 0 and #state.items == 0 and state.empty_entry then
        state.items = { state.empty_entry() }
      end
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

  if state.page > 0 or state.done then
    cb(materialize_pagination(state))
    return
  end

  load_page(state, cb)
end

local function list_root(_, cb)
  local authed = api.is_authenticated()

  cb {
    entries.route_entry('notifications', 'Unread notifications', authed and 'Requires token, paginated.' or 'Requires token.', 'yellow', {
      label = 'Notifications',
      icon = '󰜘',
    }),
    entries.route_entry(
      'repo',
      'My account, following users and repositories',
      authed and 'Includes followed users; use u for any username.' or 'Use u to open any username.',
      'green',
      { label = 'Repo', icon = '󰳏' }
    ),
    entries.route_entry('starred', 'Repositories you starred', authed and 'Requires token, paginated.' or 'Requires token.', 'cyan', {
      label = 'Starred',
      icon = '',
    }),
    entries.route_entry('search', 'Search repositories and users', 'Public API, paginated.', 'blue', {
      label = 'Search',
      icon = '󰍉',
    }),
  }
end

local function list_notifications(path, cb)
  if not api.is_authenticated() then
    cb {
      entries.info_entry(
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
      api.list_notifications(page):next(function(payload)
        local mapped = {}
        for _, item in ipairs(payload.items or {}) do
          table.insert(mapped, entries.notification_entry(item, encode_repo_ref))
        end
        done(mapped, payload.has_next == true, nil)
      end, function(err)
        done(nil, nil, err)
      end)
    end,
    empty_entry = function()
      return entries.info_entry('empty', 'No notifications', 'GitHub returned an empty list.', 'darkgray')
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
      display = lc.style.line {
        lc.style.span('Open User'):fg 'cyan',
        lc.style.span('  input a username'):fg 'darkgray',
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
      entries.info_entry('auth', 'Token optional here', 'Current user and following list need a token.', 'yellow')
    )
    cb(prefix)
    return
  end

  list_paginated(path, cb, {
    prefix = prefix,
    fetch_page = function(page, done)
      local following_promise = api.list_following(page)

      if page ~= 1 then
        following_promise:next(function(payload)
          local following = {}
          for _, item in ipairs(payload.items or {}) do
            table.insert(following, entries.user_entry(item))
          end
          done(following, payload.has_next == true, nil)
        end, function(err)
          done(nil, nil, err)
        end)
        return
      end

      Promise.all({
        api.prime_viewer(),
        following_promise,
      }):next(function(results)
        local viewer = results[1]
        local payload = results[2] or {}
        local mapped = {}

        if viewer then table.insert(mapped, entries.user_entry(viewer)) end
        for _, item in ipairs(payload.items or {}) do
          table.insert(mapped, entries.user_entry(item))
        end

        done(mapped, payload.has_next == true, nil)
      end, function(err)
        done(nil, nil, err)
      end)
    end,
    empty_entry = function()
      return entries.info_entry('empty', 'No users', 'No viewer or following users were returned.', 'darkgray')
    end,
  })
end

local function list_user_repos(path, cb)
  local username = path[3]
  local plugin_keymap = config.get().keymap or {}

  local function search_current_user_repos()
    action.search_current_user_repos_input(username)
  end

  list_paginated(path, cb, {
    fetch_page = function(page, done)
      api.list_user_repos(username, page):next(function(payload)
        local mapped = {}
        for _, item in ipairs(payload.items or {}) do
          local entry = entries.repo_entry(item, { key = item.name })
          entry.keymap[plugin_keymap.search] = {
            callback = search_current_user_repos,
            desc = 'search this user repositories',
          }
          table.insert(mapped, entry)
        end
        done(mapped, payload.has_next == true, nil)
      end, function(err)
        done(nil, nil, err)
      end)
    end,
    empty_entry = function()
      return entries.info_entry('empty', 'No repositories', 'This user has no repositories in the current scope.', 'darkgray')
    end,
  })
end

local function warm_repo(owner, repo_name)
  api.get_repo(owner, repo_name):next(function() end, function() end)
end

local function list_repo_detail(path, cb)
  local owner = path[3]
  local repo_name = path[4]
  warm_repo(owner, repo_name)
  cb {
    entries.readme_entry(owner, repo_name),
    entries.repo_detail_route_entry('issues', owner, repo_name),
    entries.repo_detail_route_entry('pulls', owner, repo_name),
    entries.repo_detail_route_entry('branches', owner, repo_name),
    entries.repo_detail_route_entry('tags', owner, repo_name),
  }
end

local function prioritize_default_branch(items, default_branch)
  default_branch = tostring(default_branch or '')
  if default_branch == '' then return items or {} end

  local matched = nil
  local rest = {}
  for _, item in ipairs(items or {}) do
    if not matched and tostring(item and item.name or '') == default_branch then
      matched = item
    else
      table.insert(rest, item)
    end
  end

  if not matched then return items or {} end
  return lc.list_extend({ matched }, rest)
end

local function list_repo_branches(path, cb)
  local owner = path[3]
  local repo_name = path[4]

  local function apply_branch_page(mapped, has_next)
    local key = path_key(path)
    runtime.paginations[key] = {
      route_key = key,
      path = { table.unpack(path) },
      page = (#mapped > 0) and 1 or 0,
      loading = false,
      done = has_next ~= true,
      prefix = {},
      items = mapped,
      fetch_page = function(page, done)
        api.list_repo_branches(owner, repo_name, page):next(function(next_payload)
          local next_mapped = {}
          for _, item in ipairs(next_payload.items or {}) do
            table.insert(next_mapped, entries.repo_ref_entry(owner, repo_name, 'branches', item))
          end
          done(next_mapped, next_payload.has_next == true, nil)
        end, function(err)
          done(nil, nil, err)
        end)
      end,
      empty_entry = function()
        return entries.info_entry('empty', 'No branches', 'No branches were returned.', 'darkgray')
      end,
    }

    if current_path_equals(path) then
      local state = runtime.paginations[key]
      lc.api.set_entries(nil, materialize_pagination(state))
    end
  end

  local function apply_branch_error(err)
    local key = path_key(path)
    runtime.paginations[key] = {
      route_key = key,
      path = { table.unpack(path) },
      page = 0,
      loading = false,
      done = true,
      prefix = {},
      items = {
        entries.info_entry('error', 'GitHub request failed', err, 'red'),
      },
      fetch_page = function(_, done)
        done(nil, nil, err)
      end,
      empty_entry = function()
        return entries.info_entry('empty', 'No branches', 'No branches were returned.', 'darkgray')
      end,
    }

    if current_path_equals(path) then
      local state = runtime.paginations[key]
      lc.api.set_entries(nil, materialize_pagination(state))
    end
  end

  api.get_repo(owner, repo_name):next(function(repo)
    local default_branch = tostring((repo or {}).default_branch or '')
    if default_branch ~= '' and current_path_equals(path) then
      lc.api.set_entries(nil, {
        entries.repo_ref_entry(owner, repo_name, 'branches', {
          name = default_branch,
          commit = {},
          is_default = true,
        }),
      })
    end

    api.list_repo_branches(owner, repo_name, 1):next(function(payload)
      local mapped = {}
      local ordered = prioritize_default_branch(payload.items or {}, default_branch)
      for _, item in ipairs(ordered) do
        item.is_default = tostring(item.name or '') == default_branch
        table.insert(mapped, entries.repo_ref_entry(owner, repo_name, 'branches', item))
      end
      apply_branch_page(mapped, payload.has_next == true)
    end, function(err)
      apply_branch_error(err)
    end)
  end, function()
    api.list_repo_branches(owner, repo_name, 1):next(function(payload)
      local mapped = {}
      for _, item in ipairs(payload.items or {}) do
        table.insert(mapped, entries.repo_ref_entry(owner, repo_name, 'branches', item))
      end
      apply_branch_page(mapped, payload.has_next == true)
    end, function(err)
      apply_branch_error(err)
    end)
  end)
end

local function list_repo_tags(path, cb)
  local owner = path[3]
  local repo_name = path[4]

  list_paginated(path, cb, {
    fetch_page = function(page, done)
      api.list_repo_tags(owner, repo_name, page):next(function(payload)
        local mapped = {}
        for _, item in ipairs(payload.items or {}) do
          table.insert(mapped, entries.repo_ref_entry(owner, repo_name, 'tags', item))
        end
        done(mapped, payload.has_next == true, nil)
      end, function(err)
        done(nil, nil, err)
      end)
    end,
    empty_entry = function()
      return entries.info_entry('empty', 'No tags', 'No tags were returned.', 'darkgray')
    end,
  })
end

local function list_repo_ref_contents(path, cb, ref_kind)
  local owner = path[3]
  local repo_name = path[4]
  local ref_name = tostring(path[6] or '')
  get_repo_browser(owner, repo_name, ref_kind, ref_name):list(path, function(items)
    cb(decorate_repo_browser_entries(items))
  end)
end

local function list_repo_issues(path, cb)
  local owner = path[3]
  local repo_name = path[4]
  local query = (path[6] == 'search') and path[7] or nil

  list_paginated(path, cb, {
    fetch_page = function(page, done)
      local promise
      if query and query ~= '' then
        promise = api.search_repo_issues(owner, repo_name, query, page)
      else
        promise = api.list_repo_issues(owner, repo_name, page)
      end

      promise:next(function(payload)
        local mapped = {}
        for _, item in ipairs(payload.items or {}) do
          item.owner = owner
          item.repo_name = repo_name
          table.insert(mapped, entries.issue_entry(item))
        end
        done(mapped, payload.has_next == true, nil)
      end, function(err)
        done(nil, nil, err)
      end)
    end,
    empty_entry = function()
      if query and query ~= '' then
        return entries.info_entry('empty', 'No issues', 'No issues matched this search.', 'darkgray')
      end
      return entries.info_entry('empty', 'No issues', 'No open issues were returned.', 'darkgray')
    end,
  })
end

local function list_repo_pulls(path, cb)
  local owner = path[3]
  local repo_name = path[4]
  local query = (path[6] == 'search') and path[7] or nil

  list_paginated(path, cb, {
    fetch_page = function(page, done)
      local promise
      if query and query ~= '' then
        promise = api.search_repo_pulls(owner, repo_name, query, page)
      else
        promise = api.list_repo_pulls(owner, repo_name, page)
      end

      promise:next(function(payload)
        local mapped = {}
        for _, item in ipairs(payload.items or {}) do
          item.owner = owner
          item.repo_name = repo_name
          table.insert(mapped, entries.pull_entry(item))
        end
        done(mapped, payload.has_next == true, nil)
      end, function(err)
        done(nil, nil, err)
      end)
    end,
    empty_entry = function()
      if query and query ~= '' then
        return entries.info_entry('empty', 'No pull requests', 'No pull requests matched this search.', 'darkgray')
      end
      return entries.info_entry('empty', 'No pull requests', 'No open pull requests were returned.', 'darkgray')
    end,
  })
end

local function list_starred(path, cb)
  if not api.is_authenticated() then
    cb {
      entries.info_entry(
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
      api.list_starred(page):next(function(payload)
        local mapped = {}
        for _, item in ipairs(payload.items or {}) do
          local owner = item.owner and item.owner.login or ''
          local repo_name = item.name or ''
          table.insert(mapped, entries.repo_entry(item, { key = encode_repo_ref(owner, repo_name) }))
        end
        done(mapped, payload.has_next == true, nil)
      end, function(err)
        done(nil, nil, err)
      end)
    end,
    empty_entry = function()
      return entries.info_entry('empty', 'No starred repositories', 'GitHub returned an empty list.', 'darkgray')
    end,
  })
end

local function list_search_root(_, cb)
  cb {
    entries.search_prompt_entry 'repo',
    entries.search_prompt_entry 'user',
  }
end

local function list_search_kind(path, cb)
  cb {
    entries.search_prompt_entry(path[3] or 'repo'),
  }
end

local function list_search_results(path, cb)
  local kind = path[3]
  local query = path[4]

  list_paginated(path, cb, {
    fetch_page = function(page, done)
      local handler = kind == 'user' and api.search_users or api.search_repositories
      handler(query, page):next(function(payload)
        local mapped = {}
        for _, item in ipairs(payload.items or {}) do
          if kind == 'user' then
            table.insert(mapped, entries.user_entry(item))
          else
            local owner = item.owner and item.owner.login or ''
            local repo_name = item.name or ''
            table.insert(mapped, entries.repo_entry(item, { key = encode_repo_ref(owner, repo_name) }))
          end
        end
        done(mapped, payload.has_next == true, nil)
      end, function(err)
        done(nil, nil, err)
      end)
    end,
    empty_entry = function()
      return entries.info_entry('empty', 'No search results', 'Try another query.', 'darkgray')
    end,
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

  if #path == 5 and path[5] == 'issues' then
    list_repo_issues(path, cb)
    return
  end

  if #path == 6 and path[5] == 'issues' then
    list_repo_issues(path, cb)
    return
  end

  if #path == 7 and path[5] == 'issues' and path[6] == 'search' then
    list_repo_issues(path, cb)
    return
  end

  if #path == 5 and path[5] == 'pulls' then
    list_repo_pulls(path, cb)
    return
  end

  if #path == 6 and path[5] == 'pulls' then
    list_repo_pulls(path, cb)
    return
  end

  if #path == 7 and path[5] == 'pulls' and path[6] == 'search' then
    list_repo_pulls(path, cb)
    return
  end

  if #path == 5 and path[5] == 'branches' then
    list_repo_branches(path, cb)
    return
  end

  if #path >= 6 and path[5] == 'branches' then
    list_repo_ref_contents(path, cb, 'branches')
    return
  end

  if #path == 5 and path[5] == 'tags' then
    list_repo_tags(path, cb)
    return
  end

  if #path >= 6 and path[5] == 'tags' then
    list_repo_ref_contents(path, cb, 'tags')
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

function M.reset()
  runtime.paginations = {}
  runtime.browsers = {}
end

function M.list(path, cb)
  if path[2] == 'notifications' and #path == 3 then
    local owner, repo = decode_repo_ref(path[3])
    if owner and repo then
      lc.api.go_to { 'github', 'repo', owner, repo }
      cb {
        entries.info_entry('redirect', 'Redirecting', 'Opening repository...', 'yellow'),
      }
      return
    end
  end

  if path[2] == 'starred' and #path == 3 then
    local owner, repo = decode_repo_ref(path[3])
    if owner and repo then
      lc.api.go_to { 'github', 'repo', owner, repo }
      cb {
        entries.info_entry('redirect', 'Redirecting', 'Opening repository...', 'yellow'),
      }
      return
    end
  end

  if path[2] == 'search' and path[3] == 'repo' and #path == 5 then
    local owner, repo = decode_repo_ref(path[5])
    if owner and repo then
      lc.api.go_to { 'github', 'repo', owner, repo }
      cb {
        entries.info_entry('redirect', 'Redirecting', 'Opening repository...', 'yellow'),
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
