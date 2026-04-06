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

local function hovered_entry() return lc.api.get_hovered() end

local function current_keymap()
  return ((config.get() or {}).keymap or {})
end

local function repo_path(owner, repo)
  if repo and repo ~= '' then return { 'github', 'repo', owner, repo } end
  return { 'github', 'repo', owner }
end

local function current_repo_owner()
  local path = lc.api.get_current_path() or {}
  if path[2] == 'repo' and path[3] and path[3] ~= '' then return tostring(path[3]) end
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

local function format_datetime(value)
  value = tostring(value or '')
  if value == '' then return '-' end

  local ok, parsed = pcall(lc.time.parse, value)
  if not ok then return value end

  local ok_format, formatted = pcall(lc.time.format, parsed, '%Y-%m-%d %H:%M')
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

local function format_size(bytes)
  local value = tonumber(bytes)
  if not value or value < 0 then return nil end
  if value < 1024 then return string.format('%dB', value) end

  local units = { 'K', 'M', 'G', 'T', 'P' }
  value = value / 1024
  for i, unit in ipairs(units) do
    if value < 1024 or i == #units then
      if value >= 10 then
        return string.format('%.0f%s', value, unit)
      end
      return string.format('%.1f%s', value, unit)
    end
    value = value / 1024
  end
end

local function kv(label, value, color)
  return line {
    span(label .. ': ', 'cyan'),
    span(has_value(value) and value or '-', color or 'white'),
  }
end

local function build_aligned_preview_header(fields, title)
  if #fields > 1 then lc.style.align_columns(fields) end

  local lines = {}
  lc.list_extend(lines, fields)
  table.insert(lines, '')
  table.insert(lines, line { span(title or '', 'white') })
  return text(lines)
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

local function trim_code_for_preview(content)
  local max_lines = tonumber(config.get().code_max_lines or 1200) or 1200
  local max_chars = tonumber(config.get().code_max_chars or 80000) or 80000
  content = tostring(content or '')
  local truncated = false

  if max_lines > 0 then
    local newline_count = 0
    for pos in content:gmatch '()\n' do
      newline_count = newline_count + 1
      if newline_count >= max_lines then
        content = content:sub(1, pos - 1)
        truncated = true
        break
      end
    end
  end

  if #content > max_chars then
    content = content:sub(1, max_chars)
    truncated = true
  end

  return content, truncated
end

local function detect_language_from_name(name)
  name = tostring(name or ''):lower()
  if name == 'dockerfile' then return 'dockerfile' end
  return name:match '%.([^.]+)$'
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

function M.search_current_user_repos_input(entry_or_username)
  local username

  if type(entry_or_username) == 'string' then
    username = trim(entry_or_username)
  elseif type(entry_or_username) == 'table' then
    username = trim(entry_or_username.username or entry_or_username.owner or entry_or_username.login or '')
  else
    username = trim(current_repo_owner() or '')
  end

  if username == '' then
    lc.notify 'Repository owner is unavailable'
    return
  end

  lc.input {
    prompt = 'Search ' .. username .. ' repositories',
    placeholder = 'repo name / keywords',
    on_submit = function(input)
      local query = trim(input)
      if query == '' then
        lc.notify 'Search query is required'
        return
      end

      lc.api.go_to { 'github', 'search', 'repo', 'user:' .. username .. ' ' .. query }
    end,
  }
end

local function current_repo_ref()
  local path = lc.api.get_current_path() or {}
  if path[2] ~= 'repo' or not path[3] or not path[4] then return nil, nil end
  return tostring(path[3]), tostring(path[4])
end

local function open_repo_item_search(kind)
  local owner, repo = current_repo_ref()
  if not has_value(owner) or not has_value(repo) then
    lc.notify 'Repository path is unavailable'
    return
  end

  local label = kind == 'pulls' and 'pull requests' or 'issues'
  lc.input {
    prompt = string.format('Search %s/%s %s', owner, repo, label),
    placeholder = 'query',
    on_submit = function(input)
      local query = trim(input)
      if query == '' then
        lc.api.go_to { 'github', 'repo', owner, repo, kind }
        return
      end
      lc.api.go_to { 'github', 'repo', owner, repo, kind, 'search', query }
    end,
  }
end

function M.search_repo_issues_input() open_repo_item_search 'issues' end
function M.search_repo_pulls_input() open_repo_item_search 'pulls' end

