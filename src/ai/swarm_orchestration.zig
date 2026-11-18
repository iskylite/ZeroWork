//! V0.7 §12 编排原语：depends_on 依赖、challenge 破坏性复审与 boost 链约束。
//! - depends_on: 所列子任务全部到达任一终态后宿主才启动本任务；闭包含
//!   自身 → DependencyCycle 报错含环路径。
//! - 依赖终态语义：succeeded 正常启动；failed/outcome_unknown/cancelled/
//!   interrupted 不自动启动，宿主向父投递"依赖未满足"事件。
//! - 等待依赖的任务计入活跃额度（child_max_active，创建即占位）。
//! - challenge(purpose) 拿被挑战者的 settle_report 做只读复审。
//! - boost 链轮次上限默认 5（可配置 ≤8），超限拒绝新挑战轮。
const std = @import("std");

/// V0.7 §12.1 create role tiers (verifier is a purpose, not a role). This
/// mirrors the wire enum of host.agent_tasks; the template slot resolution
/// in config/ai_role_templates.zig maps parent/planner/verifier/worker/batch.
pub const GatewayRole = enum { planner, worker, batch };

pub const default_boost_max_rounds: u8 = 5;
pub const max_boost_rounds: u8 = 8;

/// 环检测：dependencies 中含自身（self_seq）即闭环。
/// depends_on/challenge_target 引用的三向解析（@seq / 32 位任务 ID / 唯一裸
/// label）统一在 child_gateway.resolveChildTask 按 §2.1 规则完成。
pub fn containsSelf(dependencies: []const u32, self_seq: u32) error{DependencyCycle}!void {
    for (dependencies) |dep| if (dep == self_seq) return error.DependencyCycle;
}

pub const Dep = struct { seq: u32, terminal: bool, succeeded: bool };

pub const StartDecision = union(enum) {
    start,
    /// 前序终态非成功：不自动启动，父决定改派/串行降级/放弃分支。
    blocked: struct { failed_seq: u32 },
    /// 仍有未终态的依赖：继续等待。
    waiting,
};

/// 依赖终态语义（§12.1 表）：全部终态且全部 succeeded → start；
/// 任一终态非 succeeded → blocked；否则 waiting。
pub fn decide(dependencies: []const Dep) StartDecision {
    var all_terminal = true;
    for (dependencies) |dep| {
        if (!dep.terminal) {
            all_terminal = false;
            continue;
        }
        if (!dep.succeeded) return .{ .blocked = .{ .failed_seq = dep.seq } };
    }
    if (!all_terminal) return .waiting;
    return .start;
}

pub const Challenge = struct {
    /// 被挑战者成员（@seq）。
    target: u32,
    /// 拿 target 的 settle_report 与目标做破坏性复审；只读语义同 verify。
    pub fn validate(self: Challenge) !void {
        if (self.target == 0) return error.InvalidArguments;
    }
};

/// boost 链轮次上限：父显式声明可放宽到 8；超限拒绝新挑战轮。
pub fn allowsRound(current: u8, declared_max: u8) bool {
    const ceiling = @min(declared_max, max_boost_rounds);
    return current < ceiling;
}

test "v0.7 depends_on self-cycle detection" {
    // 闭包含自身 → DependencyCycle。
    try std.testing.expectError(error.DependencyCycle, containsSelf(&.{ 1, 2 }, 2));
    try containsSelf(&.{ 1, 3 }, 2);
}

test "v0.7 dependency terminal semantics decide start blocked waiting" {
    // 全部 succeeded → start。
    try std.testing.expect(decide(&.{ .{ .seq = 1, .terminal = true, .succeeded = true }, .{ .seq = 2, .terminal = true, .succeeded = true } }) == .start);
    // 任一 failed → blocked（携带 #seq）。
    const blocked = decide(&.{ .{ .seq = 1, .terminal = true, .succeeded = true }, .{ .seq = 2, .terminal = true, .succeeded = false } });
    try std.testing.expect(blocked == .blocked and blocked.blocked.failed_seq == 2);
    // 仍有未终态依赖 → waiting。
    try std.testing.expect(decide(&.{ .{ .seq = 1, .terminal = true, .succeeded = true }, .{ .seq = 2, .terminal = false, .succeeded = false } }) == .waiting);
    // cancelled/interrupted 同样不自动启动。
    const cancelled = decide(&.{.{ .seq = 1, .terminal = true, .succeeded = false }});
    try std.testing.expect(cancelled == .blocked);
    try std.testing.expect(decide(&.{}) == .start);
}

test "v0.7 boost chain round ceiling and challenge validation" {
    // 默认 5 轮：第 5 轮仍允许，第 6 轮拒绝。
    try std.testing.expect(allowsRound(4, default_boost_max_rounds));
    try std.testing.expect(!allowsRound(5, default_boost_max_rounds));
    // 父显式声明 ≤8。
    try std.testing.expect(allowsRound(7, 8));
    try std.testing.expect(!allowsRound(8, 8));
    // 声明超过 8 被 clamp；父可收紧。
    try std.testing.expect(!allowsRound(8, 20));
    try std.testing.expect(!allowsRound(4, 1));
    try std.testing.expect(allowsRound(0, 1));
    // challenge 目标校验。
    try (Challenge{ .target = 3 }).validate();
    try std.testing.expectError(error.InvalidArguments, (Challenge{ .target = 0 }).validate());
}
