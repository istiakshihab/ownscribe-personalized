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

// MARK: - Constants

/// Minimum peak amplitude to consider microphone audio "loud" (silence timeout).
let kMicLoudThreshold: Float = 1e-2
/// Minimum peak amplitude to consider system audio "loud" (silence timeout).
let kSystemLoudThreshold: Float = 1e-4
/// System audio capture and merge output sample rate (mono float32).
let kSystemAudioSampleRate: Double = 24000
/// Seconds of nothing but digital silence before the mic is reported as dead.
let kMicSilentAfter: Double = 5

/// Compute peak amplitude across all channels of float audio data.
func computePeakLevel(in channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
               channels: Int, frames: Int) -> Float {
    var peak: Float = 0
    for ch in 0..<channels {
        for i in 0..<frames {
            let v = abs(channelData[ch][i])
            if v > peak { peak = v }
        }
    }
    return peak
}
