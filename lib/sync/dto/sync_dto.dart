import 'dart:convert';

// ── Wire models (snake_case, matches server JSON) ────────────────────────────

class SyncEntry {
  final String id;
  final String createdAt;
  final String updatedAt;
  final String type;
  final String? title;
  final String body;
  final String status;
  final bool pinned;
  final double? geoLat;
  final double? geoLng;
  final String? reminderAt;
  final String? sourceUrl;
  final String? sourceApp;
  final List<String> tags;
  final List<Map<String, dynamic>> properties;
  final List<String> containers;
  final List<Map<String, dynamic>> attachments;
  final String? aiEnrichedAt;
  final String? lang;

  const SyncEntry({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.type,
    this.title,
    required this.body,
    required this.status,
    required this.pinned,
    this.geoLat,
    this.geoLng,
    this.reminderAt,
    this.sourceUrl,
    this.sourceApp,
    required this.tags,
    required this.properties,
    required this.containers,
    required this.attachments,
    this.aiEnrichedAt,
    this.lang,
  });

  factory SyncEntry.fromJson(Map<String, dynamic> j) => SyncEntry(
        id: j['id'] as String,
        createdAt: j['created_at'] as String,
        updatedAt: j['updated_at'] as String,
        type: j['type'] as String? ?? 'text',
        title: j['title'] as String?,
        body: j['body'] as String? ?? '',
        status: j['status'] as String? ?? 'inbox',
        pinned: j['pinned'] as bool? ?? false,
        geoLat: (j['geo_lat'] as num?)?.toDouble(),
        geoLng: (j['geo_lng'] as num?)?.toDouble(),
        reminderAt: j['reminder_at'] as String?,
        sourceUrl: j['source_url'] as String?,
        sourceApp: j['source_app'] as String?,
        tags: (j['tags'] as List<dynamic>?)?.cast<String>() ?? [],
        properties: (j['properties'] as List<dynamic>?)
                ?.map((e) => Map<String, dynamic>.from(e as Map))
                .toList() ??
            [],
        containers:
            (j['containers'] as List<dynamic>?)?.cast<String>() ?? [],
        attachments: (j['attachments'] as List<dynamic>?)
                ?.map((e) => Map<String, dynamic>.from(e as Map))
                .toList() ??
            [],
        aiEnrichedAt: j['ai_enriched_at'] as String?,
        lang: j['lang'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'type': type,
        'title': title,
        'body': body,
        'status': status,
        'pinned': pinned,
        'geo_lat': geoLat,
        'geo_lng': geoLng,
        'reminder_at': reminderAt,
        'source_url': sourceUrl,
        'source_app': sourceApp,
        'tags': tags,
        'properties': properties,
        'containers': containers,
        'attachments': attachments,
        'ai_enriched_at': aiEnrichedAt,
        'lang': lang,
      };
}

class SyncContainer {
  final String id;
  final String kind;
  final String name;
  final String? description;
  final String icon;
  final String color;
  final String createdAt;
  final String updatedAt;
  final bool archived;
  final String? filterTag;
  final String? filterStatus;
  final String? filterType;
  final String sortOrder;
  final String viewMode;
  final String? parentId;

  const SyncContainer({
    required this.id,
    required this.kind,
    required this.name,
    this.description,
    required this.icon,
    required this.color,
    required this.createdAt,
    required this.updatedAt,
    required this.archived,
    this.filterTag,
    this.filterStatus,
    this.filterType,
    required this.sortOrder,
    required this.viewMode,
    this.parentId,
  });

  factory SyncContainer.fromJson(Map<String, dynamic> j) => SyncContainer(
        id: j['id'] as String,
        kind: j['kind'] as String? ?? 'project',
        name: j['name'] as String? ?? '',
        description: j['description'] as String?,
        icon: j['icon'] as String? ?? 'folder',
        color: j['color'] as String? ?? '#14B8A6',
        createdAt: j['created_at'] as String,
        updatedAt: (j['updated_at'] ?? j['created_at']) as String,
        archived: j['archived'] as bool? ?? false,
        filterTag: j['filter_tag'] as String?,
        filterStatus: j['filter_status'] as String?,
        filterType: j['filter_type'] as String?,
        sortOrder: j['sort_order'] as String? ?? 'desc',
        viewMode: j['view_mode'] as String? ?? 'list',
        parentId: j['parent_id'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'name': name,
        'description': description,
        'icon': icon,
        'color': color,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'archived': archived,
        'filter_tag': filterTag,
        'filter_status': filterStatus,
        'filter_type': filterType,
        'sort_order': sortOrder,
        'view_mode': viewMode,
        'parent_id': parentId,
      };
}

class SyncTombstone {
  final String entityType;
  final String entityId;
  final String deletedAt;

