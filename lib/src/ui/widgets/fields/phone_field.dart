import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';

/// Default country code (India)
const String _defaultDialCode = '+91';

/// Widget for Phone field type. Uses a fixed +91 prefix; the user enters the
/// 10-digit mobile number only.
///
/// ## Why this is a [FormBuilderField] wrapping a private stateful input
/// The field's *stored* value (`+919876543210`) differs from what it *displays*
/// (`9876543210`). The form builder echoes every change back into the same
/// field via `patchValue` (for programmatic updates like auto-select). With a
/// plain name-bound `FormBuilderTextField`, that echo overwrote the visible
/// controller with the `+91…` form, whose `onChanged` re-prefixed it to
/// `+9191…`, never reaching a fixed point → **infinite recursion / stack
/// overflow** on the first keystroke (the bug this class fixes).
///
/// The fix decouples the *visible* controller (number-only, owned by
/// [_PhoneNumberInput]) from the *FormBuilder value* (stored `+91…`). External
/// patches flow in through `didUpdateWidget` and are applied to the controller
/// **only when the number actually changed** (echo guard), so a re-patch of our
/// own value is a no-op and the cycle terminates. Validation, the `+91` save
/// contract, and programmatic prefill all still work.
class PhoneField extends BaseField {
  const PhoneField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  /// Digits only, stripping any non-numeric characters.
  static String _digitsOnly(String? s) {
    if (s == null) return '';
    return s.replaceAll(RegExp(r'[^\d]'), '');
  }

  /// From a full stored value (e.g. `+919876543210`) get the number part
  /// without the country code. Returns '' for an empty / code-only value.
  static String numberFromStored(String? stored) {
    if (stored == null || stored.isEmpty) return '';
    if (stored.startsWith(_defaultDialCode)) {
      return stored
          .substring(_defaultDialCode.length)
          .replaceAll(RegExp(r'[^\d]'), '');
    }
    final digits = _digitsOnly(stored);
    const codeDigits = '91';
    if (digits == codeDigits || digits.isEmpty) return '';
    if (digits.length > 10 && digits.startsWith(codeDigits)) {
      return digits.substring(codeDigits.length);
    }
    return digits;
  }

  /// Build the stored value: dial-code + 10 digits (e.g. +919876543210).
  static String toStored(String numberDigits) {
    final digits = numberDigits.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return '';
    return '$_defaultDialCode$digits';
  }

  String? _validate(dynamic stored) {
    final raw = stored?.toString().trim() ?? '';
    if (raw.isEmpty) {
      return field.reqd ? '${field.displayLabel} is required' : null;
    }
    if (_digitsOnly(raw).length < 10) {
      return 'Please enter a valid 10-digit mobile number';
    }
    return null;
  }

  @override
  Widget buildField(BuildContext context) {
    final initialStored = value?.toString() ?? field.defaultValue?.toString();

    return FormBuilderField<String>(
      autovalidateMode: AutovalidateMode.onUserInteraction,
      key: ValueKey('phonefield_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: (initialStored != null && initialStored.isNotEmpty)
          ? initialStored
          : null,
      enabled: enabled && !field.readOnly,
      validator: _validate,
      builder: (state) {
        return _PhoneNumberInput(
          fieldKey: ValueKey('phone_${field.fieldname}'),
          storedValue: state.value,
          enabled: enabled && !field.readOnly,
          readOnly: field.readOnly,
          maxLength: (field.length != null && field.length! > 0)
              ? field.length!
              : 10,
          decoration:
              style?.decoration ??
              InputDecoration(
                hintText: field.placeholder ?? 'Enter mobile number',
                prefixText: '$_defaultDialCode ',
                border: const OutlineInputBorder(),
                filled: field.readOnly,
                fillColor: field.readOnly ? Colors.grey[200] : null,
                errorText: state.errorText,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
          onNumberChanged: (number) {
            final stored = number.isEmpty ? null : toStored(number);
            // Update the FormBuilder value (for validation/save). This does NOT
            // touch our controller, so it cannot echo back as a keystroke.
            state.didChange(stored);
            // Notify the host form (populates _formData with the +91 value).
            onChanged?.call(stored);
          },
        );
      },
    );
  }
}

/// Number-only text input owning its own controller. The controller is the
/// single source of truth for what the user sees; external [storedValue]
/// changes are reconciled in [didUpdateWidget] with an echo guard.
class _PhoneNumberInput extends StatefulWidget {
  const _PhoneNumberInput({
    required this.fieldKey,
    required this.storedValue,
    required this.enabled,
    required this.readOnly,
    required this.maxLength,
    required this.decoration,
    required this.onNumberChanged,
  });

  final Key fieldKey;
  final String? storedValue;
  final bool enabled;
  final bool readOnly;
  final int maxLength;
  final InputDecoration decoration;
  final ValueChanged<String> onNumberChanged;

  @override
  State<_PhoneNumberInput> createState() => _PhoneNumberInputState();
}

class _PhoneNumberInputState extends State<_PhoneNumberInput> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: PhoneField.numberFromStored(widget.storedValue),
    );
  }

  @override
  void didUpdateWidget(_PhoneNumberInput old) {
    super.didUpdateWidget(old);
    // Reconcile external (programmatic) changes to the stored value — but ONLY
    // when the resulting number differs from what's already shown. Re-patching
    // our own emitted value yields the same number → no write → no echo loop.
    final incoming = PhoneField.numberFromStored(widget.storedValue);
    if (incoming != _controller.text) {
      _controller.text = incoming;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: widget.fieldKey,
      controller: _controller,
      enabled: widget.enabled && !widget.readOnly,
      keyboardType: TextInputType.phone,
      maxLength: widget.maxLength,
      decoration: widget.decoration,
      onChanged: (text) {
        // Emit the digits the user typed; the wrapper converts to +91 stored.
        widget.onNumberChanged(text.replaceAll(RegExp(r'[^\d]'), ''));
      },
    );
  }
}
