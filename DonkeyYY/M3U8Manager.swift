import UIKit
import AVFoundation
import CommonCrypto


// MARK: - 简单本地HTTP服务器（用于提供HLS流）
class LocalHLSServer {
    private var listenSocket: Int32 = -1
    private(set) var port: UInt16 = 0
    private let baseURL: URL
    private var isRunning = false
    
    init(baseURL: URL) {
        self.baseURL = baseURL
    }
    
    func start() -> UInt16? {
        listenSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard listenSocket >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindOK = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(self.listenSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { return nil }
        listen(listenSocket, 10)
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actualAddr = sockaddr_in()
        getsockname(listenSocket, UnsafeMutablePointer(&actualAddr), &addrLen)
        port = actualAddr.sin_port.bigEndian
        isRunning = true
        DispatchQueue.global(qos: .background).async { self.acceptLoop() }
        return port
    }
    
    private func acceptLoop() {
        while isRunning {
            let client = accept(listenSocket, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async { self.handle(client) }
        }
    }
    
    private func handle(_ socket: Int32) {
        var req = ""
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(socket, &buf, buf.count, 0)
            if n <= 0 { break }
            req += String(bytes: buf[..<n], encoding: .utf8) ?? ""
            if req.contains("\r\n\r\n") { break }
        }
        let parts = req.components(separatedBy: " ")
        guard parts.count >= 2 else { close(socket); return }
        var path = parts[1].removingPercentEncoding ?? parts[1]
        if path.hasPrefix("/") { path.removeFirst() }
        let fileURL = baseURL.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: fileURL) else {
            let r = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
            send(socket, r, r.utf8.count, 0); close(socket); return
        }
        let ct = path.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp2t"
        let h = "HTTP/1.1 200 OK\r\nContent-Type: \(ct)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        send(socket, h, h.utf8.count, 0)
        data.withUnsafeBytes { send(socket, $0.baseAddress, data.count, 0) }
        close(socket)
    }
    
