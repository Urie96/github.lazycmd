local api = require 'github.api'
local config = require 'github.config'

local M = {}

local function span(text, color)
  local s = lc.style.span(tostring(text or ''))
  if color and color ~= '' then s = s:fg(color) end
  return s
end

local function line(parts) return lc.style.line(parts) end
local function text(lines) return lc.style.text(lines) end

local function trim(s)
  s = tostring(s or '')
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function hovered_entry() return lc.api.page_get_hovered() end

local function current_keymap()
  return ((config.get() or {}).keymap or {})
end

local function repo_path(owner, repo)
  if repo and repo ~= '' then return { 'github', 'repo', owner, repo } end
  return { 'github', 'repo', owner }
end

local function has_value(value) return value ~= nil and tostring(value) ~= '' end

local function bool_text(value) return value and 'yes' or 'no' end

local function format_date_only(value)
  value = tostring(value or '')
  if value == '' then return '-' end

  local ok, parsed = pcall(lc.time.parse, value)
  if not ok then return value end

  local ok_format, formatted = pcall(lc.time.format, parsed, '%Y-%m-%d')
  if not ok_format then return value end
  return formatted
end

local function format_count(value)
  local count = tonumber(value or 0) or 0
  if count >= 1000 then
    local count_k = count / 1000
    if count >= 100000 then
      return string.format('%.0fk', count_k)
    end
    return string.format('%.1fk', count_k)
  end
  return tostring(count)
end

local function kv(label, value, color)
  return line {
    span(label .. ': ', 'cyan'),
    span(has_value(value) and value or '-', color or 'white'),
  }
end

local function info_lines(title, detail, footer, color)
  local lines = {
    line { span(title, color or 'white') },
  }

  if detail and detail ~= '' then
    table.insert(lines, '')
    table.insert(lines, line { span(detail, 'darkgray') })
  end

  if footer and footer ~= '' then
    table.insert(lines, '')
    table.insert(lines, line { span(footer, 'yellow') })
  end

  return text(lines)
end

local function trim_content_for_preview(content)
  local max_chars = tonumber(config.get().readme_max_chars or 50000) or 50000
  content = tostring(content or '')
  if #content <= max_chars then return content, false end
  return content:sub(1, max_chars), true
end

function M.open_user_input()
  lc.input {
    prompt = 'Open GitHub user',
    placeholder = 'username',
    on_submit = function(input)
      local username = trim(input)
      if username == '' then
        lc.notify 'Username is required'
        return
      end
      lc.api.go_to(repo_path(username))
    end,
  }
end

function M.open_search_input(kind)
  kind = kind or 'repo'
  lc.input {
    prompt = 'Search GitHub ' .. kind,
    placeholder = 'query',
    on_submit = function(input)
      local query = trim(input)
      if query == '' then
        lc.api.go_to { 'github', 'search', kind }
        return
      end
      lc.api.go_to { 'github', 'search', kind, query }
    end,
  }
end

function M.search_repo_input() M.open_search_input 'repo' end
function M.search_user_input() M.open_search_input 'user' end

function M.go_to_user(entry)
  entry = entry or hovered_entry()
  local username = entry and (entry.username or entry.login or (entry.user and entry.user.login))
  if not has_value(username) then return end
  lc.api.go_to(repo_path(username))
end

function M.go_to_repo(entry)
  entry = entry or hovered_entry()
  local owner = entry and (entry.owner or (entry.repo and entry.repo.owner and entry.repo.owner.login))
  local repo = entry and (entry.repo_name or (entry.repo and entry.repo.name))
  if not has_value(owner) or not has_value(repo) then return end
  lc.api.go_to(repo_path(owner, repo))
end

function M.open_in_browser(entry)
  entry = entry or hovered_entry()
  local url = entry and (entry.html_url or entry.web_url or (entry.repo and entry.repo.html_url) or (entry.user and entry.user.html_url))
  if not has_value(url) then
    lc.notify 'No browser URL available'
    return
  end
  lc.system.open(url)
end

function M.go_to_path(path)
  if type(path) ~= 'table' or #path == 0 then return end
  lc.api.go_to(path)
end

function M.route_preview(entry)
  return info_lines(entry.title or entry.display or entry.key, entry.detail or '', entry.footer, entry.color or 'white')
end

function M.info_preview(entry)
  return info_lines(entry.title or 'Info', entry.message or '', entry.detail or '', entry.color or 'darkgray')
end

function M.user_preview(entry)
  local user = entry.user or {}
  return text {
    kv('User', user.login or entry.username or entry.key, 'green'),
    kv('Name', user.name, 'yellow'),
    kv('Followers', tostring(user.followers or '?'), 'cyan'),
    kv('Following', tostring(user.following or '?'), 'cyan'),
    kv('Public repos', tostring(user.public_repos or '?'), 'blue'),
    kv('Location', user.location, 'white'),
    kv('Blog', user.blog, 'white'),
    '',
    line { span(user.bio or 'Press Enter/Right to open repositories.', 'darkgray') },
  }
end

