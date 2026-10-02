import Darwin
import Foundation

/// Whether anything was added to or removed from a folder since the watch
/// began, read synchronously from a kqueue: the kernel queues the vnode's
/// `NOTE_WRITE` as the entry changes, so `changed()` needs no wait and cannot
/// miss a file that was created and deleted again before it was asked.
/// Each `changed()` consumes what it reports.
final class FolderWriteWatch {
    private let queue: Int32
    private let folder: Int32

    init(_ url: URL) throws {
        folder = open(url.path(percentEncoded: false), O_EVTONLY)
        queue = kqueue()
        guard folder >= 0, queue >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        var event = kevent(
            ident: UInt(folder),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: UInt32(NOTE_WRITE),
            data: 0,
            udata: nil
        )
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
    }

    deinit {
        close(folder)
        close(queue)
    }

    func changed() -> Bool {
        var event = kevent()
        var now = timespec(tv_sec: 0, tv_nsec: 0)
        return kevent(queue, nil, 0, &event, 1, &now) > 0
    }
}
