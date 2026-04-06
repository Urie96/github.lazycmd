local action = require 'github.action'
local config = require 'github.config'
local file = require 'file'

local M = {}

local function span(text, color)
  local s = lc.style.span(tostring(text or ''))
  if color and color ~= '' then s = s:fg(color) end
  return s
end

local function line(parts) return lc.style.line(parts) end

local function repo_html_url(owner, repo)
  owner = tostring(owner or '')
  repo = tostring(repo or '')
  if owner == '' or repo == '' then return nil end
  return 'https://github.com/' .. owner .. '/' .. repo
end

local function repo_ref_web_url(owner, repo, ref_target, item_path, is_file)
  local base = repo_html_url(owner, repo)
  ref_target = tostring(ref_target or '')
  item_path = tostring(item_path or '')
  if not base or ref_target == '' then return base end

  local mode = is_file and 'blob' or 'tree'
  if item_path == '' then return string.format('%s/%s/%s', base, mode, ref_target) end
  return string.format('%s/%s/%s/%s', base, mode, ref_target, item_path)
end

local function excerpt(value, max_len)
  value = tostring(value or ''):gsub('%s+', ' ')
  max_len = tonumber(max_len or 72) or 72
  if #value <= max_len then return value end
  return value:sub(1, max_len - 3) .. '...'
end

local function format_relative_time(value)
  value = tostring(value or '')
  if value == '' then return nil end

  local ok_parse, timestamp = pcall(lc.time.parse, value)
  if not ok_parse then return value end

  local ok_format, formatted = pcall(lc.time.format, timestamp, 'relative')
  if not ok_format then return value end
  return formatted
end

local function first_body_summary(body)
  body = tostring(body or '')
  if body == '' then return nil end

  local first_content_line = nil
  for raw_line in body:gmatch '([^\n\r]+)' do
    local line = tostring(raw_line):gsub('^%s+', ''):gsub('%s+$', '')
    if line ~= '' then
      if not first_content_line then first_content_line = line end
      if line:sub(1, 1) ~= '>' then return excerpt(line, 120) end
    end
  end

  if first_content_line and first_content_line ~= '' then return excerpt(first_content_line, 120) end
  return nil
end

local function summary_from_comment(comment)
  local body_summary = first_body_summary(comment.body or comment.body_text)
  if body_summary and body_summary ~= '' then return body_summary end
  return excerpt(comment.diff_hunk or '', 120)
end

local function issue_time_text(issue)
  local state = tostring(issue.state or 'open')
  local prefix = state == 'closed' and 'closed' or 'opened'
  local source = state == 'closed' and issue.closed_at or issue.created_at
  local formatted = format_relative_time(source)
  if formatted and formatted ~= '' then return prefix .. ' ' .. formatted end
  return prefix
end

local function pull_time_text(pr)
  local state = tostring(pr.state or 'open')
  local merged = pr.merged_at ~= nil and pr.merged_at ~= ''
  local prefix = merged and 'merged' or (state == 'closed' and 'closed' or 'opened')
  local source = merged and pr.merged_at or ((state == 'closed' and pr.closed_at) or pr.created_at)
  local formatted = format_relative_time(source)
  if formatted and formatted ~= '' then return prefix .. ' ' .. formatted end
  return prefix
end

local function discussion_time_text(discussion)
  local closed = discussion.closed == true or tostring(discussion.state or '') == 'closed'
  local answered = discussion.is_answered == true
  local prefix = closed and 'closed' or (answered and 'answered' or 'updated')
  local source = closed and discussion.closed_at or (discussion.updated_at or discussion.created_at)

  local formatted = format_relative_time(source)
  if formatted and formatted ~= '' then return prefix .. ' ' .. formatted end
  return prefix
end

local function discussion_style(discussion)
  if discussion.closed == true or tostring(discussion.state or '') == 'closed' then
    return '', 'magenta'
  end
  if discussion.is_answered == true then
    return '', 'green'
  end
  return '', 'cyan'
end

