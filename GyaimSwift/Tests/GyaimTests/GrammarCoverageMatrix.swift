import Foundation

/// The spec of ADR-042 as data: every predicate form paired with every
/// hiragana tail that must compose in one conversion. Readings are kana.
enum GrammarCoverageMatrix {
    struct Cell {
        let kind: String
        let lexeme: String
        let form: String
        let tail: String
        let reading: String
        let expected: String
    }

    struct Form {
        let name: String
        let kana: String
        let surface: String
    }

    static let formNames = ["mizen", "renyo", "shushi", "katei", "ikou", "te", "ta"]

    /// 五段: 未然 / 連用 / 終止 / 仮定 / 意向 / て形 / た形 の語尾。
    static let godan: [String: [String]] = [
        "k": ["か", "き", "く", "け", "こう", "いて", "いた"],
        "g": ["が", "ぎ", "ぐ", "げ", "ごう", "いで", "いだ"],
        "s": ["さ", "し", "す", "せ", "そう", "して", "した"],
        "t": ["た", "ち", "つ", "て", "とう", "って", "った"],
        "n": ["な", "に", "ぬ", "ね", "のう", "んで", "んだ"],
        "b": ["ば", "び", "ぶ", "べ", "ぼう", "んで", "んだ"],
        "m": ["ま", "み", "む", "め", "もう", "んで", "んだ"],
        "r": ["ら", "り", "る", "れ", "ろう", "って", "った"],
        "w": ["わ", "い", "う", "え", "おう", "って", "った"],
        "iku": ["か", "き", "く", "け", "こう", "って", "った"],
    ]

    struct Verb {
        let lexeme: String
        let surface: String
        let kana: String
        let type: String

        init(_ lexeme: String, _ surface: String, _ kana: String, _ type: String) {
            self.lexeme = lexeme
            self.surface = surface
            self.kana = kana
            self.type = type
        }
    }

    /// 辞書形・語幹の表記・語幹のかな・活用の種類。活用の種類ごとに 1 語以上。
    static let verbs = [
        Verb("書く", "書", "か", "k"), Verb("泳ぐ", "泳", "およ", "g"), Verb("返す", "返", "かえ", "s"),
        Verb("待つ", "待", "ま", "t"), Verb("死ぬ", "死", "し", "n"), Verb("呼ぶ", "呼", "よ", "b"),
        Verb("読む", "読", "よ", "m"), Verb("取る", "取", "と", "r"), Verb("使う", "使", "つか", "w"),
        Verb("行く", "行", "い", "iku"), Verb("見る", "見", "み", "ichidan"), Verb("食べる", "食べ", "たべ", "ichidan"),
        Verb("考える", "考え", "かんがえ", "ichidan"), Verb("する", "", "", "suru"),
        Verb("実装する", "実装", "じっそう", "suru"), Verb("確認する", "確認", "かくにん", "suru"), Verb("来る", "来", "", "kuru"),
    ]

    static let adjectives: [(lexeme: String, surface: String, kana: String)] = [
        ("高い", "高", "たか"), ("眠い", "眠", "ねむ"), ("新しい", "新し", "あたらし"), ("良い", "良", "よ"), ("難しい", "難し", "むずかし"),
    ]

    static let naAdjectives: [(lexeme: String, surface: String, kana: String)] = [
        ("静か", "静か", "しずか"), ("便利", "便利", "べんり"), ("必要", "必要", "ひつよう"), ("簡単", "簡単", "かんたん"),
    ]

    static func cells() -> [Cell] {
        var cells: [Cell] = []
        for verb in verbs {
            for form in forms(surface: verb.surface, kana: verb.kana, type: verb.type) {
                for tail in verbTails[form.name] ?? [] {
                    // 来 alone is not a word; the bare 未然形 / 連用形 of 来る is skipped.
                    if verb.type == "kuru", tail.isEmpty, form.name == "renyo" { continue }
                    cells.append(Cell(kind: "verb", lexeme: verb.lexeme, form: form.name, tail: tail,
                                      reading: form.kana + (tailKana[tail] ?? tail), expected: form.surface + tail))
                }
            }
        }
        for (kind, lexemes, tails) in [("adj", adjectives, adjectiveTails), ("na", naAdjectives, naAdjectiveTails)] {
            for lexeme in lexemes {
                for tail in tails {
                    cells.append(Cell(kind: kind, lexeme: lexeme.lexeme, form: "stem", tail: tail,
                                      reading: lexeme.kana + tail, expected: lexeme.surface + tail))
                }
            }
        }
        return cells
    }

    static func forms(surface: String, kana: String, type: String) -> [Form] {
        func make(_ kanaEndings: [String], _ surfaceEndings: [String], stemKana: String) -> [Form] {
            zip(formNames, zip(kanaEndings, surfaceEndings)).map {
                Form(name: $0, kana: stemKana + $1.0, surface: surface + $1.1)
            }
        }
        switch type {
        case "ichidan":
            let endings = ["", "", "る", "れ", "よう", "て", "た"]
            return make(endings, endings, stemKana: kana) + [
                Form(name: "passive", kana: kana + "られ", surface: surface + "られ"),
                Form(name: "causative", kana: kana + "させ", surface: surface + "させ"),
                Form(name: "zu", kana: kana, surface: surface),
            ]
        case "suru":
            let endings = ["し", "し", "する", "すれ", "しよう", "して", "した"]
            return make(endings, endings, stemKana: kana) + [
                Form(name: "passive", kana: kana + "され", surface: surface + "され"),
                Form(name: "causative", kana: kana + "させ", surface: surface + "させ"),
                Form(name: "zu", kana: kana + "せ", surface: surface + "せ"),
            ]
        case "kuru":
            return make(["こ", "き", "くる", "くれ", "こよう", "きて", "きた"], ["", "", "る", "れ", "よう", "て", "た"], stemKana: "") + [
                Form(name: "passive", kana: "こられ", surface: surface + "られ"),
                Form(name: "causative", kana: "こさせ", surface: surface + "させ"),
                Form(name: "zu", kana: "こ", surface: surface),
            ]
        default:
            let endings = godan[type] ?? []
            return make(endings, endings, stemKana: kana) + [
                Form(name: "passive", kana: kana + endings[0] + "れ", surface: surface + endings[0] + "れ"),
                Form(name: "causative", kana: kana + endings[0] + "せ", surface: surface + endings[0] + "せ"),
                Form(name: "zu", kana: kana + endings[0], surface: surface + endings[0]),
            ]
        }
    }
}
