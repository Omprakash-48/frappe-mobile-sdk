import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import '../../models/doc_type_meta.dart';
import '../../models/doc_field.dart';
import '../../models/link_filter_result.dart';
import '../../constants/field_types.dart';
import '../../services/link_option_service.dart';
import '../../services/link_field_coordinator.dart';
import '../../utils/depends_on_evaluator.dart';
import '../../utils/field_normalizer.dart';
import '../../utils/sdk_log.dart';
import 'fields/field_factory.dart';
import 'fields/base_field.dart';
import 'default_form_style.dart';

export 'fields/link_field_picker_mode.dart';

/// Simple 2-arg callback for Button field. Used by [FrappeFormBuilder] and [renderForm].
typedef ButtonPressedCallback =
    Future<void> Function(DocField field, Map<String, dynamic> formData);

/// Callback when a Button field is pressed. Implement client-script logic (API calls, dialogs).
/// Call [useDefault] to fall back to SDK default (server method from [field.options] when set).
/// Used by [FormScreen] and [navigateToForm].
typedef OnButtonPressedCallback =
    Future<void> Function(
      DocField field,
      Map<String, dynamic> formData,
      Future<void> Function(DocField field, Map<String, dynamic> formData)
      useDefault,
    );

/// Called when a field value changes. Returns a map of computed field updates
/// (e.g. for hidden computed fields) or null when there is nothing to patch.
///
/// The [formData] argument is a snapshot — mutating it does not alter the
/// SDK's internal form state. Return patches to apply changes.
typedef FieldChangeHandler =
    Map<String, dynamic>? Function(
      String fieldName,
      dynamic newValue,
      Map<String, dynamic> formData,
    );

/// Called before save with the current form data. Return a non-null error
/// message to block the save and surface the message to the user; return
/// null to allow the save to proceed.
///
/// Use this for DB-independent rules (range checks, regex, conditional
/// mandatory, cross-field rules) that can be evaluated against [data]
/// alone — so the user sees the error at save-time rather than at sync-time.
typedef FormValidator = String? Function(Map<String, dynamic> data);

/// Layout mode for form tab headers.
enum FormTabHeaderLayout { tabBar, stepper }

/// Visual style for stepper tab header mode.
class FormStepHeaderStyle {
  final Color activeColor;
  final Color inactiveColor;
  final Color inactiveTextColor;
  final Color textColor;
  final double dotSize;
  final double lineHeight;
  final double labelsTopGap;
  final double edgePadding;
  final TextStyle? numberTextStyle;
  final TextStyle? labelTextStyle;

  const FormStepHeaderStyle({
    this.activeColor = const Color(0xFF2DD4BF),
    this.inactiveColor = const Color(0xFFD1D5DB),
    this.inactiveTextColor = const Color(0xFF6B7280),
    this.textColor = const Color(0xFF111827),
    this.dotSize = 34.0,
    this.lineHeight = 2.0,
    this.labelsTopGap = 10.0,
    this.edgePadding = 8.0,
    this.numberTextStyle,
    this.labelTextStyle,
  });
}

/// Customization options for form styling
class FrappeFormStyle {
  /// Custom InputDecoration builder for text fields
  final InputDecoration Function(DocField field)? fieldDecoration;

  /// Custom label text style
  final TextStyle? labelStyle;

  /// Custom description text style
  final TextStyle? descriptionStyle;

  /// Custom section title style
  final TextStyle? sectionTitleStyle;

  /// Custom section card margin
  final EdgeInsets? sectionMargin;

  /// Custom section card padding
  final EdgeInsets? sectionPadding;

  /// Custom field spacing
  final EdgeInsets? fieldPadding;

  /// Max lines for section titles before ellipsis (default: 3)
  final int? sectionTitleMaxLines;

  /// Max lines for tab titles before ellipsis (default: 2)
  final int? tabTitleMaxLines;

  /// Header layout used when there are multiple tabs.
  final FormTabHeaderLayout tabHeaderLayout;

  /// Optional style when [tabHeaderLayout] is [FormTabHeaderLayout.stepper].
  final FormStepHeaderStyle? stepHeaderStyle;

  /// Whether to show labels above each field widget.
  final bool showFieldLabel;

  /// Whether to show field descriptions below each field widget.
  final bool showFieldDescription;

  /// Optional section card color.
  final Color? sectionCardColor;

  /// Custom input formatters builder for text fields
  final List<TextInputFormatter>? Function(DocField field)? inputFormatters;

  final LinkFieldPickerMode linkFieldPickerMode;

  /// Optional bounds evaluators for Date Pickers
  final DateTime? Function(String doctype, DocField field)? getFirstDate;
  final DateTime? Function(String doctype, DocField field)? getLastDate;

  const FrappeFormStyle({
    this.fieldDecoration,
    this.labelStyle,
    this.descriptionStyle,
    this.sectionTitleStyle,
    this.sectionMargin,
    this.sectionPadding,
    this.fieldPadding,
    this.sectionTitleMaxLines,
    this.tabTitleMaxLines,
    this.tabHeaderLayout = FormTabHeaderLayout.tabBar,
    this.stepHeaderStyle,
    this.showFieldLabel = true,
    this.showFieldDescription = true,
    this.sectionCardColor,
    this.inputFormatters,
    this.linkFieldPickerMode = LinkFieldPickerMode.inline,
    this.getFirstDate,
    this.getLastDate,
  });
}

/// Main form builder widget that renders Frappe forms based on metadata
class FrappeFormBuilder extends StatefulWidget {
  final DocTypeMeta meta;
  final Map<String, dynamic>? initialData;
  final Function(Map<String, dynamic>)? onSubmit;
  final bool readOnly;
  final LinkOptionService? linkOptionService;

  /// When true (default), use LinkFieldCoordinator for sequenced link option loading.
  final bool useLinkFieldCoordinator;

  /// Custom field factory (if null, uses default FieldFactory)
  final FieldFactory? customFieldFactory;

  /// Custom styling options
  final FrappeFormStyle? style;

  /// Upload file to server; when set, Image/Attach fields upload first and store file_url
  final Future<String?> Function(File file)? uploadFile;

  /// Base URL for displaying uploaded file URLs (e.g. for image preview)
  final String? fileUrlBase;

  /// Auth headers for loading private file URLs (e.g. [FrappeClient.requestHeaders])
  final Map<String, String>? imageHeaders;

  /// Fetches a linked document by doctype and name (for fetch_from).
  /// Try local repository first, then server. Return null if not found.
  final Future<Map<String, dynamic>?> Function(
    String linkedDoctype,
    String docName,
  )?
  fetchLinkedDocument;

  /// Resolves child doctype meta for Table fields. Required for child table support.
  final Future<DocTypeMeta> Function(String doctype)? getMeta;

  /// Called once with the form's submit handler so the parent (e.g. FormScreen) can trigger save from AppBar.
  final void Function(void Function() submit)? registerSubmit;

  /// Fires when [registerSubmit]'s callback was invoked but form
  /// validation rejected the submit attempt. Use this to stop a
  /// parent-managed loading indicator that was started before triggering
  /// submit. Does not fire on successful submit ([onSubmit] does).
  final VoidCallback? onValidationFailed;

