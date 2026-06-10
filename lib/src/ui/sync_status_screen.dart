import 'package:flutter/material.dart';
import '../services/sync_service.dart';
import '../services/offline_repository.dart';
import '../models/document.dart';
import 'widgets/screen_helpers.dart';
import '../utils/sdk_log.dart';
import '../utils/translate.dart';

/// Screen to display sync status and errors
class SyncStatusScreen extends StatefulWidget {
  final SyncService syncService;
  final OfflineRepository repository;

  const SyncStatusScreen({
    super.key,
    required this.syncService,
    required this.repository,
  });

  @override
  State<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends State<SyncStatusScreen> {
  bool _isSyncing = false;
  String? _syncStatus;
  List<Document> _dirtyDocuments = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadDirtyDocuments();
  }

  Future<void> _loadDirtyDocuments() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // No `doctype` filter → scans every doctype with a docs__ table.
      final dirty = await widget.repository.getDirtyDocuments();
      setState(() {
        _dirtyDocuments = dirty;
        _isLoading = false;
      });
    } catch (e, st) {
      sdkLog('SyncStatusScreen._loadDirtyDocuments failed — $e\n$st');
      setState(() {
        _syncStatus = sdkTr('Error loading documents: {0}', [e]);
        _isLoading = false;
      });
    }
  }

  Future<void> _syncAll() async {
    if (_isSyncing) return;

    setState(() {
      _isSyncing = true;
      _syncStatus = sdkTr('Syncing...');
    });

    try {
      final result = await widget.syncService.pushSync();

      setState(() {
        _syncStatus = sdkTr('Sync completed: {0} succeeded, {1} failed', [
          result.success,
          result.failed,
        ]);
        _isSyncing = false;
      });

      // Reload dirty documents
      await _loadDirtyDocuments();

      // Show detailed error dialog if there are errors
      if (result.errors.isNotEmpty) {
        if (mounted) {
          _showErrorDialog(result.errors);
        }
      } else if (result.success > 0 && mounted) {
        showStatusSnackBar(
          context,
          sdkTr('Successfully synced {0} document(s)', [result.success]),
          severity: SnackBarSeverity.success,
        );
      }
    } catch (e, st) {
      sdkLog('SyncStatusScreen._syncAll failed — $e\n$st');
      setState(() {
        _syncStatus = sdkTr('Sync failed: {0}', [e]);
        _isSyncing = false;
      });

      if (mounted) {
        showStatusSnackBar(
          context,
          sdkTr('Sync error: {0}', [e]),
          severity: SnackBarSeverity.error,
        );
      }
    }
  }

  Future<void> _syncDoctype(String doctype) async {
    if (_isSyncing) return;

    setState(() {
      _isSyncing = true;
      _syncStatus = sdkTr('Syncing {0}...', [doctype]);
    });

    try {
      final result = await widget.syncService.pushSync(doctype: doctype);

      setState(() {
        _syncStatus = sdkTr('Sync completed: {0} succeeded, {1} failed', [
          result.success,
          result.failed,
        ]);
        _isSyncing = false;
      });

      // Reload dirty documents
      await _loadDirtyDocuments();

      // Show detailed error dialog if there are errors
      if (result.errors.isNotEmpty) {
        if (mounted) {
          _showErrorDialog(result.errors);
        }
      } else if (result.success > 0 && mounted) {
        showStatusSnackBar(
          context,
          sdkTr('Successfully synced {0} document(s)', [result.success]),
          severity: SnackBarSeverity.success,
        );
      }
    } catch (e, st) {
      sdkLog('SyncStatusScreen._syncDoctype failed — $e\n$st');
      setState(() {
        _syncStatus = sdkTr('Sync failed: {0}', [e]);
        _isSyncing = false;
      });

      if (mounted) {
        showStatusSnackBar(
          context,
          sdkTr('Sync error: {0}', [e]),
          severity: SnackBarSeverity.error,
        );
      }
    }
  }

  void _showErrorDialog(List<SyncError> errors) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.error, color: Colors.red),
            const SizedBox(width: 8),
            Text(sdkTr('Sync Errors')),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: errors.length,
            itemBuilder: (context, index) {
              final error = errors[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                color: Colors.red[50],
                child: ListTile(
                  leading: const Icon(Icons.error_outline, color: Colors.red),
                  title: Text(
                    sdkTr('{0}: {1}', [
                      error.operation.toUpperCase(),
                      error.doctype,
                    ]),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sdkTr('Document: {0}', [error.documentId])),
                      const SizedBox(height: 4),
                      Text(
                        error.errorMessage,
                        style: TextStyle(fontSize: 12, color: Colors.red[700]),
                      ),
                      Text(
                        sdkTr('Time: {0}', [
                          error.timestamp.toString().substring(0, 19),
                        ]),
                        style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                  isThreeLine: true,
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(sdkTr('Close')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(sdkTr('Sync Status')),
        actions: [
          refreshOrSpinnerAction(
            isBusy: _isSyncing,
            onRefresh: _loadDirtyDocuments,
          ),
        ],
      ),
      body: Column(
        children: [
          // Sync status banner
          if (_syncStatus != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: _isSyncing ? Colors.blue[50] : Colors.grey[100],
              child: Row(
                children: [
                  Icon(
                    _isSyncing ? Icons.sync : Icons.info_outline,
                    color: _isSyncing ? Colors.blue : Colors.grey[700],
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _syncStatus!,
                      style: TextStyle(
                        color: _isSyncing ? Colors.blue[900] : Colors.grey[900],
                        fontWeight: _isSyncing
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Sync all button
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isSyncing ? null : _syncAll,
                icon: const Icon(Icons.cloud_upload),
                label: Text(sdkTr('Sync All Documents')),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ),

          // Dirty documents list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _dirtyDocuments.isEmpty
                // Original used `Center(Column(...))` with no surrounding
                // Padding and a bold title — EmptyStateWidget's canonical
                // Padding(24) + titleMedium would visibly shift this.
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.check_circle,
                          size: 64,
                          color: Colors.green,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          sdkTr('All documents synced'),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          sdkTr('No pending changes'),
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _dirtyDocuments.length,
                    itemBuilder: (context, index) {
                      final doc = _dirtyDocuments[index];

                      // Group by doctype
                      final isFirstOfDoctype =
                          index == 0 ||
                          _dirtyDocuments[index - 1].doctype != doc.doctype;

                      return Column(
                        children: [
                          if (isFirstOfDoctype)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              color: Colors.blue[50],
                              child: Row(
                                children: [
                                  const Icon(Icons.folder, color: Colors.blue),
                                  const SizedBox(width: 8),
                                  Text(
                                    doc.doctype,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const Spacer(),
                                  TextButton.icon(
                                    onPressed: _isSyncing
                                        ? null
                                        : () => _syncDoctype(doc.doctype),
                                    icon: const Icon(Icons.sync, size: 18),
                                    label: Text(sdkTr('Sync')),
                                  ),
                                ],
                              ),
                            ),
                          ListTile(
                            leading: Icon(
                              doc.status == 'deleted'
                                  ? Icons.delete
                                  : doc.serverId == null
                                  ? Icons.add_circle
                                  : Icons.edit,
                              color: doc.status == 'deleted'
                                  ? Colors.red
                                  : doc.serverId == null
                                  ? Colors.orange
                                  : Colors.blue,
                            ),
                            title: Text(
                              doc.serverId ?? doc.localId,
                              style: TextStyle(
                                fontWeight: doc.serverId == null
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            subtitle: Text(
                              doc.status == 'deleted'
                                  ? sdkTr('Pending deletion')
                                  : doc.serverId == null
                                  ? sdkTr('New document (not synced)')
                                  : sdkTr('Pending update'),
                            ),
                            trailing: Icon(
                              Icons.cloud_upload,
                              color: Colors.orange[300],
                              size: 20,
                            ),
                          ),
                          const Divider(height: 1),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
