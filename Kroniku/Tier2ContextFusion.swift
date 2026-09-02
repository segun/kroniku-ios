import Foundation
import AVFoundation
import Speech
import Contacts
import CoreBluetooth

private func requestSpeechAuthorizationStatusRaw() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status)
        }
    }
}

private func requestMicrophoneAccessRaw() async -> Bool {
    await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            continuation.resume(returning: granted)
        }
    }
}

protocol VoiceContextProviding: Sendable {
    var microphonePermission: PermissionState { get }
    var speechPermission: PermissionState { get }
    func requestMicrophonePermission() async -> PermissionState
    func requestSpeechPermission() async -> PermissionState
    func startRecording(onTranscript: @escaping @MainActor (String) -> Void) async throws
    func stopRecording() async -> String
    func transcribe(_ text: String) async -> Tier2TranscriptionResult?
}

@MainActor
protocol ContactsContextProviding {
    var authorizationState: PermissionState { get }
    func requestAccess() async -> PermissionState
    func resolvePerson(named personName: String) async -> Tier2ResolvedPerson?
    func resolvePeople(named personName: String, limit: Int) async -> [Tier2ResolvedPerson]
}

@MainActor
protocol BluetoothContextProviding {
    var authorizationState: PermissionState { get }
    func requestAccess() async -> PermissionState
    func captureNearbyContext() async -> BluetoothContextKind?
}

struct Tier2ResolvedPerson: Hashable {
    var identifier: String
    var displayName: String
    var disambiguationHint: String?
}

struct Tier2TranscriptionResult: Hashable {
    var transcript: String
    var extractedPersonName: String?
    var extractedInteraction: Interaction?
    var extractedOccurredAt: Date?
    var confidence: ExtractedEntityConfidence
}

enum Tier2VoiceError: LocalizedError {
    case unavailableRecognizer
    case microphoneNotAuthorized
    case speechNotAuthorized
    case onDeviceNotAvailable
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .unavailableRecognizer:
            return "Speech recognizer is unavailable on this device."
        case .microphoneNotAuthorized:
            return "Microphone access is required to record voice notes."
        case .speechNotAuthorized:
            return "Speech recognition permission is required for transcription."
        case .onDeviceNotAvailable:
            return "On-device speech recognition is not available for the current locale."
        case .engineStartFailed:
            return "Could not start recording. Please try again."
        }
    }
}

@MainActor
final class Tier2ContextController: ObservableObject {
    @Published private(set) var microphonePermission: PermissionState
    @Published private(set) var speechPermission: PermissionState
    @Published private(set) var contactsPermission: PermissionState
    @Published private(set) var bluetoothPermission: PermissionState
    @Published private(set) var isRequestingMicrophonePermission = false
    @Published private(set) var isRequestingSpeechPermission = false

    private let voiceProvider: VoiceContextProviding
    private let contactsProvider: ContactsContextProviding
    private let bluetoothProvider: BluetoothContextProviding

    init(
        voiceProvider: VoiceContextProviding = NativeVoiceProvider(),
        contactsProvider: ContactsContextProviding = ContactsDirectoryProvider(),
        bluetoothProvider: BluetoothContextProviding = BluetoothAccessoryProvider()
    ) {
        self.voiceProvider = voiceProvider
        self.contactsProvider = contactsProvider
        self.bluetoothProvider = bluetoothProvider
        self.microphonePermission = voiceProvider.microphonePermission
        self.speechPermission = voiceProvider.speechPermission
        self.contactsPermission = contactsProvider.authorizationState
        self.bluetoothPermission = bluetoothProvider.authorizationState
    }

    func refreshPermissions() {
        microphonePermission = voiceProvider.microphonePermission
        speechPermission = voiceProvider.speechPermission
        contactsPermission = contactsProvider.authorizationState
        bluetoothPermission = bluetoothProvider.authorizationState
    }

    func requestMicrophonePermission() async {
        guard !isRequestingMicrophonePermission else { return }
        isRequestingMicrophonePermission = true
        defer { isRequestingMicrophonePermission = false }

        if microphonePermission == .notDetermined {
            microphonePermission = await voiceProvider.requestMicrophonePermission()
        } else {
            microphonePermission = voiceProvider.microphonePermission
        }
    }

    func requestSpeechPermission() async {
        guard !isRequestingSpeechPermission else { return }
        isRequestingSpeechPermission = true
        defer { isRequestingSpeechPermission = false }

        if speechPermission == .notDetermined {
            speechPermission = await voiceProvider.requestSpeechPermission()
        } else {
            speechPermission = voiceProvider.speechPermission
        }
    }

