import UIKit
import AVFoundation
import CommonCrypto

class M3U8Manager {

    static let shared = M3U8Manager()

    private init() {}

    var progressView: UIAlertController?

    func downloadAndConvert(m3u8URL: String, from viewController: UIViewController, completion: @escaping (Result<URL, Error>) -> Void) {

        // 显示进度
        let alert = UIAlertController(title: "正在下载转换", message: "准备中...", preferredStyle: .alert)
        let progressView = UIProgressView(progressViewStyle: .default)
        progressView.frame = CGRect(x: 20, y: 70, width: 240, height: 2)
        progressView.progress = 0
        alert.view.addSubview(progressView)
        viewController.present(alert, animated: true)
        self.progressView = alert

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 1. 下载m3u8
                self.updateProgress(0, message: "下载m3u8索引...")
                guard let m3u8Content = try self.downloadString(url: m3u8URL) else {
                    throw NSError(domain: "DonkeyYY", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法下载m3u8文件"])
                }
                print("m3u8 content: \(m3u8Content.prefix(500))")

                // 2. 解析m3u8
                let (segments, keyURL, iv) = try self.parseM3U8(content: m3u8Content)
                print("Segments: \(segments.count), keyURL: \(keyURL ?? "none"), iv: \(iv)")

                if segments.isEmpty {
                    throw NSError(domain: "DonkeyYY", code: 2, userInfo: [NSLocalizedDescriptionKey: "m3u8中没有找到分片"])
                }

                // 3. 下载密钥
                var key: Data? = nil
                if let keyURL = keyURL {
                    let fullKeyURL = keyURL.hasPrefix("http") ? keyURL : self.resolveURL(base: m3u8URL, relative: keyURL)
                    key = try self.downloadData(url: fullKeyURL)
                    print("Key: \(key?.count ?? 0) bytes")
                }

                // 4. 创建工作目录
                let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("m3u8_work_\(Int(Date().timeIntervalSince1970))")
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

                // 5. 下载并解密分片
                let baseURL = m3u8URL.hasSuffix("/") ? m3u8URL : String(m3u8URL.prefix(m3u8URL.lastIndex(of: "/")!.utf16Offset(in: m3u8URL) + 1))
                let total = segments.count

                for (index, segName) in segments.enumerated() {
                    let segURL = segName.hasPrefix("http") ? segName : baseURL + segName

                    self.updateProgress(Float(index) / Float(total) * 0.8, message: "下载分片 \(index + 1)/\(total)")

                    guard var segData = try self.downloadData(url: segURL) else {
                        throw NSError(domain: "DonkeyYY", code: 3, userInfo: [NSLocalizedDescriptionKey: "分片下载失败: \(segName)"])
                    }

                    // AES-128解密
                    if let key = key, key.count == 16 {
                        do {
                            segData = try self.aesDecrypt(data: segData, key: key, iv: self.hexToData(iv))
                        } catch {
                            print("Decrypt fail seg \(index): \(error)")
                            // 尝试NoPadding
                            do {
                                segData = try self.aesDecryptNoPadding(data: segData, key: key, iv: self.hexToData(iv))
                            } catch {
                                print("Decrypt NoPadding also fail: \(error)")
                            }
                        }
                    }

                    let segFile = workDir.appendingPathComponent(String(format: "seg_%05d.ts", index))
                    try segData.write(to: segFile)
                }

                // 6. 合并分片
                self.updateProgress(0.85, message: "合并分片...")
                let mergedTS = workDir.appendingPathComponent("merged.ts")
                FileManager.default.createFile(atPath: mergedTS.path, contents: nil)
                let mergeHandle = try FileHandle(forWritingTo: mergedTS)
                for i in 0..<total {
                    let segFile = workDir.appendingPathComponent(String(format: "seg_%05d.ts", i))
                    let segData = try Data(contentsOf: segFile)
                    mergeHandle.write(segData)
                }
                try mergeHandle.close()

                // 7. 转封装为MP4
                self.updateProgress(0.9, message: "生成MP4...")
                let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("video_\(Int(Date().timeIntervalSince1970)).mp4")

                try self.convertTStoMP4(input: mergedTS, output: outputURL)

                self.updateProgress(1.0, message: "完成!")
                Thread.sleep(forTimeInterval: 0.3)

                DispatchQueue.main.async {
                    alert.dismiss(animated: true) {
                        completion(.success(outputURL))
                    }
                }

            } catch {
                print("Error: \(error)")
                DispatchQueue.main.async {
                    alert.dismiss(animated: true) {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    private func updateProgress(_ progress: Float, message: String) {
        DispatchQueue.main.async {
            self.progressView?.message = message
            if let progressView = self.progressView?.view.subviews.first(where: { $0 is UIProgressView }) as? UIProgressView {
                progressView.progress = progress
            }
        }
    }

    // MARK: - 解析m3u8
    private func parseM3U8(content: String) throws -> (segments: [String], keyURL: String?, iv: String) {
        var segments: [String] = []
        var keyURL: String? = nil
        var iv = "00000000000000000000000000000000"

        let lines = content.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("#EXT-X-KEY") {
                // 提取URI
                if let uriRange = trimmed.range(of: "URI=\"") {
                    let rest = String(trimmed[uriRange.upperBound...])
                    if let endRange = rest.range(of: "\"") {
                        keyURL = String(rest[..<endRange.lowerBound])
                    }
                }
                // 提取IV
                if let ivRange = trimmed.range(of: "IV=0x") {
                    let ivStr = String(trimmed[ivRange.upperBound...])
                    let hexChars = ivStr.prefix(while: { $0.isHexDigit })
                    if !hexChars.isEmpty {
                        iv = String(hexChars)
                    }
                }
            } else if !trimmed.hasPrefix("#") && trimmed.hasSuffix(".ts") {
                segments.append(trimmed)
            }
        }

        return (segments, keyURL, iv)
    }

    // MARK: - AES解密
    private func aesDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        let dataLength = data.count
        let bufferSize = dataLength + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesDecrypted = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    buffer.withUnsafeMutableBytes { bufferBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            dataLength,
                            bufferBytes.baseAddress,
                            bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw NSError(domain: "AES", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "AES解密失败"])
        }

        return buffer.prefix(numBytesDecrypted)
    }

    private func aesDecryptNoPadding(data: Data, key: Data, iv: Data) throws -> Data {
        let dataLength = data.count
        let bufferSize = dataLength + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesDecrypted = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    buffer.withUnsafeMutableBytes { bufferBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0), // NoPadding
                            keyBytes.baseAddress,
                            kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            dataLength,
                            bufferBytes.baseAddress,
                            bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw NSError(domain: "AES", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "AES解密失败(NoPadding)"])
        }

