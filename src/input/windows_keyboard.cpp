#ifdef _WIN32
#include "input/windows_keyboard.h"
#include <SDL_syswm.h>
#include <commctrl.h>
#include <imm.h>

namespace ap::input {
bool queue_windows_language_key(Uint32 window_id, unsigned key, Uint32 bits, bool down) {
    const auto scan = (bits >> 16) & 0xff;
    const bool extended = (bits & (1L << 24)) != 0;
    SDL_Scancode code;
    bool shared_alt = false;
    const bool hangul_scan = (scan == 0xf2 || scan == 0x72) &&
        PRIMARYLANGID(LOWORD(reinterpret_cast<ULONG_PTR>(GetKeyboardLayout(0)))) == LANG_KOREAN;
    if (key == VK_HANGUL || hangul_scan) {
        shared_alt = extended && scan == 0x38;
        code = shared_alt ? SDL_SCANCODE_RALT : SDL_SCANCODE_LANG1;
    } else if (key == VK_HANJA && extended && scan == 0x1d) {
        code = SDL_SCANCODE_RCTRL;
    } else if (scan == 0 && key >= VK_F1 && key <= VK_F12) {
        // Some remote and accessibility keyboards only provide a virtual key.
        code = static_cast<SDL_Scancode>(SDL_SCANCODE_F1 + key - VK_F1);
    } else if (scan == 0 && key == VK_ESCAPE) {
        code = SDL_SCANCODE_ESCAPE;
    } else {
        return false;
    }
    SDL_Event event{};
    event.type = down ? SDL_KEYDOWN : SDL_KEYUP;
    event.key.windowID = window_id;
    event.key.state = down ? SDL_PRESSED : SDL_RELEASED;
    event.key.repeat = down && (bits & (1L << 30));
    event.key.keysym.scancode = code;
    event.key.keysym.mod = static_cast<Uint16>(SDL_GetModState());
    const SDL_Scancode logical = shared_alt ? SDL_SCANCODE_LANG1 : code;
    event.key.keysym.sym = SDL_SCANCODE_TO_KEYCODE(logical);
    if (code == SDL_SCANCODE_LANG1) {
        // Dedicated Korean keys can send a make with no corresponding break.
        if (down && !event.key.repeat) {
            SDL_PushEvent(&event);
            event.type = SDL_KEYUP;
            event.key.state = SDL_RELEASED;
            SDL_PushEvent(&event);
        }
    } else {
        SDL_PushEvent(&event);
    }
    return true;
}

namespace {
LRESULT CALLBACK language_key_proc(HWND hwnd, UINT message, WPARAM vk, LPARAM bits,
                                   UINT_PTR subclass, DWORD_PTR window_id) {
    if (message == WM_NCDESTROY) RemoveWindowSubclass(hwnd, language_key_proc, subclass);
    const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN || message == WM_IME_KEYDOWN;
    const bool up = message == WM_KEYUP || message == WM_SYSKEYUP || message == WM_IME_KEYUP;
    if ((down || up) && GetFocus() == hwnd) {
        const auto key = vk == VK_PROCESSKEY ? ImmGetVirtualKey(hwnd) : static_cast<UINT>(vk);
        if (queue_windows_language_key(static_cast<Uint32>(window_id), key,
                                       static_cast<Uint32>(bits), down)) return 0;
    }
    return DefSubclassProc(hwnd, message, vk, bits);
}
}

void WindowsKeyboard::attach(SDL_Window* window) {
    if (hwnd_ || !window) return;
    SDL_SysWMinfo info{};
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_WINDOWS) return;
    HWND hwnd = info.info.win.window;
    if (!SetWindowSubclass(hwnd, language_key_proc, reinterpret_cast<UINT_PTR>(this),
                           SDL_GetWindowID(window))) return;
    hwnd_ = hwnd;
    // Let this window receive the key before the local Korean IME consumes it.
    ime_ = ImmAssociateContext(hwnd, nullptr);
}

void WindowsKeyboard::detach() {
    if (!hwnd_) return;
    auto hwnd = static_cast<HWND>(hwnd_);
    DWORD_PTR window_id = 0;
    if (IsWindow(hwnd) && GetWindowSubclass(hwnd, language_key_proc,
            reinterpret_cast<UINT_PTR>(this), &window_id)) {
        RemoveWindowSubclass(hwnd, language_key_proc, reinterpret_cast<UINT_PTR>(this));
        ImmAssociateContext(hwnd, static_cast<HIMC>(ime_));
    }
    hwnd_ = nullptr;
    ime_ = nullptr;
}

bool WindowsKeyboard::shared_right_alt() const {
    return hwnd_ && MapVirtualKeyExW(0xe038, MAPVK_VSC_TO_VK_EX, GetKeyboardLayout(0)) == VK_HANGUL;
}
} // namespace ap::input
#endif
