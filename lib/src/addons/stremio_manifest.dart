/// Parsed capability declarations from a Stremio-compatible addon manifest.
///
/// Routing is based on the manifest's declared resources, media types and ID
/// prefixes, never on provider display names. The parser intentionally tolerates
/// optional fields used by older addons while rejecting malformed manifests.
class StremioResourceCapability {
  const StremioResourceCapability({
    required this.name,
    this.types = const <String>{},
    this.idPrefixes = const <String>[],
  });

  final String name;
  final Set<String> types;
  final List<String> idPrefixes;

  bool supports({
    required String type,
    String? id,
    Set<String> fallbackTypes = const <String>{},
    List<String> fallbackIdPrefixes = const <String>[],
    bool checkIdPrefix = true,
  }) {
    final allowedTypes = types.isNotEmpty ? types : fallbackTypes;
    if (allowedTypes.isNotEmpty && !allowedTypes.contains(type)) {
      return false;
    }

    final prefixes = idPrefixes.isNotEmpty ? idPrefixes : fallbackIdPrefixes;
    if (!checkIdPrefix || id == null || prefixes.isEmpty) {
      return true;
    }
    return prefixes.any(id.startsWith);
  }
}

class StremioCatalogDefinition {
  const StremioCatalogDefinition({
    required this.type,
    required this.id,
    required this.name,
  });

  final String type;
  final String id;
  final String name;
}

class StremioAddonManifest {
  const StremioAddonManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.types,
    required this.idPrefixes,
    required this.resources,
    required this.catalogs,
  });

  final String id;
  final String name;
  final String version;
  final Set<String> types;
  final List<String> idPrefixes;
  final Map<String, StremioResourceCapability> resources;
  final List<StremioCatalogDefinition> catalogs;

  factory StremioAddonManifest.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Addon manifest must be a JSON object.');
    }
    final json = Map<String, dynamic>.from(raw);
    final id = (json['id'] ?? '').toString().trim();
    final name = (json['name'] ?? '').toString().trim();
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException(
        'Addon manifest requires non-empty id and name.',
      );
    }

    Set<String> stringSet(Object? value) {
      if (value is! List) return <String>{};
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toSet();
    }

    List<String> stringList(Object? value) {
      if (value is! List) return <String>[];
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toSet()
          .toList(growable: false);
    }

    final globalTypes = stringSet(json['types']);
    final globalPrefixes = stringList(json['idPrefixes']);
    final resources = <String, StremioResourceCapability>{};
    final rawResources = json['resources'];
    if (rawResources is List) {
      for (final rawResource in rawResources) {
        String resourceName;
        Set<String> resourceTypes = <String>{};
        List<String> resourcePrefixes = <String>[];
        if (rawResource is String) {
          resourceName = rawResource.trim();
        } else if (rawResource is Map) {
          final resource = Map<String, dynamic>.from(rawResource);
          resourceName = (resource['name'] ?? resource['resource'] ?? '')
              .toString()
              .trim();
          resourceTypes = stringSet(resource['types']);
          resourcePrefixes = stringList(resource['idPrefixes']);
        } else {
          continue;
        }
        if (resourceName.isEmpty) continue;

        final existing = resources[resourceName];
        // Multiple declarations for the same resource are uncommon but valid
        // enough to merge. An empty restriction in either declaration means
        // that dimension is unrestricted and must remain unrestricted.
        final mergedTypes = existing == null
            ? resourceTypes
            : existing.types.isEmpty || resourceTypes.isEmpty
            ? <String>{}
            : <String>{...existing.types, ...resourceTypes};
        final mergedPrefixes = existing == null
            ? resourcePrefixes
            : existing.idPrefixes.isEmpty || resourcePrefixes.isEmpty
            ? <String>[]
            : <String>{
                ...existing.idPrefixes,
                ...resourcePrefixes,
              }.toList(growable: false);
        resources[resourceName] = StremioResourceCapability(
          name: resourceName,
          types: mergedTypes,
          idPrefixes: mergedPrefixes,
        );
      }
    }
    if (resources.isEmpty) {
      throw const FormatException(
        'Addon manifest declares no usable resources.',
      );
    }

    final catalogs = <StremioCatalogDefinition>[];
    final rawCatalogs = json['catalogs'];
    if (rawCatalogs is List) {
      for (final rawCatalog in rawCatalogs.whereType<Map>()) {
        final catalog = Map<String, dynamic>.from(rawCatalog);
        final type = (catalog['type'] ?? '').toString().trim().toLowerCase();
        final catalogId = (catalog['id'] ?? '').toString().trim();
        if (type.isEmpty || catalogId.isEmpty) continue;
        catalogs.add(
          StremioCatalogDefinition(
            type: type,
            id: catalogId,
            name: (catalog['name'] ?? catalogId).toString().trim(),
          ),
        );
      }
    }

    return StremioAddonManifest(
      id: id,
      name: name,
      version: (json['version'] ?? '').toString().trim(),
      types: globalTypes,
      idPrefixes: globalPrefixes,
      resources: Map<String, StremioResourceCapability>.unmodifiable(resources),
      catalogs: List<StremioCatalogDefinition>.unmodifiable(catalogs),
    );
  }

  bool supportsResource(
    String resource, {
    required String type,
    String? id,
    bool checkIdPrefix = true,
  }) {
    final capability = resources[resource];
    if (capability == null) return false;
    return capability.supports(
      type: type,
      id: id,
      fallbackTypes: types,
      fallbackIdPrefixes: idPrefixes,
      checkIdPrefix: checkIdPrefix,
    );
  }

  /// Builds an addon resource route relative to its configured manifest URL.
  ///
  /// This preserves nested addon paths and query-based configuration tokens,
  /// which are lost when the caller reduces every manifest to just its host.
  static Uri resourceUri(
    String manifestUrl, {
    required String resource,
    required String type,
    required String id,
    Map<String, String> queryParameters = const <String, String>{},
  }) {
    final manifest = Uri.tryParse(manifestUrl.trim());
    if (manifest == null ||
        !manifest.hasScheme ||
        !{'http', 'https'}.contains(manifest.scheme) ||
        manifest.host.isEmpty) {
      throw const FormatException(
        'Addon manifest URL must be a valid HTTP(S) URL.',
      );
    }

    final baseSegments = manifest.pathSegments.toList();
    if (baseSegments.isNotEmpty &&
        baseSegments.last.toLowerCase() == 'manifest.json') {
      baseSegments.removeLast();
    }
    final mergedQuery = <String, String>{
      ...manifest.queryParameters,
      ...queryParameters,
    };
    return manifest.replace(
      pathSegments: <String>[
        ...baseSegments.where((segment) => segment.isNotEmpty),
        resource,
        type,
        '$id.json',
      ],
      queryParameters: mergedQuery.isEmpty ? null : mergedQuery,
    );
  }
}