    func requestContactsPermission() async {
        contactsPermission = await contactsProvider.requestAccess()
    }

    func requestBluetoothPermission() async {
        bluetoothPermission = await bluetoothProvider.requestAccess()
    }

    func transcribe(_ text: String) async -> Tier2TranscriptionResult? {
        await voiceProvider.transcribe(text)
    }

    func startRecording(onTranscript: @escaping @MainActor (String) -> Void) async throws {
        try await voiceProvider.startRecording(onTranscript: onTranscript)
    }

    func stopRecording() async -> String {
        await voiceProvider.stopRecording()
    }

    func resolvePerson(named personName: String) async -> Tier2ResolvedPerson? {
        guard !personName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard contactsPermission == .authorized else {
            return nil
        }
        return await contactsProvider.resolvePerson(named: personName)
    }

    func resolvePeople(named personName: String, limit: Int = 5) async -> [Tier2ResolvedPerson] {
        guard !personName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        guard contactsPermission == .authorized else {
            return []
        }
        return await contactsProvider.resolvePeople(named: personName, limit: max(1, limit))
    }

    func captureBluetoothContext() async -> BluetoothContextKind? {
        guard bluetoothPermission == .authorized else {
            return nil
        }
        return await bluetoothProvider.captureNearbyContext()
    }
}

