#pragma once
#ifdef _WIN32
#include <SDL.h>

namespace ap::input {
// Queue a normalized SDL key or return false for normal window processing.
bool queue_windows_language_key(Uint32 window_id, unsigned virtual_key, Uint32 key_data, bool down);

// Handles IME-specific keys only on the focused SDL video window.
class WindowsKeyboard {
public:
    void attach(SDL_Window* window);
    void detach();
    bool shared_right_alt() const;
private:
    void* hwnd_ = nullptr;
    void* ime_ = nullptr;
};
}
#endif
