import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import '../../../utils/translate.dart';
import 'base_field.dart';
import 'field_helpers.dart';

/// Widget for Select field type. Supports single and multi-select (when field.allowMultiple).
class SelectField extends BaseField {
  const SelectField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  /// Raw (untranslated) option keys — used as stored document values.
  List<String> _getRawOptions() {
    if (field.options == null || field.options!.isEmpty) return [];
    return field.options!
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// Translated display labels — used only for rendering.
  List<String> _getOptions() {
    final raw = _getRawOptions();
    final t = style?.translate;
    return t == null ? raw : raw.map(t).toList();
  }

  /// Parse stored value to list for multi-select (comma-separated)
  List<String> _valueToList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    return raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// Serialize list to comma-separated string for form/server
  String _listToValue(List<String>? list) {
    if (list == null || list.isEmpty) return '';
    return list.join(',');
  }

  @override
  Widget buildField(BuildContext context) {
    // rawOptions: English keys used for stored values and equality checks.
    // displayOptions: translated labels used only for display (Text children).
    final rawOptions = _getRawOptions();
    final displayOptions = _getOptions();

    if (rawOptions.isEmpty) {
      return FormBuilderTextField(
        autovalidateMode: AutovalidateMode.onUserInteraction,
        key: ValueKey('${field.fieldname}_no_options'),
        name: field.fieldname ?? '',
        initialValue: value?.toString() ?? field.defaultValue ?? '',
        enabled: false,
        decoration:
            style?.decoration ??
            InputDecoration(
              hintText: sdkTr('No options available'),
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: Colors.grey[200],
            ),
      );
    }

    if (field.allowMultiple) {
      final initialList = _valueToList(value?.toString() ?? field.defaultValue);
      // Match against raw English keys, not translated labels.
      final validInitialList = initialList
          .where((v) => rawOptions.contains(v))
          .toList();

      // Auto-select when exactly one option and no valid selection.
      // Use raw English key for the stored value.
      final displayList = rawOptions.length == 1 && validInitialList.isEmpty
          ? [rawOptions.first]
          : validInitialList;
      if (rawOptions.length == 1 && validInitialList.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onChanged?.call(_listToValue([rawOptions.first]));
        });
      }

      return FormBuilderCheckboxGroup<String>(
        autovalidateMode: AutovalidateMode.onUserInteraction,
        key: ValueKey('${field.fieldname}_multi_${rawOptions.length}'),
        name: field.fieldname ?? '',
        initialValue: displayList,
        enabled: enabled && !field.readOnly,
        decoration:
            style?.decoration ??
            InputDecoration(
              labelText:
                  field.placeholder ?? sdkTr('Select {0}', [field.displayLabel]),
              border: const OutlineInputBorder(),
              filled: field.readOnly,
              fillColor: field.readOnly ? Colors.grey[200] : null,
            ),
        // value: raw English key (stored value); child: translated display label.
        options: rawOptions.asMap().entries.map((entry) {
          return FormBuilderFieldOption(
            value: entry.value,
            child: Text(displayOptions[entry.key]),
          );
        }).toList(),
        validator: field.reqd
            ? (value) => requiredValidator(value, field.displayLabel)
            : null,
        onChanged: (val) => onChanged?.call(_listToValue(val)),
      );
    }

    final initialValueStr = value?.toString() ?? field.defaultValue;
    String? validInitialValue;
    if (initialValueStr != null && initialValueStr.isNotEmpty) {
      // Match against raw English keys, not translated labels.
      if (rawOptions.contains(initialValueStr)) {
        validInitialValue = initialValueStr;
      } else {
        validInitialValue = null;
      }
    }

    // Auto-select when exactly one option and no valid selection.
    // Emit raw English key — never a translated label.
    if (rawOptions.length == 1 &&
        (validInitialValue == null || validInitialValue.isEmpty)) {
      validInitialValue = rawOptions.first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onChanged?.call(rawOptions.first);
      });
    }

    return FormBuilderDropdown<String>(
      autovalidateMode: AutovalidateMode.onUserInteraction,
      key: ValueKey('select_${field.fieldname}_${rawOptions.length}'),
      name: field.fieldname ?? '',
      initialValue: validInitialValue,
      enabled: enabled && !field.readOnly,
      decoration:
          style?.decoration ??
          InputDecoration(
            hintText:
                field.placeholder ?? sdkTr('Select {0}', [field.displayLabel]),
            border: const OutlineInputBorder(),
            filled: field.readOnly,
            fillColor: field.readOnly ? Colors.grey[200] : null,
          ),
      // value: raw English key (stored value); child: translated display label.
      items: rawOptions.asMap().entries.map((entry) {
        return DropdownMenuItem<String>(
          value: entry.value,
          child: Text(displayOptions[entry.key]),
        );
      }).toList(),
      validator: field.reqd
          ? (value) => requiredValidator(value, field.displayLabel)
          : null,
      onChanged: (val) => onChanged?.call(val),
    );
  }
}
