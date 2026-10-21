import Testing
@testable import DesignSystem

struct DownloadSettingsPaneTests {
    private func state(isDefault: Bool, notice: String? = nil) -> DownloadSettingsState {
        DownloadSettingsState(
            folderName: isDefault ? "Downloads" : "Work",
            folderPath: isDefault ? "/Users/someone/Downloads" : "/Users/someone/Work",
            isDefault: isDefault,
            notice: notice
        )
    }

    /// The menu lists Downloads once: as the checked item while it is in use,
    /// beside the current folder otherwise.
    @Test("Downloads is listed once, checked or beside the chosen folder", arguments: [
        (true, nil as String?, DownloadFolderMenuItem.downloads, false),
        (false, nil, DownloadFolderMenuItem.current, true),
        (true, "The folder Kibble was saving to is gone, so downloads go to Downloads.", .downloads, false),
        (false, "Kibble couldn't remember “Projects”, so it is still saving to Work.", .current, true)
    ])
    func downloadsIsListedOnce(
        _ isDefault: Bool, _ notice: String?, _ checked: DownloadFolderMenuItem, _ listsDownloads: Bool
    ) {
        let state = state(isDefault: isDefault, notice: notice)
        #expect(state.currentItem == checked)
        #expect(state.offersDownloads == listsDownloads)
    }
}
