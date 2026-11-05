# 终端文件工具与静态图片

范围限于 Local、SSH 终端会话。SFTP、KVM 等其他协议不贡献这三个文件工具；已有其他协议能力不受影响。

## 文件操作

- `file.read_text`：有界完整采集，按页返回 UTF-8 文本和版本；默认每页 4096 字节，最大 8192 字节。
- `file.write_text`：默认 create，已存在时拒绝。replace 必须携带读取返回的 `expected_version`。
- `file.edit_text`：原文精确匹配、唯一匹配、禁止重叠；全部修改验证后才提交。
- 文件上限 65536 字节；保留 BOM、原有换行及未修改字节。版本绑定会话代际、exec 服务绑定、绝对路径、文件元数据及完整内容。写入/编辑参数为 JSON 转义预留 512 KiB，其他工具保持各自原限制。
- 本地 worker 使用文件 API；SSH 使用独立无 PTY 的 exec，文件数据走有界 stdin，不拼入 shell 命令、不进入交互终端。
- SSH 固定脚本使用绝对路径 `/usr/bin/env`、`/bin/sh`，清空继承环境并设置系统工具 PATH 与 C locale，不使用项目 PATH 中的同名工具。
- 同应用的文件修改串行提交；对其他程序采用乐观冲突检测，不能声称跨程序严格事务。
- 首版拒绝最终符号链接、硬链接、多余权限位、父级 `..` 路径。相对路径只基于操作捕获的可靠 cwd；不自动提权。
- 本地元数据通过 macOS `fcopyfile` 保留，内容写完后同步。远端使用 GNU `cp --preserve=all` 或 BSD `cp -p`，并检查基本所有权、权限一致；不承诺所有服务器的扩展属性及崩溃持久性。
- 替换要求原文件可写；本地先以不跟随链接、非阻塞方式打开并核对原始文件，再复制元数据。暂存内容位于当前用户的 0700 私有目录中，提交前再次核对暂存 inode、原文和取消状态。目录路径末尾的 `/` 被拒绝，避免将目录意图解释为文件写入。
- SSH 需要可用的 `sh`、`stat`（GNU/BSD 格式）、`wc`、`dd`、`cmp`、`mktemp`、`cp`、`mv` 等基础工具；create 需要精确不覆盖目标的 `link`。能力不足时返回失败，不安装依赖、不回退截断覆盖。
- 审批沿用 confirm/auto，卡片显示路径、候选内容或精确替换差异，复制保留原始参数。结果分别记录 committed、verified、outcome_unknown 和实际清理回执。
- 文件步骤的历史详情显示目标路径，复制仍取原始完整参数，避免为显示结果反复排版整份文件 JSON。

取消、非零退出码和本地通道释放都不能证明远端没有写入。已观察到提交标记时保留 `committed=true`；没有标记且无法证明提交前拒绝时返回 `outcome_unknown=true`，不自动重试。回读未完成时不提供伪版本，`version=null`。清理或快照状态未知时保留原句柄，并传播 unknown 关闭回执；绑定身份不匹配时不取消或回收另一调用。

## 图片

Markdown `![说明](/absolute/path.png)` 或 `![说明](relative/path.png)` 由显示层解析；带空格的路径可使用 `<...>`。本地也接受 `file:///...`，远程不借此获得本地文件权限。代码围栏、行内代码、转义及未完成的语法不加载。

原回合保存会话代际及 cwd，显示缓存按对话、回合、来源和绝对路径区分。读取、图片解码和模型请求完全分开；不会把显示图片添加到 `provider.Message.images`、草稿附件、工具反馈或后续视觉上下文。图片预览、刷新无需模型请求。

复用现有 PNG/JPEG/静态 GIF/WebP 校验、解码及原生图片预览。沿用单张 10,000,000 字节、8192 边长、16 Mi 像素上限；预览缓存最多 32 个资源，原始字节与 CPU 像素合计最多 128 MiB，串行读取解码。显示保持宽高比、高度不超过 240 逻辑像素。

当前会话内保留不可变快照，重新加载才读取新文件。跨进程图片持久化和 SVG/HTML 动画不在本轮范围。

## 设计与验证

`index.html` 为可编辑局部原型，覆盖图片就绪、读取中、失败及文件变更确认。复用项目 Inter 字体与现有 Button、ScrollArea、Modal、Markdown 及图片纹理能力，没有 WebView。

浏览器实际测量使用 800 CSS 像素宽、DPR 1、100% 缩放；图片卡片内边距 10、纵向 gap 6，元信息字体 11、line-height 1.65。原型与原生以相同内容区和逻辑像素比较；原生截图为真实 Metal 窗口，交互由公开 Harness 合成。

针对性命令：

```sh
./scripts/test_isolated.sh test -Dtest-filter='terminal files' -j2
./scripts/test_isolated.sh test-ui -Dui-test-filter='terminal files' -j2
./scripts/test_isolated.sh test-ui -Dui-test-filter='transcript image' -j2
python3 e2e/terminal_files_scripts.py
zig build ssh-exec-acceptance -j2
python3 e2e/ssh_exec_service.py --runner zig-out/bin/ssh-exec-service-runner --output /tmp/zerowork-terminal-files/ssh-exec-report.json
zig build -j2 -Dtest-mode=true -De2e-port=19818
node e2e/terminal_files_native.ts /tmp/zerowork-terminal-files/native
node e2e/terminal_files_native.ts /tmp/zerowork-terminal-files/native-ssh zig-out/bin/zerowork ssh
ZW_TEST_VISION=1 node e2e/terminal_files_native.ts /tmp/zerowork-terminal-files/native-vision
node e2e/terminal_files_native.ts /tmp/zerowork-terminal-files/ssh-cancel zig-out/bin/zerowork ssh cancel-after-commit
```

SSH 回环 fixture 的 Python 环境需要 Paramiko；可用 `ZW_TEST_PYTHON` 指定隔离测试解释器。它是测试依赖，产品远端不需要 Python。

故障模式包括 `post-commit-exit`、`disconnect-after-commit`、`cancel-before-commit`、`cancel-after-commit`，执行真实脚本并对照磁盘内容、工具回执与单次写入次数。显示层图片还验证历史图片重读工具无法找回该快照，以及 OpenAI、Anthropic、Ollama 的请求均只包含原有路径文字。
