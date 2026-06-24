import 'package:flutter/material.dart';

import '../../../models/doc_field.dart';
import '../../../utils/translate.dart';
import 'base_field.dart';

/// `validator` for a required field. Returns the standard
/// `'$label is required'` message when [value] is null OR its string form
/// is empty; null otherwise (valid). Shared by every field widget that
/// wires a non-null `validator:` callback so the message text and the
/// null-or-empty check do not drift between widgets. Use
/// `(value) => requiredValidator(value, field.displayLabel)` (or fold
/// translation through [BaseField.style]) at the call site.
String? requiredValidator(dynamic value, String label) {
  if (value == null) {
    return sdkTr('{0} is required', [label]);
  }
  if (value is Iterable && value.isEmpty) {
    return sdkTr('{0} is required', [label]);
  }
  if (value.toString().isEmpty) {
    return sdkTr('{0} is required', [label]);
  }
  return null;
}

/// Returns an `InputDecoration` that applies the SDK's read-only fill
/// (grey-200 background when `field.readOnly`) on top of any caller-provided
/// [style] decoration. Used by every text-shaped field widget so a change
/// to the read-only theming applies everywhere at once.
InputDecoration baseFieldDecoration(
  DocField field, {
  String? hint,
  FieldStyle? style,
}) {
  return style?.decoration ??
      InputDecoration(
        hintText: hint ?? field.placeholder,
        border: const OutlineInputBorder(),
        filled: field.readOnly,
        fillColor: field.readOnly ? Colors.grey[200] : null,
      );
}

/// Splits [decoration] so a dropdown's FULL bordered box opens the menu.
///
/// `DropdownButtonFormField` / `FormBuilderDropdown` only treat the area
/// INSIDE the decoration's `contentPadding` as clickable. With the standard
/// form style that padding is 16px horizontal / 12px vertical, so a tap on the
/// left, right, top, or bottom edge of the visible box does nothing — the
/// touch target is smaller than the field. This zeroes the `contentPadding`
/// entirely (removing the dead margins on all sides) and returns the removed
/// inset as the dropdown's own `padding`, which IS part of the clickable area
/// (per `FormBuilderDropdown.padding` docs). The value therefore stays visually
/// inset while the entire box — full width AND full height — opens the menu.
({InputDecoration decoration, EdgeInsetsGeometry padding}) dropdownFullTap(
  InputDecoration decoration,
) {
  final cp = decoration.contentPadding;
  // Resolve to concrete insets. When the caller left contentPadding null the
  // framework applies its own ~12px default, so mirror that here rather than
  // collapsing the inset to zero.
  final resolved = cp is EdgeInsets
      ? cp
      : cp?.resolve(TextDirection.ltr) ??
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12);
  return (
    // contentPadding fully zeroed — every pixel of the box belongs to the
    // (clickable) dropdown padding below, so the whole field opens the menu.
    decoration: decoration.copyWith(contentPadding: EdgeInsets.zero),
    padding: resolved,
  );
}

/// Renders the field's validation error in the standard red 12px style
/// underneath the input. Used by the custom `FormBuilderField.builder`
/// field widgets (attach, image, rating) that build their own column and
/// need to surface `fieldState.errorText` manually.
Widget fieldErrorText(FormFieldState fieldState) {
  if (!fieldState.hasError) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(top: 4.0),
    child: Text(
      fieldState.errorText!,
      style: const TextStyle(color: Colors.red, fontSize: 12),
    ),
  );
}