local function notification_target(notification, owner, repo)
  local repository = notification.repository or {}
  local subject = notification.subject or {}
  local base = repo_html_url(owner, repo) or repository.html_url
  local subject_type = tostring(subject.type or '')
  local subject_url = tostring(subject.url or '')

  if not base or base == '' then return { kind = subject_type, web_url = nil, path = nil } end

  local resource, identifier = subject_url:match '/repos/[^/]+/[^/]+/([^/?#]+)/([^/?#]+)'
  resource = tostring(resource or '')
  identifier = tostring(identifier or '')

  if resource == 'pulls' and identifier ~= '' then
    return {
      kind = 'PullRequest',
      web_url = string.format('%s/pull/%s', base, identifier),
      path = { 'github', 'repo', owner, repo, 'pulls', identifier },
    }
  end

  if resource == 'issues' and identifier ~= '' then
    if subject_type == 'PullRequest' then
      return {
        kind = 'PullRequest',
        web_url = string.format('%s/pull/%s', base, identifier),
        path = { 'github', 'repo', owner, repo, 'pulls', identifier },
      }
    end

    return {
      kind = 'Issue',
      web_url = string.format('%s/issues/%s', base, identifier),
      path = { 'github', 'repo', owner, repo, 'issues', identifier },
    }
  end

  if resource == 'discussions' and identifier ~= '' then
    return {
      kind = 'Discussion',
      web_url = string.format('%s/discussions/%s', base, identifier),
      path = { 'github', 'repo', owner, repo, 'discussions', identifier },
    }
  end

  if resource == 'commits' and identifier ~= '' then
    return {
      kind = 'Commit',
      web_url = string.format('%s/commit/%s', base, identifier),
      path = nil,
    }
  end

  return {
    kind = subject_type,
    web_url = base,
    path = nil,
  }
end

local function notification_type_style(kind)
  local map = {
    Issue = { icon = '', color = 'red', label = 'Issue' },
    PullRequest = { icon = '', color = 'magenta', label = 'PR' },
    Discussion = { icon = '', color = 'cyan', label = 'Discussion' },
    Commit = { icon = '󰜘', color = 'yellow', label = 'Commit' },
    Release = { icon = '', color = 'green', label = 'Release' },
  }
  return map[tostring(kind or '')] or { icon = '󰧞', color = 'darkgray', label = tostring(kind or 'Notice') }
end

local function language_style(language)
  local name = tostring(language or '')
  local language_to_filename = {
    Rust = 'main.rs',
    Lua = 'init.lua',
    Go = 'main.go',
    Python = 'main.py',
    JavaScript = 'index.js',
    TypeScript = 'index.ts',
    TSX = 'index.tsx',
    JSX = 'index.jsx',
    Shell = 'script.sh',
    Bash = 'script.sh',
    Zig = 'main.zig',
    Nix = 'default.nix',
    C = 'main.c',
    ['C++'] = 'main.cpp',
    ['C#'] = 'main.cs',
    ['F#'] = 'main.fs',
    Java = 'Main.java',
    Kotlin = 'Main.kt',
    Swift = 'main.swift',
    PHP = 'index.php',
    Ruby = 'main.rb',
    Haskell = 'main.hs',
    Elixir = 'main.ex',
    Erlang = 'main.erl',
    OCaml = 'main.ml',
    Dart = 'main.dart',
    R = 'main.r',
    Scala = 'Main.scala',
    Perl = 'main.pl',
    ['Vim Script'] = 'plugin.vim',
    Clojure = 'core.clj',
    HCL = 'main.tf',
    Astro = 'index.astro',
    HTML = 'index.html',
    CSS = 'style.css',
    SCSS = 'style.scss',
    Vue = 'App.vue',
    Svelte = 'App.svelte',
    Dockerfile = 'Dockerfile',
    Makefile = 'Makefile',
    Markdown = 'README.md',
    JSON = 'package.json',
    YAML = 'config.yaml',
    Toml = 'Cargo.toml',
  }

  local sample = language_to_filename[name]
  if sample and sample ~= '' then
    local icon, color = file.get_icon(sample)
    if icon and icon ~= '' then return { icon = icon, color = color or 'darkgray' } end
  end

  return { icon = '󰈔', color = 'darkgray' }
