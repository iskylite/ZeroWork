//! User-facing explanations shared by existing notification and field surfaces.
const std = @import("std");
pub fn knownMessage(code: []const u8) ?[]const u8 {
    const entries = .{
        .{ "MissingProviderConfiguration", "尚未配置 AI 服务，请打开 AI 设置并添加服务提供方和模型。" },
        .{ "MissingProvider", "尚未配置 AI 服务，请打开 AI 设置并添加服务提供方和模型。" },
        .{ "UnknownProvider", "所选 AI 服务已不存在，请重新选择服务提供方。" },
        .{ "ProviderDisabled", "所选 AI 服务已停用，请在 AI 设置中启用或选择其他服务。" },
        .{ "MissingApiKey", "缺少 API Key，请在 AI 设置中补齐后重试。" },
        .{ "McpCredentialMissing", "找不到此 MCP 服务已保存的凭据。请在 MCP 设置中重新填写环境变量或请求头，再测试连接。" },
        .{ "CredentialMissing", "系统钥匙串中找不到已保存的凭据。请在对应配置中重新填写。" },
        .{ "CredentialDenied", "ZeroWork 无权访问系统钥匙串。请授权后重试。" },
        .{ "CredentialLocked", "系统钥匙串已锁定。请解锁后重试。" },
        .{ "CredentialUnavailable", "暂时无法访问系统钥匙串。请确认钥匙串可用后重试。" },
        .{ "CredentialStorageFailure", "无法读写系统钥匙串。请检查钥匙串状态后重试。" },
        .{ "CredentialAuthenticationCanceled", "已取消系统身份验证。请重试并完成验证。" },
        .{ "CredentialAuthenticationFailed", "系统身份验证未通过。请重新验证。" },
        .{ "InvalidCredentialReference", "配置中的凭据引用无效。请重新填写凭据，或检查导入文件。" },
        .{ "AmbiguousCredential", "配置同时包含明文凭据和钥匙串引用，无法确定使用哪一项。请检查配置文件。" },
        .{ "WizardAlreadyOpen", "已有一份主机配置正在编辑。请先保存或取消当前编辑。" },
        .{ "StaleAsset", "主机配置已变化。请从侧栏重新打开。" },
        .{ "ConnectionNotFound", "这台主机已被移除。请从侧栏重新选择。" },
        .{ "ConnectionEditorUnavailable", "此协议的配置编辑器不可用。请检查对应的扩展是否已启用。" },
        .{ "UnknownPlugin", "找不到此协议所需的扩展。请检查扩展是否已启用。" },
        .{ "UnsupportedPayloadVersion", "当前版本无法读取这份连接配置。请使用支持该配置的 ZeroWork 版本。" },
        .{ "UnsupportedImportProtocol", "导入文件包含当前版本不支持的连接协议，请检查扩展或导出版本。" },
        .{ "MissingRouteReference", "找不到连接路径里的跳板主机。请检查路径并重新选择跳板。" },
        .{ "InvalidRouteProtocol", "连接路径只能使用 SSH 主机作为跳板，请重新选择。" },
        .{ "RouteCycle", "连接路径包含循环或重复的主机，请检查跳板顺序。" },
        .{ "DuplicateRoute", "连接路径包含重复的跳板，请移除重复项。" },
        .{ "InteractionUnavailable", "这次测试无法询问凭据。请补填凭据，或直接发起连接后按提示输入。" },
        .{ "MissingEndpoint", "缺少 API 地址，请在 AI 设置中填写服务地址。" },
        .{ "MissingModel", "尚未选择可用模型，请在 AI 设置中添加并选择模型。" },
        .{ "UnknownModel", "所选模型已不存在，请重新选择模型。" },
        .{ "InvalidContextWindow", "模型上下文窗口无效，请在 AI 设置中填写大于 0 的窗口大小。" },
        .{ "UnsupportedEffort", "当前模型不支持所选推理等级，请重新选择等级或模型。" },
        .{ "InvalidImage", "无法识别此图片，请选择有效的 PNG 或 JPEG 图片。" },
        .{ "UnsupportedImage", "不支持此图片格式，请选择 PNG 或 JPEG 图片。" },
        .{ "ImageTooLarge", "图片超过大小或尺寸限制，请缩小后重试。" },
        .{ "TooManyImages", "最多添加 4 张图片，请先移除已有图片。" },
        .{ "AnimatedImageUnsupported", "暂不支持动态图，请选择静态图片。" },
        .{ "InvalidUtf8", "内容不是有效的 UTF-8 文本，请检查文件编码。" },
        .{ "AccessDenied", "没有操作权限，请检查文件或目录的访问权限。" },
        .{ "PermissionDenied", "没有操作权限，请检查文件或目录的访问权限。" },
        .{ "FileNotFound", "文件或目录已不存在，请刷新列表后重新选择。" },
        .{ "PathNotFound", "路径不存在，请检查路径或重新选择目录。" },
        .{ "NotDir", "目标路径不是目录，请选择有效目录。" },
        .{ "InvalidPath", "路径无效，请检查路径后重新输入。" },
        .{ "PathAlreadyExists", "目标名称已存在，请换一个名称。" },
        .{ "NoSpaceLeft", "磁盘空间不足，请释放空间后重试。" },
        .{ "OutOfMemory", "内存不足，操作未完成；请释放内存后重试。" },
        .{ "Timeout", "操作超时，请检查连接状态后重试。" },
        .{ "ConnectionRefused", "连接被拒绝，请检查服务是否启动以及地址、端口是否正确。" },
        .{ "ConnectionClosed", "连接已关闭，请重新连接后重试。" },
        .{ "SessionDisconnected", "会话已断开，请重新连接后重试。" },
        .{ "StaleSession", "原会话已失效，请选择当前可用的会话。" },
        .{ "StaleOwner", "原操作所属会话已变化，请返回当前会话重新操作。" },
        .{ "StaleBinding", "连接已变化，请刷新后重新操作。" },
        .{ "StaleFileSelection", "所选文件已变化，请刷新列表后重新选择。" },
        .{ "StaleFileAction", "文件列表或选择已变化，请关闭菜单后重新选择。" },
        .{ "StaleFileProjection", "文件列表已更新，请重新选择文件后操作。" },
        .{ "StaleTransferDestination", "传输目标已变化，请重新选择目标目录。" },
        .{ "InvalidFileDrop", "无法放到此位置，请选择可写入的目标目录。" },
        .{ "OnlyRegularFilesCanBeDraggedOut", "只能拖出普通文件，请重新选择文件。" },
        .{ "FileTransferUnavailable", "当前文件连接不可用于传输，请检查连接后重试。" },
        .{ "OperationBusy", "上一项操作尚未结束，请等待完成后再操作。" },
        .{ "SettingsBusy", "设置正在保存，请稍候再操作。" },
        .{ "LiveSessionActive", "仍有活动会话，请先结束会话后再执行此操作。" },
        .{ "Cancelled", "操作已取消。" },
    };
    inline for (entries) |entry| if (std.mem.eql(u8, code, entry[0])) return entry[1];
    return null;
}

pub fn message(label: []const u8, buffer: []u8) []const u8 {
    if (knownMessage(label)) |value| return value;
    if (label.len == 0) return "";
    // Only a standalone internal identifier gets the fallback. Already useful
    // source-authored sentences, paths and network diagnostics stay intact.
    if (label.len <= 128 and std.ascii.isUpper(label[0])) {
        var code = true;
        for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') {
            code = false;
            break;
        };
        if (code) return std.fmt.bufPrint(buffer, "操作未完成（{s}）。请检查当前状态后再试。", .{label}) catch "操作未完成，请检查当前状态。";
    }
    return label;
}

test "operation feedback translates internal codes and preserves source diagnostic text" {
    var buffer: [512]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, message("MissingApiKey", &buffer), "AI 设置") != null);
    try std.testing.expect(std.mem.indexOf(u8, message("FutureFailureCode", &buffer), "操作未完成") != null);
    try std.testing.expect(std.mem.indexOf(u8, message("FutureFailureCode", &buffer), "FutureFailureCode") != null);
    try std.testing.expectEqualStrings("HTTP 422 · 无效参数", message("HTTP 422 · 无效参数", &buffer));
}
