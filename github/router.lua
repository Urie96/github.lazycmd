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
  local plugin_keymap = (config.get() or {}).keymap or {}
  local global_config = (lc.config.get() or {}).keymap or {}
  local browser_key_name = plugin_keymap.open_in_browser
  local enter_key_name = global_config.enter
  local open_key_name = global_config.open
  local base_path = lc.api.get_current_path() or {}
  local out = {}

  for _, entry in ipairs(items or {}) do
    if entry.handle then
      entry.owner = entry.handle.owner
      entry.repo_name = entry.handle.repo_name
      entry.ref_kind = entry.handle.ref_kind
      entry.ref_name = entry.handle.ref_name
      entry.html_url = entry.handle.html_url
      entry.web_url = entry.handle.web_url

      local maps = lc.tbl_extend('force', {}, entry.keymap or {})

      if browser_key_name and browser_key_name ~= '' and entry.web_url then
        maps[browser_key_name] = { callback = action.open_in_browser, desc = 'open in browser' }
      end

      if not entry.handle.is_dir then
        -- For files: enter opens in $EDITOR, open/right keeps default browser action
        if enter_key_name and enter_key_name ~= '' then
          maps[enter_key_name] = { callback = action.open_file_in_editor, desc = 'open in editor' }
        end
      else
        -- For directories: enter/open navigates into the directory
        local nav_path = { table.unpack(base_path) }
        table.insert(nav_path, entry.key)
        if enter_key_name and enter_key_name ~= '' then
          maps[enter_key_name] = { callback = function() action.go_to_path(nav_path) end, desc = 'open directory' }
        end
        if open_key_name and open_key_name ~= '' and open_key_name ~= enter_key_name then
          maps[open_key_name] = { callback = function() action.go_to_path(nav_path) end, desc = 'open directory' }
        end
      end

      entry.keymap = maps
    end
    table.insert(out, entry)
  end

  return out
end