end

local function file_style_from_name(name)
  local icon, color = file.get_icon(name)
  return {
    icon = icon or '󰈔',
    color = color or 'white',
  }
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

local function format_repo_stars(value)
  local stars = tonumber(value or 0) or 0
  if stars < 1000 then return tostring(stars) end

  local count = stars / 1000
  if stars >= 100000 then return string.format('%.0fk', count) end
  return string.format('%.1fk', count)
end

function M.align_repo_entry_columns(items)
  local lines = {}

  for _, entry in ipairs(items or {}) do
    if entry.kind == 'repo' and entry.display then table.insert(lines, entry.display) end
  end

  if #lines > 1 then lc.style.align_columns(lines) end
end

function M.info_entry(key, title, message, color, detail)
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

function M.route_entry(key, title, detail, color, opts)
  opts = opts or {}
  local plugin_keymap = config.get().keymap or {}
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

function M.user_entry(user)
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

function M.repo_entry(repo, opts)
  opts = opts or {}
  local owner = repo.owner and repo.owner.login or ''
  local name = repo.name or ''
  local key = opts.key or name
  local full_name = owner ~= '' and (owner .. '/' .. name) or name
  local lang = language_style(repo.language)

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
      span(format_repo_stars(repo.stargazers_count), '#f1e05a'),
    },
    keymap = build_open_keymap(action.go_to_repo, 'open repository', 'open in browser'),
    preview = action.repo_preview,
  }
end

function M.notification_entry(notification, encode_repo_ref)
  local repository = notification.repository or {}
  local subject = notification.subject or {}
  local owner, repo = '', ''
  local full_name = tostring(repository.full_name or '')

  if full_name ~= '' then
    owner, repo = full_name:match '^([^/]+)/(.+)$'
    owner = owner or ''
    repo = repo or ''
  end

  local target = notification_target(notification, owner, repo)
  local subject_style = notification_type_style(target.kind or subject.type)
  local open_callback = target.path and function() action.go_to_path(target.path) end or action.open_in_browser
  local open_desc = target.path and ('open ' .. string.lower(subject_style.label)) or 'open in browser'
  local unread = notification.unread ~= false
  local unread_icon = unread and '' or ''
  local unread_color = unread and 'yellow' or 'darkgray'
  local title_color = unread and 'white' or 'darkgray'
  local updated_text = format_relative_time(notification.updated_at) or format_relative_time(notification.last_read_at) or nil

  return {
    key = full_name ~= '' and encode_repo_ref(owner, repo)
      or tostring(notification.id or tostring(subject.title or 'notification')),
    kind = 'notification',
    notification = notification,
    repo_full_name = full_name,
    owner = owner,
    repo_name = repo,
    repo = repository,
    html_url = target.web_url or repository.html_url,
    web_url = target.web_url or repository.html_url,
    notification_target_kind = target.kind or subject.type,
    display = line {
      span(unread_icon, unread_color),
      span(' ' .. subject_style.icon, subject_style.color),
      span(' ' .. full_name, 'green'),
      span('  ' .. tostring(subject.title or subject.type or 'notification'), title_color),
      updated_text and span('  ' .. updated_text, 'darkgray') or '',
    },
    keymap = build_open_keymap(open_callback, open_desc, 'open in browser'),
    preview = action.notification_preview,
  }
end

function M.readme_entry(owner, repo, repo_info)
  local url = repo_html_url(owner, repo) or (repo_info and repo_info.html_url) or nil
  return {
    key = 'readme',
    kind = 'readme',
    owner = owner,
    repo_name = repo,
    repo = repo_info,
    html_url = url,
    web_url = url,
    display = line {
      span('󰂺 Readme', 'cyan'),
      span('  preview repository README', 'darkgray'),
    },
    keymap = build_open_keymap(action.open_in_browser, 'open repository in browser', 'open repository in browser'),
    preview = action.readme_preview,
  }
