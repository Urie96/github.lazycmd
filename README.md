# github.lazycmd

GitHub API 客户端插件，按 `examples/demo.lazycmd` 的模块拆分方式组织：

- `github/config.lua` - 配置和快捷键
- `github/api.lua` - GitHub REST API 封装
- `github/action.lua` - 输入、跳转、分页动作
- `github/entries.lua` - 各类 entry 构造
- `github/provider.lua` - GitHub 仓库代码浏览的只读 file provider（通过 `file.new(provider, ...)` 生成 repo contents entry/display/preview）
- `github/router.lua` - 路由分发和分页状态
- `github/init.lua` - 插件入口和 setup

## 已实现路径

- `/github/notifications`
- `/github/repo`
- `/github/repo/<username>`
- `/github/repo/<username>/<repo>`
- `/github/repo/<username>/<repo>/branches`
- `/github/repo/<username>/<repo>/branches/<ref>/...`
- `/github/repo/<username>/<repo>/tags`
- `/github/repo/<username>/<repo>/tags/<ref>/...`
- `/github/repo/<username>/<repo>/issues`
- `/github/repo/<username>/<repo>/issues/open`
- `/github/repo/<username>/<repo>/issues/closed`
- `/github/repo/<username>/<repo>/issues/<number>`
- `/github/repo/<username>/<repo>/issues/search/<query>`
- `/github/repo/<username>/<repo>/pulls`
- `/github/repo/<username>/<repo>/pulls/open`
- `/github/repo/<username>/<repo>/pulls/closed`
- `/github/repo/<username>/<repo>/pulls/<number>`
- `/github/repo/<username>/<repo>/pulls/search/<query>`
- `/github/repo/<username>/<repo>/discussions`
- `/github/repo/<username>/<repo>/discussions/<number>`
- `/github/trending`
- `/github/trending/daily`
- `/github/trending/weekly`
- `/github/trending/monthly`
- `/github/starred`
- `/github/search`
- `/github/search/repo`
- `/github/search/repo/<query>`
- `/github/search/user`
- `/github/search/user/<query>`

其中：

- `/github/repo` 会展示“打开任意用户”的入口；如果配置了 token，还会额外展示当前用户和 following 用户
- 在 `/github/repo/<username>` 页面按搜索快捷键会弹出“搜索该用户仓库”的输入框，提交后跳到 `/github/search/repo/user:<username> <query>`
- `/github/repo/<username>/<repo>` 当前提供 `readme`、`issues`、`pulls`、`discussions`、`branches`、`tags` 条目
- `/github/repo/<username>/<repo>/branches` 会展示该仓库的分支；进入分支后通过 `file` 插件的 browser/provider 复用代码浏览、目录预览、文件图标和列表 display；在代码文件上按 `Enter` 用 `$VISUAL`/`$EDITOR` 打开临时文件，按 `o` 打开 GitHub 浏览器页面
- `/github/repo/<username>/<repo>/tags` 会展示该仓库的标签；进入标签后通过 `file` 插件的 browser/provider 复用代码浏览、目录预览、文件图标和列表 display；在代码文件上按 `Enter` 用 `$VISUAL`/`$EDITOR` 打开临时文件，按 `o` 打开 GitHub 浏览器页面
- GitHub 仓库代码浏览是只读的，不提供 `file` 插件里的新建、删除、重命名等本地文件操作
- 代码预览仍受 `code_max_lines` 和 `code_max_chars` 限制
- `/github/repo/<username>/<repo>/issues` 会通过 GitHub Search API 展示该仓库的全部 issues；按 `--filter` 可选择跳到 `/issues/open` 或 `/issues/closed`
- `/github/repo/<username>/<repo>/issues` 页面按 `s` 会搜索当前仓库 issues，结果路由为 `/github/repo/<username>/<repo>/issues/search/<query>`
- `/github/repo/<username>/<repo>/pulls` 会通过 GitHub Search API 展示该仓库的全部 pull requests；按 `--filter` 可选择跳到 `/pulls/open` 或 `/pulls/closed`
- `/github/repo/<username>/<repo>/pulls` 页面按 `s` 会搜索当前仓库 pull requests，结果路由为 `/github/repo/<username>/<repo>/pulls/search/<query>`
- `/github/repo/<username>/<repo>/issues/<number>` 和 `/github/repo/<username>/<repo>/pulls/<number>` 会展示正文和全部评论
- `/github/repo/<username>/<repo>/discussions` 会通过 GitHub GraphQL API 展示该仓库的 discussions；进入 discussion 后会展示正文和评论
- `/github/trending` 会展示 `Today`、`This week`、`This month` 三个入口，当前仅支持 `language:any`
- 分页列表会在末尾追加 `Load more...`
- 插件内部的 `go_to({ ... })` / `get_current_path()` 统一使用原始 path segment；如果 ref 名里包含 `/` 等特殊字符，header 和命令行字符串路径会由 Rust 自动做 percent 编解码

## 配置

在 `config/init.lua` 里加入：

```lua
lc.config {
  plugins = {
    { dir = 'plugins/github.lazycmd' },
  },
}
```

可选配置：

```lua
{
  dir = 'plugins/github.lazycmd',
  config = function()
    require('github').setup {
      token = os.getenv 'GITHUB_TOKEN',
      per_page = 20,
      readme_max_chars = 50000,
      code_max_chars = 80000,
      code_max_lines = 1200,
      cache_ttl = {
        notifications = 60,
        search_repositories = 300,
        search_users = 300,
        search_repo_issues = 120,
        search_repo_pulls = 120,
        trending = 300,
        repo = 900,
        repo_branches = 300,
        repo_tags = 300,
        repo_contents = 300,
        repo_languages = 21600,
        repo_readme = 21600,
        repo_issues = 120,
        repo_pulls = 120,
        repo_discussions = 120,
      },
      keymap = {
        search = 's',
        filter_state = '--filter',
        open_user = 'u',
        open_in_browser = 'o',
      },
    }
  end,
}
```

## Token

以下路径需要 GitHub token：

- `/github/notifications`
- `/github/repo/<username>/<repo>/discussions`
- `/github/starred`
- `/github/repo` 中“当前用户 + following 用户”列表

插件只读取 `setup()` 传入的 `token`。

## 缓存

插件会通过 `lc.cache` 缓存 GitHub API 响应，并按场景使用不同 TTL：

- `notifications`：60 秒
- `following`、`starred`、搜索结果：5 分钟
- 仓库内 `issues` / `pulls` 搜索结果：2 分钟
- 分支、标签、代码目录：5 分钟
- 用户仓库列表：3 分钟
- `viewer`：5 分钟
- 用户资料：30 分钟
- 仓库详情：15 分钟
- `languages`、`README`：6 小时
- `issues`、`pulls`、`discussions`：2 分钟

可以通过 `setup { cache_ttl = { ... } }` 覆盖这些 TTL，单位为秒。

插件仍然保留进程内 session 缓存；`lc.cache` 用于跨重载和重启复用结果。
