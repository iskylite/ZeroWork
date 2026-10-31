# 会话状态提示

目标：先说明状态与下一步，再提供明确操作。覆盖本地终端启动、退出、启动失败、关闭中、清理结果未知。

基准为同目录 index.html；复用项目主题颜色和原生 Button / Spinner。退出使用终端图标，不使用表示成功的勾号。关闭按钮写明“关闭页签”，主操作为“新建终端”或“重试启动”。保留退出码、终止信号与启动失败原因。

浏览器实测：1280×720 CSS px、DPR 2。横幅高 64px、水平内边距 16px、组件间距 12px；文字区域 flex:1/min-width:0，两行间距 2px；标题 13px/20px/600，说明 12px/18px/400；按钮高 30px、水平内边距 12px、内容宽度。原生启动提示维持 pane 内 16px 浮层；其余状态在输出上方占位，不覆盖历史输出。

验证：`zig build test-ui -Dui-test-filter='Local presentation' -j2`；隔离数据目录运行新构建的原生程序，输入 exit 130，检查普通/最小窗口、新建终端和关闭页签。截图与结果见仓库 output/session-notice/。HTML 参考截图为 reference.png。短暂状态的真实生命周期不通过人为延迟或新故障注入改写。


远程会话沿用同一组几何与主题样式，状态为远程终端已退出、连接已断开、正在重新连接、重新连接失败；退出码及错误原因来自当前运行时快照。只在原连接实际释放后显示重新连接／重试连接按钮。重连中保留“关闭页签”，既有会话的普通重连进度显示在提示条中，认证仍使用受保护的认证弹窗；连接恢复后自动隐藏提示条。自动重连倒计时来自控制器已有重连票据；输入缓冲说明跟随用户实际设置。

原生验收：`node e2e/remote_session_notice_native.ts output/remote-session-notice`；自动重连及缓冲输入：`node e2e/remote_session_notice_native.ts output/remote-session-notice-auto --automatic --buffered`。所有 SSH 流量与信任记录均使用临时目录和本机回环服务。远程参考截图为 remote-reference.png。
