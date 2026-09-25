import UIKit
import AVFoundation

// MARK: - TS手动解析转MP4（重新封装，不转码）
class TSToMP4Converter {
    
    static func convert(tsURL: URL, outputURL: URL) throws {
        let tsData = try Data(contentsOf: tsURL)
        guard !tsData.isEmpty else {
            throw NSError(domain: "TSToMP4", code: 1, userInfo: [NSLocalizedDescriptionKey: "TS文件为空"])
        }
        
        // 1. 解析所有TS包
        var packets: [(pid: UInt16, payload: Data)] = []
        var offset = 0
        while offset + 188 <= tsData.count {
            if tsData[offset] == 0x47 {
                let pid = (UInt16(tsData[offset + 1] & 0x1F) << 8) | UInt16(tsData[offset + 2])
                let flags = tsData[offset + 3]
                let hasPayload = (flags & 0x10) != 0
                let hasAdaptation = (flags & 0x20) != 0
                var payloadStart = offset + 4
                if hasAdaptation {
                    let adaptLen = Int(tsData[payloadStart])
                    payloadStart += 1 + adaptLen
                }
                if hasPayload && payloadStart < offset + 188 {
                    let payload = tsData[payloadStart..<(offset + 188)]
                    packets.append((pid, Data(payload)))
                }
            }
            offset += 188
        }
        
        guard !packets.isEmpty else {
            throw NSError(domain: "TSToMP4", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到TS包"])
        }
        
        // 2. 解析PAT获取PMT PID
        var pmtPID: UInt16 = 0
        for packet in packets {
            if packet.pid == 0 {
                let d = packet.payload
                if d.count >= 5 {
                    var idx = 5 // 跳过table_id等
                    while idx + 4 <= d.count {
                        let progNum = (UInt16(d[idx]) << 8) | UInt16(d[idx + 1])
                        if progNum != 0 {
                            pmtPID = (UInt16(d[idx + 2] & 0x1F) << 8) | UInt16(d[idx + 3])
                            break
                        }
                        idx += 4
                    }
                }
                break
            }
        }
        
        guard pmtPID != 0 else {
            throw NSError(domain: "TSToMP4", code: 3, userInfo: [NSLocalizedDescriptionKey: "未找到PMT"])
        }
        
        // 3. 解析PMT获取视频/音频PID
        var videoPID: UInt16 = 0
        var audioPID: UInt16 = 0
        for packet in packets {
            if packet.pid == pmtPID {
                let d = packet.payload
                if d.count >= 12 {
                    let progInfoLen = (Int(d[10] & 0x0F) << 8) | Int(d[11])
                    var idx = 12 + progInfoLen
                    while idx + 5 <= d.count {
                        let streamType = d[idx]
                        let elemPID = (UInt16(d[idx + 1] & 0x1F) << 8) | UInt16(d[idx + 2])
                        let esInfoLen = (Int(d[idx + 3] & 0x0F) << 8) | Int(d[idx + 4])
                        if streamType == 0x1B && videoPID == 0 { // H.264
                            videoPID = elemPID
                        }
                        if (streamType == 0x0F || streamType == 0x11) && audioPID == 0 { // AAC
                            audioPID = elemPID
                        }
                        idx += 5 + esInfoLen
                    }
                }
                break
            }
        }
        
        guard videoPID != 0 else {
            throw NSError(domain: "TSToMP4", code: 4, userInfo: [NSLocalizedDescriptionKey: "未找到视频流"])
        }
        
        // 4. 收集视频和音频PES数据
        var videoPESData = Data()
        var audioPESData = Data()
        for packet in packets {
            if packet.pid == videoPID {
                videoPESData.append(packet.payload)
            } else if packet.pid == audioPID && audioPID != 0 {
                audioPESData.append(packet.payload)
            }
        }
        
        // 5. 解析视频PES，提取H.264 NAL单元
        let h264Data = extractPESPayload(videoPESData)
        let naluUnits = parseH264NALUnits(h264Data)
        
        guard !naluUnits.isEmpty else {
            throw NSError(domain: "TSToMP4", code: 5, userInfo: [NSLocalizedDescriptionKey: "未提取到H.264数据"])
        }
        
        // 6. 提取SPS/PPS
        var spsData: Data?
        var ppsData: Data?
        var videoSamples: [Data] = []
        for nalu in naluUnits {
            let type = nalu[0] & 0x1F
            if type == 7 { spsData = nalu }
            else if type == 8 { ppsData = nalu }
            else if type == 5 || type == 1 || type == 6 {
                videoSamples.append(nalu)
            }
        }
        
        guard let sps = spsData, let pps = ppsData else {
            throw NSError(domain: "TSToMP4", code: 6, userInfo: [NSLocalizedDescriptionKey: "未找到SPS/PPS"])
        }
        
        // 7. 解析音频PES，提取AAC帧
        var aacSamples: [Data] = []
        if audioPID != 0 {
            let aacData = extractPESPayload(audioPESData)
            aacSamples = parseAACFrames(aacData)
        }
        
        // 8. 创建AVAssetWriter
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            throw NSError(domain: "TSToMP4", code: 7, userInfo: [NSLocalizedDescriptionKey: "无法创建写入器"])
        }
        
        // 视频格式描述
        let videoSize = parseSPSResolution(sps: sps)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        if writer.canAdd(videoInput) { writer.add(videoInput) }
        
        // 音频格式描述
        var audioInput: AVAssetWriterInput? = nil
        if !aacSamples.isEmpty {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128000
            ]
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = false
            if let a = audioInput, writer.canAdd(a) { writer.add(a) }
        }
        
