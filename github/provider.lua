local api = require 'github.api'
local config = require 'github.config'

local M = {}

local function join_repo_path(segments)
  if not segments or #segments == 0 then return '/' end
  return '/' .. table.concat(segments, '/')
end

local function split_repo_path(path)
  local out = {}
  for segment in tostring(path or ''):gmatch '[^/]+' do
    table.insert(out, segment)
  end
  return out
end

local function basename(path)
  local value = tostring(path or '')
  if value == '' or value == '/' then return '' end
  return value:match '([^/]+)$' or value
end

local function dirname(path)
  local value = tostring(path or '')
  if value == '' or value == '/' then return '/' end
  local dir = value:match '^(.*)/[^/]+$'
  if not dir or dir == '' then return '/' end
  return dir
end

local function repo_ref_web_url(owner, repo, ref_name, item_path, is_file)
  owner = tostring(owner or '')
  repo = tostring(repo or '')
  ref_name = tostring(ref_name or '')
  if owner == '' or repo == '' or ref_name == '' then return nil end

  local base = 'https://github.com/' .. owner .. '/' .. repo
  local mode = is_file and 'blob' or 'tree'
  local suffix = ''
  if item_path and item_path ~= '' then suffix = '/' .. lc.url.encode(item_path):gsub('%%2F', '/') end
  return string.format('%s/%s/%s%s', base, mode, lc.url.encode(ref_name):gsub('%%2F', '/'), suffix)
end

function M.new(owner, repo_name, ref_kind, ref_name)
  local self = {
    name = 'github',
    owner = tostring(owner or ''),
    repo_name = tostring(repo_name or ''),
    ref_kind = tostring(ref_kind or 'branches'),
    ref_name = tostring(ref_name or ''),
  }
  return setmetatable(self, { __index = M })
end

function M:handle(path, is_dir, item)
  local repo_path = tostring(path or '/')
  if repo_path == '' then repo_path = '/' end

  local content_path = repo_path == '/' and '' or repo_path:sub(2)
  local item_type = tostring(item and item.type or '')
  local dir_flag = is_dir == true or item_type == 'dir'
  local file_flag = not dir_flag

  return {
    id = table.concat({
      self.owner,
      self.repo_name,
      self.ref_kind,
      self.ref_name,
      content_path,
    }, '\x1f'),
    name = item and tostring(item.name or basename(repo_path)) or basename(repo_path),
    path = repo_path,
    is_dir = dir_flag,
    size = item and item.size or nil,
    owner = self.owner,
    repo_name = self.repo_name,
    ref_kind = self.ref_kind,
    ref_name = self.ref_name,
    item = item,
    web_url = repo_ref_web_url(self.owner, self.repo_name, self.ref_name, content_path, file_flag),
    html_url = repo_ref_web_url(self.owner, self.repo_name, self.ref_name, content_path, file_flag),
  }
end

function M:decode_page_path(path)
  if type(path) ~= 'table' or path[2] ~= 'repo' then
    return nil, 'Invalid GitHub repository path'
  end
  if path[3] ~= self.owner or path[4] ~= self.repo_name or path[5] ~= self.ref_kind or path[6] ~= self.ref_name then
    return nil, 'GitHub repository browser context mismatch'
  end

  local segments = {}
  for i = 7, #path do
    table.insert(segments, path[i])
  end
  return self:handle(join_repo_path(segments), true)
end

function M:encode_page_path(handle)
  local out = { 'github', 'repo', self.owner, self.repo_name, self.ref_kind, self.ref_name }
  for _, segment in ipairs(split_repo_path(handle and handle.path or '/')) do
    table.insert(out, segment)
  end
  return out
end

function M:list(dir_handle, cb)
  local content_path = dir_handle.path == '/' and '' or dir_handle.path:sub(2)
  api.get_repo_contents(self.owner, self.repo_name, self.ref_name, content_path):next(function(data)
    if type(data) == 'table' and data.type == 'file' then
      cb {
        self:handle('/' .. tostring(data.path or data.name or ''), false, data),
      }
      return
    end

    local out = {}
    for _, item in ipairs(data or {}) do
      local item_path = '/' .. tostring(item.path or item.name or '')
      table.insert(out, self:handle(item_path, tostring(item.type or '') == 'dir', item))
    end
    cb(out)
  end, function(err)
    cb(nil, err)
  end)
end

function M:stat(handle, cb)
  cb({
    exists = true,
    is_dir = handle.is_dir == true,
    is_file = handle.is_dir ~= true,
    is_readable = true,
    is_writable = false,
    is_executable = false,
  })
end

function M:parent(handle)
  local value = tostring(handle and handle.path or '/')
  if value == '' or value == '/' then return nil end
  return self:handle(dirname(value), true)
end

function M:join(dir_handle, name)
  local base = tostring(dir_handle and dir_handle.path or '/')
  local child = base == '/' and ('/' .. tostring(name or '')) or (base .. '/' .. tostring(name or ''))
  return self:handle(child, false)
end

function M:read_file(handle, opts, cb)
  local limits = opts or {}
  local max_chars = math.max(tonumber(limits.max_chars) or 0, 0)
  local max_lines = math.max(tonumber((config.get() or {}).code_max_lines) or 0, 0)
  local content_path = tostring(handle and handle.path or '/')
  if content_path == '/' then
    cb('', 'Cannot preview repository root as a file')
    return
  end

  api.get_repo_contents(self.owner, self.repo_name, self.ref_name, content_path:sub(2)):next(function(data)
    local encoded = tostring(data and data.content or '')
    local content = tostring(data and data.decoded_content or '')
    local truncated = false

    if content == '' and encoded ~= '' then content = '\0' end

    if max_lines > 0 then
      local lines = {}
      local line_count = 0
      for line in (content .. '\n'):gmatch('(.-)\n') do
        line_count = line_count + 1
        if line_count > max_lines then
          truncated = true
          break
        end
        table.insert(lines, line)
      end
      content = table.concat(lines, '\n')
    end

    if max_chars > 0 and #content > max_chars then
      content = content:sub(1, max_chars)
      truncated = true
    end

    cb(content, nil, { truncated = truncated })
  end, function(err)
    cb('', err)
  end)
end

return M
