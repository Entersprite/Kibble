import SyncEngine

extension AppEnvironment {
    func configureComposerFeedback(_ model: ChatSessionModel) {
        model.didBeginSending = { [weak services] in services?.messageSending() }
        model.didUpload = { [weak self] attachment, file in
            self?.seedUpload(attachment, from: file)
        }
        followStagedFiles(of: model)
    }
}
