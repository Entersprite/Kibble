import ChatRules
import GRDB

package extension ValueObservation where Reducer: ValueReducer {
    /// Complete UI snapshots supersede earlier pending snapshots. A slow or
    /// stalled UI must not retain every full query result while writes continue.
    /// Event streams and connection transitions still need every delivery.
    func snapshotValues(
        in reader: any DatabaseReader,
        scheduling scheduler: some ValueObservationScheduler = .task
    ) -> AsyncValueObservation<Reducer.Value> {
        values(in: reader, scheduling: scheduler, bufferingPolicy: .bufferingNewest(1))
    }
}
