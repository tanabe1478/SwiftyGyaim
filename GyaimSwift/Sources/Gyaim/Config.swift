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
        createSampleSecretScript(fm: fm)
        Log.config.info("Config setup complete")
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
        SERVICE="gyaim"
        case "$1" in
          encrypt)
            LABEL=$(osascript -e 'display dialog "ラベル名を入力:" default answer ""' \
                    -e 'text returned of result' 2>/dev/null)
            [ -z "$LABEL" ] && exit 1
            security add-generic-password -a "$LABEL" -s "$SERVICE" -w "$2" 2>/dev/null \
              || security delete-generic-password -a "$LABEL" -s "$SERVICE" 2>/dev/null \
              && security add-generic-password -a "$LABEL" -s "$SERVICE" -w "$2" 2>/dev/null
            echo "保存しました: $LABEL"
            ;;
          list)
            security dump-keychain 2>/dev/null \
              | grep -A4 "\"svce\"<blob>=\"$SERVICE\"" \
              | grep '"acct"' \
              | sed 's/.*="\(.*\)"/\1/' \
              | sort -u
            ;;
          decrypt)
            security find-generic-password -a "$2" -s "$SERVICE" -w 2>/dev/null
            ;;
          *)
            echo "Usage: $0 {encrypt|list|decrypt} [argument]"
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
