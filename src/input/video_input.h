#pragma once
#include "input/channel.h"
#include "input/pairing.h"
#include "input/windows_keyboard.h"
#include <SDL.h>
#include <array>
#include <bitset>
#include <string>

namespace ap::input {
bool put_point(Packet& packet, int x, int y, SDL_Rect rect, int angle, bool clamp);

class VideoInput {
public:
    ~VideoInput();
    void update(SDL_Window* window, const std::string& peer, const std::string& session,
                bool mac_key_positions = true, const std::string& device_id = {},
                const std::string& device_name = {});
    void presented(SDL_Rect pixels, int angle, int output_w, int output_h);
    bool event(const SDL_Event& e);
    bool capturing() const;
    bool ready() const { return channel_.state() == Channel::State::ready; }
    bool pairing() const { return pairing_; }
    void request_pair();
    bool confirm_pairing() { return pairing_ && activate(address_.data(), secret_.data(), true); }
    bool activate(const char* address, const char* hex, bool remember = false);
    void draw();
private:
    void stop();
    Channel channel_;
    SDL_Window* window_ = nullptr;
    SDL_Rect video_{};
    int angle_ = 0, output_w_ = 0, output_h_ = 0;
    unsigned buttons_ = 0;
    bool mac_key_positions_ = true;
    bool keyboard_grabbed_ = false;
#ifdef _WIN32
    WindowsKeyboard windows_keyboard_;
#endif
    std::bitset<256> held_keys_;
    bool hangul_tap_ = false;
    bool local_f8_ = false, language_f9_ = false;
    bool popup_ = false, pairing_ = false, paired_ = false;
    bool write_pending_ = false;
    std::string peer_, session_, device_id_, device_name_, target_, message_;
    PairingKey secret_{};
    std::array<char, 80> address_{};
};
} // namespace ap::input
