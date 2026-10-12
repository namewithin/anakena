/// The word-boundary decision and typing-run state, independent of event delivery.
struct WordPipeline {
    static let maxBuffer = 64

    struct Word {
        let strokes: [Stroke]
        let lang: Lang
        let boundary: UInt16
        var manual = false
        var learned: String? = nil
    }

    enum Action {
        case unchanged
        case correction(Correction)
        case correctionGroup([Correction])
        case shortWords([Correction])

        var corrections: [Correction]? {
            switch self {
            case let .correction(c): return [c]
            case let .correctionGroup(group): return group
            default: return nil
            }
        }
    }

    var run: [Word] = []
    var afterFix = false

    mutating func end(_ strokes: [Stroke], boundary: UInt16, lang: Lang,
                      automatic: Bool, corrector: Corrector) -> Action {
        guard !strokes.isEmpty else {
            if boundary != 49 { afterFix = false }
            run = []
            return .unchanged
        }

        let context = afterFix
        let prev = run
        afterFix = false
        run = []
        // A valid short predecessor can supply context for a two-letter anchor.
        // The anchor still has to be wrong as typed and dictionary-valid after conversion.
        let leading = automatic ? corrector.fixShortWords(prev.map { ($0.strokes, $0.lang) },
                                                         before: corrector.layouts.other(lang) ?? lang) : []
        if automatic, let c = corrector.decide(strokes, current: lang, afterFix: context || !leading.isEmpty) {
            afterFix = boundary == 49
            return leading.isEmpty ? .correction(c) : .correctionGroup(leading + [c])
        }

        let dictionaryAnchor = corrector.isWord(strokes, in: lang)
        let singleAnchor = corrector.isSingleLetterWord(strokes, in: lang)
        var short = automatic && !prev.isEmpty && (dictionaryAnchor || singleAnchor)
            ? corrector.fixShortWords(prev.map { ($0.strokes, $0.lang) }, before: lang) : []
        if !dictionaryAnchor {
            // A lone letter is weaker context: do not reinterpret units such as "s,"
            // or other single-letter tokens. Preserve a contiguous eligible suffix.
            short = Array(short.reversed().prefix {
                $0.word.count == 2 && $0.typed == $0.word
            }.reversed())
        }
        if !short.isEmpty { return .shortWords(short) }
        if boundary == 49 {
            run = Array((prev + [Word(strokes: strokes, lang: lang, boundary: boundary)]).suffix(3))
        }
        return .unchanged
    }
}