local function decorate_repo_item_page_keymap(path, items)
  path = path or {}
  items = items or {}

  if #path < 5 or path[2] ~= 'repo' then return end

  local plugin_keymap = config.get().keymap or {}
  local search_key = plugin_keymap.search
  local filter_key = plugin_keymap.filter_state

  local callback
  local desc
  local filter_callback
  local filter_desc = 'filter by state'

  if path[5] == 'issues' then
    callback = action.search_repo_issues_input
    desc = 'search issues'
    filter_callback = action.filter_repo_issues_state_input
  elseif path[5] == 'pulls' then
    callback = action.search_repo_pulls_input
    desc = 'search pull requests'
    filter_callback = action.filter_repo_pulls_state_input
  else
    return
  end

  for _, entry in ipairs(items) do
    entry.keymap = entry.keymap or {}
    if search_key and search_key ~= '' and entry.keymap[search_key] == nil then
      entry.keymap[search_key] = { callback = callback, desc = desc }
    end
    if filter_key and filter_key ~= '' and filter_callback and entry.keymap[filter_key] == nil then
      entry.keymap[filter_key] = { callback = filter_callback, desc = filter_desc }
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

  decorate_repo_item_page_keymap(state.path, items)
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
    entries.route_entry('notifications', 'Notifications', authed and 'Read and unread, paginated.' or 'Requires token.', 'yellow', {
      label = 'Notifications',
      icon = '󰜘',
    }),
    entries.route_entry('trending', 'Browse trending repositories', 'Today, this week, and this month.', 'magenta', {
      label = 'Trending',
      icon = '',
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

local function list_trending_root(_, cb)
  local plugin_keymap = config.get().keymap or {}

  local function period_entry(key, label, detail, color)
    local path = { 'github', 'trending', key }
    return {
      key = key,
      kind = 'route',
      title = label,
      detail = detail,
      color = color,
      display = lc.style.line {
        lc.style.span(' ', color),
        lc.style.span(label, color),
      },
      keymap = {
        [plugin_keymap.open] = { callback = function() action.go_to_path(path) end, desc = 'open' },
        [plugin_keymap.enter] = { callback = function() action.go_to_path(path) end, desc = 'open' },
      },
      preview = action.route_preview,
    }
  end

  cb {
    period_entry('daily', 'Today', 'Trending repositories today.', 'green'),
    period_entry('weekly', 'This week', 'Trending repositories this week.', 'yellow'),
    period_entry('monthly', 'This month', 'Trending repositories this month.', 'magenta'),
  }
end

local function list_trending_period(path, cb)
  local period = tostring(path[3] or 'daily')
  local title_map = {
    daily = 'today',
    weekly = 'this week',
    monthly = 'this month',
  }

  cb {
    entries.info_entry('loading', 'Loading trending', 'Fetching github.com/trending (' .. period .. ') ...', 'cyan'),
  }

  api.list_trending(period):next(function(items)
    local mapped = {}
    for _, item in ipairs(items or {}) do
      table.insert(mapped, entries.trending_repo_entry(item))
    end

    if #mapped == 0 then
      mapped = {
        entries.info_entry(
          'empty',
          'No trending repositories',
          'GitHub returned an empty list for ' .. (title_map[period] or period) .. '.',
          'darkgray'
        ),
      }
    else
      entries.align_repo_entry_columns(mapped)
    end

    if current_path_equals(path) then lc.api.set_entries(nil, mapped) end
  end, function(err)
    if current_path_equals(path) then
      lc.api.set_entries(nil, {
        entries.info_entry('error', 'GitHub request failed', err, 'red'),
      })
    end
  end)
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
    entries.repo_detail_route_entry('discussions', owner, repo_name),
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
  local state = (path[6] == 'open' or path[6] == 'closed') and path[6] or nil

  list_paginated(path, cb, {
    fetch_page = function(page, done)
      local promise
      if query and query ~= '' then
        promise = api.search_repo_issues(owner, repo_name, query, page)
      else
        promise = api.list_repo_issues(owner, repo_name, page, state)
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
      if state == 'open' then
        return entries.info_entry('empty', 'No issues', 'No open issues were returned.', 'darkgray')
      end
      if state == 'closed' then
        return entries.info_entry('empty', 'No issues', 'No closed issues were returned.', 'darkgray')
      end
      return entries.info_entry('empty', 'No issues', 'No issues were returned.', 'darkgray')
    end,
  })
end

local function sort_comments(items)
  table.sort(items, function(a, b)
    local a_time = tostring(a.sort_time or '')
    local b_time = tostring(b.sort_time or '')
    if a_time == b_time then
      return tostring((a.entry and a.entry.key) or '') < tostring((b.entry and b.entry.key) or '')
    end
    return a_time < b_time
  end)
  return items
end

local function sort_by_timestamp(items, field)
  table.sort(items, function(a, b)
    local a_time = tostring((a or {})[field] or (a or {}).updated_at or '')
    local b_time = tostring((b or {})[field] or (b or {}).updated_at or '')
    if a_time == b_time then
      return tostring((a or {}).id or (a or {}).node_id or '') < tostring((b or {}).id or (b or {}).node_id or '')
    end
    return a_time < b_time
  end)
  return items
end

local function append_pull_review_thread(mapped, comment, replies_by_parent)
  local suffix = comment.path and (tostring(comment.path) .. ':' .. tostring(comment.line or comment.original_line or '?')) or nil
  table.insert(mapped, entries.comment_entry(comment, {
    kind = 'pull_review_comment',
    prefix = '󰘬',
    color = 'yellow',
    suffix = suffix,
    indent = 2,
  }))

  for _, reply in ipairs(replies_by_parent[tostring(comment.id or '')] or {}) do
    local reply_suffix = reply.path and (tostring(reply.path) .. ':' .. tostring(reply.line or reply.original_line or '?')) or nil
    table.insert(mapped, entries.comment_entry(reply, {
      kind = 'pull_review_comment',
      prefix = '󰘍',
      color = 'cyan',
      suffix = reply_suffix,
      indent = 4,
    }))
  end
end

local function collect_all_pages(loader, cb, page, acc)
  page = tonumber(page or 1) or 1
  acc = acc or {}

  loader(page):next(function(payload)
    for _, item in ipairs((payload or {}).items or {}) do
      table.insert(acc, item)
    end

    if payload and payload.has_next == true then
      collect_all_pages(loader, cb, page + 1, acc)
      return
    end

    cb(acc, nil)
  end, function(err)
    cb(nil, err)
  end)
end

local function list_repo_issue_detail(path, cb)
  local owner = path[3]
  local repo_name = path[4]
  local number = tostring(path[6] or '')

  cb {
    entries.info_entry('loading', 'Loading issue', 'Fetching issue details and comments...', 'cyan'),
  }

  Promise.all({
    api.get_issue(owner, repo_name, number),
    Promise.new(function(resolve, reject)
      collect_all_pages(function(page)
        return api.list_issue_comments(owner, repo_name, number, page)
      end, function(items, err)
        if err then
          reject(err)
          return
        end
        resolve(items or {})
      end)
    end),
  }):next(function(results)
    local issue = results[1] or {}
    local comments = results[2] or {}
    issue.owner = issue.owner or owner
    issue.repo_name = issue.repo_name or repo_name

    local mapped = {
      entries.issue_detail_entry(issue),
    }

    if #comments == 0 then
      table.insert(mapped, entries.info_entry('empty-comments', 'No comments', 'This issue has no comments.', 'darkgray'))
    else
      for _, item in ipairs(comments) do
        table.insert(mapped, entries.comment_entry(item, { kind = 'issue_comment', prefix = '', color = 'blue' }))
      end
    end

    if current_path_equals(path) then lc.api.set_entries(nil, mapped) end
  end, function(err)
    if current_path_equals(path) then
      lc.api.set_entries(nil, {
        entries.info_entry('error', 'GitHub request failed', err, 'red'),
      })
    end
  end)
end

local function list_repo_pulls(path, cb)
  local owner = path[3]
  local repo_name = path[4]
  local query = (path[6] == 'search') and path[7] or nil
  local state = (path[6] == 'open' or path[6] == 'closed') and path[6] or nil

  list_paginated(path, cb, {
    fetch_page = function(page, done)
      local promise
      if query and query ~= '' then
        promise = api.search_repo_pulls(owner, repo_name, query, page)
      else
        promise = api.list_repo_pulls(owner, repo_name, page, state)
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
      if state == 'open' then
        return entries.info_entry('empty', 'No pull requests', 'No open pull requests were returned.', 'darkgray')
      end
      if state == 'closed' then
        return entries.info_entry('empty', 'No pull requests', 'No closed pull requests were returned.', 'darkgray')
      end
      return entries.info_entry('empty', 'No pull requests', 'No pull requests were returned.', 'darkgray')
    end,
  })
end

local function list_repo_pull_detail(path, cb)
  local owner = path[3]
  local repo_name = path[4]
  local number = tostring(path[6] or '')

  cb {
    entries.info_entry('loading', 'Loading pull request', 'Fetching pull request details and comments...', 'cyan'),
  }

  Promise.all({
    api.get_pull(owner, repo_name, number),
    Promise.new(function(resolve, reject)
      collect_all_pages(function(page)
        return api.list_pull_issue_comments(owner, repo_name, number, page)
      end, function(items, err)
        if err then
          reject(err)
          return
        end
        resolve(items or {})
      end)
    end),
    Promise.new(function(resolve, reject)
      collect_all_pages(function(page)
        return api.list_pull_reviews(owner, repo_name, number, page)
      end, function(items, err)
        if err then
          reject(err)
          return
        end
        resolve(items or {})
      end)
    end),
    Promise.new(function(resolve, reject)
      collect_all_pages(function(page)
        return api.list_pull_review_comments(owner, repo_name, number, page)
      end, function(items, err)
        if err then
          reject(err)
          return
        end
        resolve(items or {})
      end)
    end),
  }):next(function(results)
    local pr = results[1] or {}
    local issue_comments = results[2] or {}
    local reviews = results[3] or {}
    local review_comments = results[4] or {}
    pr.owner = pr.owner or owner
    pr.repo_name = pr.repo_name or repo_name

    local mapped = {
      entries.pull_detail_entry(pr),
    }

    sort_by_timestamp(issue_comments, 'created_at')
    sort_by_timestamp(reviews, 'submitted_at')
    sort_by_timestamp(review_comments, 'created_at')

    local replies_by_parent = {}
    local root_comments = {}
    for _, item in ipairs(review_comments) do
      local parent_id = item.in_reply_to_id
      if parent_id ~= nil and tostring(parent_id) ~= '' then
        local key = tostring(parent_id)
        replies_by_parent[key] = replies_by_parent[key] or {}
        table.insert(replies_by_parent[key], item)
      else
        table.insert(root_comments, item)
      end
    end
    for _, items in pairs(replies_by_parent) do
      sort_by_timestamp(items, 'created_at')
    end

    local root_comments_by_review = {}
    local consumed_root_ids = {}
    for _, item in ipairs(root_comments) do
      local review_id = item.pull_request_review_id
      if review_id ~= nil and tostring(review_id) ~= '' then
        local key = tostring(review_id)
        root_comments_by_review[key] = root_comments_by_review[key] or {}
        table.insert(root_comments_by_review[key], item)
      end
    end
    for _, items in pairs(root_comments_by_review) do
      sort_by_timestamp(items, 'created_at')
    end

    local events = {}

    for _, item in ipairs(issue_comments) do
      table.insert(events, {
        sort_time = tostring(item.created_at or item.updated_at or ''),
        render = function(out)
          table.insert(out, entries.comment_entry(item, { kind = 'pull_comment', prefix = '', color = 'blue' }))
        end,
      })
    end

    for _, review in ipairs(reviews) do
      local review_key = tostring(review.id or '')
      local attached_roots = root_comments_by_review[review_key] or {}
      for _, root in ipairs(attached_roots) do
        consumed_root_ids[tostring(root.id or '')] = true
      end

      if tostring(review.body or '') ~= '' or #attached_roots > 0 then
        table.insert(events, {
          sort_time = tostring(review.submitted_at or review.created_at or review.updated_at or ''),
          render = function(out)
            if tostring(review.body or '') ~= '' then
              table.insert(out, entries.comment_entry(review, {
                kind = 'pull_review',
                prefix = '󰙨',
                color = 'magenta',
                suffix = tostring(review.state or 'review'),
              }))
            end

            for _, root in ipairs(attached_roots) do
              append_pull_review_thread(out, root, replies_by_parent)
            end
          end,
        })
      end
    end

    for _, root in ipairs(root_comments) do
      local root_id = tostring(root.id or '')
      if not consumed_root_ids[root_id] then
        table.insert(events, {
          sort_time = tostring(root.created_at or root.updated_at or ''),
          render = function(out)
            append_pull_review_thread(out, root, replies_by_parent)
          end,
        })
      end
    end

    table.sort(events, function(a, b)
      local a_time = tostring(a.sort_time or '')
      local b_time = tostring(b.sort_time or '')
      if a_time == b_time then return false end
      return a_time < b_time
    end)

    if #events == 0 then
      table.insert(mapped, entries.info_entry('empty-comments', 'No comments', 'This pull request has no comments.', 'darkgray'))
    else
      for _, event in ipairs(events) do
        event.render(mapped)
      end
    end

    if current_path_equals(path) then lc.api.set_entries(nil, mapped) end
  end, function(err)
    if current_path_equals(path) then
      lc.api.set_entries(nil, {
        entries.info_entry('error', 'GitHub request failed', err, 'red'),
      })
    end
  end)
end

local function list_repo_discussions(path, cb)
  if not api.is_authenticated() then
    cb {
      entries.info_entry(
        'auth',
        'Token required',
        'Discussions currently use the GitHub GraphQL API and require a token.',
        'yellow',
        "Pass token in require('github').setup { token = ... }."
      ),
    }
    return
  end

  local owner = path[3]
  local repo_name = path[4]
  local cursor_by_page = { [1] = '' }

  list_paginated(path, cb, {
    fetch_page = function(page, done)
      local after = cursor_by_page[page] or ''
      api.list_repo_discussions(owner, repo_name, after):next(function(payload)
        local mapped = {}
        for _, item in ipairs(payload.items or {}) do
          item.owner = owner
          item.repo_name = repo_name
          table.insert(mapped, entries.discussion_entry(item))
        end
        cursor_by_page[page + 1] = payload.cursor or ''
        done(mapped, payload.has_next == true, nil)
      end, function(err)
        done(nil, nil, err)
      end)
    end,
    empty_entry = function()
      return entries.info_entry('empty', 'No discussions', 'No discussions were returned.', 'darkgray')
    end,
  })
end

local function list_repo_discussion_detail(path, cb)
  if not api.is_authenticated() then
    cb {
      entries.info_entry(
        'auth',
        'Token required',
        'Discussion details currently use the GitHub GraphQL API and require a token.',
        'yellow',
        "Pass token in require('github').setup { token = ... }."
      ),
    }
    return
  end

  local owner = path[3]
  local repo_name = path[4]
  local number = tostring(path[6] or '')

  cb {
    entries.info_entry('loading', 'Loading discussion', 'Fetching discussion details and comments...', 'cyan'),
  }

  local all_comments = {}
  local function collect_discussion_comments(after, resolve, reject)
    api.list_discussion_comments(owner, repo_name, number, after):next(function(payload)
      for _, item in ipairs(payload.items or {}) do
        table.insert(all_comments, item)
      end

      if payload.has_next == true and payload.cursor and payload.cursor ~= '' then
        collect_discussion_comments(payload.cursor, resolve, reject)
        return
      end

      resolve(all_comments)
    end, reject)
  end

  Promise.all({
    api.get_repo_discussion(owner, repo_name, number),
    Promise.new(function(resolve, reject)
      collect_discussion_comments('', resolve, reject)
    end),
  }):next(function(results)
    local discussion = results[1] or {}
    local comments = results[2] or {}

    local mapped = {
      entries.discussion_detail_entry(discussion),
    }

    if #comments == 0 then
      table.insert(mapped, entries.info_entry('empty-comments', 'No comments', 'This discussion has no comments.', 'darkgray'))
    else
      -- Preserve parent-comment grouping: replies should stay adjacent to the
      -- comment node they came from instead of being globally time-sorted.
      for _, item in ipairs(comments) do
        table.insert(mapped, entries.comment_entry(item, {
          kind = item.kind or 'discussion_comment',
          prefix = item.is_answer and '' or ((item.kind == 'discussion_reply') and '󰘍' or ''),
          color = item.is_answer and 'green' or ((item.kind == 'discussion_reply') and 'cyan' or 'blue'),
          suffix = item.is_answer and 'answer' or nil,
          indent = item.kind == 'discussion_reply' and 2 or 0,
        }))
      end
    end

    if current_path_equals(path) then lc.api.set_entries(nil, mapped) end
  end, function(err)
    if current_path_equals(path) then
      lc.api.set_entries(nil, {
        entries.info_entry('error', 'GitHub request failed', err, 'red'),
      })
    end
  end)
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

  if #path == 6 and path[5] == 'issues' and (path[6] == 'open' or path[6] == 'closed') then
    list_repo_issues(path, cb)
    return
  end

  if #path == 6 and path[5] == 'issues' and path[6] ~= 'search' then
    list_repo_issue_detail(path, cb)
    return
  end

  if #path == 6 and path[5] == 'issues' and path[6] == 'search' then
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

  if #path == 5 and path[5] == 'discussions' then
    list_repo_discussions(path, cb)
    return
  end

  if #path == 6 and path[5] == 'pulls' and (path[6] == 'open' or path[6] == 'closed') then
    list_repo_pulls(path, cb)
    return
  end

  if #path == 6 and path[5] == 'pulls' and path[6] ~= 'search' then
    list_repo_pull_detail(path, cb)
    return
  end

  if #path == 6 and path[5] == 'discussions' then
    list_repo_discussion_detail(path, cb)
    return
  end

  if #path == 6 and path[5] == 'pulls' and path[6] == 'search' then
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

  if route == 'trending' then
    if #path == 2 then
      list_trending_root(path, cb)
      return
    end

    if #path == 3 and (path[3] == 'daily' or path[3] == 'weekly' or path[3] == 'monthly') then
      list_trending_period(path, cb)
      return
    end

    cb {}
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
