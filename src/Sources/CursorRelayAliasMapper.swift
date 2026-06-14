import Foundation

/// Model alias handling for the Cursor relay.
///
/// Cursor users can pick relay-only aliases such as "-extra" or Cursor-style
/// "-xhigh-fast" variants. The relay rewrites them to the real upstream model
/// and adds the matching reasoning effort before forwarding.
struct CursorRelayAliasMapper {
    private typealias AliasTarget = (upstreamModel: String, reasoningEffort: String?)

    private static let modernEfforts = ["none", "low", "medium", "high", "xhigh"]
    private static let codexEfforts = ["low", "medium", "high", "xhigh"]
    private static let olderCodexEfforts = ["low", "medium", "high"]
    private static let proEfforts = ["medium", "high", "xhigh"]
    private static let highOnlyEfforts = ["high"]
    private static let legacyEfforts = ["minimal", "low", "medium", "high"]
    private static let knownEfforts = ["none", "minimal", "low", "medium", "high", "xhigh"]

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

        let sourceModels = models
        var advertisedIDs = Set(models.compactMap { $0["id"] as? String })
        for source in sourceModels {
            guard let model = source["id"] as? String, shouldAdvertiseAliases(for: model) else { continue }
            for alias in aliases(for: model) where !advertisedIDs.contains(alias) {
                var aliasModel = source
                aliasModel["id"] = alias
                models.append(aliasModel)
                advertisedIDs.insert(alias)
            }
        }

        json["data"] = models
        return (try? JSONSerialization.data(withJSONObject: json)) ?? data
    }

    private static func aliasTarget(for model: String) -> AliasTarget? {
        if let target = extraAliasTarget(for: model) {
            return target
        }

        if let target = effortAliasTarget(for: model) {
            return target
        }

        guard model.hasSuffix("-fast") else { return nil }

        var withoutFast = model
        withoutFast.removeLast("-fast".count)

        if let target = extraAliasTarget(for: withoutFast) {
            return target
        }

        if let effortAlias = parseEffortAlias(withoutFast) {
            guard supportedEfforts(for: effortAlias.baseModel).contains(effortAlias.effort) else { return nil }
            return (effortAlias.baseModel, effortAlias.effort)
        }

        return shouldStripFastSuffix(for: withoutFast) ? (withoutFast, nil) : nil
    }

    private static func aliases(for model: String) -> [String] {
        var aliases = ["\(model)-fast"]
        let efforts = supportedEfforts(for: model)
        aliases += efforts.flatMap { ["\(model)-\($0)", "\(model)-\($0)-fast"] }
        if efforts.contains("xhigh") {
            aliases.append("\(model)-extra")
            aliases.append("\(model)-extra-fast")
            aliases.append("\(model)-extra-high")
            aliases.append("\(model)-extra-high-fast")
        }
        return aliases
    }

    private static func extraAliasTarget(for model: String) -> AliasTarget? {
        if model.hasSuffix("-extra") {
            var baseModel = model
            baseModel.removeLast("-extra".count)
            return maxEffortTarget(for: baseModel)
        }

        for effort in knownEfforts {
            let suffix = "-extra-\(effort)"
            guard model.hasSuffix(suffix) else { continue }
            var baseModel = model
            baseModel.removeLast(suffix.count)
            return maxEffortTarget(for: baseModel)
        }

        return nil
    }

    private static func maxEffortTarget(for baseModel: String) -> AliasTarget? {
        guard supportedEfforts(for: baseModel).contains("xhigh") else { return nil }
        return (baseModel, "xhigh")
    }

    private static func effortAliasTarget(for model: String) -> AliasTarget? {
        guard let effortAlias = parseEffortAlias(model),
              supportedEfforts(for: effortAlias.baseModel).contains(effortAlias.effort) else {
            return nil
        }
        return (effortAlias.baseModel, effortAlias.effort)
    }

    private static func parseEffortAlias(_ model: String) -> (baseModel: String, effort: String)? {
        for effort in knownEfforts {
            let suffix = "-\(effort)"
            guard model.hasSuffix(suffix) else { continue }
            var baseModel = model
            baseModel.removeLast(suffix.count)
            guard isGPT5Model(baseModel) else { return nil }
            return (baseModel, effort)
        }
        return nil
    }

    private static func supportedEfforts(for model: String) -> [String] {
        if isChatModel(model) {
            return []
        }
        if model.contains("-spark") {
            return []
        }
        if matchesModelFamily(model, "gpt-5.5-pro") || matchesModelFamily(model, "gpt-5.4-pro") || matchesModelFamily(model, "gpt-5.2-pro") {
            return proEfforts
        }
        if matchesModelFamily(model, "gpt-5-pro") {
            return highOnlyEfforts
        }
        if matchesModelFamily(model, "gpt-5.3-codex") {
            return codexEfforts
        }
        if matchesModelFamily(model, "gpt-5.2-codex") {
            return codexEfforts
        }
        if matchesModelFamily(model, "gpt-5.1-codex-max") {
            return codexEfforts
        }
        if matchesModelFamily(model, "gpt-5.1-codex") {
            return olderCodexEfforts
        }
        if matchesModelFamily(model, "gpt-5-codex") {
            return olderCodexEfforts
        }
        if matchesModelFamily(model, "gpt-5.1") {
            return ["none", "low", "medium", "high"]
        }
        if model == "gpt-5" || model.hasPrefix("gpt-5-") {
            return legacyEfforts
        }
        if model.hasPrefix("gpt-5.") {
            return modernEfforts
        }
        return []
    }

    private static func shouldAdvertiseAliases(for model: String) -> Bool {
        shouldStripFastSuffix(for: model) && !model.hasSuffix("-fast") && !model.hasSuffix("-extra")
    }

    private static func isGPT5Model(_ model: String) -> Bool {
        model == "gpt-5" || model.hasPrefix("gpt-5.") || model.hasPrefix("gpt-5-")
    }

    private static func shouldStripFastSuffix(for model: String) -> Bool {
        isGPT5Model(model) && !isChatModel(model)
    }

    private static func isChatModel(_ model: String) -> Bool {
        model.contains("-chat-") || model.hasSuffix("-chat")
    }

    private static func matchesModelFamily(_ model: String, _ family: String) -> Bool {
        model == family || model.hasPrefix("\(family)-")
    }
}
