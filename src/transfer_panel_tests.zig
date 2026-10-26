//! transfer_panel 的 zenit 布局测试聚合器：独立测试模块（test-ui step）。
//! 单独存在的理由见 build.zig 注释——zenit 的 coretext 桥是 C 源，挂到被
//! exe 依赖的模块上会传播成重复链接（zenit build.zig 同款警告）。
// Load the nested host UI contract even under a narrow test filter.
comptime {
    _ = @import("transfer/sftp_engine.zig");
    _ = @import("ui/wizard.zig");
    _ = @import("ui/workspace.zig");
    _ = @import("file_application_host_tests.zig");
}
test {
    _ = @import("ui_constraint_tests.zig");
    _ = @import("record_cleanup_ui_tests.zig");
    _ = @import("application_data_cleanup_ui_tests.zig");
    _ = @import("ai_remote_picker_view_tests.zig");
    _ = @import("notification_presenter_controls_tests.zig");
    _ = @import("chrome_policy_tests.zig");
    _ = @import("ui/transfer_panel.zig");
    _ = @import("wizard_tests.zig");
    _ = @import("wizard_probe_tests.zig");
    _ = @import("settings_content_tests.zig");
    _ = @import("plugin_settings_v3_tests.zig");
    _ = @import("settings_transfer_budget_tests.zig");
    _ = @import("settings_transfer_defaults_tests.zig");
    _ = @import("theme_layer_tests.zig");
    _ = @import("terminal_overlay_theme_tests.zig");
    _ = @import("terminal_search_theme_tests.zig");
    _ = @import("settings_field_lifecycle_tests.zig");
    _ = @import("settings_search_alias_tests.zig");
    _ = @import("status_detail_tests.zig");
    _ = @import("ssh_status_host_tests.zig");
    _ = @import("ssh_terminal_status_tests.zig");
    _ = @import("asset_group_host_tests.zig");
    _ = @import("sidebar_view_tests.zig");
    _ = @import("ai_message_alignment_tests.zig");
    _ = @import("settings_runtime_consumer_tests.zig");
    _ = @import("terminal_surface_tests.zig");
    _ = @import("ui/background_layers.zig");
    _ = @import("background_surface_tests.zig");
    _ = @import("socks_info_theme_tests.zig");
    _ = @import("socks_background_ui_tests.zig");
    _ = @import("material_popup_tests.zig");
    _ = @import("shared_transfer_native_tests.zig");
    _ = @import("totp_autofill_tests.zig");
    _ = @import("notification_read_view_tests.zig");
    _ = @import("settings_notification_permission_view_tests.zig");
    _ = @import("auxiliary_appearance_tests.zig");
    _ = @import("ui/session_menu.zig");
    _ = @import("transfer_manager_view_tests.zig");
    _ = @import("transfer_confirmation_view_tests.zig");
    _ = @import("settings_picker_tests.zig");
    _ = @import("keybinding_recorder_tests.zig");
    _ = @import("ai_provider_settings_tests.zig");
    _ = @import("ai_composer_controls_view_tests.zig");
    _ = @import("ai_composer_input_tests.zig");
    _ = @import("ai_attachments_view_tests.zig");
    _ = @import("ai_image_attachment_view_tests.zig");
    _ = @import("ai_image_attachment_tests.zig");
    _ = @import("ai_terminal_text_attachment_tests.zig");
    _ = @import("ai_vt_attachment_view_tests.zig");
    _ = @import("ai_panel_visibility_tests.zig");
    _ = @import("command_error_hint_tests.zig");
    _ = @import("ai_float_gestures_tests.zig");
    _ = @import("ai_tool_approval_view_tests.zig");
    _ = @import("ai_tool_results_view_tests.zig");
    _ = @import("ai_recovery_view_tests.zig");
    _ = @import("connection_host_tests.zig");
    _ = @import("quick_connect_view_tests.zig");
    _ = @import("wizard_test_progress_tests.zig");
    _ = @import("terminal_search_tests.zig");
    _ = @import("ui/terminal_view.zig");
    _ = @import("vt/ssh_worker.zig");
    _ = @import("ui/tab_rename.zig");
    _ = @import("ui/tab_picker.zig");
    _ = @import("ui/workspace.zig");
    _ = @import("ui/application_host.zig");
    _ = @import("ui/multiwindow_test_routes.zig");
    _ = @import("fullscreen_titlebar_tests.zig");
    _ = @import("ui/history_list.zig");
    _ = @import("ui/history_row.zig");
    _ = @import("ui/session_runtime.zig");
    _ = @import("ssh_resource_ledger_tests.zig");
    _ = @import("auth_challenge_view_tests.zig");
    _ = @import("connection_progress_view_tests.zig");
    _ = @import("asset_action_view_tests.zig");
    _ = @import("connection_details_view_tests.zig");
    _ = @import("connection_logs_view_tests.zig");
    _ = @import("status_connection_view_tests.zig");
    _ = @import("socks_info_view_tests.zig");
    _ = @import("socks_config_view_tests.zig");
    _ = @import("ui/socks_exposure_confirm_tests.zig");
    _ = @import("ai_local_tools_tests.zig");
    _ = @import("group_close_controller_tests.zig");
    _ = @import("application_task_domain_tests.zig");
    _ = @import("provider_protocol_tools_tests.zig");
    _ = @import("sftp_readonly_tests.zig");
    _ = @import("sftp_resume_native_tests.zig");
    _ = @import("file_binding_host_tests.zig");
    _ = @import("file_binding_startup_tests.zig");
    _ = @import("file_route_factory_tests.zig");
    _ = @import("file_workspace_view_tests.zig");
    _ = @import("transfer_engine_mux_tests.zig");
    _ = @import("file_transfer_runtime_tests.zig");
    _ = @import("file_workspace_controller_tests.zig");
    _ = @import("sftp_adapter_tests.zig");
    _ = @import("file_authentication_tests.zig");
    _ = @import("file_workspace_presentation_tests.zig");
    _ = @import("file_transfer_host_tests.zig");
    _ = @import("engine_dispatch_tests.zig");
    _ = @import("transfer_conflict_tests.zig");
    _ = @import("file_application_host_tests.zig");
    _ = @import("ai_ssh_tools_tests.zig");
    _ = @import("ai_file_tool_result_tests.zig");
    _ = @import("ai_tail_follow_tests.zig");
    _ = @import("local_fs_service_tests.zig");
}

test {
    _ = @import("file_mkdir_view_tests.zig");
    _ = @import("transfer_conflict_view_tests.zig");
}

test {
    _ = @import("broadcast_view_tests.zig");
}
