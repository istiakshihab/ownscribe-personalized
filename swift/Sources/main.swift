import AVFAudio
import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit

// MARK: - Main

func printUsage() {
    fputs("""
    ownscribe-audio — system audio capture helper

    USAGE:
        ownscribe-audio capture --output FILE [--mic] [--mic-device NAME] [--avoid-bluetooth-mic]
                                [--capture-mode-all] [--silence-timeout N]
        ownscribe-audio capture --session DIR --control stdio [--mic|--no-mic] [--mic-auto|--mic-default]
                                [--mic-device UID] [--app BUNDLE_ID]... [--exclude-bundle BUNDLE_ID]...
                                [--silence-timeout N] [--source test-tone]
        ownscribe-audio merge --session DIR
        ownscribe-audio list-apps [--json]
        ownscribe-audio list-devices [--json]

    SESSION MODE (docs/engine-protocol.md):
        JSON commands on stdin, JSON events on stdout; per-source tracks in DIR/tracks,
        capture.json, and the mixdown in DIR/recording.wav. --source test-tone needs no permissions.

    OPTIONS:
        --output, -o FILE    Output WAV file path (required for capture)
        --mic                Also capture microphone input
        --mic-device NAME    Use specific mic input device (implies --mic)
        --avoid-bluetooth-mic
                             With --mic and no --mic-device: when the default input is a
                             Bluetooth headset, record the built-in mic instead
        --capture-mode-all   Capture all system audio without showing the source picker
        --silence-timeout N  Auto-stop after N seconds of silence (0 = disabled)
        --help, -h           Show this help

    SUBCOMMANDS:
        capture              Record audio to a WAV file
        list-apps            Show running applications
        list-devices         Show available audio input devices

    """, stderr)
}

func main() {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        printUsage()
        exit(1)
    }

    let command = args[1]

    switch command {
    case "list-apps":
        if args.contains("--json") { listAppsJSON() } else { listAudioApps() }

    case "list-devices":
        if args.contains("--json") { listDevicesJSON() } else { listInputDevices() }

    case "capture" where args.contains("--session"):
        runSessionCapture(Array(args.dropFirst(2)))

    case "merge":
        runMergeCommand(Array(args.dropFirst(2)))

    case "capture":
        // The Python wrapper reads our stderr through a pipe. If it goes away (a second
        // Ctrl+C, a crash), the next write would raise SIGPIPE and kill us mid-merge,
        // losing the recording. Ignore it: writes then just fail with EPIPE.
        signal(SIGPIPE, SIG_IGN)

        // Initialize NSApplication so the picker GUI can render
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var outputPath: String?
        var enableMic = false
        var micDeviceName: String?
        var avoidBluetoothMic = false
        var captureModeAll = false
        var silenceTimeout: TimeInterval = 0

        var i = 2
        while i < args.count {
            switch args[i] {
            case "--output", "-o":
                i += 1
                guard i < args.count else {
                    fputs("Error: --output requires a file path\n", stderr)
                    exit(1)
                }
                outputPath = args[i]
            case "--capture-mode-all":
                captureModeAll = true
            case "--mic":
                enableMic = true
            case "--mic-device":
                i += 1
                guard i < args.count else {
                    fputs("Error: --mic-device requires a device name\n", stderr)
                    exit(1)
                }
                micDeviceName = args[i]
                enableMic = true  // --mic-device implies --mic
            case "--avoid-bluetooth-mic":
                avoidBluetoothMic = true
            case "--silence-timeout":
                i += 1
                guard i < args.count, let val = TimeInterval(args[i]) else {
                    fputs("Error: --silence-timeout requires a number of seconds\n", stderr)
                    exit(1)
                }
                if val < 0 {
                    fputs("Error: --silence-timeout must be zero (disabled) or a positive number of seconds\n", stderr)
                    exit(1)
                }
                silenceTimeout = val
            default:
                fputs("Unknown option: \(args[i])\n", stderr)
                printUsage()
                exit(1)
            }
            i += 1
        }

        guard let output = outputPath else {
            fputs("Error: --output is required\n", stderr)
            printUsage()
            exit(1)
        }

        // Determine paths: if mic enabled, use temp files then merge
        let systemPath = enableMic ? output + ".sys.tmp.wav" : output
        let micPath = output + ".mic.tmp.wav"

        let capture = SystemAudioCapture(outputPath: systemPath)
        capture.captureModeAll = captureModeAll
        capture.silenceTimeout = silenceTimeout
        var micCapture: MicCapture?

        // Host time before either track can start: the merge rejects any track start
        // time earlier than this (or 0, meaning the track never delivered audio).
        let sessionStartHostTime = mach_absolute_time()

        // Shared shutdown logic for SIGINT, SIGTERM, the silence timeout and a cancelled
        // picker. All of them arrive on .main; only the first one may run.
        var shuttingDown = false
        let shutdown: () -> Void = {
            guard !shuttingDown else { return }
            shuttingDown = true
            capture.stop()
            if let mic = micCapture {
                mic.stop()
                do {
                    try mergeAudioFiles(
                        systemPath: systemPath,
                        micPath: micPath,
                        systemStartHostTime: capture.startHostTime,
                        micStartHostTime: mic.startHostTime,
                        sessionStartHostTime: sessionStartHostTime,
                        outputPath: output)
                } catch {
                    fputs("Error merging audio: \(error)\n", stderr)
                }
            }
            exit(0)
        }

        capture.onSilenceTimeout = shutdown
        capture.onCancel = shutdown

        // Handle Ctrl+C gracefully. Installed before the mic starts, so an early SIGINT
        // can't hit the default action and kill the process with nothing saved.
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigintSource.setEventHandler { shutdown() }
        sigintSource.resume()

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        sigtermSource.setEventHandler { shutdown() }
        sigtermSource.resume()

        if enableMic {
            let selection: MicCapture.Selection
            if let name = micDeviceName {
                selection = .named(name)
            } else if avoidBluetoothMic {
                selection = .avoidBluetooth
            } else {
                selection = .systemDefault
            }
            let mic = MicCapture(selection: selection)
            do {
                try mic.start(outputPath: micPath)
            } catch {
                fputs("Error starting mic capture: \(error)\n", stderr)
                exit(1)
            }
            micCapture = mic
            capture.micCapture = mic
        }

        // Toggle mic mute on SIGUSR1 (sent by Python wrapper)
        var _sigusr1Source: DispatchSourceSignal?  // retained to keep source alive
        if let mic = micCapture {
            signal(SIGUSR1, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            src.setEventHandler { mic.toggleMute() }
            src.resume()
            _sigusr1Source = src
        }
        _ = _sigusr1Source

        Task {
            do {
                try await capture.start()
            } catch {
                fputs("Error: \(error)\n", stderr)
                exit(1)
            }
        }

        app.run()

    case "--help", "-h":
        printUsage()

    default:
        fputs("Unknown command: \(command)\n", stderr)
        printUsage()
        exit(1)
    }
}

main()
