import CryptoKit
import Foundation

/// Minimal S3 client (AWS Signature Version 4) for Cloudflare R2 and other S3-compatible storage.
/// Uses path-style URLs: <endpoint>/<bucket>/<key>. Payloads are streamed and sent as UNSIGNED-PAYLOAD over HTTPS.
struct S3Client {
    var endpoint: URL
    var bucket: String
    var region: String
    var accessKeyID: String
    var secretAccessKey: String

    enum S3Error: LocalizedError {
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .http(let status, let body):
                let code = body.range(of: "<Code>").flatMap { start in
                    body.range(of: "</Code>").map { String(body[start.upperBound..<$0.lowerBound]) }
                }
                return "HTTP \(status)" + (code.map { " (\($0))" } ?? "")
            case .badResponse:
                return L("The server sent no valid response.")
            }
        }
    }

    /// Uploads a file. `contentDisposition` is stored with the object and sent back on download.
    /// `progress` receives values from 0 to 1.
    func putObject(key: String, fileURL: URL, contentType: String, contentDisposition: String? = nil,
                   progress: (@Sendable (Double) -> Void)? = nil) async throws {
        var headers = ["content-type": contentType, "cache-control": "public, max-age=31536000, immutable"]
        if let contentDisposition { headers["content-disposition"] = contentDisposition }
        var request = signedRequest(method: "PUT", key: key, extraHeaders: headers)
        request.httpMethod = "PUT"
        let delegate = ProgressDelegate(progress: progress)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL, delegate: delegate)
        try check(response, data)
    }

    func deleteObject(key: String) async throws {
        let request = signedRequest(method: "DELETE", key: key, extraHeaders: [:])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw S3Error.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw S3Error.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: Signature V4

    func signedRequest(method: String, key: String, extraHeaders: [String: String], date: Date = Date()) -> URLRequest {
        let path = "/" + Self.encodePath(bucket) + "/" + key.split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.encodePath(String($0)) }.joined(separator: "/")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        let url = components.url!
        let host = components.port.map { "\(components.host ?? ""):\($0)" } ?? (components.host ?? "")

        let signed = Self.sign(method: method, path: path, host: host, headers: extraHeaders, payloadHash: "UNSIGNED-PAYLOAD",
                               accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, region: region, date: date)
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in signed.headers where name != "host" { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(signed.authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    /// AWS Signature Version 4 for one request. Returns all headers to send (incl. x-amz-*) and the Authorization value.
    static func sign(method: String, path: String, query: String = "", host: String, headers extra: [String: String],
                     payloadHash: String, accessKeyID: String, secretAccessKey: String, region: String,
                     date: Date) -> (headers: [String: String], authorization: String, signature: String) {
        let amzDate = format(date, "yyyyMMdd'T'HHmmss'Z'")
        let day = format(date, "yyyyMMdd")
        // Canonical header values are trimmed with inner runs of spaces collapsed; the request sends them the same way.
        var headers = extra.reduce(into: [String: String]()) {
            $0[$1.key.lowercased()] = $1.value.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        }
        headers["host"] = host
        headers["x-amz-content-sha256"] = payloadHash
        headers["x-amz-date"] = amzDate
        let signedNames = headers.keys.sorted()
        let canonicalHeaders = signedNames.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = signedNames.joined(separator: ";")

        let canonicalRequest = [method, path, query, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        for part in [day, region, "s3", "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return (headers, authorization, signature)
    }

    /// RFC 3986 encoding of one path segment (unreserved characters stay).
    static func encodePath(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = pattern
        return f.string(from: date)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
        let progress: (@Sendable (Double) -> Void)?
        init(progress: (@Sendable (Double) -> Void)?) { self.progress = progress }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            progress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        }
    }
}
