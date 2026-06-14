import Foundation

/// Model alias handling for the Cursor relay.
///
/// Cursor users can pick relay-only aliases such as "-extra" or Cursor-style
/// "-xhigh-fast" variants. The relay rewrites them to the real upstream model
/// and adds the matching reasoning effort before forwarding.
struct CursorRelayAliasMapper {
    private static let modelEfforts: [String: [String]] = [
        "gpt-5.5": ["none", "low", "medium", "high", "xhigh"],
        "gpt-5.4": ["none", "low", "medium", "high", "xhigh"],
        "gpt-5.4-mini": ["none", "low", "medium", "high", "xhigh"],
        "gpt-5.3-codex": ["low", "medium", "high", "xhigh"],
        "gpt-5.2": ["none", "low", "medium", "high", "xhigh"],
        "gpt-5.1": ["none", "low", "medium", "high"],
        "gpt-5": ["minimal", "low", "medium", "high"]
    ]
    private static let fastOnlyModels = ["gpt-5.3-codex-spark"]
    private static let aliases = makeAliases()

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

    private static func makeAliases() -> [String: (upstreamModel: String, reasoningEffort: String?)] {
        var aliases: [String: (upstreamModel: String, reasoningEffort: String?)] = [:]

        for (model, efforts) in modelEfforts {
            aliases["\(model)-fast"] = (model, nil)
            for effort in efforts {
                aliases["\(model)-\(effort)-fast"] = (model, effort)
            }
            if efforts.contains("xhigh") {
                aliases["\(model)-extra"] = (model, "xhigh")
            }
        }

        for model in fastOnlyModels {
            aliases["\(model)-fast"] = (model, nil)
        }

        return aliases
    }
}