end

function M.repo_detail_route_entry(kind, owner, repo, repo_info)
  local plugin_keymap = config.get().keymap or {}
  local title_map = {
    issues = 'Issues',
    pulls = 'Pulls',
    discussions = 'Discussions',
    branches = 'Branches',
    tags = 'Tags',
  }
  local icon_map = {
    issues = '',
    pulls = '',
    discussions = '',
    branches = '󰘬',
    tags = '',
  }
  local color_map = {
    issues = 'yellow',
    pulls = 'magenta',
    discussions = 'cyan',
    branches = 'green',
    tags = 'cyan',
  }
  local title = title_map[kind] or kind
  local icon = icon_map[kind] or '󰈔'
  local color = color_map[kind] or 'white'
  local path = { 'github', 'repo', owner, repo, kind }
  local url = repo_html_url(owner, repo) or (repo_info and repo_info.html_url) or nil
  if kind == 'discussions' and url then url = url .. '/discussions' end

  return {
    key = kind,
    kind = 'repo_detail_route',
    owner = owner,
    repo_name = repo,
    repo = repo_info,
    title = title,
    detail = kind == 'branches' and 'Browse repository branches'
      or (kind == 'tags' and 'Browse repository tags' or ('Open ' .. title:lower() .. ' list')),
    html_url = url,
    web_url = url,
    display = line {
      span(icon .. ' ' .. title, color),
      span('  open ' .. title:lower() .. ' list', 'darkgray'),
    },
    keymap = {
      [plugin_keymap.open] = { callback = function() action.go_to_path(path) end, desc = 'open' },
      [plugin_keymap.enter] = { callback = function() action.go_to_path(path) end, desc = 'open' },
      [plugin_keymap.open_in_browser] = { callback = action.open_in_browser, desc = 'open repository in browser' },
    },
    preview = action.info_preview,
  }
end

function M.repo_ref_entry(owner, repo, ref_kind, item)
  local plugin_keymap = config.get().keymap or {}
  local name = tostring(item.name or '')
  local commit = item.commit or {}
  local commit_sha = tostring(commit.sha or '')
  local short_sha = commit_sha ~= '' and commit_sha:sub(1, 7) or '-'
  local is_default = item.is_default == true
  local path = { 'github', 'repo', owner, repo, ref_kind, name }
  local label = ref_kind == 'branches' and 'Branch' or 'Tag'
  local color = ref_kind == 'branches' and 'green' or 'cyan'

  return {
    key = name,
    kind = ref_kind == 'branches' and 'repo_branch' or 'repo_tag',
    owner = owner,
    repo_name = repo,
    ref_kind = ref_kind,
    ref_name = name,
    ref_target = commit_sha ~= '' and commit_sha or name,
    ref = item,
    html_url = repo_ref_web_url(owner, repo, commit_sha ~= '' and commit_sha or name, '', false),
    web_url = repo_ref_web_url(owner, repo, commit_sha ~= '' and commit_sha or name, '', false),
    display = line {
      span(ref_kind == 'branches' and '󰘬 ' or ' ', color),
      span(name ~= '' and name or label, 'white'),
      is_default and span('  default', 'yellow') or '',
      span('  ' .. short_sha, 'darkgray'),
    },
    keymap = {
      [plugin_keymap.open] = { callback = function() action.go_to_path(path) end, desc = 'open' },
      [plugin_keymap.enter] = { callback = function() action.go_to_path(path) end, desc = 'open' },
      [plugin_keymap.open_in_browser] = { callback = action.open_in_browser, desc = 'open in browser' },
    },
    preview = action.repo_ref_preview,
  }
end

-- repo contents are now built via github.provider + file.new(...)

