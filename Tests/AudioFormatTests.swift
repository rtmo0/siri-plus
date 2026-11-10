import AVFoundation
import CoreMedia
import Testing
@testable import SiriPlusCore

struct AudioFormatTests {
    /// Interleaved Float32 samples with `channels` channels and no channel layout, as a voice-processed microphone
    /// may deliver them; channel 0 holds 0.5, the others -0.25.
    private func sampleBuffer(channels: UInt32, frames: Int) throws -> CMSampleBuffer {
        var stream = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &stream, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                               magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        var samples = [Float](repeating: -0.25, count: frames * Int(channels))
        for frame in 0..<frames { samples[frame * Int(channels)] = 0.5 }
        let length = samples.count * 4
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr)
        let blockBuffer = try #require(block)
        samples.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: length)
        }
        var sample: CMSampleBuffer?
        #expect(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: blockBuffer, formatDescription: try #require(description),
                                                                     sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    @Test func manyChannelsWithoutALayoutBecomeTheFirstChannel() throws {
        let buffer = try #require(try sampleBuffer(channels: 4, frames: 480).pcmBuffer())
        #expect(buffer.format.channelCount == 1)
        #expect(buffer.frameLength == 480)
        let first = try #require(buffer.floatChannelData)[0]
        #expect((0..<480).allSatisfy { first[$0] == 0.5 })
    }

    @Test func monoAndStereoStayAsTheyAre() throws {
        let mono = try #require(try sampleBuffer(channels: 1, frames: 100).pcmBuffer())
        #expect(mono.format.channelCount == 1)
        let stereo = try #require(try sampleBuffer(channels: 2, frames: 100).pcmBuffer())
        #expect(stereo.format.channelCount == 2)
        #expect(stereo.frameLength == 100)
    }

    @Test func formatsThatAreNotPCMAreSkipped() throws {
        var stream = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                                 mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var description: CMAudioFormatDescription?
        _ = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &stream, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        #expect(CMSampleBuffer.pcmFormat(of: try #require(description)) == nil)
    }
}