local function open_repo_item_state_filter(kind)
  local owner, repo = current_repo_ref()
  if not has_value(owner) or not has_value(repo) then
    lc.notify 'Repository path is unavailable'
    return
  end

  local label = kind == 'pulls' and 'pull requests' or 'issues'
  lc.select({
    prompt = string.format('Filter %s/%s %s by state', owner, repo, label),
    options = {
      { value = 'open', display = line { span('Open', 'red') } },
      { value = 'closed', display = line { span('Closed', 'magenta') } },
    },
  }, function(choice)
    if not choice or choice == '' then return end
    lc.api.go_to { 'github', 'repo', owner, repo, kind, tostring(choice) }
  end)
end

function M.filter_repo_issues_state_input() open_repo_item_state_filter 'issues' end
function M.filter_repo_pulls_state_input() open_repo_item_state_filter 'pulls' end

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
      local percent = string.format('%.1f%%', item.percent_value)
      if percent ~= '0.0%' then
        table.insert(result, {
          name = item.name,
          percent = percent,
        })
      end
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

  api.get_repo_languages(owner, repo_name):next(function(data)
    entry.language_stats_loading = false
    entry.language_stats = build_language_stats(data)
    if cb then cb(render_preview(entry.language_stats)) end
  end, function()
    entry.language_stats_loading = false
    entry.language_stats = {}
    if cb then cb(render_preview()) end
  end)

  if not cb then return render_preview() end
end