function M.issue_entry(issue)
  local state = tostring(issue.state or 'open')
  local icon = state == 'open' and '' or ''
  local icon_color = state == 'open' and 'red' or 'magenta'
  local path = { 'github', 'repo', issue.owner, issue.repo_name, 'issues', tostring(issue.number or '?') }

  return {
    key = tostring(issue.number or '?'),
    kind = 'issue',
    issue = issue,
    owner = issue.owner,
    repo_name = issue.repo_name,
    html_url = issue.html_url,
    web_url = issue.html_url,
    display = line {
      span(icon, icon_color),
      span(' ' .. tostring(issue.title or 'Issue'), 'white'),
      span('  ' .. issue_time_text(issue), 'darkgray'),
    },
    keymap = build_open_keymap(function() action.go_to_path(path) end, 'open issue', 'open issue in browser'),
    preview = action.issue_preview,
  }
end

function M.pull_entry(pr)
  local state = tostring(pr.state or 'open')
  local merged = pr.merged_at ~= nil
  local icon = merged and '' or (state == 'open' and '' or '')
  local icon_color = merged and 'magenta' or (state == 'open' and 'red' or 'magenta')
  local path = { 'github', 'repo', pr.owner, pr.repo_name, 'pulls', tostring(pr.number or '?') }

  return {
    key = tostring(pr.number or '?'),
    kind = 'pull',
    pull = pr,
    owner = pr.owner,
    repo_name = pr.repo_name,
    html_url = pr.html_url,
    web_url = pr.html_url,
    display = line {
      span(icon, icon_color),
      span(pr.draft and ' [draft]' or '', 'yellow'),
      span(' ' .. tostring(pr.title or 'Pull request'), 'white'),
      span('  ' .. pull_time_text(pr), 'darkgray'),
    },
    keymap = build_open_keymap(function() action.go_to_path(path) end, 'open pull request', 'open pull request in browser'),
    preview = action.pull_preview,
  }
end

function M.issue_detail_entry(issue)
  local state = tostring(issue.state or 'open')
  local author = ((issue.user or {}).login) or 'unknown'
  local created = format_relative_time(issue.created_at) or '-'
  local summary = tostring(issue.title or 'Issue')
  local color = state == 'open' and 'red' or 'magenta'
  local icon = state == 'open' and '' or ''

  return {
    key = '__issue__',
    kind = 'issue_detail',
    issue = issue,
    owner = issue.owner,
    repo_name = issue.repo_name,
    html_url = issue.html_url,
    web_url = issue.html_url,
    display = line {
      span(icon, color),
      span(' @' .. author, color),
      span(' ' .. created, 'darkgray'),
      span(' ' .. summary, 'white'),
    },
    keymap = build_open_keymap(action.open_in_browser, 'open issue in browser', 'open issue in browser'),
    preview = action.issue_preview,
  }
end

function M.pull_detail_entry(pr)
  local merged = pr.merged_at ~= nil and pr.merged_at ~= ''
  local state = tostring(pr.state or 'open')
  local icon = merged and '' or ''
  local color = merged and 'magenta' or (state == 'open' and 'red' or 'magenta')
  local author = ((pr.user or {}).login) or 'unknown'
  local created = format_relative_time(pr.created_at) or '-'
  local summary = tostring(pr.title or 'Pull request')

  return {
    key = '__pull__',
    kind = 'pull_detail',
    pull = pr,
    owner = pr.owner,
    repo_name = pr.repo_name,
    html_url = pr.html_url,
    web_url = pr.html_url,
    display = line {
      span(icon, color),
      span(' @' .. author, color),
      span(' ' .. created, 'darkgray'),
      span(' ' .. summary, 'white'),
    },
    keymap = build_open_keymap(action.open_in_browser, 'open pull request in browser', 'open pull request in browser'),
    preview = action.pull_preview,
  }
end

