import Testing
@testable import DesignSystem

struct DownloadSettingsPaneTests {
    @Test("Use Downloads is offered for a changed folder and for any notice", arguments: [
        (true, nil as String?, false),
        (false, nil, true),
        (true, "The folder Kibble was saving to is gone, so downloads go to Downloads.", true),
        (false, "Kibble couldn't remember “Projects”, so it is still saving to Work.", true)
    ])
    func useDownloadsIsOffered(_ isDefault: Bool, _ notice: String?, _ offered: Bool) {
        let state = DownloadSettingsState(
            folderName: "Downloads",
            folderPath: "/Users/someone/Downloads",
            isDefault: isDefault,
            notice: notice
        )
        #expect(state.offersUseDownloads == offered)
    }
}