        return buffer.prefix(numBytesDecrypted)
    }

    // MARK: - TS转MP4（AVAssetReader+Writer手动转码）
    private func convertTStoMP4(input: URL, output: URL) throws {
        let asset = AVURLAsset(url: input)
        
        // 等待track加载
        let sem = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { sem.signal() }
        sem.wait()
        
        let videoTracks = asset.tracks(withMediaType: .video)
        let audioTracks = asset.tracks(withMediaType: .audio)
        
        guard !videoTracks.isEmpty else {
            throw NSError(domain: "DonkeyYY", code: 10, userInfo: [NSLocalizedDescriptionKey: "无视频轨"])
        }
        
        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
        }
        
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else {
            throw NSError(domain: "DonkeyYY", code: 11, userInfo: [NSLocalizedDescriptionKey: "无法创建写入器"])
        }
        
        // 视频写入配置
        let videoTrack = videoTracks[0]
        let videoSize = videoTrack.naturalSize
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height
        ]
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = false
        if writer.canAdd(videoWriterInput) { writer.add(videoWriterInput) }
        
        // 音频写入配置
        var audioWriterInput: AVAssetWriterInput? = nil
        if !audioTracks.isEmpty {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128000
            ]
            audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioWriterInput?.expectsMediaDataInRealTime = false
            if let a = audioWriterInput, writer.canAdd(a) { writer.add(a) }
        }
        
        // 创建读取器
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw NSError(domain: "DonkeyYY", code: 12, userInfo: [NSLocalizedDescriptionKey: "无法创建读取器"])
        }
        
        let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        if reader.canAdd(videoReaderOutput) { reader.add(videoReaderOutput) }
        
        var audioReaderOutput: AVAssetReaderTrackOutput? = nil
        if !audioTracks.isEmpty {
            audioReaderOutput = AVAssetReaderTrackOutput(track: audioTracks[0], outputSettings: nil)
            if let a = audioReaderOutput, reader.canAdd(a) { reader.add(a) }
        }
        
        writer.startWriting()
        reader.startReading()
        writer.startSession(atSourceTime: .zero)
        
        let group = DispatchGroup()
        var transcodeError: Error? = nil
        
        // 视频转码
        group.enter()
        videoWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "video_transcode")) {
            while videoWriterInput.isReadyForMoreMediaData {
                if let sample = videoReaderOutput.copyNextSampleBuffer() {
                    videoWriterInput.append(sample)
                } else {
                    videoWriterInput.markAsFinished()
                    group.leave()
                    break
                }
            }
        }
        
        // 音频转码
        if let audioWriterInput = audioWriterInput, let audioReaderOutput = audioReaderOutput {
            group.enter()
            audioWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audio_transcode")) {
                while audioWriterInput.isReadyForMoreMediaData {
                    if let sample = audioReaderOutput.copyNextSampleBuffer() {
                        audioWriterInput.append(sample)
                    } else {
                        audioWriterInput.markAsFinished()
                        group.leave()
                        break
                    }
                }
            }
        }
        
        group.wait()
        
        if reader.status != .completed {
            transcodeError = reader.error
        }
        
        let finishSem = DispatchSemaphore(value: 0)
        writer.finishWriting {
            if writer.status != .completed {
                transcodeError = writer.error
            }
            finishSem.signal()
        }
        finishSem.wait()
        
        if let error = transcodeError {
            throw error
        }
        if writer.status != .completed {
            throw NSError(domain: "DonkeyYY", code: 13, userInfo: [NSLocalizedDescriptionKey: "写入失败"])
        }
    }

    // MARK: - 网络请求
    private func downloadString(url: String) throws -> String? {
        guard let data = try downloadData(url: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func downloadData(url: String) throws -> Data? {
        guard let urlObj = URL(string: url) else { return nil }

        var request = URLRequest(url: urlObj)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://duys.k2sw9ni.live/", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data? = nil
        var resultError: Error? = nil

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                resultError = error
            } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                resultError = NSError(domain: "HTTP", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
            } else {
                resultData = data
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = resultError {
            throw error
        }
        return resultData
    }

    // MARK: - 工具方法
    private func resolveURL(base: String, relative: String) -> String {
        if relative.hasPrefix("http") { return relative }
        if relative.hasPrefix("//") { return "https:" + relative }
        if relative.hasPrefix("/") {
            if let url = URL(string: base), let host = url.host {
                return "\(url.scheme ?? "https")://\(host)\(relative)"
            }
        }
        let baseDir = base.hasSuffix("/") ? base : String(base.prefix(upTo: base.lastIndex(of: "/")!))
        return baseDir + "/" + relative
    }

    private func hexToData(_ hex: String) -> Data {
        var data = Data()
        var hexStr = hex
        if hexStr.count % 2 != 0 { hexStr = "0" + hexStr }
        var index = hexStr.startIndex
        while index < hexStr.endIndex {
            let nextIndex = hexStr.index(index, offsetBy: 2)
            let byteString = String(hexStr[index..<nextIndex])
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        return data
    }
}