        // 9. 创建format description
        let parameterSet = [sps, pps]
        guard let videoFormatDesc = createVideoFormatDescription(sps: sps, pps: pps) else {
            throw NSError(domain: "TSToMP4", code: 8, userInfo: [NSLocalizedDescriptionKey: "无法创建视频格式描述"])
        }
        
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        // 10. 写入视频样本
        let videoGroup = DispatchGroup()
        videoGroup.enter()
        var videoTime = CMTime.zero
        let frameDuration = CMTime(value: 1, timescale: 30)
        
        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "video_write")) {
            while videoInput.isReadyForMoreMediaData && !videoSamples.isEmpty {
                let nalu = videoSamples.removeFirst()
                // Annex B -> AVCC (4字节长度前缀)
                var avccData = Data(count: 4)
                avccData[0] = UInt8((nalu.count >> 24) & 0xFF)
                avccData[1] = UInt8((nalu.count >> 16) & 0xFF)
                avccData[2] = UInt8((nalu.count >> 8) & 0xFF)
                avccData[3] = UInt8(nalu.count & 0xFF)
                avccData.append(nalu)
                
                if let sampleBuffer = createSampleBuffer(data: avccData, formatDesc: videoFormatDesc, presentationTime: videoTime, duration: frameDuration) {
                    videoInput.append(sampleBuffer)
                }
                videoTime = CMTimeAdd(videoTime, frameDuration)
            }
            if videoSamples.isEmpty {
                videoInput.markAsFinished()
                videoGroup.leave()
            }
        }
        
        // 11. 写入音频样本
        let audioGroup = DispatchGroup()
        if let audioInput = audioInput, !aacSamples.isEmpty {
            audioGroup.enter()
            var audioTime = CMTime.zero
            guard let audioFormatDesc = createAudioFormatDescription() else {
                audioInput.markAsFinished()
                audioGroup.leave()
                return
            }
            
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audio_write")) {
                while audioInput.isReadyForMoreMediaData && !aacSamples.isEmpty {
                    let frame = aacSamples.removeFirst()
                    if let sampleBuffer = createSampleBuffer(data: frame, formatDesc: audioFormatDesc, presentationTime: audioTime, duration: CMTime(value: 1024, timescale: 44100)) {
                        audioInput.append(sampleBuffer)
                    }
                    audioTime = CMTimeAdd(audioTime, CMTime(value: 1024, timescale: 44100))
                }
                if aacSamples.isEmpty {
                    audioInput.markAsFinished()
                    audioGroup.leave()
                }
            }
        }
        
        videoGroup.wait()
        if !aacSamples.isEmpty { audioGroup.wait() }
        
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting {
            sem.signal()
        }
        sem.wait()
        
        if writer.status != .completed {
            throw NSError(domain: "TSToMP4", code: 9, userInfo: [NSLocalizedDescriptionKey: "写入失败: \(writer.error?.localizedDescription ?? "unknown")"])
        }
    }
    
    // MARK: - 辅助方法
    
    private static func extractPESPayload(_ data: Data) -> Data {
        var result = Data()
        var offset = 0
        while offset + 9 <= data.count {
            // 查找PES起始码 00 00 01
            if data[offset] == 0 && data[offset + 1] == 0 && data[offset + 2] == 1 {
                let streamID = data[offset + 3]
                let pesLen = (Int(data[offset + 4]) << 8) | Int(data[offset + 5])
                if offset + 6 + pesLen <= data.count {
                    // 跳过PES头
                    let headerDataLen = Int(data[offset + 8])
                    let payloadStart = offset + 9 + headerDataLen
                    if payloadStart < offset + 6 + pesLen {
                        result.append(data[payloadStart..<(offset + 6 + pesLen)])
                    }
                    offset += 6 + pesLen
                    continue
                }
            }
            offset += 1
        }
        return result
    }
    
    private static func parseH264NALUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        var offset = 0
        while offset < data.count {
            // 查找起始码 00 00 00 01 或 00 00 01
            var startCodeLen = 0
            if offset + 4 <= data.count && data[offset] == 0 && data[offset + 1] == 0 && data[offset + 2] == 0 && data[offset + 3] == 1 {
                startCodeLen = 4
            } else if offset + 3 <= data.count && data[offset] == 0 && data[offset + 1] == 0 && data[offset + 2] == 1 {
                startCodeLen = 3
            }
            if startCodeLen > 0 {
                let naluStart = offset + startCodeLen
                var naluEnd = data.count
                // 查找下一个起始码
                var searchPos = naluStart
                while searchPos + 3 <= data.count {
                    if (data[searchPos] == 0 && data[searchPos + 1] == 0 && data[searchPos + 2] == 1) ||
                       (searchPos + 4 <= data.count && data[searchPos] == 0 && data[searchPos + 1] == 0 && data[searchPos + 2] == 0 && data[searchPos + 3] == 1) {
                        naluEnd = searchPos
                        break
                    }
                    searchPos += 1
                }
                if naluEnd > naluStart {
                    units.append(data[naluStart..<naluEnd])
                }
                offset = naluEnd
            } else {
                offset += 1
            }
        }
        return units
    }
    
    private static func parseAACFrames(_ data: Data) -> [Data] {
        var frames: [Data] = []
        var offset = 0
        while offset + 7 <= data.count {
            // ADTS头: 0xFF 0xFx
            if data[offset] == 0xFF && (data[offset + 1] & 0xF0) == 0xF0 {
                let frameLen = (Int(data[offset + 3] & 0x03) << 11) | (Int(data[offset + 4]) << 3) | (Int(data[offset + 5] >> 5))
                if frameLen > 7 && offset + frameLen <= data.count {
                    // 去掉ADTS头(7字节)，只保留AAC raw数据
                    frames.append(data[(offset + 7)..<(offset + frameLen)])
                    offset += frameLen
                    continue
                }
            }
            offset += 1
        }
        return frames
    }
    
    private static func parseSPSResolution(sps: Data) -> (width: Int, height: Int) {
        // 简化：从SPS解析分辨率，默认720x1280
        // 实际项目中应完整解析SPS
        return (720, 1280)
    }
    
    private static func createVideoFormatDescription(sps: Data, pps: Data) -> CMFormatDescription? {
        var formatDesc: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsPtr -> OSStatus in
            pps.withUnsafeBytes { ppsPtr -> OSStatus in
                let spsUInt8 = spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let ppsUInt8 = ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let pointers = [spsUInt8, ppsUInt8]
                let sizes = [sps.count, pps.count]
                var formatDescOut: CMFormatDescription?
                let result = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescOut
                )
                formatDesc = formatDescOut
                return result
            }
        }
        return status == noErr ? formatDesc : nil
    }
    
    private static func createAudioFormatDescription() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        return formatDesc
    }
    
    private static func createSampleBuffer(data: Data, formatDesc: CMFormatDescription, presentationTime: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = data.withUnsafeBytes { ptr -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: ptr.baseAddress!),
                blockLength: data.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: data.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard status == noErr, let bb = blockBuffer else { return nil }
        
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(duration: duration, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }
}
