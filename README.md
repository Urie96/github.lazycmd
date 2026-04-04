# github.lazycmd

GitHub API 客户端插件，按 `examples/demo.lazycmd` 的模块拆分方式组织：

- `github/config.lua` - 配置和快捷键
- `github/api.lua` - GitHub REST API 封装
- `github/action.lua` - 输入、跳转、分页动作
- `github/init.lua` - 路由分发、entry 行为绑定和分页状态

## 已实现路径

- `/github/notifications`
- `/github/repo`
- `/github/repo/<username>`
- `/github/repo/<username>/<repo>`
- `/github/starred`
- `/github/search`
- `/github/search/repo`
- `/github/search/repo/<query>`
- `/github/search/user`
- `/github/search/user/<query>`

其中：

- `/github/repo` 会展示“打开任意用户”的入口；如果配置了 token，还会额外展示当前用户和 following 用户
- `/github/repo/<username>/<repo>` 当前先提供 `readme` 条目，预览面板里读取 GitHub README
- 分页列表会在末尾追加 `Load more...`

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
      keymap = {
        search = 's',
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
- `/github/starred`
- `/github/repo` 中“当前用户 + following 用户”列表

插件只读取 `setup()` 传入的 `token`。
