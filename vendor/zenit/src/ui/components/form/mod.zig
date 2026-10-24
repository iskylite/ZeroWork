/// Form component module
///
/// Three-tier architecture:
/// - Layer 0: FormOf(T), data + validation
/// - Layer 1: FormFieldOf(T), field container UI
/// - Layer 2: Form, layout container
const std = @import("std");

// Layer 0: Data + validation layer
pub const form_data = @import("form_data.zig");
pub const FormOf = form_data.FormOf;
pub const ValidationResult = form_data.ValidationResult;
pub const ValidateTrigger = form_data.ValidateTrigger;
pub const FieldMeta = form_data.FieldMeta;

// Layer 1: Field container UI
pub const form_field = @import("form_field.zig");
pub const FormFieldOf = form_field.FormFieldOf;
pub const FormFieldResult = form_field.FormFieldResult;
pub const FormFieldConfig = form_field.FormFieldConfig;

// Layer 2: Layout container
pub const form_layout = @import("form_layout.zig");
pub const Form = form_layout.Form;
pub const FormBuilder = form_layout.FormBuilder;
pub const FormLayout = form_layout.FormLayout;
pub const FormResult = form_layout.FormResult;
pub const FormSection = form_layout.FormSection;

test {
    std.testing.refAllDecls(@This());
}
