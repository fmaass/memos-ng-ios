import MemosAPI

/// The map surface of the contract, held to by the COMPILER rather than by an assertion.
///
/// swift-openapi-generator answers a schema or an operation it will not emit by emitting nothing:
/// the symbol is simply absent, every build stays green, and the first sign of it is a field that
/// is always nil at runtime or a call nobody can write. Two things make that silence likely here
/// rather than theoretical. The generator drops a property written as `anyOf: [{$ref: X},
/// {"type": "null"}]` with a warning nothing fails on — which is why the basemap manifest that
/// carries the only two such unions is filtered out of generation entirely. And the filter that
/// does the excluding is inclusion-only, so everything this app DOES read is named in a list a
/// re-vendor can silently fail to extend.
///
/// So the markers surface is named here, line by line. A symbol the generator drops is a symbol
/// none of these lines can name, which turns a silent omission into a build failure.
private func markersOperationIsGenerated(_ client: any APIProtocol) async throws {
    _ = try await client.listMarkersApiMapMarkersGet(.init())
}

private func markerListIsGenerated(_ list: Components.Schemas.MapMarkerList) {
    _ = list.markers
}

/// The fields the map screens are built from. `memoUid` and `takenAt` are spelled `memo_uid` and
/// `taken_at` upstream, so they are also the two lines that would break if the naming strategy
/// changed under us — a different failure from a dropped field, and one the diagnostic names.
private func markerPropertiesAreGenerated(_ marker: Components.Schemas.MapMarker) {
    _ = marker.uid
    _ = marker.memoUid
    _ = marker.latitude
    _ = marker.longitude
    _ = marker.takenAt
    _ = marker.mime
    _ = marker.blurhash
    _ = marker.width
    _ = marker.height
    _ = marker.thumbnailUrl
    _ = marker.previewUrl
    _ = marker.downloadUrl
}
