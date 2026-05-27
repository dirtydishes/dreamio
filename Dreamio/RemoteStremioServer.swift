import Foundation

enum RemoteStremioServerURLValidationError: LocalizedError, Equatable {
    case empty
    case unsupportedScheme(String)
    case missingHost
    case containsCredentials
    case containsQueryOrFragment
    case insecureRemoteHTTP(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter the base URL for your Stremio Server."
        case let .unsupportedScheme(scheme):
            return "Stremio Server URLs must use http or https, not \(scheme)."
        case .missingHost:
            return "The Stremio Server URL needs a host name or IP address."
        case .containsCredentials:
            return "Do not include usernames, passwords, or tokens in the Stremio Server URL."
        case .containsQueryOrFragment:
            return "Use the Stremio Server base URL only, without query strings or fragments."
        case let .insecureRemoteHTTP(host):
            return "HTTP is only accepted automatically for localhost or private-network addresses. Use HTTPS for \(host), or explicitly allow insecure HTTP."
        }
    }
}

struct RemoteStremioServerConfiguration: Equatable {
    static let streamingServerQueryItem = "streamingServerUrl"

    let baseURL: URL

    init(input: String, allowInsecureRemoteHTTP: Bool = false) throws {
        baseURL = try Self.normalizedURL(from: input, allowInsecureRemoteHTTP: allowInsecureRemoteHTTP)
    }

    static func normalizedURL(from input: String, allowInsecureRemoteHTTP: Bool = false) throws -> URL {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw RemoteStremioServerURLValidationError.empty
        }

        if !value.contains("://") {
            value = "https://\(value)"
        }

        guard var components = URLComponents(string: value) else {
            throw RemoteStremioServerURLValidationError.missingHost
        }

        let scheme = components.scheme?.lowercased() ?? ""
        guard ["http", "https"].contains(scheme) else {
            throw RemoteStremioServerURLValidationError.unsupportedScheme(scheme.isEmpty ? "missing scheme" : scheme)
        }
        components.scheme = scheme

        guard let host = components.host, !host.isEmpty else {
            throw RemoteStremioServerURLValidationError.missingHost
        }

        guard components.user == nil, components.password == nil else {
            throw RemoteStremioServerURLValidationError.containsCredentials
        }

        guard components.query == nil, components.fragment == nil else {
            throw RemoteStremioServerURLValidationError.containsQueryOrFragment
        }

        if scheme == "http", !isLocalOrPrivateHost(host), !allowInsecureRemoteHTTP {
            throw RemoteStremioServerURLValidationError.insecureRemoteHTTP(host)
        }

        if components.path.isEmpty {
            components.path = "/"
        } else if !components.path.hasSuffix("/") {
            components.path += "/"
        }

        guard let url = components.url else {
            throw RemoteStremioServerURLValidationError.missingHost
        }

        return url
    }

    static func stremioWebURL(baseURL: URL, serverURL: URL?) -> URL {
        guard let serverURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            return baseURL
        }

        var queryItems = components.queryItems?.filter { $0.name != streamingServerQueryItem } ?? []
        queryItems.append(URLQueryItem(name: streamingServerQueryItem, value: serverURL.absoluteString))
        components.queryItems = queryItems
        return components.url ?? baseURL
    }

    static func settingsEndpoint(for serverURL: URL) -> URL {
        serverURL.appendingPathComponent("settings")
    }

    static func redactedDisplayString(for serverURL: URL?) -> String {
        guard let serverURL,
              var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        else {
            return "Not configured"
        }

        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? "Configured server"
    }

    static func isLocalOrPrivateHost(_ host: String) -> Bool {
        let lowercased = host.lowercased()
        if lowercased == "localhost" || lowercased == "::1" || lowercased == "[::1]" {
            return true
        }

        if lowercased.hasPrefix("fe80:") || lowercased.hasPrefix("fc") || lowercased.hasPrefix("fd") {
            return true
        }

        let octets = lowercased.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return false
        }

        if octets[0] == 10 || octets[0] == 127 {
            return true
        }
        if octets[0] == 192, octets[1] == 168 {
            return true
        }
        if octets[0] == 172, (16...31).contains(octets[1]) {
            return true
        }
        return false
    }
}

struct RemoteStremioServerStore {
    static let storageKey = "Dreamio.RemoteStremioServer.baseURL"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var serverURL: URL? {
        guard let value = userDefaults.string(forKey: Self.storageKey),
              let url = try? RemoteStremioServerConfiguration.normalizedURL(
                from: value,
                allowInsecureRemoteHTTP: true
              )
        else {
            return nil
        }
        return url
    }

    func save(serverURL: URL) {
        userDefaults.set(serverURL.absoluteString, forKey: Self.storageKey)
    }

    func clear() {
        userDefaults.removeObject(forKey: Self.storageKey)
    }
}

struct RemoteStremioServerValidationSummary: Equatable {
    let serverURL: URL
    let settingsEndpoint: URL
    let serverVersion: String
    let reportedBaseURL: URL?
    let hasTranscodingSetting: Bool
}

enum RemoteStremioServerValidationError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case missingServerVersion

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server did not return a valid Stremio Server settings response."
        case let .httpStatus(status):
            return "The Stremio Server settings endpoint returned HTTP \(status)."
        case .missingServerVersion:
            return "The settings response did not include a Stremio Server version."
        }
    }
}

final class RemoteStremioServerValidator {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validate(serverURL: URL) async throws -> RemoteStremioServerValidationSummary {
        let endpoint = RemoteStremioServerConfiguration.settingsEndpoint(for: serverURL)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteStremioServerValidationError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw RemoteStremioServerValidationError.httpStatus(httpResponse.statusCode)
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = payload["values"] as? [String: Any]
        else {
            throw RemoteStremioServerValidationError.invalidResponse
        }
        guard let serverVersion = values["serverVersion"] as? String, !serverVersion.isEmpty else {
            throw RemoteStremioServerValidationError.missingServerVersion
        }

        let reportedBaseURL = (payload["baseUrl"] as? String).flatMap(URL.init(string:))
        return RemoteStremioServerValidationSummary(
            serverURL: serverURL,
            settingsEndpoint: endpoint,
            serverVersion: serverVersion,
            reportedBaseURL: reportedBaseURL,
            hasTranscodingSetting: values.keys.contains("transcodeProfile")
        )
    }
}