    func stop() {
        isRunning = false
        if listenSocket >= 0 { close(listenSocket); listenSocket = -1 }
    }
}

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
                let (segments, keyURL, iv, hasExplicitIV) = try self.parseM3U8(content: m3u8Content)
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

                    // AES-128解密（HLS规范：无显式IV时用分片序列号作为IV，大端32位前补0）
                    if let key = key, key.count == 16 {
                        let segIV: Data
                        if hasExplicitIV {
                            segIV = self.hexToData(iv)
                        } else {
                            var ivData = Data(count: 16)
                            ivData[12] = UInt8((index >> 24) & 0xFF)
                            ivData[13] = UInt8((index >> 16) & 0xFF)
                            ivData[14] = UInt8((index >> 8) & 0xFF)
                            ivData[15] = UInt8(index & 0xFF)
                            segIV = ivData
                        }
                        do {
                            segData = try self.aesDecrypt(data: segData, key: key, iv: segIV)
                        } catch {
                            print("Decrypt fail seg \(index): \(error)")
                            do {
                                segData = try self.aesDecryptNoPadding(data: segData, key: key, iv: segIV)
                            } catch {
                                print("Decrypt NoPadding also fail: \(error)")
                            }
                        }
                    }

                    let segFile = workDir.appendingPathComponent(String(format: "seg_%05d.ts", index))
                    try segData.write(to: segFile)
                }

                // 6. 创建本地m3u8播放列表
                self.updateProgress(0.85, message: "创建播放列表...")
                let m3u8File = workDir.appendingPathComponent("local.m3u8")
                var m3u8Str = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n"
                for i in 0..<total {
                    m3u8Str += "#EXTINF:10.0,\nseg_\(String(format: "%05d", i)).ts\n"
                }
                m3u8Str += "#EXT-X-ENDLIST\n"
                try m3u8Str.write(to: m3u8File, atomically: true, encoding: .utf8)

                // 7. 转封装为MP4
                self.updateProgress(0.9, message: "生成MP4...")
                                let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("video_\(Int(Date().timeIntervalSince1970)).mp4")
                let server = LocalHLSServer(baseURL: workDir)
                guard let port = server.start() else {
                    throw NSError(domain: "DonkeyYY", code: 20, userInfo: [NSLocalizedDescriptionKey: "无法启动本地服务器"])
                }
                defer { server.stop() }
                let hlsURL = URL(string: "http://127.0.0.1:\(port)/local.m3u8")!
                print("HLS URL: \(hlsURL)")
                try self.convertHLStoMP4(input: hlsURL, output: outputURL)

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
    private func parseM3U8(content: String) throws -> (segments: [String], keyURL: String?, iv: String, hasExplicitIV: Bool) {
        var segments: [String] = []
        var keyURL: String? = nil
        var iv = "00000000000000000000000000000000"
        var hasExplicitIV = false

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
                        hasExplicitIV = true
                    }
                }
            } else if !trimmed.hasPrefix("#") && trimmed.hasSuffix(".ts") {
                segments.append(trimmed)
            }
        }

        return (segments, keyURL, iv, hasExplicitIV)
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

    // MARK: - HLS转MP4（本地HTTP服务器+AVAssetReader）
    private func convertHLStoMP4(input: URL, output: URL) throws {
        let asset = AVURLAsset(url: input)
        
        // 等待track加载
        let sem = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { sem.signal() }
        sem.wait()
        
        let videoTracks = asset.tracks(withMediaType: .video)
        let audioTracks = asset.tracks(withMediaType: .audio)
        
        print("视频轨: \(videoTracks.count), 音频轨: \(audioTracks.count)")
        
        guard !videoTracks.isEmpty else {
            throw NSError(domain: "DonkeyYY", code: 10, userInfo: [NSLocalizedDescriptionKey: "无视频轨"])
        }
        
        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
        }
        
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else {
            throw NSError(domain: "DonkeyYY", code: 11, userInfo: [NSLocalizedDescriptionKey: "无法创建写入器"])
        }
        
        // 视频
        let videoTrack = videoTracks[0]
        let videoSize = videoTrack.naturalSize
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        if writer.canAdd(videoInput) { writer.add(videoInput) }
        
        // 音频
        var audioInput: AVAssetWriterInput? = nil
        if !audioTracks.isEmpty {
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
        
        // 读取器
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw NSError(domain: "DonkeyYY", code: 12, userInfo: [NSLocalizedDescriptionKey: "无法创建读取器"])
        }
        
        let videoReader = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        if reader.canAdd(videoReader) { reader.add(videoReader) }
        
        var audioReader: AVAssetReaderTrackOutput? = nil
        if !audioTracks.isEmpty {
            audioReader = AVAssetReaderTrackOutput(track: audioTracks[0], outputSettings: nil)
            if let a = audioReader, reader.canAdd(a) { reader.add(a) }
        }
        
        writer.startWriting()
        reader.startReading()
        writer.startSession(atSourceTime: .zero)
        
        let group = DispatchGroup()
        var transcodeError: Error? = nil
        
        group.enter()
        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "vt")) {
            while videoInput.isReadyForMoreMediaData {
                if let s = videoReader.copyNextSampleBuffer() {
                    videoInput.append(s)
                } else {
                    videoInput.markAsFinished()
                    group.leave()
                    break
                }
            }
        }
        
        if let audioInput = audioInput, let audioReader = audioReader {
            group.enter()
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "at")) {
                while audioInput.isReadyForMoreMediaData {
                    if let s = audioReader.copyNextSampleBuffer() {
                        audioInput.append(s)
                    } else {
                        audioInput.markAsFinished()
                        group.leave()
                        break
                    }
                }
            }
        }
        
        group.wait()
        
        if reader.status != .completed { transcodeError = reader.error }
        
        let finishSem = DispatchSemaphore(value: 0)
        writer.finishWriting {
            if writer.status != .completed { transcodeError = writer.error }
            finishSem.signal()
        }
        finishSem.wait()
        
        if let e = transcodeError { throw e }
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