final class NativeVoiceProvider: NSObject, VoiceContextProviding, @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let transcriptLock = NSLock()
    private var committedTranscript: String = ""
    private var partialTranscript: String = ""

    private func resetLiveTranscript() {
        transcriptLock.lock()
        committedTranscript = ""
        partialTranscript = ""
        transcriptLock.unlock()
    }

    private func updateLiveTranscript(with incoming: String, isFinal: Bool) -> String {
        transcriptLock.lock()
        defer { transcriptLock.unlock() }

        let trimmedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIncoming.isEmpty else { return composedTranscriptLocked() }

        if isFinal {
            committedTranscript = Self.mergeTranscript(committedTranscript, trimmedIncoming)
            partialTranscript = ""
        } else {
            partialTranscript = trimmedIncoming
        }

        return composedTranscriptLocked()
    }

    private func composedTranscriptLocked() -> String {
        let committed = committedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let partial = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.mergeTranscript(committed, partial)
    }

    private static func mergeTranscript(_ base: String, _ addition: String) -> String {
        let lhs = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        if lhs == rhs || lhs.localizedCaseInsensitiveContains(rhs) { return lhs }
        if rhs.localizedCaseInsensitiveContains(lhs) { return rhs }

        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        let maxOverlap = min(lhsChars.count, rhsChars.count)
        var overlap = 0

        if maxOverlap > 0 {
            for size in stride(from: maxOverlap, through: 1, by: -1) {
                let lhsSuffix = String(lhsChars[(lhsChars.count - size)...]).lowercased()
                let rhsPrefix = String(rhsChars[..<size]).lowercased()
                if lhsSuffix == rhsPrefix {
                    overlap = size
                    break
                }
            }
        }

        let appended = String(rhsChars.dropFirst(overlap)).trimmingCharacters(in: .whitespacesAndNewlines)
        if appended.isEmpty { return lhs }
        return "\(lhs) \(appended)"
    }

    private func currentLiveTranscript() -> String {
        transcriptLock.lock()
        let text = composedTranscriptLocked()
        transcriptLock.unlock()
        return text
    }

    var microphonePermission: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }

    var speechPermission: PermissionState {
#if targetEnvironment(simulator)
        return .restricted
#else
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
#endif
    }

    func requestMicrophonePermission() async -> PermissionState {
        let granted = await requestMicrophoneAccessRaw()
        return granted ? .authorized : .denied
    }

    func requestSpeechPermission() async -> PermissionState {
#if targetEnvironment(simulator)
        return .restricted
#else
        let status = await requestSpeechAuthorizationStatusRaw()
        return Self.permissionState(for: status)
#endif
    }

    private static func permissionState(for status: SFSpeechRecognizerAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }

    func startRecording(onTranscript: @escaping @MainActor (String) -> Void) async throws {
        guard microphonePermission == .authorized else {
            throw Tier2VoiceError.microphoneNotAuthorized
        }
        guard speechPermission == .authorized else {
            throw Tier2VoiceError.speechNotAuthorized
        }
        guard let recognizer else {
            throw Tier2VoiceError.unavailableRecognizer
        }
        guard recognizer.isAvailable else {
            throw Tier2VoiceError.unavailableRecognizer
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw Tier2VoiceError.onDeviceNotAvailable
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else {
            throw Tier2VoiceError.engineStartFailed
        }
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw Tier2VoiceError.engineStartFailed
        }

        resetLiveTranscript()
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, _ in
            guard let self, let result else { return }
            let transcript = result.bestTranscription.formattedString
            let mergedTranscript = self.updateLiveTranscript(with: transcript, isFinal: result.isFinal)
            Task { @MainActor in
                onTranscript(mergedTranscript)
            }
        }
    }

    func stopRecording() async -> String {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
        return currentLiveTranscript()
    }

    func transcribe(_ text: String) async -> Tier2TranscriptionResult? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let extractedInteraction = inferInteraction(from: cleaned)
        let extractedPerson = inferPerson(from: cleaned)
        let extractedDate = inferDate(from: cleaned)

        let confidence = ExtractedEntityConfidence(
            person: extractedPerson == nil ? 0.42 : 0.84,
            interaction: extractedInteraction == nil ? 0.48 : 0.82,
            timestamp: extractedDate == nil ? 0.40 : 0.76
        )

        return Tier2TranscriptionResult(
            transcript: cleaned,
            extractedPersonName: extractedPerson,
            extractedInteraction: extractedInteraction,
            extractedOccurredAt: extractedDate,
            confidence: confidence
        )
    }

    private func inferInteraction(from text: String) -> Interaction? {
        let lowered = text.lowercased()
        if lowered.contains("met ") || lowered.contains("meeting") || lowered.contains("meet ") {
            return .meeting
        }
        if lowered.contains("called ") || lowered.contains("call ") || lowered.contains("phone") {
            return .call
        }
        if lowered.contains("texted ") || lowered.contains("message") || lowered.contains("sms") {
            return .text
        }
        return nil
    }

    private func inferPerson(from text: String) -> String? {
        let rawTokens = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !rawTokens.isEmpty else { return nil }

        let anchorTokens: Set<String> = ["met", "called", "texted", "with", "to"]
        let stopTokens: Set<String> = ["on", "about", "for", "at", "in", "during", "regarding"]
        let honorifics: Set<String> = ["mr", "mrs", "ms", "miss", "dr", "prof", "sir", "madam", "mx"]

        func isLikelyNameToken(_ token: String) -> Bool {
            guard token.count >= 2, let first = token.first else { return false }
            return first.isUppercase
        }

        for (index, token) in rawTokens.enumerated() {
            guard anchorTokens.contains(token.lowercased()) else { continue }

            var cursor = index + 1
            while cursor < rawTokens.count && honorifics.contains(rawTokens[cursor].lowercased()) {
                cursor += 1
            }

            var picked: [String] = []
            while cursor < rawTokens.count {
                let candidate = rawTokens[cursor]
                let lowered = candidate.lowercased()
                if stopTokens.contains(lowered) {
                    break
                }
                guard isLikelyNameToken(candidate), !honorifics.contains(lowered) else {
                    break
                }
                picked.append(candidate)
                cursor += 1
            }

            if !picked.isEmpty {
                return picked.joined(separator: " ")
            }
        }

        // Fallback: find first run of likely name tokens and drop honorifics.
        var fallback: [String] = []
        for token in rawTokens {
            let lowered = token.lowercased()
            if honorifics.contains(lowered) {
                if fallback.isEmpty { continue }
                break
            }
            if isLikelyNameToken(token) {
                fallback.append(token)
            } else if !fallback.isEmpty {
                break
            }
        }
        return fallback.isEmpty ? nil : fallback.joined(separator: " ")
    }

    private func inferDate(from text: String) -> Date? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = detector?.matches(in: text, options: [], range: range).first,
           let date = match.date {
            return date
        }
        return nil
    }
}

@MainActor
final class ContactsDirectoryProvider: ContactsContextProviding {
    nonisolated private static let honorificTokens: Set<String> = [
        "mr", "mrs", "ms", "miss", "dr", "prof", "sir", "madam", "mx"
    ]

