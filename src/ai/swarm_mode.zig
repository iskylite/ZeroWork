//! V0.7 §10 三档模式：Auto/Swarm/Boost 的判定与切换语义。
//! - Auto（默认）：宿主按「信号 + 实质」两步判定是否本次按 Swarm 执行；
//!   无法判定实质时不升级（保守默认普通助手）。
//! - Swarm：会话级锁定，父提示注入 coordinator 段，create 默认 worker+常驻。
//! - Boost：仅手动进入，父提示注入 deep-lead 段；Auto 永不自动进入 Boost。
//! 档位切换对下一次用户请求生效；运行中的任务不迁移。
const std = @import("std");

pub const Mode = enum { auto, swarm, boost };

/// 每会话的档位状态。
pub const Session = struct {
    mode: Mode = .auto,
    /// V0.7 §10.2: Auto upgrades act on one request only and are not
    /// remembered between requests.
    last_auto_upgrade: bool = false,
};

/// 信号词（任一命中即开启判定，不足以单独升级）。
const signal_words = [_][]const u8{ "并行", "同时", "各自", "分别", "另开", "顺便" };

pub fn hasSignal(text: []const u8) bool {
    for (signal_words) |word| if (std.mem.indexOf(u8, text, word) != null) return true;
    return false;
}

pub const SubstanceCheck = struct {
    /// 可独立执行：≥2 个互不冲突的目标，或一段可并行的只读调查。
    independent_targets: bool,
    /// 已授权范围内（授权目标/会话/工具目录机器可判）。
    within_grant: bool,
    /// 可独立验收：每个子块有独立完成标准。
    independently_acceptable: bool,
};

/// V0.7 §10.2 实质判定：三条件须同时成立。
pub fn hasSubstance(check: SubstanceCheck) bool {
    return check.independent_targets and check.within_grant and check.independently_acceptable;
}

pub const AutoDecision = struct {
    upgrade: bool,
    /// 判定依据（记录于任务事件，面板可查——可解释）。
    reason: []const u8 = "",
};

/// Auto 档两步判定。信号未命中或实质不全 → 不升级。
pub fn decideAuto(text: []const u8, authorized_targets: usize, substance: SubstanceCheck) AutoDecision {
    const signal = hasSignal(text) or authorized_targets >= 2;
    if (!signal) return .{ .upgrade = false, .reason = "无并行信号" };
    if (!hasSubstance(substance)) return .{ .upgrade = false, .reason = "实质条件不全（独立目标/授权内/独立验收）" };
    return .{ .upgrade = true, .reason = "信号+实质成立，本次按 Swarm 执行" };
}

/// V0.7 §10.1.4: 模板菜单挂在模式菜单内；三档互斥单选。
pub fn modeLabel(mode: Mode) []const u8 {
    return switch (mode) {
        .auto => "Auto",
        .swarm => "Swarm",
        .boost => "Boost",
    };
}

/// §10.1 图标名（项目现有 Lucide 库）：bot / network / flame。
pub fn modeIcon(mode: Mode) []const u8 {
    return switch (mode) {
        .auto => "bot",
        .swarm => "network",
        .boost => "flame",
    };
}

/// 键盘等价命令（§10.1）：/swarm /boost /auto。
pub fn modeForCommand(command: []const u8) ?Mode {
    if (std.mem.eql(u8, command, "/swarm")) return .swarm;
    if (std.mem.eql(u8, command, "/boost")) return .boost;
    if (std.mem.eql(u8, command, "/auto")) return .auto;
    return null;
}

/// Boost 永不自动进入（多轮对抗须显式意图）。
pub fn canAutoEnter(mode: Mode) bool {
    return mode != .boost;
}

test "v0.7 mode auto signal plus substance two-step decision" {
    // 信号词 + 实质齐全 → 升级。
    const full: SubstanceCheck = .{ .independent_targets = true, .within_grant = true, .independently_acceptable = true };
    try std.testing.expect(decideAuto("同时检查三台主机", 3, full).upgrade);
    // 信号命中但实质不全 → 不升级（"顺便解释一下" 假阳性）。
    const partial: SubstanceCheck = .{ .independent_targets = false, .within_grant = true, .independently_acceptable = true };
    const casual = decideAuto("顺便解释一下这个报错", 1, partial);
    try std.testing.expect(!casual.upgrade);
    // 无信号不升级。
    try std.testing.expect(!decideAuto("检查主机", 1, full).upgrade);
    // ≥2 个已授权目标本身是信号。
    try std.testing.expect(decideAuto("检查主机", 2, full).upgrade);
    // 无法判定实质（如独立验收为否）→ 保守不升级。
    const unverifiable: SubstanceCheck = .{ .independent_targets = true, .within_grant = true, .independently_acceptable = false };
    try std.testing.expect(!decideAuto("并行处理", 2, unverifiable).upgrade);
}

test "v0.7 mode commands labels icons and boost guard" {
    try std.testing.expectEqual(Mode.swarm, modeForCommand("/swarm"));
    try std.testing.expectEqual(Mode.boost, modeForCommand("/boost"));
    try std.testing.expectEqual(Mode.auto, modeForCommand("/auto"));
    try std.testing.expect(modeForCommand("/other") == null);
    try std.testing.expectEqualStrings("Auto", modeLabel(.auto));
    try std.testing.expectEqualStrings("Swarm", modeLabel(.swarm));
    try std.testing.expectEqualStrings("Boost", modeLabel(.boost));
    try std.testing.expectEqualStrings("bot", modeIcon(.auto));
    try std.testing.expectEqualStrings("network", modeIcon(.swarm));
    try std.testing.expectEqualStrings("flame", modeIcon(.boost));
    // Boost 永不自动进入。
    try std.testing.expect(!canAutoEnter(.boost));
    try std.testing.expect(canAutoEnter(.auto));
    try std.testing.expect(canAutoEnter(.swarm));
}
