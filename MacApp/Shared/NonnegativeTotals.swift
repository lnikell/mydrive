import Foundation

/// Several individually valid file sizes can exceed a signed byte counter.
/// Saturate display aggregates instead of trapping or wrapping below zero.
enum NonnegativeTotals {
    static func add(_ left: Int64, _ right: Int64) -> Int64 {
        let (total, overflow) = max(0, left).addingReportingOverflow(max(0, right))
        return overflow ? .max : total
    }
}