function M.comment_entry(comment, opts)
  opts = opts or {}
  local author = ((comment.user or {}).login) or ((comment.author or {}).login) or 'unknown'
  local body = summary_from_comment(comment)
  local prefix = opts.prefix or ''
  local color = opts.color or 'blue'
  local indent = string.rep(' ', tonumber(opts.indent or 0) or 0)
  if comment.is_answer and opts.prefix == nil then
    prefix = ''
    color = 'green'
  end
  local suffix = opts.suffix and (' ' .. opts.suffix) or ''
  local created = format_relative_time(comment.created_at or comment.submitted_at or comment.updated_at)

  return {
    key = tostring(comment.id or comment.node_id or body or 'comment'),
    kind = opts.kind or 'comment',
    comment = comment,
    html_url = comment.html_url,
    web_url = comment.html_url,
    display = line {
      indent ~= '' and span(indent, 'darkgray') or '',
      span(prefix, color),
      span(' @' .. tostring(author), color),
      span(suffix, 'darkgray'),
      span(created and created ~= '' and (' ' .. created) or '', 'darkgray'),
      span(body ~= '' and (' ' .. body) or ' no content', 'white'),
    },
    keymap = build_open_keymap(action.open_in_browser, 'open comment in browser', 'open comment in browser'),
    preview = action.comment_preview,
  }
end

function M.load_more_entry(route_key_value, loading, callback)
  local plugin_keymap = config.get().keymap or {}

  return {
    key = '__load_more__',
    kind = 'load_more',
    route_key = route_key_value,
    loading = loading == true,
    keymap = {
      [plugin_keymap.open] = { callback = callback, desc = 'load more' },
      [plugin_keymap.enter] = { callback = callback, desc = 'load more' },
    },
    preview = action.load_more_preview,
    display = line {
      span(loading and 'Loading more...' or 'Load more...', 'yellow'),
    },
  }
end

function M.search_prompt_entry(kind)
  local plugin_keymap = config.get().keymap or {}
  local callback = kind == 'user' and action.search_user_input or action.search_repo_input

  return {
    key = kind,
    kind = 'search_prompt',
    search_kind = kind,
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

function M.trending_repo_entry(repo)
  local owner = ((repo or {}).owner or {}).login or ''
  local name = repo.name or ''
  local full_name = repo.full_name or (owner ~= '' and name ~= '' and (owner .. '/' .. name) or name)
  local lang = language_style(repo.language)
  local today = tostring(repo.trending_stars_today or '')

  return {
    key = full_name ~= '' and full_name or name,
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
      span(format_repo_stars(repo.stargazers_count), '#f1e05a'),
      today ~= '' and span('  ' .. today, 'green') or '',
    },
    keymap = build_open_keymap(action.go_to_repo, 'open repository', 'open in browser'),
    preview = action.repo_preview,
  }
end

function M.discussion_entry(discussion)
  local icon, icon_color = discussion_style(discussion)
  local path = { 'github', 'repo', discussion.owner, discussion.repo_name, 'discussions', tostring(discussion.number or '?') }

  return {
    key = tostring(discussion.number or '?'),
    kind = 'discussion',
    discussion = discussion,
    owner = discussion.owner,
    repo_name = discussion.repo_name,
    html_url = discussion.html_url,
    web_url = discussion.html_url,
    display = line {
      span(icon, icon_color),
      span(' ' .. tostring(discussion.title or 'Discussion'), 'white'),
      span('  ' .. discussion_time_text(discussion), 'darkgray'),
    },
    keymap = build_open_keymap(function() action.go_to_path(path) end, 'open discussion', 'open discussion in browser'),
    preview = action.discussion_preview,
  }
end

function M.discussion_detail_entry(discussion)
  local icon, color = discussion_style(discussion)
  local author = ((discussion.user or {}).login) or ((discussion.author or {}).login) or 'unknown'
  local created = format_relative_time(discussion.created_at) or '-'
  local summary = tostring(discussion.title or 'Discussion')

  return {
    key = '__discussion__',
    kind = 'discussion_detail',
    discussion = discussion,
    owner = discussion.owner,
    repo_name = discussion.repo_name,
    html_url = discussion.html_url,
    web_url = discussion.html_url,
    display = line {
      span(icon, color),
      span(' @' .. author, color),
      span(' ' .. created, 'darkgray'),
      span(' ' .. summary, 'white'),
    },
    keymap = build_open_keymap(action.open_in_browser, 'open discussion in browser', 'open discussion in browser'),
    preview = action.discussion_preview,
  }
end

return M
