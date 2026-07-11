# Release safety / 发布安全检查

正式发布前，应对完整安装包和 OTA 包分别执行检查。发布包不得来自正在使用的 Kindle 插件目录直接压缩，除非先完成彻底清理和审计。

## 必须排除的用户数据

- `config.lua`、`config.lua.old`、`config.lua.new`、`config.lua.bak`
- KOReader 运行设置 `settings/weread.lua`、`.old`、`.new`
- Cookie、API Key、Token、二维码登录状态和账号信息
- `wr_skey`、`wr_rt`、`wr_vid`、`x-wr-ticket`、`x-wrpa-0` 等真实凭据
- 下载的书籍、公众号文章、封面、图片、想法缓存和脚注缓存
- KOReader 日志、崩溃日志和调试输出
- OTA 临时包、备份目录、`.old`、`.new` 和编辑器临时文件
- 操作系统元数据，如 `.DS_Store`、`Thumbs.db` 和 `__MACOSX`

## 完整包必须包含

- `weread.koplugin/_meta.lua`
- `weread.koplugin/main.lua`
- 所有 `require("lib.*")` 对应的 Lua 模块
- `weread.koplugin/lib/weread.lua`
- `weread.koplugin/fonts/NotoEmoji-Regular.ttf`
- `README.md`、`NOTICE.md`、`CHANGELOG.md` 和本文件
- 不含真实凭据的 `config.example.lua`

## 结构检查

完整包解压后必须是：

```text
weread.koplugin/
├── _meta.lua
├── main.lua
├── lib/
└── fonts/
```

不得出现双层目录：

```text
weread.koplugin/weread.koplugin/main.lua
```

## 版本和 OTA 检查

- `main.lua` 中的 `PLUGIN_VERSION` 与 `_meta.lua` 的版本一致。
- GitHub Release tag、资产文件名和 `update.json` 版本一致。
- OTA 下载 URL 指向当前维护仓库和正确 Release 资产。
- `update.json` 中的 SHA-256 与实际 OTA 文件一致。
- OTA 包保留用户设置和凭据文件，不通过完整覆盖删除运行数据。
- `delete_list` 只能包含明确允许删除的插件相对路径。

## 代码完整性检查

- 对全部 Lua 文件执行语法检查。
- 扫描所有 `require("lib.*")` 并确认目标模块存在。
- 检查 `_meta.lua`、`main.lua`、`lib/updater.lua` 和字体文件是否存在。
- 扫描压缩包文本内容，确认没有真实 Cookie、API Key、Token 或账号标识。

## 干净安装隐私测试

1. 完全退出 KOReader。
2. 备份后删除现有 `plugins/weread.koplugin`。
3. 删除 KOReader 设置目录中的 `weread.lua`、`.old` 和 `.new`。
4. 安装待发布完整包。
5. 启动 KOReader。
6. 确认账号状态为未登录，书架不能直接显示维护者账号。
7. 确认插件菜单、字体和全部依赖可以正常加载。

Runtime source modules and the bundled Emoji font are required for normal plugin operation and should not be removed from the full package.
