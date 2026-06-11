import Foundation

/// Model alias handling for the Cursor relay.
///
/// Cursor users can pick "-extra" variants of the Codex models; the relay
/// rewrites them to the real upstream model and forces maximum reasoning
/// effort, mirroring what the standalone Node relay used to do.
struct CursorRelayAliasMapper {
    static let aliases: [String: String] = [
        "gpt-5.5-extra": "gpt-5.5",
        "gpt-5.4-extra": "gpt-5.4",
        "gpt-5.4-mini-extra": "gpt-5.4-mini"
    ]

    /// Rewrites a chat-completions request body if it targets an alias model.
    /// Alias requests get `reasoning_effort: "xhigh"` injected.
    static func rewriteChatBody(_ body: Data) -> Data {
        guard !body.isEmpty,
              var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let model = json["model"] as? String,
              let upstreamModel = aliases[model] else {
            return body
        }

        json["model"] = upstreamModel
        json["reasoning_effort"] = "xhigh"

        guard let rewritten = try? JSONSerialization.data(withJSONObject: json) else {
            return body
        }
        NSLog("[CursorRelay] Rewrote model alias %@ -> %@ (reasoning_effort=xhigh)", model, upstreamModel)
        return rewritten
    }

    /// Adds the alias model entries to a /v1/models response so they are
    /// selectable in Cursor's model list.
    static func injectAliases(intoModelsResponse data: Data) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var models = json["data"] as? [[String: Any]] else {
            return data
        }

        let existingIDs = Set(models.compactMap { $0["id"] as? String })
        for (alias, real) in aliases where existingIDs.contains(real) && !existingIDs.contains(alias) {
            guard var source = models.first(where: { ($0["id"] as? String) == real }) else { continue }
            source["id"] = alias
            models.append(source)
        }

        json["data"] = models
        return (try? JSONSerialization.data(withJSONObject: json)) ?? data
    }
}
