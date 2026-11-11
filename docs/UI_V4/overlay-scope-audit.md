# 遮罩范围审查

遮罩范围跟随操作的归属。连接和编辑发生在单个内容页，会话组内进一步收窄到对应分栏。跨会话的新建和偏好设置最多占用发起窗口。清除全部应用数据、确认退出并安装等影响整个应用的动作，才在用户确认后协调所有窗口。

范围覆盖主程序、内置插件和系统文件选择器。页内对话在其归属不可见时隐藏，返回原处后恢复仍有效的操作。

| 浮层 | 当前入口 | 范围与处理 |
| --- | --- | --- |
| 连接进度、取消与失败 | [SSH、SFTP 共用进度](../../src/ui/connection_host.zig) | 连接中、取消中显示在对应内容页或分栏。释放完成后留页内结果与重连、关闭、查看日志入口。取消以「已取消」为主状态，技术错误仅留在日志。切换页签不会取消正在进行的其他连接。 |
| 连接日志、逐跳节点详情 | [连接日志](../../src/ui/connection_logs_view.zig)、[路径节点](../../src/ui/connection_details_view.zig) | 从状态或节点入口打开非模态详情，保留复制与展开。关闭或切换页签后，详情不得改绑到另一条连接。 |
| SSH/SFTP 认证、主机信任、插件挑战 | [认证](../../src/ui/auth_challenge_view.zig)、[工作区主机信任](../../src/ui/workspace.zig)、[插件挑战](../../src/ui/plugin_challenge_presenter.zig) | 只挡住发起会话内容。包括密码、OTP、主机密钥、插件认证和网页 alert、confirm、prompt、HTTP 登录。换页后提示留在原会话，等待或取消继续沿用原请求的有效期和身份。测试连接的挑战留在向导内。 |
| 新建、编辑连接，从已有主机复制 | [共享向导](../../src/ui/wizard.zig)、[远端编辑器](../../src/plugins/remote/editor.zig) | 新建向导可以占发起窗口。附着到某条连接的编辑表单可放内容区。复制选择只遮住父向导，返回保留原草稿。 |
| 笔记新建名称、管理、锁定导入选择、图片查看 | [笔记视图](../../src/plugins/notes/view.zig)、[笔记管理](../../src/plugins/notes/editor_management.zig) | 标准笔记页只挡笔记内容，浮窗里的操作只挡笔记浮窗。删除、恢复、只读等确认冻结目标和编辑租约。图片查看在内容区展开，切页签后关闭或保留在原笔记。 |
| KVM 断开确认、连接日志、只读启动顺序、管理测试日志 | [会话界面](../../src/plugins/bmc_ikvm/views.zig)、[编辑器](../../src/plugins/bmc_ikvm/editor.zig) | 断开确认只挡目标 KVM 分栏，先释放捕获的键鼠。日志和只读顺序用非模态详情。管理测试日志留在编辑向导。 |
| 本地终端关闭、关闭确认、多行粘贴 | [Local 关闭](../../src/ui/local_close_view.zig)、[工作区关闭确认](../../src/ui/workspace.zig)、[终端输入](../../src/ui/terminal_surface_input.zig) | 只挡目标终端分栏。粘贴内容、确认及回执绑定原输入目标。换页不得把待粘贴文字交给另一终端，取消不得发送任何内容。 |
| 加入、关闭会话组 | [加入会话组](../../src/ui/group_join_view.zig)、[关闭会话组](../../src/ui/workspace.zig) | 选择器从发起控件展开，关闭确认只挡目标组。组成员变化时重新核对操作范围。 |
| 文件复制、上传表单、传输冲突 | [复制](../../src/ui/file_copy_view.zig)、[上传](../../src/ui/transfer_panel.zig)、[冲突](../../src/ui/transfer_conflict_view.zig) | 表单限原文件页或发起面板。冲突停在该任务，可从传输管理器回到原任务处理，其他传输继续。 |
| SOCKS 配置、暴露确认 | [转发配置](../../src/ui/socks_config_view.zig)、[暴露确认](../../src/ui/socks_exposure_confirm.zig) | 挡住当前转发配置及所属内容，显式确认监听地址和端口。换页不得把确认提交给其他转发。 |
| AI 子对话、记录历史与删除、附件、图片、远端文件选择 | [子对话](../../src/main.zig)、[记录与历史](../../src/ui/ai_sessions_view.zig)、[附件](../../src/ui/ai_attachments_view.zig)、[图片](../../src/ui/ai_image_attachments_view.zig)、[远端选择](../../src/ui/ai_remote_picker.zig) | 遮罩留在发起对话或子面板。历史和预览允许收起，选择器及删除确认固定到原对话。后台任务的审批或提问保留在对应记录的待处理入口。 |
| 偏好设置、恢复默认、快捷键录制、模型编辑、删除服务商、插件说明 | [设置和确认](../../src/main.zig)、[快捷键](../../src/config/keybinding_picker.zig)、[模型](../../src/config/ai_model_editor.zig)、[服务商](../../src/config/provider_delete_dialog.zig)、[插件说明](../../src/config/settings_parts/settings_plugins.zig) | 偏好设置属于发起窗口。二级表单和确认只挡设置面板，录制期间由录制框接收键盘。插件说明可改为内联详情。 |
| 清理记录、清除数据、应用更新 | [清理记录](../../src/ui/record_cleanup_view.zig)、[清除数据](../../src/ui/application_data_cleanup_view.zig)、[更新](../../src/ui/app_update_view.zig) | 记录清理确认限所属记录范围。查看更新和下载使用普通面板，只有确认结束会话并安装、确认清除全部数据时，才进入应用级协调。 |
| AppKit 文件选择与启动恢复 | [文件选择器](../../src/platform/macos_file_sheet.m)、[数据告警](../../src/platform/macos_data_alert.m)、[更新恢复](../../src/update/native_runtime.m) | 文件选择器应随发起窗口。启动数据告警和更新恢复没有可操作工作区时，可保留系统模态。 |

菜单、快速连接、通知、主题、命令历史、传输管理器、网页书签和笔记主浮窗保持可在原工作区操作的浮层。只有面板覆盖的区域拦截鼠标和滚轮。内容未被遮挡时，仍可点击其他分栏、页签、侧栏和顶栏。

## 实现与验收

- [遮罩绑定](../../src/ui/scoped_modal.zig) 以当前内容节点的几何边界为准。会话组重排或切页后重新解析归属，已关闭或换代的会话不能接收旧请求。取消和失败释放后可从页内状态查看原日志。
- [原生网页](../../src/ui/plugin_window_host.zig) 按遮罩和面板与网页的实际相交范围裁剪，点击和辅助功能使用相同的可见区域。焦点离开网页时仍保留页面和导航状态。
- 验收覆盖普通页、会话组分栏、双窗口和宽窄视口。检查未覆盖区域可操作、覆盖区域不接收底层点击和滚轮、认证与确认不改绑、网页不重载，以及关闭时焦点回到仍有效的位置。
