import AVFAudio
import Foundation

private func printJSON(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// `list-devices --json`: input devices for the mic picker.
func listDevicesJSON() {
    let defaultDevice = defaultInputDevice()
    let devices: [[String: Any]] = audioDeviceIDs().compactMap { id in
        let channels = inputChannelCount(id)
        guard channels > 0 else { return nil }
        return ["uid": deviceUID(id) ?? "", "name": deviceName(id), "transport": transportLabel(id),
                "sample_rate": Int(nominalSampleRate(id)), "channels": channels, "default": id == defaultDevice]
    }
    printJSON(["devices": devices])
}

/// `list-apps --json`: running apps that can be given their own source, flagged when playing audio.
func listAppsJSON() {
    let playing = Set(audioProcessObjects().filter(\.isPlaying).map(\.bundleID))
    let apps: [[String: Any]] = runningApps().map { app in
        let isPlaying = playing.contains { $0 == app.bundleID || $0.hasPrefix(app.bundleID + ".") }
        return ["bundle_id": app.bundleID, "name": app.name, "pid": Int(app.pid), "playing": isPlaying]
    }
    printJSON(["apps": apps])
}

/// `merge --session DIR`: rebuild recording.wav from capture.json (e.g. after a crash).
func runMergeCommand(_ args: [String]) -> Never {
    guard let index = args.firstIndex(of: "--session"), index + 1 < args.count else {
        fputs("Usage: ownscribe-audio merge --session DIR\n", stderr)
        exit(64)
    }
    let dir = URL(fileURLWithPath: (args[index + 1] as NSString).expandingTildeInPath)
    do {
        var manifest = try CaptureManifest.load(from: dir)
        let result = try mergeSession(at: dir, manifest: manifest)
        guard let recording = result.recording else {
            fputs("No track in \(dir.path) has any audio.\n", stderr)
            exit(1)
        }
        manifest.recording = recording.lastPathComponent
        if manifest.duration == nil { manifest.duration = Double(result.frames) / kTrackSampleRate }
        manifest.status = result.skippedTracks.isEmpty ? "saved" : "partial"
        try manifest.save(to: dir)
        printJSON(["recording": recording.path, "tracks": result.mergedTracks, "skipped": result.skippedTracks,
                   "duration": Double(result.frames) / kTrackSampleRate])
        exit(result.skippedTracks.isEmpty ? 0 : 2)
    } catch {
        fputs("Merge failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
