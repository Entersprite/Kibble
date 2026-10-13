#if DEBUG
    import MacHost
    import SwiftUI

    @MainActor
    struct MeetDMCallTrialView: View {
        @State private var model = MeetDMCallTrialModel()
        @State private var query = ""
        @State private var muted = false

        private var people: [MeetCallTrialPerson] {
            guard !query.isEmpty else { return model.people }
            return model.people.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.email?.localizedCaseInsensitiveContains(query) == true
            }
        }

        private var incomingControls: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Listen for Incoming Calls") { Task { await model.startListening() } }
                        .disabled(model.isListening || model.isBusy || model.people.isEmpty)
                    Button("Stop Listening") { Task { await model.stopListening() } }
                        .disabled(!model.isListening)
                }
                Text(model.incomingStatus).font(.callout).foregroundStyle(.secondary)
                if let person = model.incomingPerson {
                    Text("Incoming call: \(person.name)").font(.headline)
                    HStack {
                        Button("Accept with Native Audio") { Task { await model.acceptIncoming() } }
                            .disabled(model.isBusy || model.isNativeCallActive)
                        Button("Dismiss Locally") { Task { await model.dismissIncoming() } }
                            .disabled(model.isBusy)
                    }
                }
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Native DM call trial").font(.title2.bold())
                Text("Choose a person who is ready to test a real call with you.")
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 8) {
                        TextField("Find a person", text: $query)
                            .textFieldStyle(.roundedBorder)
                        List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                            ForEach(people) { person in
                                VStack(alignment: .leading) {
                                    Text(person.name)
                                    if let email = person.email {
                                        Text(email).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .tag(person.id)
                            }
                        }
                        .disabled(model.isBusy || model.isNativeCallActive)
                        Button("Reload People") { Task { await model.load() } }
                            .disabled(model.isBusy || model.isNativeCallActive)
                    }
                    .frame(width: 310)
                    VStack(alignment: .leading, spacing: 16) {
                        if let person = model.selectedPerson {
                            Text(person.name).font(.headline)
                            if let email = person.email {
                                Text(email).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Select a person from your DMs.").font(.headline)
                        }
                        incomingControls
                        Divider()
                        Button("1. Prepare Call") { Task { await model.prepare() } }
                            .disabled(!model.canPrepare)
                        Button("2. Connect Native Audio") { Task { await model.joinNative() } }
                            .disabled(!model.canJoinNative)
                        Button("3. Ring Person") { Task { await model.ring() } }
                            .disabled(!model.canRing)
                        Toggle("Mute microphone", isOn: $muted)
                            .onChange(of: muted) { _, value in model.setNativeMuted(value) }
                            .disabled(!model.isNativeCallActive)
                        Button("End Native Call") { Task { await model.endNativeCall() } }
                            .disabled(!model.isNativeCallActive || model.isEndingNativeCall)
                        Divider()
                        Text(model.status).textSelection(.enabled)
                        if model.isBusy {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        Text(
                            "Connect native audio first, then ring explicitly. "
                                + "This trial uses audio; video is still pending."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                        Text("End Native Call closes audio and asks Meet to remove Kibble's caller device.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Text(model.reportStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Report", action: model.copyReport)
                        .disabled(model.reportText.isEmpty)
                }
            }
            .padding(24)
            .frame(minWidth: 820, minHeight: 570)
            .task { await model.load() }
            .onChange(of: model.isNativeCallActive) { _, active in
                if !active {
                    muted = false
                }
            }
            .onDisappear { Task { await model.close() } }
        }
    }
#endif
