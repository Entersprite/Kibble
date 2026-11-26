import Foundation

public enum CallViewLayout: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic, tiled, spotlight, sidebar

    public var id: Self {
        self
    }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .tiled: "Tiled"
        case .spotlight: "Spotlight"
        case .sidebar: "Sidebar"
        }
    }
}

public enum CallTileLimit: Int, CaseIterable, Codable, Identifiable, Sendable {
    case four = 4, nine = 9, sixteen = 16, twentyFive = 25, thirtySix = 36, fortyNine = 49

    public var id: Self {
        self
    }
}

/// The viewer's defaults for arranging video across calls.
public struct CallLayoutPreferences: Codable, Equatable, Sendable {
    public var layout: CallViewLayout
    public var tileLimit: CallTileLimit
    public var hidesTilesWithoutVideo: Bool
    public var selfView: CallSelfViewPreferences

    public init(
        layout: CallViewLayout = .automatic, tileLimit: CallTileLimit = .sixteen,
        hidesTilesWithoutVideo: Bool = false, selfView: CallSelfViewPreferences = CallSelfViewPreferences()
    ) {
        self.layout = layout
        self.tileLimit = tileLimit
        self.hidesTilesWithoutVideo = hidesTilesWithoutVideo
        self.selfView = selfView
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        layout = try fields.decode(CallViewLayout.self, forKey: .layout)
        tileLimit = try fields.decode(CallTileLimit.self, forKey: .tileLimit)
        hidesTilesWithoutVideo = try fields.decode(Bool.self, forKey: .hidesTilesWithoutVideo)
        selfView = try fields.decodeIfPresent(CallSelfViewPreferences.self, forKey: .selfView)
            ?? CallSelfViewPreferences()
    }
}

public struct CallSelfViewPreferences: Codable, Equatable, Sendable {
    public enum Placement: String, Codable, CaseIterable, Sendable {
        case automatic, floating, tile
    }

    public enum Corner: String, Codable, CaseIterable, Sendable {
        case topTrailing, topLeading, bottomTrailing, bottomLeading
    }

    public var placement: Placement
    public var corner: Corner
    public var cropped: Bool

    public init(placement: Placement = .automatic, corner: Corner = .topTrailing, cropped: Bool = false) {
        self.placement = placement
        self.corner = corner
        self.cropped = cropped
    }
}

/// Sizes the call window's two layouts share with the host.
public enum CallLayout {
    /// The audio window. Its height grows only if a long notice needs it.
    public static let compact = CGSize(width: 360, height: 460)
    /// The size a call window grows to when video first appears.
    public static let video = CGSize(width: 760, height: 480)
    /// The smallest a video call window can be resized to.
    public static let videoMinimum = CGSize(width: 480, height: 360)
    /// Space reserved below the window controls.
    static let titlebarGap: CGFloat = 14
    /// Your camera, your shared screen and the videos beside a shared screen.
    static let tile: CGFloat = 192
    static let enlargedPresentationTile: CGFloat = 144
    static let button: CGFloat = 46
    static let answerButton: CGFloat = 62
}