    var authorizationState: PermissionState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized, .limited: return .authorized
        @unknown default: return .restricted
        }
    }

    func requestAccess() async -> PermissionState {
        let store = CNContactStore()
        do {
            _ = try await store.requestAccess(for: .contacts)
        } catch {
            print("Contacts permission request failed: \(error)")
        }
        return authorizationState
    }

    func resolvePerson(named personName: String) async -> Tier2ResolvedPerson? {
        let matches = await resolvePeople(named: personName, limit: 1)
        return matches.first
    }

    func resolvePeople(named personName: String, limit: Int) async -> [Tier2ResolvedPerson] {
        let name = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        let resultLimit = max(1, limit)

        return await Task.detached(priority: .userInitiated) {
            Self.resolvePeopleSync(named: name, limit: resultLimit)
        }.value
    }

    nonisolated private static func resolvePeopleSync(named name: String, limit: Int) -> [Tier2ResolvedPerson] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var matches: [(identifier: String, displayName: String, disambiguationHint: String?, score: Int)] = []

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let full = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                let score = matchScore(personName: name, candidate: full)
                if score == 0 { return }
                let display = full.isEmpty ? name : full
                let hint = buildDisambiguationHint(for: contact)
                matches.append((contact.identifier, display, hint, score))
            }
        } catch {
            print("Contact resolution failed: \(error)")
            return []
        }

        let ranked = matches
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

        var unique: [Tier2ResolvedPerson] = []
        var seen = Set<String>()
        for entry in ranked where unique.count < limit {
            guard !seen.contains(entry.identifier) else { continue }
            seen.insert(entry.identifier)
            unique.append(Tier2ResolvedPerson(identifier: entry.identifier, displayName: entry.displayName, disambiguationHint: entry.disambiguationHint))
        }

        return unique
    }

    nonisolated private static func buildDisambiguationHint(for contact: CNContact) -> String? {
        let organization = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !organization.isEmpty { return organization }

        if let phone = contact.phoneNumbers.first?.value.stringValue {
            let digits = phone.filter(\ .isNumber)
            if digits.count >= 4 {
                return "phone ••••\(digits.suffix(4))"
            }
        }

        if let email = contact.emailAddresses.first?.value as String? {
            let cleaned = email.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }

        return nil
    }

    nonisolated private static func matchScore(personName: String, candidate: String) -> Int {
        let query = normalizedTokens(from: personName)
        let target = normalizedTokens(from: candidate)

        guard !query.full.isEmpty, !target.full.isEmpty else { return 0 }

        if query.full == target.full { return 120 }

        if query.full == target.given || query.full == target.family {
            return 110
        }

        // Require at least 3 chars for prefix matching to avoid noisy matches.
        if query.full.count >= 3 {
            if target.tokens.contains(where: { $0.hasPrefix(query.full) }) {
                return 92
            }
            if target.full.hasPrefix(query.full) {
                return 90
            }
        }

        if query.tokens.count >= 2 {
            let allQueryTokensMatch = query.tokens.allSatisfy { token in
                token.count >= 2 && target.tokens.contains(where: { $0.hasPrefix(token) || $0 == token })
            }
            if allQueryTokensMatch {
                return 100
            }
        }

        return 0
    }

    nonisolated private static func normalizedTokens(from raw: String) -> (
        full: String,
        given: String,
        family: String,
        tokens: [String]
    ) {
        let lowered = raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let compact = lowered
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let parts = compact
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                !honorificTokens.contains(token) && token.count >= 2
            }
        let normalized = parts.joined(separator: " ")
        return (
            full: normalized,
            given: parts.first ?? "",
            family: parts.dropFirst().joined(separator: " "),
            tokens: parts
        )
    }
}

@MainActor
final class BluetoothAccessoryProvider: NSObject, BluetoothContextProviding, @preconcurrency CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var continuation: CheckedContinuation<PermissionState, Never>?

    var authorizationState: PermissionState {
        switch CBCentralManager.authorization {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .allowedAlways: return .authorized
        @unknown default: return .restricted
        }
    }

    func requestAccess() async -> PermissionState {
        if authorizationState != .notDetermined {
            return authorizationState
        }

        manager = CBCentralManager(delegate: self, queue: nil)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func captureNearbyContext() async -> BluetoothContextKind? {
        guard authorizationState == .authorized else {
            return nil
        }

        let route = AVAudioSession.sharedInstance().currentRoute
        let outputs = route.outputs.map { $0.portType }

        if outputs.contains(.carAudio) {
            return .car
        }
        if outputs.contains(.bluetoothA2DP) || outputs.contains(.bluetoothLE) || outputs.contains(.bluetoothHFP) {
            // Assume personal audio routes are usually headphones unless clearly external.
            return .headphones
        }
        if outputs.contains(.airPlay) || outputs.contains(.builtInSpeaker) {
            return .speaker
        }

        return nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if let continuation {
            continuation.resume(returning: authorizationState)
            self.continuation = nil
        }
    }
}
