#pragma once
#include "input/channel.h"
#include <SDL.h>
#include <array>
#include <string>

namespace ap::input {
bool put_point(Packet& packet, int x, int y, SDL_Rect rect, int angle, bool clamp);

class VideoInput {
public:
    ~VideoInput();
    void update(SDL_Window* window, const std::string& peer, const std::string& session, bool mac_key_positions = true);
    void presented(SDL_Rect pixels, int angle, int output_w, int output_h);
    bool event(const SDL_Event& e);
    bool capturing() const;
    bool ready() const { return channel_.state() == Channel::State::ready; }
    bool pairing() const { return pairing_; }
    void request_pair();
    bool activate(const char* address, const char* hex);
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
    bool popup_ = false, pairing_ = false, paired_ = false;
    std::string peer_, session_, message_;
    std::array<char, 33> secret_{};
    std::array<char, 16> address_{};
};
} // namespace ap::input