  const SyncTombstone({
    required this.entityType,
    required this.entityId,
    required this.deletedAt,
  });

  factory SyncTombstone.fromJson(Map<String, dynamic> j) => SyncTombstone(
        entityType: j['entityType'] as String? ?? j['entity_type'] as String,
        entityId: j['entityId'] as String? ?? j['entity_id'] as String,
        deletedAt: j['deletedAt'] as String? ?? j['deleted_at'] as String,
      );

  Map<String, dynamic> toJson() => {
        'entityType': entityType,
        'entityId': entityId,
        'deletedAt': deletedAt,
      };
}

class SyncConflict {
  final String entityType;
  final String entityId;
  final String serverModifiedAt;

  const SyncConflict({
    required this.entityType,
    required this.entityId,
    required this.serverModifiedAt,
  });

  factory SyncConflict.fromJson(Map<String, dynamic> j) => SyncConflict(
        entityType: j['entityType'] as String,
        entityId: j['entityId'] as String,
        serverModifiedAt: j['serverModifiedAt'] as String,
      );
}

// ── Request / Response wrappers ───────────────────────────────────────────────

class SyncPullResponse {
  final String syncedAt;
  final String serverDeviceId;
  final String serverName;
  final List<SyncEntry> entries;
  final List<SyncContainer> containers;
  final List<SyncTombstone> tombstones;

  const SyncPullResponse({
    required this.syncedAt,
    required this.serverDeviceId,
    required this.serverName,
    required this.entries,
    required this.containers,
    required this.tombstones,
  });

  factory SyncPullResponse.fromJson(Map<String, dynamic> j) => SyncPullResponse(
        syncedAt: j['syncedAt'] as String,
        serverDeviceId: j['serverDeviceId'] as String,
        serverName: j['serverName'] as String? ?? '',
        entries: (j['entries'] as List<dynamic>?)
                ?.map((e) => SyncEntry.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            [],
        containers: (j['containers'] as List<dynamic>?)
                ?.map((e) => SyncContainer.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            [],
        tombstones: (j['tombstones'] as List<dynamic>?)
                ?.map((e) => SyncTombstone.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            [],
      );
}

class SyncPushRequest {
  final String deviceId;
  final List<SyncEntry> entries;
  final List<SyncContainer> containers;
  final List<SyncTombstone> tombstones;

  const SyncPushRequest({
    required this.deviceId,
    required this.entries,
    required this.containers,
    required this.tombstones,
  });

  String toJsonString() => jsonEncode({
        'deviceId': deviceId,
        'entries': entries.map((e) => e.toJson()).toList(),
        'containers': containers.map((c) => c.toJson()).toList(),
        'tombstones': tombstones.map((t) => t.toJson()).toList(),
      });
}

class SyncPushResponse {
  final List<SyncConflict> conflicts;

  const SyncPushResponse({required this.conflicts});

  factory SyncPushResponse.fromJson(Map<String, dynamic> j) => SyncPushResponse(
        conflicts: (j['conflicts'] as List<dynamic>?)
                ?.map((e) => SyncConflict.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            [],
      );
}

// ── Peer (discovered via mDNS or manual entry) ───────────────────────────────

class SyncPeer {
  final String deviceId;
  final String deviceName;
  final String host;
  final int port;
  final bool paired;

  const SyncPeer({
    required this.deviceId,
    required this.deviceName,
    required this.host,
    required this.port,
    this.paired = false,
  });

  SyncPeer copyWith({bool? paired}) => SyncPeer(
        deviceId: deviceId,
        deviceName: deviceName,
        host: host,
        port: port,
        paired: paired ?? this.paired,
      );

  String get baseUrl => 'http://$host:$port';

  @override
  bool operator ==(Object other) =>
      other is SyncPeer && other.deviceId == deviceId;

  @override
  int get hashCode => deviceId.hashCode;
}

// ── Sync Status ───────────────────────────────────────────────────────────────

enum SyncStatus { idle, syncing, success, error, disabled, notConfigured }

class SyncState {
  final SyncStatus status;
  final String? message;
  final DateTime? lastSyncAt;
  final List<SyncConflict> pendingConflicts;

  const SyncState({
    this.status = SyncStatus.notConfigured,
    this.message,
    this.lastSyncAt,
    this.pendingConflicts = const [],
  });

  SyncState copyWith({
    SyncStatus? status,
    String? message,
    DateTime? lastSyncAt,
    List<SyncConflict>? pendingConflicts,
  }) =>
      SyncState(
        status: status ?? this.status,
        message: message ?? this.message,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        pendingConflicts: pendingConflicts ?? this.pendingConflicts,
      );
}
