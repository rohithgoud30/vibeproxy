import Foundation

/// Model alias handling for the Cursor relay.
///
/// Cursor users can pick relay-only aliases such as "-extra" or Cursor-style
/// "-xhigh-fast" variants. The relay rewrites them to the real upstream model
/// and adds the matching reasoning effort before forwarding.
struct CursorRelayAliasMapper {
    private struct AliasTarget {
        let upstreamModel: String
        let reasoningEffort: String?
    }

    private static let explicitAliases: [String: AliasTarget] = [
        "gpt-5.5-extra": AliasTarget(upstreamModel: "gpt-5.5", reasoningEffort: "xhigh"),
        "gpt-5.4-extra": AliasTarget(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh"),
        "gpt-5.4-mini-extra": AliasTarget(upstreamModel: "gpt-5.4-mini", reasoningEffort: "xhigh")
    ]

    /// Rewrites a chat-completions request body if it targets an alias model.
    /// Alias requests get the requested `reasoning_effort` injected.
    static func rewriteChatBody(_ body: Data) -> Data {
        guard !body.isEmpty,
              var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let model = json["model"] as? String,
              let target = aliasTarget(for: model) else {
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

        var existingIDs = Set(models.compactMap { $0["id"] as? String })
        for (alias, real) in listedAliases(existingIDs: existingIDs) where !existingIDs.contains(alias) {
            guard var source = models.first(where: { ($0["id"] as? String) == real }) else { continue }
            source["id"] = alias
            models.append(source)
            existingIDs.insert(alias)
        }

        json["data"] = models
        return (try? JSONSerialization.data(withJSONObject: json)) ?? data
    }

    private static func aliasTarget(for model: String) -> AliasTarget? {
        if let target = explicitAliases[model] {
            return target
        }

        var normalized = model
        let hadFastSuffix = normalized.hasSuffix("-fast")
        if hadFastSuffix {
            normalized.removeLast("-fast".count)
        }

        if let parsed = parseEffortSuffix(from: normalized) {
            return AliasTarget(upstreamModel: parsed.baseModel, reasoningEffort: parsed.effort)
        }

        if hadFastSuffix, isGPT5Model(normalized) {
            return AliasTarget(upstreamModel: normalized, reasoningEffort: nil)
        }

        return nil
    }

    private static func parseEffortSuffix(from model: String) -> (baseModel: String, effort: String)? {
        for effort in ["xhigh", "high", "medium", "low", "minimal", "none"] {
            let suffix = "-\(effort)"
            guard model.hasSuffix(suffix) else { continue }
            var baseModel = model
            baseModel.removeLast(suffix.count)
            guard isGPT5Model(baseModel) else { continue }
            return (baseModel, effort)
        }
        return nil
    }

    private static func isGPT5Model(_ model: String) -> Bool {
        model.hasPrefix("gpt-5.")
    }

    private static func listedAliases(existingIDs: Set<String>) -> [(alias: String, real: String)] {
        var aliases = explicitAliases.map { (alias: $0.key, real: $0.value.upstreamModel) }

        for model in existingIDs where isGPT5Model(model) {
            aliases.append((alias: "\(model)-fast", real: model))
            aliases.append((alias: "\(model)-xhigh-fast", real: model))
        }

        return aliases
    }
}
