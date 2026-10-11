import MemosAPI
import Testing

/// The collections surface of the contract, held to by the COMPILER first and an assertion second.
///
/// The generator's filter is inclusion-only (see `openapi-generator-config.yaml`), so an
/// operation a re-vendor fails to name is simply absent and every build stays green. Naming each
/// generated operation type here turns that silence into a build failure; reading its `id` back
/// pins each type to the server's operationId, so a type generated from the wrong route fails the
/// assertion.
@Suite("Collections contract")
struct CollectionsContractTests {
    @Test("the eight collection operations are generated under their server operationIds")
    func collectionOperationsAreGenerated() {
        let generated: [(String, String)] = [
            (
                Operations.CreateCollectionApiCollectionsPost.id,
                "create_collection_api_collections_post"
            ),
            (
                Operations.DeleteCollectionApiCollectionsUidDelete.id,
                "delete_collection_api_collections__uid__delete"
            ),
            (
                Operations.ExcludeAttachmentApiCollectionsUidExclusionsAttachmentUidPut.id,
                "exclude_attachment_api_collections__uid__exclusions__attachment_uid__put"
            ),
            (
                Operations.GetCollectionApiCollectionsUidGet.id,
                "get_collection_api_collections__uid__get"
            ),
            (
                Operations.IncludeAttachmentApiCollectionsUidExclusionsAttachmentUidDelete.id,
                "include_attachment_api_collections__uid__exclusions__attachment_uid__delete"
            ),
            (
                Operations.ListCollectionsApiCollectionsGet.id,
                "list_collections_api_collections_get"
            ),
            (
                Operations.ListMembersApiCollectionsUidAttachmentsGet.id,
                "list_members_api_collections__uid__attachments_get"
            ),
            (
                Operations.UpdateCollectionApiCollectionsUidPatch.id,
                "update_collection_api_collections__uid__patch"
            ),
        ]
        for (id, expected) in generated {
            #expect(id == expected)
        }
    }
}
