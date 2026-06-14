import Foundation

/// Model alias handling for the Cursor relay.
///
/// Cursor users can pick relay-only aliases such as "-extra" or Cursor-style
/// "-xhigh-fast" variants. The relay rewrites them to the real upstream model
/// and adds the matching reasoning effort before forwarding.
struct CursorRelayAliasMapper {
    private static let aliases: [String: (upstreamModel: String, reasoningEffort: String?)] = [
        "gpt-5.5-extra": ("gpt-5.5", "xhigh"),
        "gpt-5.5-fast": ("gpt-5.5", nil),
        "gpt-5.5-xhigh-fast": ("gpt-5.5", "xhigh"),
        "gpt-5.4-extra": ("gpt-5.4", "xhigh"),
        "gpt-5.4-fast": ("gpt-5.4", nil),
        "gpt-5.4-xhigh-fast": ("gpt-5.4", "xhigh"),
        "gpt-5.4-mini-extra": ("gpt-5.4-mini", "xhigh"),
        "gpt-5.4-mini-fast": ("gpt-5.4-mini", nil),
        "gpt-5.4-mini-xhigh-fast": ("gpt-5.4-mini", "xhigh")
    ]

    /// Rewrites a chat-completions request body if it targets an alias model.
    /// Alias requests get the requested `reasoning_effort` injected.
    static func rewriteChatBody(_ body: Data) -> Data {
        guard !body.isEmpty,
              var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let model = json["model"] as? String,
              let target = aliases[model] else {
            return body
        }

        json["model"] = target.upstreamModel
        if let reasoningEffort = target.reasoningEffort {
            json["reasoning_effort"] = reasoningEffort
        }

        guard let rewritten = try? JSONSerialization.data(withJSONObject: json) else {
            return body
        }
        NSLog("[CursorRelay] Rewrote model alias %@ -> %@ (reasoning_effort=%@)", model, target.upstreamModel, target.reasoningEffort ?? "unchanged")
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
        for (alias, target) in aliases where existingIDs.contains(target.upstreamModel) && !existingIDs.contains(alias) {
            guard var source = models.first(where: { ($0["id"] as? String) == target.upstreamModel }) else { continue }
            source["id"] = alias
            models.append(source)
        }

        json["data"] = models
        return (try? JSONSerialization.data(withJSONObject: json)) ?? data
    }
}
