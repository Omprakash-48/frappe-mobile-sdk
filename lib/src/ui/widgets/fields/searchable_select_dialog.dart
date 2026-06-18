import 'package:flutter/material.dart';
import '../../../database/entities/link_option_entity.dart';

class SearchableSelectDialog extends StatefulWidget {
  final List<LinkOptionEntity> options;
  final List<String> initialSelected;
  final bool multiSelect;
  final String? title;

  const SearchableSelectDialog({
    super.key,
    required this.options,
    required this.initialSelected,
    required this.multiSelect,
    this.title,
  });

  @override
  State<SearchableSelectDialog> createState() => _SearchableSelectDialogState();
}

class _SearchableSelectDialogState extends State<SearchableSelectDialog> {
  String _searchQuery = '';
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.initialSelected);
  }

  void _toggleSelection(String value) {
    setState(() {
      if (widget.multiSelect) {
        if (_selected.contains(value)) {
          _selected.remove(value);
        } else {
          _selected.add(value);
        }
      } else {
        _selected = [value];
        Navigator.of(context).pop(_selected);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final filteredOptions = widget.options.where((option) {
      if (_searchQuery.isEmpty) return true;
      final labelLower = (option.label ?? option.name).toLowerCase();
      final nameLower = option.name.toLowerCase();
      final queryLower = _searchQuery.toLowerCase();
      return labelLower.contains(queryLower) || nameLower.contains(queryLower);
    }).toList();

    return AlertDialog(
      title: Text(widget.title ?? 'Select Options'),
      contentPadding: const EdgeInsets.only(top: 16.0),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 24.0,
                vertical: 8.0,
              ),
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Search...',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.0),
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                ),
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value;
                  });
                },
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: filteredOptions.length,
                itemBuilder: (context, index) {
                  final option = filteredOptions[index];
                  final isSelected = _selected.contains(option.name);

                  if (widget.multiSelect) {
                    return CheckboxListTile(
                      title: Text(option.label ?? option.name),
                      value: isSelected,
                      onChanged: (bool? checked) {
                        _toggleSelection(option.name);
                      },
                    );
                  } else {
                    return ListTile(
                      title: Text(option.label ?? option.name),
                      trailing: isSelected
                          ? const Icon(Icons.check, color: Colors.blue)
                          : null,
                      onTap: () {
                        _toggleSelection(option.name);
                      },
                    );
                  }
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.multiSelect ? 'Cancel' : 'Close'),
        ),
        if (widget.multiSelect)
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(_selected),
            child: const Text('Done'),
          ),
      ],
    );
  }
}
