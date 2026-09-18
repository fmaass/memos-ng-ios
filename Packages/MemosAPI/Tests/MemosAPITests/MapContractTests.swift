import MemosAPI

/// The map surface of the contract, held to by the COMPILER rather than by an assertion.
///
/// swift-openapi-generator answers a schema it will not emit by emitting nothing: the property or
/// the operation is simply absent, every build stays green, and the first sign of it is a field
/// that is always nil at runtime. `MapManifest.planet` and `.detail` are written as
/// `anyOf: [{$ref: MapArchive}, {"type": "null"}]` — the first union of that shape ever vendored
/// here — so they are the two these lines exist for. A symbol the generator drops is a symbol no
/// line below can name, which turns a silent omission into a build failure.
private func markersOperationIsGenerated(_ client: any APIProtocol) async throws {
    _ = try await client.listMarkersApiMapMarkersGet(.init())
}

private func manifestPropertiesAreGenerated(_ manifest: Components.Schemas.MapManifest) {
    _ = manifest.planet
    _ = manifest.detail
    // A nullable scalar on the SAME schema, spelled the way every nullable field already vendored
    // here is: it must survive whatever becomes of the two above, so a build that loses all three
    // is a broken vendoring rather than the union idiom being dropped.
    _ = manifest.assetsCommit
}
