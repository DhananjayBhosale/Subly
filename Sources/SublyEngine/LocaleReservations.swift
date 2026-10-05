import Foundation
import Speech

/// macOS keeps only a small number of speech locales reserved at once
/// (`AssetInventory.maximumReservedLocales`, currently 5). Exceeding it fails the
/// install with "Too many allocated locales", which would break a multi-language app
/// on the sixth language a user tries.
///
/// This manages the pool as an LRU cache: the least recently used locale is released
/// to make room. Released locales stay downloaded on disk — only the reservation is
/// given up — so reusing one later is cheap.
public actor LocaleReservations {

    public static let shared = LocaleReservations()

    private let usageKey = "SublyLocaleLastUsed"

    public struct PoolState: Sendable {
        public var reserved: [String]
        public var maximum: Int
        public var isFull: Bool { reserved.count >= maximum }
    }

    private init() {}

    // MARK: - Usage log

    private var usage: [String: Date] {
        get {
            (UserDefaults.standard.dictionary(forKey: usageKey) as? [String: Date]) ?? [:]
        }
        set { UserDefaults.standard.set(newValue, forKey: usageKey) }
    }

    private func touch(_ identifier: String) {
        var u = usage
        u[identifier] = Date()
        usage = u
    }

    // MARK: - Pool

    public func state() async -> PoolState {
        let reserved = await AssetInventory.reservedLocales
        return PoolState(reserved: reserved.map { $0.identifier(.bcp47) },
                         maximum: AssetInventory.maximumReservedLocales)
    }

    /// Make sure `locale` holds a reservation, evicting the least recently used one if
    /// the pool is already full. Returns the identifier that was evicted, if any, so
    /// the caller can tell the user plainly.
    @discardableResult
    public func ensureReserved(_ locale: Locale) async throws -> String? {
        let wanted = locale.identifier(.bcp47)
        let reserved = await AssetInventory.reservedLocales

        if reserved.contains(where: { $0.identifier(.bcp47) == wanted }) {
            touch(wanted)
            return nil
        }

        var evicted: String?
        let maximum = AssetInventory.maximumReservedLocales
        if reserved.count >= maximum {
            // Evict the least recently used reservation. A locale we have never
            // recorded sorts oldest, which is the behaviour we want.
            let log = usage
            let victim = reserved
                .filter { $0.identifier(.bcp47) != wanted }
                .min { a, b in
                    (log[a.identifier(.bcp47)] ?? .distantPast)
                        < (log[b.identifier(.bcp47)] ?? .distantPast)
                }
            if let victim {
                let released = await AssetInventory.release(reservedLocale: victim)
                if released {
                    evicted = victim.identifier(.bcp47)
                    var u = usage
                    u.removeValue(forKey: victim.identifier(.bcp47))
                    usage = u
                }
            }
        }

        _ = try await AssetInventory.reserve(locale: locale)
        touch(wanted)
        return evicted
    }

    /// Give up a reservation explicitly. The downloaded assets remain on disk.
    public func release(_ locale: Locale) async {
        _ = await AssetInventory.release(reservedLocale: locale)
        var u = usage
        u.removeValue(forKey: locale.identifier(.bcp47))
        usage = u
    }
}
