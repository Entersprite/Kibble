import Foundation
import GRDB

/// How every `Date` column in this store is held: a REAL of seconds since
/// 1970, the same `Double` `Date.timeIntervalSince1970` returns.
///
/// **Not GRDB's default**, which is the text `yyyy-MM-dd HH:mm:ss.SSS` and
/// keeps milliseconds only, rounded to the nearest. Mark-read takes its
/// position from messages read back out of this store, so a message at
/// `.128263` came back as `.128`, the backend's one-microsecond offset
/// published `.128001` - before the message itself - and Google kept the
/// conversation unread. A live probe measured GChat's own mark landing
/// 262 µs short of the message it named. At current epoch values a `Double`
/// resolves about 0.24 µs, so a microsecond survives the round trip exactly.
///
/// **One representation, spelled here, for records and raw SQL alike.** A
/// record's strategy reaches only what the record itself encodes. A `Date`
/// bound as a raw-SQL argument - `arguments: [someDate]`, or a
/// query-interface `Column("createdAt") < someDate` - goes through
/// `Date.databaseValue` instead, which is GRDB's **text** whatever any
/// record says. Against a REAL column that compares a number with a string,
/// SQLite orders every number before every text, and the answer is wrong
/// with nothing failing. So never bind a `Date` into this store directly:
/// bind `StoredDate.value(_:)`.
enum StoredDate {
    /// For `databaseDateEncodingStrategy(for:)` on every record with a date.
    static let encoding = DatabaseDateEncodingStrategy.timeIntervalSince1970

    /// For `databaseDateDecodingStrategy(for:)`, matching `encoding`.
    ///
    /// For a REAL it reads exactly what GRDB's default would. It differs only
    /// on a stray text value, which the default would read correctly and
    /// this reads as a moment in 1970. That is deliberate: a text value in
    /// these columns is a bug that sorts wrong, and a 1970 date makes it
    /// visible rather than hiding it. Deleting this changes no test's
    /// outcome, because since `v5` nothing in the store writes text here.
    static let decoding = DatabaseDateDecodingStrategy.timeIntervalSince1970

    /// What a date column holds for `date`: the value to bind in raw SQL.
    static func value(_ date: Date) -> Double {
        date.timeIntervalSince1970
    }

    /// The date a date column's value names.
    static func date(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value)
    }
}