function M.repo_preview(entry, cb)
  local repo = entry.repo or {}
  local function render_preview(language_stats)
    local language_value = repo.language
    if language_stats and #language_stats > 0 then
      local parts = {}
      for _, item in ipairs(language_stats) do
        table.insert(parts, string.format('%s %s', item.name, item.percent))
      end
      language_value = table.concat(parts, ', ')
    end

    local lines = {
      kv('Visibility', repo.private and 'private' or 'public', repo.private and 'yellow' or 'cyan'),
      kv(language_stats and #language_stats > 0 and 'Languages' or 'Language', language_value, 'blue'),
      kv('Stars', format_count(repo.stargazers_count), 'yellow'),
      kv('Forks', format_count(repo.forks_count), 'cyan'),
      kv('Watchers', format_count(repo.watchers_count), 'cyan'),
      kv('Issues', tostring(repo.open_issues_count or 0), 'red'),
      kv('Updated', format_date_only(repo.updated_at), 'white'),
    }

    lc.style.align_columns(lines)
    table.insert(lines, '')
    table.insert(lines, line { span(repo.description or 'No description', 'white') })

    local rendered = {}
    for _, value in ipairs(lines) do
      table.insert(rendered, value)
    end

    return text(rendered)
  end

  if not entry.owner or not entry.repo_name then
    if cb then
      cb(render_preview())
      return
    end
    return render_preview()
  end

  local owner = entry.owner
  local repo_name = entry.repo_name

  local function build_language_stats(data)
    if type(data) ~= 'table' then return {} end

    local items = {}
    local total = 0
    for _, bytes in pairs(data) do
      total = total + (tonumber(bytes) or 0)
    end

    if total <= 0 then return {} end

    for name, bytes in pairs(data) do
      local count = tonumber(bytes) or 0
      if count > 0 then
        table.insert(items, {
          name = tostring(name),
          bytes = count,
          percent_value = count * 100 / total,
        })
      end
    end

    table.sort(items, function(a, b) return a.bytes > b.bytes end)

    local result = {}
    local limit = math.min(#items, 5)
    for i = 1, limit do
      local item = items[i]
      table.insert(result, {
        name = item.name,
        percent = string.format('%.1f%%', item.percent_value),
      })
    end
    return result
  end

  if entry.language_stats then
    if cb then
      cb(render_preview(entry.language_stats))
      return
    end
    return render_preview(entry.language_stats)
  end

  if cb then cb(render_preview()) end
  if entry.language_stats_loading then
    if not cb then return render_preview() end
    return
  end
  entry.language_stats_loading = true

  api.get_repo_languages(owner, repo_name, function(data, err)
    entry.language_stats_loading = false
    if err then
      entry.language_stats = {}
      if cb then cb(render_preview()) end
      return
    end
    entry.language_stats = build_language_stats(data)
    if cb then cb(render_preview(entry.language_stats)) end
  end)

  if not cb then return render_preview() end
end

function M.notification_preview(entry)
  local notif = entry.notification or {}
  local subject = notif.subject or {}
  local repository = notif.repository or {}
  return text {
    kv('Repo', repository.full_name or entry.repo_full_name, 'green'),
    kv('Type', subject.type, 'yellow'),
    kv('Reason', notif.reason, 'blue'),
    kv('Unread', bool_text(notif.unread ~= false), notif.unread ~= false and 'yellow' or 'darkgray'),
    kv('Updated', notif.updated_at, 'white'),
    '',
    line { span(subject.title or 'No title', 'white') },
  }
end

function M.load_more_preview(entry)
  if entry.loading then
    return info_lines('Loading more...', 'The next GitHub page is being fetched.', '', 'yellow')
  end
  return info_lines('Load more...', 'Fetch the next page from GitHub for this list.', '', 'yellow')
end

function M.readme_preview(entry, cb)
  entry = entry or hovered_entry()
  if not entry or entry.kind ~= 'readme' or not entry.owner or not entry.repo_name then
    cb 'README unavailable'
    return
  end

  cb(info_lines('README', 'Loading README from GitHub...', '', 'cyan'))

  api.get_repo_readme(entry.owner, entry.repo_name, function(content, err)
    if err then
      cb(info_lines('README', err, '', 'red'))
      return
    end

    if trim(content) == '' then
      cb(info_lines('README', 'This repository does not expose a README through the GitHub API.', '', 'darkgray'))
      return
    end

    local clipped, truncated = trim_content_for_preview(content)
    local rendered = lc.style.highlight(clipped, 'markdown')
    if truncated then
      rendered:append ''
      rendered:append(line { span('[truncated]', 'yellow') })
    end

    cb(rendered)
  end)
end

function M.search_prompt_preview(entry)
  local kind = entry.search_kind or 'repo'
  local keymap = current_keymap()
  return text {
    kv('Search kind', kind, kind == 'user' and 'green' or 'yellow'),
    '',
    line { span('Open this entry to input a query.', 'white') },
    line { span('Shortcut: ' .. tostring(keymap.search or 's'), 'darkgray') },
  }
end

return M
