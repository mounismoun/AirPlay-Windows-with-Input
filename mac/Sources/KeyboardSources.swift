import Carbon
import Foundation

// TIS keyboard source changes run on the main thread, alongside the input frames.
final class KeyboardSources {
    struct Source {
        let ref: TISInputSource
        let id: String
        let ascii: Bool
        let korean: Bool

        init?(_ ref: TISInputSource) {
            guard let id = Self.property(ref, kTISPropertyInputSourceID) as? String else { return nil }
            self.ref = ref
            self.id = id
            ascii = Self.property(ref, kTISPropertyInputSourceIsASCIICapable) as? Bool ?? false
            let languages = Self.property(ref, kTISPropertyInputSourceLanguages) as? [String] ?? []
            korean = languages.contains { $0 == "ko" || $0.hasPrefix("ko-") }
        }

        private static func property(_ ref: TISInputSource, _ name: CFString) -> AnyObject? {
            guard let value = TISGetInputSourceProperty(ref, name) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
        }
    }

    private var lastLatin: String?
    private var lastNonLatin: String?
    private var lastKorean: String?

    static func current() -> Source? {
        describe(TISCopyCurrentKeyboardInputSource())
    }

    private static func describe(_ owned: Unmanaged<TISInputSource>?) -> Source? {
        guard let ref = owned?.takeRetainedValue() else { return nil }
        return Source(ref)
    }

    static func enabled() -> [Source] {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource!,
            kTISPropertyInputSourceIsSelectCapable as String: true,
            kTISPropertyInputSourceIsEnabled as String: true
        ]
        guard let refs = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue()
                as? [TISInputSource] else { return [] }
        return refs.compactMap(Source.init)
    }

    func capsBehavior() -> CapsBehavior {
        // A missing preference is the macOS default for an enabled non-Latin
        // input method. Read the user's setting on press so Settings changes take effect.
        let domain = "com.apple.HIToolbox" as CFString
        let enabled = CFPreferencesCopyAppValue("TISRomanSwitchState" as CFString, domain) as? NSNumber
        guard enabled?.boolValue != false else { return .lock }
        let sources = Self.enabled()
        guard sources.contains(where: { !$0.ascii }), sources.contains(where: { $0.ascii }) else { return .lock }
        let holdToUnlock = CFPreferencesCopyAppValue("AppleCapsLockPressAndHoldToggleOff" as CFString, domain) as? NSNumber
        return .language(holdToUnlock: holdToUnlock?.boolValue ?? false)
    }

    // nil means the system accepted the switch. Never enable an unconfigured source.
    func select(_ intent: SourceSwitch) -> String? {
        guard let current = Self.current() else { return "현재 macOS 입력 소스를 확인할 수 없습니다." }
        let sources = Self.enabled()
        if current.ascii { lastLatin = current.id }
        else { lastNonLatin = current.id }
        if current.korean { lastKorean = current.id }

        let target: Source?
        if intent == .hangul && !current.korean {
            let korean = sources.filter { $0.korean && !$0.ascii }
            target = korean.first { $0.id == lastKorean } ?? korean.first
        } else if intent == .caps && current.ascii {
            let nonLatin = sources.filter { !$0.ascii }
            target = nonLatin.first { $0.id == lastNonLatin } ?? nonLatin.first
        } else {
            let latin = sources.filter { $0.ascii && !$0.korean }
            let recent = Self.describe(TISCopyCurrentASCIICapableKeyboardInputSource())?.id
            target = latin.first { $0.id == lastLatin } ?? latin.first { $0.id == recent }
                ?? latin.first { $0.id == "com.apple.keylayout.ABC" } ?? latin.first
        }
        guard let target else { return "시스템 설정 → 키보드 → 입력 소스에서 사용할 입력 소스를 추가하세요." }
        let status = TISSelectInputSource(target.ref)
        return status == noErr ? nil : "macOS 입력 소스 전환 실패 (\(status))"
    }
}