  /// If set, field labels, section titles and tab labels are passed through this (e.g. sdk.translations.translate).
  final String Function(String)? translate;

  /// Called when a Button field is pressed. [FormScreen] adapts [OnButtonPressedCallback] to this.
  final ButtonPressedCallback? onButtonPressed;

  /// Called when form data changes (any field value). Use to detect dirty state.
  final void Function(Map<String, dynamic> currentData)? onFormDataChanged;

  /// Called when a field value changes. Returns a map of computed field updates
  /// to patch into the form (e.g. for hidden computed fields).
  final FieldChangeHandler? onFieldChange;

  /// Parent form data when this builder renders a child-table row.
  /// Null for top-level forms.
  final Map<String, dynamic>? parentFormData;

  /// Looks up a filter builder by doctype + fieldname. Returns null when
  /// the app has no custom filter for that field.
  final LinkFilterBuilder? Function(String doctype, String fieldname)?
  getLinkFilterBuilder;

  /// When true, a value set programmatically by [onFieldChange] (a computed
  /// value, or a `fetch_from` result) re-fires the SAME change pipeline for
  /// that field — its own `fetch_from`, [onFieldChange] and `depends_on` — so
  /// dependent fields recompute. This mirrors Frappe Desk, where
  /// `frm.set_value(field, value)` fires that field's change trigger even for a
  /// programmatic set.
  ///
  /// Without this, a patched value does NOT chain: the patch writes the value
  /// into form state and calls `patchValue`, but the re-entrant `onChanged`
  /// sees `oldValue == value` (the value is already stored) and the pipeline's
  /// own guard no-ops it — so a computed field that feeds another computed
  /// field never triggers the second computation.
  ///
  /// Loop safety is value-equality (a field re-fires only when its value
  /// actually changed, so the cascade converges to a fixpoint) plus a hard
  /// depth cap ([_maxProgrammaticCascadeDepth]). Default `false` preserves the
  /// legacy behaviour where programmatic patches never cascaded.
  final bool cascadeProgrammaticChanges;

  const FrappeFormBuilder({
    super.key,
    required this.meta,
    this.initialData,
    this.onSubmit,
    this.readOnly = false,
    this.linkOptionService,
    this.useLinkFieldCoordinator = true,
    this.customFieldFactory,
    this.style,
    this.uploadFile,
    this.fileUrlBase,
    this.imageHeaders,
    this.fetchLinkedDocument,
    this.getMeta,
    this.registerSubmit,
    this.onValidationFailed,
    this.translate,
    this.onButtonPressed,
    this.onFormDataChanged,
    this.onFieldChange,
    this.parentFormData,
    this.getLinkFilterBuilder,
    this.cascadeProgrammaticChanges = false,
  });

  @override
  State<FrappeFormBuilder> createState() => _FrappeFormBuilderState();
}

/// Form structure for building tabs/sections
class _FormTab {
  final DocField tabField;
  final List<_FormSection> sections = [];

  _FormTab(this.tabField);
}

class _FormSection {
  final DocField sectionField;
  final List<_FormColumn> columns = [];

  _FormSection(this.sectionField);
}

class _FormColumn {
  final List<DocField> fields = [];
}

