import Foundation

enum Config {
    static let gyaimDir: String = {
        let path = NSString("~/.gyaim").expandingTildeInPath
        return path
    }()

    static let cacheDir: String = {
        "\(gyaimDir)/cacheimages"
    }()

    static let imageDir: String = {
        "\(gyaimDir)/images"
    }()

    static let localDictFile: String = {
        "\(gyaimDir)/localdict.txt"
    }()

    static let studyDictFile: String = {
        "\(gyaimDir)/studydict.txt"
    }()

    static let copyTextFile: String = {
        "\(gyaimDir)/copytext"
    }()

    static let secretScriptFile: String = {
        "\(gyaimDir)/secret.sh"
    }()

    static let labelDialogFile: String = {
        "\(gyaimDir)/GyaimLabelDialog"
    }()

    static let selectDialogFile: String = {
        "\(gyaimDir)/GyaimSelectDialog"
    }()

    static func setup() {
        let fm = FileManager.default
        for dir in [gyaimDir, cacheDir, imageDir] {
            if !fm.fileExists(atPath: dir) {
                do {
                    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                } catch {
                    Log.config.error("Failed to create directory \(dir): \(error.localizedDescription)")
                }
            }
        }
        for file in [localDictFile, studyDictFile] {
            if !fm.fileExists(atPath: file) {
                fm.createFile(atPath: file, contents: nil)
            }
        }
        copyHelperTool(fm: fm, name: "GyaimLabelDialog")
        copyHelperTool(fm: fm, name: "GyaimSelectDialog")
        createSampleSecretScript(fm: fm)
        Log.config.info("Config setup complete")
    }

    private static func copyHelperTool(fm: FileManager, name: String) {
        let bundlePath = Bundle.main.bundlePath + "/Contents/MacOS/\(name)"
        guard fm.fileExists(atPath: bundlePath) else {
            Log.config.info("\(name) not found in bundle, skipping copy")
            return
        }
        // Copy if destination doesn't exist or is older than bundle version
        let destPath = "\(gyaimDir)/\(name)"
        let shouldCopy: Bool
        if !fm.fileExists(atPath: destPath) {
            shouldCopy = true
        } else {
            let srcMod = (try? fm.attributesOfItem(atPath: bundlePath)[.modificationDate] as? Date) ?? .distantPast
            let dstMod = (try? fm.attributesOfItem(atPath: destPath)[.modificationDate] as? Date) ?? .distantPast
            shouldCopy = srcMod > dstMod
        }
        guard shouldCopy else { return }
        do {
            if fm.fileExists(atPath: destPath) {
                try fm.removeItem(atPath: destPath)
            }
            try fm.copyItem(atPath: bundlePath, toPath: destPath)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath)
            Log.config.info("Copied \(name) to \(destPath)")
        } catch {
            Log.config.error("Failed to copy \(name): \(error.localizedDescription)")
        }
    }

    private static func createSampleSecretScript(fm: FileManager) {
        guard !fm.fileExists(atPath: secretScriptFile) else { return }
        let content = #"""
        #!/bin/bash
        # ~/.gyaim/secret.sh - Gyaim外部コマンド
        # サブコマンド: encrypt <平文> | list | decrypt <ラベル>
        #
        # このスクリプトを編集して、お好みの暗号化/保管方式を実装してください。
        # 例: Keychain, EpisoPass, 1Password CLI, GPG など
        #
        # EpisoPass連携: このスクリプトを差し替えるだけで実現可能。
        # 詳細は docs/adr/012-external-command-integration.md を参照。
        SERVICE="gyaim"

        # ラベル入力ダイアログ（GyaimLabelDialog ヘルパーバイナリを使用）
        # Gyaim.app に同梱され、起動時に ~/.gyaim/ にコピーされる
        ask_label() {
          ~/.gyaim/GyaimLabelDialog "$1"
        }

        case "$1" in
          encrypt)
            LABEL=$(ask_label "ラベル名を入力:")
            [ -z "$LABEL" ] && exit 1
            security add-generic-password -a "$LABEL" -s "$SERVICE" -w "$2" 2>/dev/null \
              || security delete-generic-password -a "$LABEL" -s "$SERVICE" 2>/dev/null \
              && security add-generic-password -a "$LABEL" -s "$SERVICE" -w "$2" 2>/dev/null
            echo "保存しました: $LABEL"
            ;;
          list)
            security dump-keychain 2>/dev/null \
              | awk -v svc="$SERVICE" '
                /^keychain:/ { acct="" }
                /"acct"<blob>=/ {
                  sub(/.*"acct"<blob>=/, "")
                  acct = $0
                }
                /"svce"<blob>="/ && index($0, "=\"" svc "\"") && acct != "" {
                  print acct
                  acct = ""
                }
              ' \
              | while IFS= read -r line; do
                  case "$line" in
                    '"'*'"')
                      echo "$line" | sed 's/^"//; s/".*$//'
                      ;;
                    0x*)
                      hex=$(echo "$line" | sed 's/^0x//; s/[^0-9A-Fa-f].*//')
                      printf '%s' "$hex" | xxd -r -p
                      echo
                      ;;
                    *) echo "$line" ;;
                  esac
                done \
              | sort -u
            ;;
          decrypt)
            security find-generic-password -a "$2" -s "$SERVICE" -w 2>/dev/null
            ;;
          decrypt-interactive)
            LABELS=$("$0" list)
            if [ -z "$LABELS" ]; then
              echo "保存済みデータがありません"
              exit 1
            fi
            SELECTED=$(echo "$LABELS" | ~/.gyaim/GyaimSelectDialog "復号するラベルを選択:")
            [ -z "$SELECTED" ] && exit 1
            security find-generic-password -a "$SELECTED" -s "$SERVICE" -w 2>/dev/null
            ;;
          *)
            echo "Usage: $0 {encrypt|list|decrypt|decrypt-interactive} [argument]"
            exit 1
            ;;
        esac
        """#
        fm.createFile(atPath: secretScriptFile, contents: content.data(using: .utf8))
        do {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secretScriptFile)
        } catch {
            Log.config.error("Failed to set permissions on \(secretScriptFile): \(error.localizedDescription)")
        }
        Log.config.info("Created sample secret script at \(secretScriptFile)")
    }
}
