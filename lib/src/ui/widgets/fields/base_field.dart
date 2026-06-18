import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../models/doc_field.dart';
import '../../../utils/translate.dart';
import 'link_field_picker_mode.dart';

export 'link_field_picker_mode.dart';

/// Customization options for field styling
class FieldStyle {
  final TextStyle? labelStyle;
  final TextStyle? descriptionStyle;
  final InputDecoration? decoration;

  /// If set, used to translate field label and description (e.g. from Frappe translations).
  final String Function(String)? translate;

  /// When false, hides the external label rendered above the field widget.
  final bool showLabel;

  /// When false, hides the external description rendered below the field widget.
  final bool showDescription;

  /// Keystroke-level input formatters for text inputs
  final List<TextInputFormatter>? inputFormatters;

  final LinkFieldPickerMode linkFieldPickerMode;

  final DateTime? Function(DocField field)? getFirstDate;
  final DateTime? Function(DocField field)? getLastDate;

  const FieldStyle({
    this.labelStyle,
    this.descriptionStyle,
    this.decoration,
    this.translate,
    // Default to showing labels/descriptions for backward compatibility — a
    // consumer constructing FieldStyle for an unrelated reason (e.g. a custom
    // decoration) must not silently lose them (PR#36 round-4 B6).
    // FrappeFormBuilder always passes these explicitly (form_builder.dart),
    // so this default only affects external consumers.
    this.showLabel = true,
    this.showDescription = true,
    this.inputFormatters,
    this.linkFieldPickerMode = LinkFieldPickerMode.inline,
    this.getFirstDate,
    this.getLastDate,
  });
}

/// Base class for all Frappe field widgets
abstract class BaseField extends StatelessWidget {
  final DocField field;
  final dynamic value;
  final ValueChanged<dynamic>? onChanged;
  final bool enabled;
  final FieldStyle? style;

  const BaseField({
    super.key,
    required this.field,
    this.value,
    this.onChanged,
    this.enabled = true,
    this.style,
  });

  /// Build the field widget
  @override
  Widget build(BuildContext context) {
    if (field.hidden) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (style?.showLabel != false &&
            field.label != null &&
            field.label!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    style?.translate != null
                        ? style!.translate!(field.displayLabel)
                        : field.displayLabel,
                    softWrap: true,
                    style:
                        style?.labelStyle ??
                        TextStyle(
                          fontWeight: field.reqd
                              ? FontWeight.bold
                              : FontWeight.normal,
                          fontSize: 14,
                        ),
                  ),
                ),
                if (field.reqd)
                  const Padding(
                    padding: EdgeInsets.only(left: 4.0),
                    child: Text('*', style: TextStyle(color: Colors.red)),
                  ),
              ],
            ),
          ),
        buildField(context),
        if (style?.showDescription != false &&
            field.description != null &&
            field.description!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: Text(
              style?.translate != null
                  ? style!.translate!(field.description!)
                  : field.description!,
              style:
                  style?.descriptionStyle ??
                  Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
            ),
          ),
      ],
    );
  }

  /// Build the actual input widget (to be implemented by subclasses)
  Widget buildField(BuildContext context);

  /// Validate the field value
  String? validate(dynamic value) {
    if (field.reqd && (value == null || value.toString().isEmpty)) {
      final label = style?.translate != null
          ? style!.translate!(field.displayLabel)
          : field.displayLabel;
      return sdkTr('{0} is required', [label]);
    }
    return null;
  }
}
