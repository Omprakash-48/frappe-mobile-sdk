/// Represents a mobile form name from login response.
class MobileFormName {
  final String mobileDoctype;
  final String? groupName;
  final String? doctypeMetaModifiedAt;
  final String? doctypeIcon;

  const MobileFormName({
    required this.mobileDoctype,
    this.groupName,
    this.doctypeMetaModifiedAt,
    this.doctypeIcon,
  });

  factory MobileFormName.fromJson(Map<String, dynamic> json) {
    return MobileFormName(
      mobileDoctype: json['mobile_workspace_item'] as String? ?? '',
      groupName: json['group_name'] as String?,
      // Read-only fallback to the previously-misspelled key so any payload
      // (or older cached/replayed response) still emitting the typo keeps
      // working. MobileFormName is never persisted (toJson has no callers), so
      // no kv migration is needed — this is pure defense-in-depth.
      doctypeMetaModifiedAt:
          json['doctype_meta_modified_at'] as String? ??
          json['doctype_meta_modifed_at'] as String?,
      doctypeIcon: json['doctype_icon'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'mobile_doctype': mobileDoctype,
      if (groupName != null) 'group_name': groupName,
      if (doctypeMetaModifiedAt != null)
        'doctype_meta_modified_at': doctypeMetaModifiedAt,
      if (doctypeIcon != null) 'doctype_icon': doctypeIcon,
    };
  }
}
