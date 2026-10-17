import Foundation
import DayPageStorage

/// Public connection metadata for the native Mac client.
///
/// The bundled fallback intentionally targets the isolated DayPage staging
/// project. Both values are public client configuration (never a service-role
/// or DayPage PAT). A release pipeline can override them through generated
/// Info.plist keys without changing source.
///
/// URL and publishable key are always selected as ONE complete pair from ONE
/// configuration tier (`SyncConfigurationPair`): a tier that overrides only
/// one of the two fails loudly instead of borrowing the missing half from
/// another tier, so a stale key can never be paired with a new backend.
struct MacCloudConfiguration: Equatable {
    let backend: SyncBackendConfiguration

    var supabaseURL: URL { backend.url }
    var publishableKey: String { backend.publishableKey }

    static func current(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MacCloudConfiguration {
        let backend: SyncBackendConfiguration
        do {
            backend = try SyncConfigurationPair.select(
                tiers: [
                    SyncConfigurationTier(
                        url: environment["DAYPAGE_SUPABASE_URL"],
                        key: environment["DAYPAGE_SUPABASE_PUBLISHABLE_KEY"]
                    ),
                    SyncConfigurationTier(
                        url: bundle.object(forInfoDictionaryKey: "DayPageSupabaseURL") as? String,
                        key: bundle.object(forInfoDictionaryKey: "DayPageSupabasePublishableKey") as? String
                    ),
                ],
                fallback: SyncConfigurationTier(
                    url: "https://gcukhewnszjrwfzhxctn.supabase.co",
                    key: "sb_publishable_bE_AwZrkhj6ypsEX0p6Cgw_LaRQ1M91"
                )
            )
        } catch {
            // The checked-in fallbacks are complete constants, so this can
            // only fail after an invalid deployment override (partial pair or
            // invalid URL). Fail loudly instead of routing a user's notes to
            // an ambiguous host.
            preconditionFailure("Invalid DayPage Supabase configuration")
        }
        return MacCloudConfiguration(backend: backend)
    }
}