function M.notification_preview(entry)
  local notif = entry.notification or {}
  local subject = notif.subject or {}
  local repository = notif.repository or {}
  return text {
    kv('Repo', repository.full_name or entry.repo_full_name, 'green'),
    kv('Type', entry.notification_target_kind or subject.type, 'yellow'),
    kv('Reason', notif.reason, 'blue'),
    kv('Unread', bool_text(notif.unread ~= false), notif.unread ~= false and 'yellow' or 'darkgray'),
    kv('Updated', format_datetime(notif.updated_at), 'white'),
    kv('Open', entry.html_url, 'darkgray'),
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

  api.get_repo_readme(entry.owner, entry.repo_name):next(function(content)
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
  end, function(err)
    cb(info_lines('README', err, '', 'red'))
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

function M.repo_ref_preview(entry)
  local ref = entry.ref or {}
  local commit = ref.commit or {}
  local label = entry.ref_kind == 'branches' and 'Branch' or 'Tag'
  return text {
    kv(label, entry.ref_name or entry.key, entry.ref_kind == 'branches' and 'green' or 'cyan'),
    kv('Commit', commit.sha or entry.ref_target or '-', 'yellow'),
    '',
    line { span('Press Enter/Right to browse repository code at this ref.', 'darkgray') },
  }
end

function M.repo_content_preview(entry, cb)
  local item = entry.item or {}
  local item_type = tostring(item.type or '')

  if item_type ~= 'file' then
    return text {
      kv('Path', entry.item_path or item.path or entry.key, 'yellow'),
      kv('Type', item_type ~= '' and item_type or 'dir', 'cyan'),
      kv('Ref', entry.ref_name or '-', 'green'),
      '',
      line { span('Press Enter/Right to open this directory.', 'darkgray') },
    }
  end

  local function render_file(content)
    local clipped, truncated = trim_code_for_preview(content or '')
    local language = detect_language_from_name(item.name or entry.item_path) or 'text'
    local rendered = lc.style.highlight(clipped, language)
    if truncated then
      rendered:append ''
      rendered:append(line { span('[truncated]', 'yellow') })
    end
    return rendered
  end

  if type(item.decoded_content) == 'string' and item.decoded_content ~= '' then
    local preview = render_file(item.decoded_content)
    if cb then
      cb(preview)
      return
    end
    return preview
  end

  if cb then cb(info_lines('Code', 'Loading file content from GitHub...', '', 'cyan')) end
  api.get_repo_contents(entry.owner, entry.repo_name, entry.ref_name, entry.item_path):next(function(data)
    entry.item = data or entry.item
    local content = data and data.decoded_content or ''
    if content == '' then
      if cb then cb(info_lines('Code', 'This file does not expose decodable text content.', '', 'darkgray')) end
      return
    end
    if cb then cb(render_file(content)) end
  end, function(err)
    if cb then cb(info_lines('Code', err, '', 'red')) end
  end)

  if not cb then
    return info_lines('Code', 'Loading file content from GitHub...', '', 'cyan')
  end
end

function M.issue_preview(entry)
  local issue = entry.issue or {}
  local header = build_aligned_preview_header({
    kv('Issue', '#' .. tostring(issue.number or '?'), 'yellow'),
    kv('State', issue.state or 'open', (issue.state or 'open') == 'open' and 'red' or 'magenta'),
    kv('Author', issue.user and issue.user.login, 'cyan'),
    kv('Comments', tostring(issue.comments or 0), 'blue'),
    kv('Created', format_datetime(issue.created_at), 'white'),
    kv('Updated', format_datetime(issue.updated_at), 'white'),
  }, issue.title or 'Issue')

  if issue.body and issue.body ~= '' then
    return text {
      header,
      '',
      lc.style.highlight(issue.body, 'markdown'),
    }
  end

  return text {
    header,
    '',
    line { span('No description', 'darkgray') },
  }
end

function M.pull_preview(entry)
  local pr = entry.pull or {}
  local merged = pr.merged_at ~= nil
  local state_label = merged and 'merged' or (pr.state or 'open')
  local state_color = merged and 'magenta' or ((pr.state or 'open') == 'open' and 'red' or 'magenta')

  local header = build_aligned_preview_header({
    kv('Pull', '#' .. tostring(pr.number or '?'), 'magenta'),
    kv('State', state_label, state_color),
    kv('Author', pr.user and pr.user.login, 'cyan'),
    kv('Comments', tostring(pr.comments or 0), 'blue'),
    kv('Draft', bool_text(pr.draft == true), pr.draft and 'yellow' or 'darkgray'),
    kv('Created', format_datetime(pr.created_at), 'white'),
    kv('Updated', format_datetime(pr.updated_at), 'white'),
  }, pr.title or 'Pull request')

  if pr.body and pr.body ~= '' then
    return text {
      header,
      '',
      lc.style.highlight(pr.body, 'markdown'),
    }
  end

  return text {
    header,
    '',
    line { span('No description', 'darkgray') },
  }
end

function M.discussion_preview(entry)
  local discussion = entry.discussion or {}
  local state_label = discussion.closed and 'closed' or (discussion.is_answered and 'answered' or 'open')
  local state_color = discussion.closed and 'magenta' or (discussion.is_answered and 'green' or 'cyan')
  local category = ((discussion.category or {}).name)

  local header = build_aligned_preview_header({
    kv('Discussion', '#' .. tostring(discussion.number or '?'), 'cyan'),
    kv('State', state_label, state_color),
    kv('Author', discussion.user and discussion.user.login, 'cyan'),
    kv('Category', category, 'yellow'),
    kv('Comments', tostring(discussion.comments or 0), 'blue'),
    kv('Created', format_datetime(discussion.created_at), 'white'),
    kv('Updated', format_datetime(discussion.updated_at), 'white'),
  }, discussion.title or 'Discussion')

  if discussion.body and discussion.body ~= '' then
    return text {
      header,
      '',
      lc.style.highlight(discussion.body, 'markdown'),
    }
  end

  return text {
    header,
    '',
    line { span('No description', 'darkgray') },
  }
end

function M.comment_preview(entry)
  local comment = entry.comment or {}
  local author = ((comment.user or {}).login) or ((comment.author or {}).login) or '-'
  local detail = entry.kind == 'pull_review' and 'Review'
    or (entry.kind == 'pull_review_comment' and 'Review comment' or 'Comment')
  local created = comment.created_at or comment.submitted_at or comment.updated_at
  local path = comment.path or '-'
  local body = trim(comment.body or comment.body_text or '')

  local header = build_aligned_preview_header({
    kv('Kind', detail, 'yellow'),
    kv('Author', author, 'cyan'),
    kv('Created', format_datetime(created), 'white'),
    kv('Path', path, 'green'),
  }, detail)

  if body ~= '' then
    return text {
      header,
      '',
      lc.style.highlight(body, 'markdown'),
    }
  end

  if comment.diff_hunk and comment.diff_hunk ~= '' then
    return text {
      header,
      '',
      lc.style.highlight(comment.diff_hunk, 'diff'),
    }
  end

  return text {
    header,
    '',
    line { span('No content', 'darkgray') },
  }
end

return M
