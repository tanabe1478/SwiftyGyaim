import Cocoa

// MARK: - Ranking (model + context learning)

final class RankingSection: PreferencesSection {
    private let fastContext: ClosureButton
    private let useModel: ClosureButton
    private let bundledModel: ClosureButton
    private let rerankLogging: ClosureButton
    private let contextLearning: ClosureButton
    private let contextCount = PreferencesSection.makeLabel("")

    init() {
        fastContext = ClosureButton.checkbox("通常入力で候補を並べ替える", isOn: GyaimController.isFastContextRerankEnabled) {
            GyaimController.setFastContextRerankEnabled($0)
        }
        useModel = ClosureButton.checkbox("並べ替えに同梱モデルを使う",
                                          isOn: GyaimController.isFastContextRerankModelEnabled) {
            GyaimController.setFastContextRerankModelEnabled($0)
        }
        bundledModel = ClosureButton.checkbox("同梱モデルを読み込む", isOn: GyaimController.isBundledZenzEnabled) {
            GyaimController.setBundledZenzEnabled($0)
        }
        rerankLogging = ClosureButton.checkbox("並べ替えのレイテンシと順序をログに出す",
                                               isOn: GyaimController.isFastContextRerankLoggingEnabled) {
            GyaimController.setFastContextRerankLoggingEnabled($0)
        }
        contextLearning = ClosureButton.checkbox("文脈学習を使う", isOn: ContextDict.isEnabled) {
            ContextDict.setEnabled($0)
        }
        super.init(title: "候補の並べ替え")

        addRow(fastContext)
        addHint("読み完全一致を優先し、直前の文脈で予測候補を並べ替えます。OFF で辞書順のまま")
        addIndentedRow(useModel)
        addHint("辞書候補をモデルで採点し、学習頻度・文脈学習・複合語の加点と合わせて並べます（ADR-032）。"
                + "打鍵は止めず、裏で採点して差し替えます")
        addIndentedRow(bundledModel)
        addHint("OFF にするとモデルを使う経路をすべて止め、heuristic だけで並べます。customModelPath の GGUF もここで切れます")
        addIndentedRow(rerankLogging)
        addHint("入力ごとに出るので普段は OFF。dogfood の集計や性能確認のときだけ ON にします")

        addRow(contextLearning)
        addHint("確定直前の文脈と組で語を覚え、同じ文脈では同音異義語を学習どおりに出します（ADR-020）")
        let count = contextCount
        count.stringValue = Self.contextCountString()
        addControlsRow([
            count,
            ClosureButton.push("文脈学習をクリア") {
                ContextDict.shared.clear()
                count.stringValue = Self.contextCountString()
            },
        ])
    }

    override func reload() {
        fastContext.state = GyaimController.isFastContextRerankEnabled ? .on : .off
        useModel.state = GyaimController.isFastContextRerankModelEnabled ? .on : .off
        bundledModel.state = GyaimController.isBundledZenzEnabled ? .on : .off
        rerankLogging.state = GyaimController.isFastContextRerankLoggingEnabled ? .on : .off
        contextLearning.state = ContextDict.isEnabled ? .on : .off
        contextCount.stringValue = Self.contextCountString()
    }

    private static func contextCountString() -> String {
        "学習済みの文脈: \(ContextDict.shared.entryCount())件"
    }
}

// MARK: - Connection dictionary import

final class ConnectionDictSection: PreferencesSection {
    private let urlField = NSTextField()
    private let status = PreferencesSection.makeHintLabel("")
    private let importButton = ClosureButton.push("インポート") {}

    init() {
        super.init(title: "接続辞書")
        urlField.placeholderString = GictionaryConnectionImporter.recommendedDict2URLString
        urlField.stringValue = GictionaryConnectionImporter.sourceURLString
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        importButton.onClick = { [weak self] _ in self?.importDictionary() }
        addLabeledRow("URL:", urlField, trailing: importButton)
        addHint("masui/Gictionary のリポジトリ URL か raw の dict2.txt URL。空欄なら推奨 URL。成功後すぐ反映します",
                indent: false)
        status.stringValue = Self.statusText()
        addControlsRow([
            status,
            ClosureButton.push("内蔵辞書に戻す") { [weak self] in self?.restoreBundled() },
        ])
    }

    override func reload() {
        urlField.stringValue = GictionaryConnectionImporter.sourceURLString
        status.stringValue = Self.statusText()
    }

    private func importDictionary() {
        let typed = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = typed.isEmpty ? GictionaryConnectionImporter.recommendedDict2URLString : typed
        guard let url = URL(string: raw), let scheme = url.scheme, ["http", "https", "file"].contains(scheme) else {
            status.stringValue = "URL が正しくありません"
            return
        }
        importButton.isEnabled = false
        status.stringValue = "インポート中..."
        GictionaryConnectionImporter.importFromURL(url) { [weak self] result in
            DispatchQueue.main.async {
                self?.importButton.isEnabled = true
                switch result {
                case .success(let importResult):
                    GyaimController.reloadConnectionDictionary()
                    self?.status.stringValue = "インポート済み: \(importResult.entryCount)件"
                case .failure(let error):
                    self?.status.stringValue = "失敗: \(error.localizedDescription)"
                }
            }
        }
    }

    private func restoreBundled() {
        do {
            try GictionaryConnectionImporter.removeImportedDictionary()
            GyaimController.reloadConnectionDictionary()
            urlField.stringValue = ""
            status.stringValue = Self.statusText()
        } catch {
            status.stringValue = "失敗: \(error.localizedDescription)"
        }
    }

    private static func statusText() -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Config.importedConnectionDictFile),
              let size = (try? fm.attributesOfItem(atPath: Config.importedConnectionDictFile)[.size] as? NSNumber)?
                  .intValue,
              size > 0 else {
            return "現在: 内蔵辞書"
        }
        return "現在: インポート辞書 (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
    }
}

// MARK: - Logging

final class LogSection: PreferencesSection {
    private let logging: ClosureButton
    private let sizeLabel: NSTextField

    init() {
        let sizeLabel = PreferencesSection.makeLabel("")
        self.sizeLabel = sizeLabel
        logging = ClosureButton.checkbox("ロギングを有効にする", isOn: Log.isEnabled) { enabled in
            Log.setEnabled(enabled)
            sizeLabel.stringValue = Self.sizeString()
        }
        super.init(title: "ログ")
        addRow(logging)
        addHint("~/.gyaim/gyaim.log に info 以上を書きます。5MB ごとに 7 世代をローテーション")
        sizeLabel.stringValue = Self.sizeString()
        addControlsRow([
            sizeLabel,
            ClosureButton.push("ログを削除") {
                FileLogger.shared.clearLog()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    sizeLabel.stringValue = Self.sizeString()
                }
            },
            ClosureButton.push("Finder で表示") { Self.showInFinder() },
        ])
    }

    override func reload() {
        logging.state = Log.isEnabled ? .on : .off
        sizeLabel.stringValue = Self.sizeString()
    }

    private static func sizeString() -> String {
        let size = FileLogger.shared.logFileSize()
        if size == 0 { return "gyaim.log: 0 B" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "gyaim.log: \(formatter.string(fromByteCount: size))"
    }

    private static func showInFinder() {
        let logPath = "\(Config.gyaimDir)/gyaim.log"
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Config.gyaimDir)
        }
    }
}