class _FrappeFormBuilderState extends State<FrappeFormBuilder>
    with TickerProviderStateMixin {
  late GlobalKey<FormBuilderState> _formKey;
  late final FieldFactory _fieldFactory;
  LinkFieldCoordinator? _linkFieldCoordinator;
  StreamSubscription<LinkLoadProgress>? _progressSubscription;
  bool _linkOptionsLoading = false;
  String? _linkOptionsLoadingMessage;
  final Map<String, dynamic> _formData = {};

  /// > 0 while a programmatic-patch `patchValue` is being applied under
  /// [FrappeFormBuilder.cascadeProgrammaticChanges]. The `patchValue` re-fires
  /// this field's `onChanged` synchronously (didChange → onChanged); for typed
  /// fields [FieldNormalizer] can change the value's representation, so that
  /// echo would NOT self-guard and would double-run the pipeline alongside the
  /// explicit cascade. This flag makes the echo a pure state-sync no-op so the
  /// explicit [_scheduleProgrammaticCascade] is the single cascade path. Raised
  /// for the synchronous cross-field (`rest`) echo only when the cascade flag
  /// is on (legacy behaviour otherwise), but ALWAYS for the deferred self-key
  /// echo — an unguarded self-key echo on a typed field re-fires the pipeline
  /// every frame with no depth cap (the cap is cascade-gated), so a
  /// self-referential handler would hang. See the self-key echo in
  /// [_onFieldValueChanged].
  int _programmaticEchoGuard = 0;

  late TabController _tabController;
  final List<_FormTab> _tabs = [];
  final Map<String, int> _fieldTabIndex = {};

  /// Parent form data for filter resolution. Equals [_formData] when this
  /// builder is a top-level form (not a child-row form).
  Map<String, dynamic> get effectiveParentFormData =>
      widget.parentFormData ?? _formData;

  TabController get tabController => _tabController;

  void _attachTabControllerListener() {
    _tabController.addListener(() {
      if (!mounted) return;
      // Rebuild to keep custom stepper header in sync with active tab.
      setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    _formKey = GlobalKey<FormBuilderState>();

    _formData.addAll(widget.initialData ?? {});

    for (final field in widget.meta.fields) {
      if (field.fieldname != null && !_formData.containsKey(field.fieldname)) {
        final defVal = field.defaultValue;
        if (defVal != null &&
            field.fieldtype == 'Date' &&
            defVal.toLowerCase() == 'today') {
          final now = DateTime.now();
          _formData[field.fieldname!] =
              '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        } else {
          _formData[field.fieldname!] ??= defVal;
        }
      }
    }

    if (widget.linkOptionService != null && widget.useLinkFieldCoordinator) {
      _linkFieldCoordinator = LinkFieldCoordinator(
        meta: widget.meta,
        linkOptionService: widget.linkOptionService!,
        useCoordinator: true,
        parentFormData: effectiveParentFormData,
        getLinkFilterBuilder: widget.getLinkFilterBuilder,
      );
      _linkFieldCoordinator!.prefetchInitial(_formData);
      _progressSubscription = _linkFieldCoordinator!.progressStream.listen((p) {
        if (mounted) {
          setState(() {
            _linkOptionsLoading = p.loading;
            _linkOptionsLoadingMessage = p.message;
          });
        }
      });
    }

    _fieldFactory =
        widget.customFieldFactory ??
        FieldFactory(
          linkOptionService: widget.linkOptionService,
          linkFieldCoordinator: _linkFieldCoordinator,
        );
    // Custom factories supplied by the host won't have these wired in
    // their own constructor — they're host-internal services exposed
    // here so override factories (e.g. SNF's SnfFieldFactory) can
    // still produce Link/etc. fields without their pickers being half-
    // configured on first build. Default-constructed FieldFactory above
    // sets both directly; this branch handles the custom case.
    if (widget.customFieldFactory != null) {
      _fieldFactory.linkOptionService ??= widget.linkOptionService;
      _fieldFactory.linkFieldCoordinator ??= _linkFieldCoordinator;
    }

    _buildFormStructure();
    _tabController = TabController(
      length: _tabs.isEmpty ? 1 : _tabs.length,
      vsync: this,
    );
    _attachTabControllerListener();
    _triggerFetchFromForPrefilledLinks();
  }

  /// Trigger fetch_from for Link fields that already have values in _formData
  /// so dependent fields (e.g. patient_name from patient) get populated.
  /// Called from both initState and didUpdateWidget.
  void _triggerFetchFromForPrefilledLinks() {
    if (widget.fetchLinkedDocument == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final field in widget.meta.fields) {
        if (field.fieldtype == 'Link' && field.fieldname != null) {
          final val = _formData[field.fieldname];
          if (val != null && val.toString().trim().isNotEmpty) {
            _handleFetchFrom(field.fieldname!, val);
          }
        }
      }
    });
  }

  Map<String, dynamic> _normalizePatchValues(Map<String, dynamic> updates) {
    final normalized = <String, dynamic>{};
    for (final entry in updates.entries) {
      final fieldMeta = widget.meta.fields
          .where((f) => f.fieldname == entry.key)
          .cast<DocField?>()
          .firstWhere((f) => f != null, orElse: () => null);
      if (fieldMeta == null) {
        normalized[entry.key] = entry.value ?? '';
        continue;
      }
      normalized[entry.key] = FieldNormalizer.normalize(fieldMeta, entry.value);
    }
    return normalized;
  }

  /// The number of tabs [_buildFormStructure] will actually produce for [meta]
  /// — i.e. the live `_tabs.length`, which is what the [TabController] length
  /// must match.
  ///
  /// A plain count of `Tab Break` fields is NOT equivalent and must not be used
  /// for the [didUpdateWidget] rebuild guard: [_buildFormStructure] skips
  /// `hidden` fields (so a hidden Tab Break yields no tab) and synthesises an
  /// implicit leading "Details" tab when content precedes the first Tab Break.
  /// Counting raw Tab Break fields would miss both, letting the guard skip a
  /// needed [TabController] rebuild and crash with a length/`_tabs` mismatch.
  static int _effectiveTabCount(DocTypeMeta meta) {
    var tabs = 0;
    var sawContentBeforeFirstTab = false;
    var inTab = false;
    for (final field in meta.fields) {
      if (field.hidden) continue;
      final type = field.fieldtype;
      if (type == FieldTypes.tabBreak) {
        tabs++;
        inTab = true;
      } else if (type != FieldTypes.sectionBreak &&
          type != FieldTypes.columnBreak) {
        // A real content field outside any tab → implicit "Details" tab.
        if (!inTab) sawContentBeforeFirstTab = true;
      }
    }
    if (sawContentBeforeFirstTab) tabs++;
    return tabs;
  }

  void _buildFormStructure() {
    _tabs.clear();
    _FormTab? currentTab;
    _FormSection? currentSection;
    _FormColumn? currentColumn;

    for (final field in widget.meta.fields) {
      if (field.hidden) continue;

      switch (field.fieldtype) {
        case FieldTypes.tabBreak:
          if (currentColumn != null) {
            currentSection ??= _FormSection(
              DocField(fieldtype: 'Section Break', label: ''),
            );
            currentSection.columns.add(currentColumn);
            currentColumn = null;
          }
          if (currentSection != null && currentTab != null) {
            currentTab.sections.add(currentSection);
            currentSection = null;
          }
          if (currentTab != null) {
            _tabs.add(currentTab);
          }
          currentTab = _FormTab(field);
          currentSection = null;
          currentColumn = null;
          break;

        case FieldTypes.sectionBreak:
          if (currentColumn != null) {
            currentSection ??= _FormSection(
              DocField(fieldtype: 'Section Break', label: ''),
            );
            currentSection.columns.add(currentColumn);
            currentColumn = null;
          }
          if (currentSection != null && currentTab != null) {
            currentTab.sections.add(currentSection);
          }
          currentSection = _FormSection(field);
          currentColumn = null;
          break;

        case FieldTypes.columnBreak:
          if (currentColumn != null) {
            currentSection ??= _FormSection(
              DocField(fieldtype: 'Section Break', label: ''),
            );
            currentSection.columns.add(currentColumn);
          }
          currentColumn = _FormColumn();
          break;

        default:
          currentColumn ??= _FormColumn();
          currentSection ??= _FormSection(
            DocField(fieldtype: 'Section Break', label: ''),
          );
          currentTab ??= _FormTab(
            DocField(fieldtype: 'Tab Break', label: 'Details'),
          );
          currentColumn.fields.add(field);
          break;
      }
    }

    // Add remaining structure
    if (currentColumn != null) {
      currentSection ??= _FormSection(
        DocField(fieldtype: 'Section Break', label: ''),
      );
      currentSection.columns.add(currentColumn);
    }
    if (currentSection != null && currentTab != null) {
      currentTab.sections.add(currentSection);
    }
    if (currentTab != null) {
      _tabs.add(currentTab);
    }

    // Build field -> tab index mapping for focusing invalid fields
    _fieldTabIndex.clear();
    for (var tabIndex = 0; tabIndex < _tabs.length; tabIndex++) {
      final tab = _tabs[tabIndex];
      for (final section in tab.sections) {
        for (final column in section.columns) {
          for (final f in column.fields) {
            final name = f.fieldname;
            if (name != null && name.isNotEmpty) {
              _fieldTabIndex[name] = tabIndex;
            }
          }
        }
      }
    }
  }

  /// Evaluates a `depends_on` expression against the current form data,
  /// returning [defaultValue] when [expr] is null or empty. Shared by
  /// [_shouldShowField], [_isFieldRequired], and [_isFieldReadOnly] so a
  /// future change to `DependsOnEvaluator.evaluate` (e.g. adding a parent
  /// context parameter) applies to all three guards at once.
  bool _evaluateDepends(String? expr, bool defaultValue) {
    if (expr == null || expr.isEmpty) return defaultValue;
    return DependsOnEvaluator.evaluate(expr, _formData);
  }

  bool _shouldShowField(DocField field) =>
      _evaluateDepends(field.dependsOn, true);

  bool _isFieldRequired(DocField field) =>
      field.reqd || _evaluateDepends(field.mandatoryDependsOn, false);

  bool _isFieldReadOnly(DocField field) =>
      field.readOnly || _evaluateDepends(field.readOnlyDependsOn, false);

  /// Handles fetch_from: when a Link field changes, fetch the linked document
  /// and patch target fields (format: "link_field_name.source_field_name").
  Future<void> _handleFetchFrom(String changedFieldName, dynamic value) async {
    if (widget.fetchLinkedDocument == null) return;

    final fieldsToUpdate = <DocField>[];
    for (final f in widget.meta.fields) {
      if (f.fetchFrom == null || f.fetchFrom!.isEmpty) continue;
      final parts = f.fetchFrom!.split('.');
      if (parts.length != 2) continue;
      final linkField = parts[0].trim();
      if (linkField == changedFieldName) {
        fieldsToUpdate.add(f);
      }
    }
    if (fieldsToUpdate.isEmpty) return;

    DocField? linkFieldMeta;
    for (final f in widget.meta.fields) {
      if (f.fieldname == changedFieldName) {
        linkFieldMeta = f;
        break;
      }
    }
    if (linkFieldMeta?.options == null) return;

    final linkedDoctype = linkFieldMeta!.options!;
    final linkedDocName = value.toString().trim();

    try {
      final linkedData = await widget.fetchLinkedDocument!(
        linkedDoctype,
        linkedDocName,
      );
      if (linkedData == null || !mounted) return;

      final updates = <String, dynamic>{};
      for (final targetField in fieldsToUpdate) {
        final parts = targetField.fetchFrom!.split('.');
        final sourceFieldName = parts[1].trim();
        if (linkedData.containsKey(sourceFieldName)) {
          final val = linkedData[sourceFieldName];
          if (targetField.fieldname != null) {
            updates[targetField.fieldname!] = val?.toString();
          }
        }
      }
      if (updates.isEmpty) return;

      setState(() {
        _formData.addAll(updates);
      });
      _formKey.currentState?.patchValue(_normalizePatchValues(updates));

      // Chain: if a patched field is itself a Link, trigger its dependents too.
      // e.g. picking a parent Link cascades to the child's own Link fields.
      for (final entry in updates.entries) {
        if (entry.value == null || entry.value.toString().trim().isEmpty) {
          continue;
        }
        DocField? updatedFieldMeta;
        for (final f in widget.meta.fields) {
          if (f.fieldname == entry.key) {
            updatedFieldMeta = f;
            break;
          }
        }
        if (updatedFieldMeta?.fieldtype == FieldTypes.link) {
          _handleFetchFrom(entry.key, entry.value.toString());
        }
      }
    } catch (e) {
      debugPrint('FetchFrom error: $e');
    }
  }

  /// Hard cap on programmatic-cascade recursion depth (see
  /// [FrappeFormBuilder.cascadeProgrammaticChanges]). Real chains are 2–4 deep;
  /// this is a backstop against a non-converging [FrappeFormBuilder.onFieldChange],
  /// not a limit on normal use.
  static const int _maxProgrammaticCascadeDepth = 12;

  /// Applies a field-value change through the full pipeline (dependent-link
  /// clearing, `fetch_from`, [FrappeFormBuilder.onFieldChange], depends_on
  /// rebuild). Extracted from the field `onChanged` callback so a value set
  /// programmatically can re-enter the SAME pipeline — see
  /// [_scheduleProgrammaticCascade].
  ///
  /// [cascadeDepth] > 0 marks a programmatic cascade re-fire: the field's value
  /// is already in [_formData] (the parent patch set it), so `oldValue == value`
  /// and the normal guard would no-op the pipeline. Forcing it here mirrors
  /// Frappe Desk, where `frm.set_value` fires the change trigger for a
  /// programmatic set too. Loop safety is enforced by
  /// [_scheduleProgrammaticCascade] (value-equality) and
  /// [_maxProgrammaticCascadeDepth].
  void _onFieldValueChanged(
    DocField field,
    dynamic value, {
    int cascadeDepth = 0,
  }) {
    // Echo from a programmatic `patchValue` (see [_programmaticEchoGuard]): the
    // explicit cascade (cascadeDepth > 0, dispatched post-frame after the guard
    // is released) is the sole re-fire path, so this synchronous echo only
    // syncs form state and returns without re-running the pipeline.
    if (_programmaticEchoGuard > 0 && cascadeDepth == 0) {
      if (field.fieldname != null) {
        if (value == null) {
          _formData.remove(field.fieldname);
        } else {
          _formData[field.fieldname!] = value;
        }
      }
      return;
    }
    setState(() {
      final oldValue = _formData[field.fieldname];
      // A programmatic re-fire (cascadeDepth > 0) forces the pipeline even
      // though the value is already present in _formData.
      final changed = oldValue != value || cascadeDepth > 0;
      if (value == null) {
        if (field.fieldname != null) {
          _formData.remove(field.fieldname);
        }
      } else {
        if (field.fieldname != null) {
          _formData[field.fieldname!] = value;
        }
      }

      // Sync FormBuilder internal state (needed for programmatic updates e.g. auto-select)
      if (field.fieldname != null && oldValue != value) {
        _formKey.currentState?.patchValue({
          field.fieldname!: FieldNormalizer.normalize(field, value),
        });
      }

      // If value changed, clear dependent link fields that depend on this field
      if (changed && field.fieldname != null) {
        for (final otherField in widget.meta.fields) {
          if (otherField.fieldtype == 'Link' &&
              otherField.linkFilters != null &&
              // Check if other field's link filters depend on this field ignoring spaces
              RegExp(
                'eval\\s*:\\s*doc\\.${field.fieldname}',
              ).hasMatch(otherField.linkFilters ?? "")) {
            _formData.remove(otherField.fieldname);
          }
        }
      }

      // Fetch-from: when a Link (or source field) changes, fetch linked doc and patch form
      if (changed &&
          field.fieldname != null &&
          value != null &&
          value.toString().trim().isNotEmpty) {
        _handleFetchFrom(field.fieldname!, value);
      }

      // Notify external listener. Pass a snapshot so handlers cannot
      // accidentally mutate _formData; they must return patches instead.
      if (changed && field.fieldname != null) {
        final patches = widget.onFieldChange?.call(
          field.fieldname!,
          value,
          Map<String, dynamic>.from(_formData),
        );
        if (patches != null && patches.isNotEmpty) {
          // Snapshot prior values BEFORE applying, so the cascade can tell a
          // real change from a no-op echo (the value-equality loop breaker).
          // Self-referential patch (handler patches THIS field): its own new
          // value was already written into _formData above, so prior[self] is
          // the just-set value, not the pre-edit one. Consequence: the self
          // re-fire happens only when the handler actually REWROTE the value,
          // and an idempotent rewrite converges on the next round (pinned in
          // form_builder_cascade_test.dart).
          final prior = <String, dynamic>{
            for (final key in patches.keys) key: _formData[key],
          };
          _formData.addAll(patches);
          final cascade = widget.cascadeProgrammaticChanges;
          // Self-key widget patch is DEFERRED one frame: patching the field
          // that is currently dispatching its own change re-enters the text
          // field's didChange/TextEditingController notification stack and,
          // when the handler rewrote the value ('hi'→'HI'), the in-flight
          // editing value keeps alternating with the patch — unbounded
          // synchronous recursion (StackOverflowError). Pre-existing defect,
          // independent of the cascade flag. _formData above already holds
          // the value; only the widget sync waits for the next frame.
          final selfKey =
              field.fieldname != null && patches.containsKey(field.fieldname)
              ? field.fieldname
              : null;
          final rest = selfKey == null
              ? patches
              : (Map<String, dynamic>.from(patches)..remove(selfKey));
          // Suppress the synchronous patchValue→onChanged echo so only the
          // explicit cascade re-fires the pipeline (avoids a double-run for
          // typed fields whose representation FieldNormalizer changes). Guard
          // is raised only when cascading, so legacy behaviour is untouched.
          if (rest.isNotEmpty) {
            if (cascade) _programmaticEchoGuard++;
            try {
              _formKey.currentState?.patchValue(_normalizePatchValues(rest));
            } finally {
              if (cascade) _programmaticEchoGuard--;
            }
          }
          if (selfKey != null) {
            final selfValue = patches[selfKey];
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              // The self-key echo guard is raised UNCONDITIONALLY (not just
              // when cascading). The deferred patchValue re-fires this field's
              // onChanged; for a typed field (Check/Date/Rating) FieldNormalizer
              // changes the value's representation, so the echoed value never
              // equals the doc-space value in _formData, `changed` stays true,
              // and a self-referential handler re-fires forever across
              // postFrameCallbacks — an uncapped infinite hang, because the
              // depth cap lives only in the cascade-gated
              // [_scheduleProgrammaticCascade]. Making the echo a pure
              // state-sync no-op here bounds it regardless of the flag; no
              // finite cascade-off case relies on this echo re-running the
              // pipeline (see form_builder_cascade_test.dart).
              _programmaticEchoGuard++;
              try {
                _formKey.currentState?.patchValue(
                  _normalizePatchValues({selfKey: selfValue}),
                );
              } finally {
                _programmaticEchoGuard--;
              }
            });
          }
          if (cascade) {
            _scheduleProgrammaticCascade(patches, prior, cascadeDepth);
          }
        }
      }

      // Trigger rebuild to update dependent fields
      if (changed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {});
            _emitFormDataChanged();
          }
        });
      }
    });
  }

  /// Frappe `set_value` parity: for each field in [patches] just set
  /// programmatically whose value ACTUALLY changed (value-equality vs [prior]),
  /// re-fire the change pipeline on the next frame (deferred to avoid a nested
  /// `setState`). A converged field re-emits its current value ⇒ equal ⇒ no
  /// re-fire, so the cascade reaches a fixpoint; [_maxProgrammaticCascadeDepth]
  /// is the backstop against a non-converging handler.
  void _scheduleProgrammaticCascade(
    Map<String, dynamic> patches,
    Map<String, dynamic> prior,
    int depth,
  ) {
    if (depth >= _maxProgrammaticCascadeDepth) {
      sdkLog(
        'FrappeFormBuilder: programmatic cascade depth cap '
        '($_maxProgrammaticCascadeDepth) reached; stopping '
        '(non-converging onFieldChange?)',
      );
      return;
    }
    for (final entry in patches.entries) {
      final newValue = entry.value;
      // Child-table payloads are patched wholesale, not treated as field edits.
      if (newValue is List || newValue is Map) continue;
      // Value-equality: skip fields whose value did not actually change.
      if (_cascadeValuesEqual(prior[entry.key], newValue)) {
        continue;
      }
      DocField? target;
      for (final f in widget.meta.fields) {
        if (f.fieldname == entry.key) {
          target = f;
          break;
        }
      }
      if (target == null) continue;
      final field = target;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _onFieldValueChanged(field, newValue, cascadeDepth: depth + 1);
        }
      });
    }
  }

  /// Cascade value-equality. When BOTH operands parse as numbers they are
  /// compared numerically, so `10`/`"10"`/`"10.0"`/`10.0` are all equal and a
  /// representation change (e.g. a Float field re-emitting `"10.0"` for `10`)
  /// does not trigger a spurious self-terminating re-fire. Otherwise falls back
  /// to trimmed-string equality, so a null/absent value never spuriously
  /// "changes" and non-numeric values (Link ids, Select text) compare as-is.
  static bool _cascadeValuesEqual(dynamic a, dynamic b) {
    final na = _asNum(a);
    final nb = _asNum(b);
    if (na != null && nb != null) return na == nb;
    return a?.toString().trim() == b?.toString().trim();
  }

  /// Parse [v] to a [num] (int or double), or null if it is not numeric.
  static num? _asNum(dynamic v) {
    if (v is num) return v;
    final s = v?.toString().trim();
    if (s == null || s.isEmpty) return null;
    return num.tryParse(s);
  }

  Widget _buildFieldWidget(DocField field) {
    if (!_shouldShowField(field)) {
      // Clear stale data for hidden fields so they don't submit old values
      if (field.fieldname != null && _formData.containsKey(field.fieldname)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _formData.containsKey(field.fieldname)) {
            setState(() {
              _formData.remove(field.fieldname);
            });
          }
        });
      }
      return const SizedBox.shrink();
    }

    final formStyle = widget.style ?? DefaultFormStyle.standard;

    // Compute effective reqd / readonly first so the decoration below can
    // reflect the current state of `mandatory_depends_on` (not just the
    // static `reqd` flag).
    final effectiveReqd = _isFieldRequired(field);
    final effectiveReadOnly = _isFieldReadOnly(field) || widget.readOnly;

    var decoration = formStyle.fieldDecoration?.call(field);
    if (widget.translate != null && decoration != null) {
      final labelText = widget.translate!(field.label ?? field.fieldname ?? '');
      decoration = decoration.copyWith(
        // When showFieldLabel=true, BaseField renders the external label above
        // the box; setting labelText here would produce a second floating label
        // inside the box. Only set it when there is no external label.
        labelText: formStyle.showFieldLabel ? null : labelText,
        hintText: field.placeholder != null
            ? widget.translate!(field.placeholder!)
            : (formStyle.showFieldLabel ? decoration.hintText : labelText),
        // When showFieldDescription=true, BaseField renders the description
        // below the box; setting helperText here would duplicate it.
        helperText: formStyle.showFieldDescription
            ? null
            : (field.description != null
                  ? widget.translate!(field.description!)
                  : decoration.helperText),
      );
    }

    // Render the mandatory indicator (`*`) on the visible label.
    // When showFieldLabel=true, BaseField's external Row already appends a red
    // `*` Text widget — no need to also mark the decoration label/hint.
    // When showFieldLabel=false, the decoration carries the visible label, so
    // append `*` to labelText first, then hintText as fallback.
    if (effectiveReqd && decoration != null && !formStyle.showFieldLabel) {
      final labelTxt = decoration.labelText;
      if (labelTxt != null && labelTxt.isNotEmpty && !labelTxt.endsWith(' *')) {
        decoration = decoration.copyWith(labelText: '$labelTxt *');
      } else {
        final hintTxt = decoration.hintText;
        if (hintTxt != null && hintTxt.isNotEmpty && !hintTxt.endsWith(' *')) {
          decoration = decoration.copyWith(hintText: '$hintTxt *');
        }
      }
    }

    final fieldStyle = FieldStyle(
      labelStyle: formStyle.labelStyle,
      descriptionStyle: formStyle.descriptionStyle,
      decoration: decoration,
      translate: widget.translate,
      showLabel: formStyle.showFieldLabel,
      showDescription: formStyle.showFieldDescription,
      inputFormatters: formStyle.inputFormatters?.call(field),
      linkFieldPickerMode: formStyle.linkFieldPickerMode,
      getFirstDate: formStyle.getFirstDate != null
          ? (f) => formStyle.getFirstDate!(widget.meta.name, f)
          : null,
      getLastDate: formStyle.getLastDate != null
          ? (f) => formStyle.getLastDate!(widget.meta.name, f)
          : null,
    );

    final fieldWithEffectiveProps = DocField(
      fieldname: field.fieldname,
      fieldtype: field.fieldtype,
      label: field.label,
      reqd: effectiveReqd,
      readOnly: effectiveReadOnly,
      hidden: field.hidden,
      options: field.options,
      dependsOn: field.dependsOn,
      mandatoryDependsOn: field.mandatoryDependsOn,
      readOnlyDependsOn: field.readOnlyDependsOn,
      linkFilters: field.linkFilters,
      fetchFrom: field.fetchFrom,
      section: field.section,
      defaultValue: field.defaultValue,
      description: field.description,
      placeholder: field.placeholder,
      precision: field.precision,
      length: field.length,
      idx: field.idx,
      inListView: field.inListView,
      allowMultiple: field.allowMultiple,
      searchIndex: field.searchIndex,
    );

    final initialValue =
        _formData[field.fieldname] ??
        widget.initialData?[field.fieldname] ??
        field.defaultValue;

    final fieldWidget = _fieldFactory.createField(
      field: fieldWithEffectiveProps,
      value: initialValue,
      uploadFile: widget.uploadFile,
      fileUrlBase: widget.fileUrlBase,
      imageHeaders: widget.imageHeaders,
      getMeta: widget.getMeta,
      parentFormData: effectiveParentFormData,
      getLinkFilterBuilder: widget.getLinkFilterBuilder,
      childTableFormBuilder: widget.getMeta != null
          ? (childMeta, initialData, onSubmit, {registerSubmit}) =>
                FrappeFormBuilder(
                  meta: childMeta,
                  initialData: initialData,
                  onSubmit: onSubmit,
                  registerSubmit: registerSubmit,
                  getMeta: widget.getMeta,
                  linkOptionService: widget.linkOptionService,
                  useLinkFieldCoordinator: widget.useLinkFieldCoordinator,
                  fileUrlBase: widget.fileUrlBase,
                  imageHeaders: widget.imageHeaders,
                  // fetch linked document for child doctype.
                  fetchLinkedDocument: widget.fetchLinkedDocument,
                  translate: widget.translate,
                  onButtonPressed: widget.onButtonPressed,
                  onFieldChange: widget.onFieldChange,
                  parentFormData: effectiveParentFormData,
                  getLinkFilterBuilder: widget.getLinkFilterBuilder,
                )
          : null,
      onButtonPressed: widget.onButtonPressed,
      onChanged: (value) => _onFieldValueChanged(field, value),
      enabled: !effectiveReadOnly,
      formData: Map<String, dynamic>.from(_formData),
      style: fieldStyle,
      onIsLocalChanged: (isLocal) {
        // Picker tells us whether the chosen target is local-only
        // (mobile_uuid) or server-known. Mirror that into the
        // `<field>__is_local` companion so [LocalWriter] persists it
        // and [UuidRewriter] can rewrite the value at push time.
        final fname = field.fieldname;
        if (fname == null) return;
        final companion = '${fname}__is_local';
        setState(() {
          _formData[companion] = isLocal ? 1 : 0;
        });
        _formKey.currentState?.patchValue({companion: isLocal ? 1 : 0});
      },
    );

    if (fieldWidget == null) return const SizedBox.shrink();

    return Padding(
      padding: formStyle.fieldPadding ?? const EdgeInsets.only(bottom: 16.0),
      child: fieldWidget,
    );
  }

  Widget _buildColumn(_FormColumn column) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: column.fields.map((field) => _buildFieldWidget(field)).toList(),
    );
  }

  /// Returns true if at least one data field in the section is currently visible.
  /// Matches Frappe Desk behavior: a section header is hidden when all its fields
  /// are hidden by their own depends_on, even if the section's own depends_on passes.
  bool _hasAnyVisibleField(_FormSection section) {
    return section.columns.any(
      (col) => col.fields.any(
        (field) =>
            field.isDataField && !field.hidden && _shouldShowField(field),
      ),
    );
  }

  Widget _buildSection(_FormSection section) {
    final formStyle = widget.style ?? DefaultFormStyle.standard;

    if (section.columns.isEmpty) return const SizedBox.shrink();

    // Evaluate section-level depends_on — hide entire section if condition is false
    if (!_shouldShowField(section.sectionField)) {
      return const SizedBox.shrink();
    }

    // Hide section header when all its fields are hidden (matches Frappe Desk behavior).
    // This covers cases where the section's depends_on passes but no field inside is visible.
    if (!_hasAnyVisibleField(section)) {
      return const SizedBox.shrink();
    }

    Widget content;
    if (section.columns.length == 1) {
      content = _buildColumn(section.columns.first);
    } else {
      // Responsive layout: Use Row on larger screens, Column on smaller screens
      content = LayoutBuilder(
        builder: (context, constraints) {
          final isWideScreen = constraints.maxWidth > 600;

          if (isWideScreen) {
            // Desktop/Tablet: Side by side columns
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: section.columns.map((col) {
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: _buildColumn(col),
                  ),
                );
              }).toList(),
            );
          } else {
            // Mobile: Stack columns vertically
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: section.columns.map((col) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: _buildColumn(col),
                );
              }).toList(),
            );
          }
        },
      );
    }

    if (section.sectionField.label == null ||
        section.sectionField.label!.isEmpty) {
      return Padding(
        padding: formStyle.sectionPadding ?? const EdgeInsets.all(16.0),
        child: content,
      );
    }

    return Card(
      margin: formStyle.sectionMargin ?? const EdgeInsets.only(bottom: 16.0),
      color: formStyle.sectionCardColor,
      child: Padding(
        padding: formStyle.sectionPadding ?? const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: double.infinity,
              child: Text(
                widget.translate != null
                    ? widget.translate!(section.sectionField.displayLabel)
                    : section.sectionField.displayLabel,
                style:
                    formStyle.sectionTitleStyle ??
                    Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                maxLines: formStyle.sectionTitleMaxLines ?? 3,
                overflow: TextOverflow.ellipsis,
                softWrap: true,
              ),
            ),
            const SizedBox(height: 16),
            content,
          ],
        ),
      ),
    );
  }

  Widget _buildTabContent(_FormTab tab) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: tab.sections
            .map((section) => _buildSection(section))
            .toList(),
      ),
    );
  }

  Widget _buildStepHeader(FrappeFormStyle formStyle) {
    final stepStyle = formStyle.stepHeaderStyle ?? const FormStepHeaderStyle();
    final currentStep = _tabController.index + 1;
    final titles = _tabs
        .map(
          (tab) => widget.translate != null
              ? widget.translate!(tab.tabField.displayLabel)
              : tab.tabField.displayLabel,
        )
        .toList();

    Widget buildDot(int step) {
      final isCompleted = step < currentStep;
      final isActive = step == currentStep;
      final bg = isCompleted || isActive ? stepStyle.activeColor : Colors.white;
      final border = isCompleted || isActive
          ? stepStyle.activeColor
          : stepStyle.inactiveColor;
      final fg = isCompleted
          ? Colors.white
          : (isActive ? Colors.white : stepStyle.inactiveTextColor);

      final numberStyle =
          stepStyle.numberTextStyle ??
          TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            height: 1.0,
            color: fg,
          );
      final child = isCompleted
          ? const Icon(Icons.check, size: 18, color: Colors.white)
          : Text('$step', style: numberStyle);

      return InkWell(
        onTap: () => _tabController.animateTo(step - 1),
        customBorder: const CircleBorder(),
        child: Container(
          width: stepStyle.dotSize,
          height: stepStyle.dotSize,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: Border.all(color: border, width: 2),
          ),
          child: Center(child: child),
        ),
      );
    }

    Widget buildLabel(String text, bool active, int step) {
      final mergedStyle =
          stepStyle.labelTextStyle?.copyWith(
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? stepStyle.textColor : stepStyle.inactiveTextColor,
          ) ??
          TextStyle(
            fontSize: 12,
            height: 1.2,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? stepStyle.textColor : stepStyle.inactiveTextColor,
          );
      return InkWell(
        onTap: () => _tabController.animateTo(step - 1),
        child: Text(
          text,
          textAlign: TextAlign.center,
          maxLines: formStyle.tabTitleMaxLines ?? 2,
          overflow: TextOverflow.ellipsis,
          style: mergedStyle,
        ),
      );
    }

    return SizedBox(
      height: stepStyle.dotSize + stepStyle.labelsTopGap + 34.0,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth - (stepStyle.edgePadding * 2);
          final stepCount = titles.length;
          final dx = stepCount <= 1
              ? 0.0
              : (w - stepStyle.dotSize) / (stepCount - 1);

          double leftForStep(int step) =>
              stepStyle.edgePadding + (step - 1) * dx;
          double centerXForStep(int step) =>
              leftForStep(step) + stepStyle.dotSize / 2;

          Widget lineSegment(int fromStep, int toStep, bool active) {
            final left = centerXForStep(fromStep);
            final right = centerXForStep(toStep);
            return Positioned(
              left: left,
              top: stepStyle.dotSize / 2 - stepStyle.lineHeight / 2,
              width: (right - left),
              height: stepStyle.lineHeight,
              child: Container(
                color: active ? stepStyle.activeColor : stepStyle.inactiveColor,
              ),
            );
          }

          Widget labelAt(int step, String text, bool active) {
            return Positioned(
              left: leftForStep(step) - 18,
              top: stepStyle.dotSize + stepStyle.labelsTopGap,
              width: stepStyle.dotSize + 36,
              child: buildLabel(text, active, step),
            );
          }

          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 1; i < stepCount; i++)
                lineSegment(i, i + 1, currentStep > i),
              for (var i = 1; i <= stepCount; i++)
                Positioned(left: leftForStep(i), top: 0, child: buildDot(i)),
              for (var i = 1; i <= stepCount; i++)
                labelAt(i, titles[i - 1], currentStep == i),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTabHeader(FrappeFormStyle formStyle) {
    if (_tabs.length <= 1) return const SizedBox.shrink();
    if (formStyle.tabHeaderLayout == FormTabHeaderLayout.stepper) {
      return _buildStepHeader(formStyle);
    }
    return TabBar(
      controller: _tabController,
      isScrollable: true,
      tabs: _tabs
          .map(
            (tab) => Tab(
              child: Text(
                widget.translate != null
                    ? widget.translate!(tab.tabField.displayLabel)
                    : tab.tabField.displayLabel,
                maxLines: formStyle.tabTitleMaxLines ?? 2,
                overflow: TextOverflow.ellipsis,
                softWrap: true,
                textAlign: TextAlign.center,
              ),
            ),
          )
          .toList(),
    );
  }

  @override
  void didUpdateWidget(FrappeFormBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    final initialDataChanged = !mapEquals(
      oldWidget.initialData,
      widget.initialData,
    );
    final metaChanged =
        oldWidget.meta.name != widget.meta.name ||
        _effectiveTabCount(oldWidget.meta) != _effectiveTabCount(widget.meta);
    if (initialDataChanged || metaChanged) {
      _progressSubscription?.cancel();
      _linkFieldCoordinator?.dispose();
      _linkFieldCoordinator = null;
      _formKey = GlobalKey<FormBuilderState>();
      _formData.clear();
      if (widget.initialData != null) {
        _formData.addAll(widget.initialData!);
      }
      for (final field in widget.meta.fields) {
        if (field.fieldname != null &&
            !field.hidden &&
            !_formData.containsKey(field.fieldname)) {
          _formData[field.fieldname!] ??= field.defaultValue;
        }
      }
      if (widget.linkOptionService != null && widget.useLinkFieldCoordinator) {
        _linkFieldCoordinator = LinkFieldCoordinator(
          meta: widget.meta,
          linkOptionService: widget.linkOptionService!,
          useCoordinator: true,
          parentFormData: effectiveParentFormData,
          getLinkFilterBuilder: widget.getLinkFilterBuilder,
        );
        _linkFieldCoordinator!.prefetchInitial(_formData);
        _progressSubscription = _linkFieldCoordinator!.progressStream.listen((
          p,
        ) {
          if (mounted) {
            setState(() {
              _linkOptionsLoading = p.loading;
              _linkOptionsLoadingMessage = p.message;
            });
          }
        });
      }
      _fieldFactory.linkFieldCoordinator = _linkFieldCoordinator;
      _buildFormStructure();
      _tabController.dispose();
      _tabController = TabController(
        length: _tabs.isEmpty ? 1 : _tabs.length,
        vsync: this,
      );
      _attachTabControllerListener();
      _triggerFetchFromForPrefilledLinks();
    }
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _linkFieldCoordinator?.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _handleSubmit() {
    final state = _formKey.currentState;
    if (state == null) return;

    final isValid = state.saveAndValidate();
    if (!isValid) {
      // Switch to tab containing the first invalid field so user sees the error.
      String? firstInvalidField;
      for (final field in widget.meta.fields) {
        final name = field.fieldname;
        if (name == null || name.isEmpty) continue;
        final fieldState = state.fields[name];
        if (fieldState != null && fieldState.hasError) {
          firstInvalidField = name;
          final tabIndex = _fieldTabIndex[name];
          if (tabIndex != null && _tabs.length > 1) {
            setState(() {
              _tabController.index = tabIndex;
            });
          }
          break;
        }
      }

      // Smooth scroll to the first invalid field element
      if (firstInvalidField != null) {
        Future.delayed(const Duration(milliseconds: 150), () {
          if (!mounted) return;
          Element? errorElement;
          void findErrorRecursive(Element element) {
            if (errorElement != null) return;
            final state = element is StatefulElement ? element.state : null;
            if (state is FormFieldState && state.hasError) {
              errorElement = element;
              return;
            }
            element.visitChildren(findErrorRecursive);
          }

          context.visitChildElements(findErrorRecursive);

          if (errorElement != null) {
            final renderObject = errorElement!.renderObject;
            if (renderObject != null && renderObject.attached) {
              Scrollable.ensureVisible(
                errorElement!,
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOutCubic,
                alignment: 0.2, // 20% offset from top
              );
            }
          }
        });
      }

      widget.onValidationFailed?.call();
      return;
    }

    // Save all form fields first to ensure FormBuilder captures all values
    state.save();

    // Get all form values from FormBuilder (includes all fields)
    final formValues = Map<String, dynamic>.from(state.value);

    // Merge with _formData (fields that were changed via onChanged)
    formValues.addAll(_formData);

    // Build complete form data with ALL fields from metadata
    // This ensures we save complete data, not just changed fields
    final completeFormData = <String, dynamic>{};

    // First, initialize all visible data fields from metadata with their
    // default/initial values. Hidden-by-depends_on fields are skipped so
    // they neither seed defaults nor survive into the save payload — this
    // half of the sweep covers fields with no current value but a stale
    // default; the post-merge sweep below covers fields with stale user
    // input from before the gate flipped.
    for (final field in widget.meta.fields) {
      if (field.fieldname != null && !field.hidden && field.isDataField) {
        if (field.dependsOn != null && field.dependsOn!.isNotEmpty) {
          // Evaluate against the merged formValues so the latest user
          // changes drive the visibility decision.
          if (!DependsOnEvaluator.evaluate(field.dependsOn, formValues)) {
            continue;
          }
        }
        // Priority: formValues > initialData > defaultValue > empty value
        completeFormData[field.fieldname!] =
            formValues[field.fieldname] ??
            widget.initialData?[field.fieldname] ??
            field.defaultValue ??
            (field.fieldtype == 'Check'
                ? 0
                : (field.fieldtype == 'Table' ||
                      field.fieldtype == 'Table MultiSelect')
                ? <dynamic>[]
                : '');
      }
    }

    // Then override with any form values (user input takes precedence)
    // But skip null values for Table fields — ChildTableField is not a
    // FormBuilderField, so state.value returns null for Table fields even
    // when _formData has the actual child row data.
    for (final entry in formValues.entries) {
      if (entry.value != null) {
        completeFormData[entry.key] = entry.value;
      }
    }

    // Drop fields the user can't actually see from the save payload,
    // mirroring Frappe Desk's behaviour where hidden-by-depends_on fields
    // are not part of `frm.doc` at save time. A field is "not visible" if
    // its own `depends_on` evaluates false, OR if the enclosing section /
    // tab break's `depends_on` evaluates false (hidden sections
    // short-circuit before their children build, so the build-time clear
    // at `_buildFieldWidget` never runs for them).
    final dataForDepends = Map<String, dynamic>.from(completeFormData);
    final hiddenByContainer = <String>{};
    String? currentSectionDeps;
    String? currentTabDeps;
    for (final f in widget.meta.fields) {
      if (f.fieldtype == 'Tab Break') {
        currentTabDeps = (f.dependsOn != null && f.dependsOn!.isNotEmpty)
            ? f.dependsOn
            : null;
        currentSectionDeps = null;
        continue;
      }
      if (f.fieldtype == 'Section Break') {
        currentSectionDeps = (f.dependsOn != null && f.dependsOn!.isNotEmpty)
            ? f.dependsOn
            : null;
        continue;
      }
      if (f.fieldtype == 'Column Break') continue;
      if (f.fieldname == null) continue;
      final tabHidden =
          currentTabDeps != null &&
          !DependsOnEvaluator.evaluate(currentTabDeps, dataForDepends);
      final secHidden =
          currentSectionDeps != null &&
          !DependsOnEvaluator.evaluate(currentSectionDeps, dataForDepends);
      if (tabHidden || secHidden) {
        hiddenByContainer.add(f.fieldname!);
      }
    }
    completeFormData.removeWhere((fieldname, _) {
      if (hiddenByContainer.contains(fieldname)) return true;
      final field = widget.meta.fields.firstWhere(
        (f) => f.fieldname == fieldname,
        orElse: () => DocField(fieldtype: '_missing_'),
      );
      if (field.fieldtype == '_missing_') return false;
      if (field.dependsOn == null || field.dependsOn!.isEmpty) return false;
      return !DependsOnEvaluator.evaluate(field.dependsOn, dataForDepends);
    });

    widget.onSubmit?.call(completeFormData);
  }

  /// Assembles the full form data map: every non-hidden data field with
  /// its current value (user input takes precedence), filling in
  /// `initialData` / `defaultValue` / per-fieldtype empties for fields
  /// the user hasn't touched. Shared by [_handleSubmit] (post-validate)
  /// and [_getCurrentFormData] (dirty detection) so the default-value
  /// fallback logic stays consistent between submit and dirty-check.
  Map<String, dynamic> _buildCompleteFormData() {
    final state = _formKey.currentState;
    final formValues = state != null
        ? Map<String, dynamic>.from(state.value)
        : <String, dynamic>{};
    formValues.addAll(_formData);
    final complete = <String, dynamic>{};
    for (final field in widget.meta.fields) {
      if (field.fieldname != null && !field.hidden && field.isDataField) {
        complete[field.fieldname!] =
            formValues[field.fieldname] ??
            widget.initialData?[field.fieldname] ??
            field.defaultValue ??
            (field.fieldtype == 'Check'
                ? 0
                : (field.fieldtype == 'Table' ||
                      field.fieldtype == 'Table MultiSelect')
                ? <dynamic>[]
                : '');
      }
    }
    for (final entry in formValues.entries) {
      if (entry.value != null) {
        complete[entry.key] = entry.value;
      }
    }
    return complete;
  }

  /// Builds current form data (same structure as submit). Used for dirty detection.
  Map<String, dynamic> _getCurrentFormData() => _buildCompleteFormData();

  void _emitFormDataChanged() {
    widget.onFormDataChanged?.call(_getCurrentFormData());
  }

  @override
  Widget build(BuildContext context) {
    if (_tabs.isEmpty) {
      return const Center(child: Text('No fields to display'));
    }
    widget.registerSubmit?.call(_handleSubmit);

    final formStyle = widget.style ?? DefaultFormStyle.standard;

    return FormBuilder(
      key: _formKey,
      initialValue: Map<String, dynamic>.from(_formData),
      child: Column(
        children: [
          if (_linkOptionsLoading)
            Material(
              elevation: 0,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _linkOptionsLoadingMessage ?? 'Loading options...',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          _buildTabHeader(formStyle),
          Expanded(
            child: _tabs.length > 1
                ? TabBarView(
                    controller: _tabController,
                    children: _tabs
                        .map((tab) => _buildTabContent(tab))
                        .toList(),
                  )
                : _buildTabContent(_tabs.first),
          ),
        ],
      ),
    );
  }
}
