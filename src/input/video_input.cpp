#include "input/video_input.h"
#include "net/socket.h"
#include "imgui.h"
#include <openssl/crypto.h>
#include <algorithm>
#include <cmath>
#include <cstdio>

namespace ap::input {
// The v1 Swift agent assigns its own Quartz modifiers to these wire codes.
// Send its existing left/right codes so previously paired agents work as-is.
static SDL_Scancode mac_position_code(SDL_Scancode physical) {
    switch (physical) {
    case SDL_SCANCODE_LCTRL: return SDL_SCANCODE_RGUI;  // left Control
    case SDL_SCANCODE_LGUI:  return SDL_SCANCODE_LALT;  // left Option
    case SDL_SCANCODE_LALT:  return SDL_SCANCODE_LCTRL; // left Command
    case SDL_SCANCODE_RALT:  return SDL_SCANCODE_LGUI;  // right Command
    case SDL_SCANCODE_RGUI:  return SDL_SCANCODE_RALT;  // right Option
    default: return physical; // right Ctrl already produces right Control
    }
}

bool put_point(Packet& packet, int x, int y, SDL_Rect r, int angle, bool clamp) {
    if (r.w < 2 || r.h < 2) return false;
    if (!clamp && (x < r.x || y < r.y || x >= r.x+r.w || y >= r.y+r.h)) return false;
    auto axis = [](int delta, int extent) {
        return static_cast<int>(std::lround(65535.0 * std::clamp(delta, 0, extent-1) / (extent-1)));
    };
    int u = axis(x-r.x, r.w), v = axis(y-r.y, r.h);
    if (angle == 90) { std::swap(u,v); v = 65535-v; }
    else if (angle == 180) { u = 65535-u; v = 65535-v; }
    else if (angle == 270) { std::swap(u,v); u = 65535-u; }
    packet[4] = uint8_t(u >> 8); packet[5] = uint8_t(u);
    packet[6] = uint8_t(v >> 8); packet[7] = uint8_t(v);
    return true;
}

VideoInput::~VideoInput() { stop(); OPENSSL_cleanse(secret_.data(), secret_.size()); }

bool VideoInput::capturing() const {
    auto state = channel_.state();
    return state == Channel::State::connecting || state == Channel::State::ready;
}

void VideoInput::stop() {
    channel_.stop();
    if (keyboard_grabbed_) {
        SDL_SetWindowKeyboardGrab(window_, SDL_FALSE);
        keyboard_grabbed_ = false;
    }
    if (buttons_) SDL_CaptureMouse(SDL_FALSE);
    buttons_ = 0;
}

void VideoInput::update(SDL_Window* window, const std::string& peer, const std::string& session, bool mac_key_positions) {
    window_ = window;
    if (peer != peer_ || session != session_) {
        stop();
        peer_ = peer;
        session_ = session;
        address_.fill(0);
        paired_ = pairing_ = popup_ = false;
        OPENSSL_cleanse(secret_.data(), secret_.size());
        video_ = {};
    }
    if (channel_.state() == Channel::State::failed) {
        const auto failure = channel_.failure_message();
        stop();
        paired_ = false;
        OPENSSL_cleanse(secret_.data(), secret_.size());
        request_pair();
        message_ = failure;
    }
    if (capturing() && SDL_GetKeyboardFocus() != window_) stop();
    // Never switch a held key's mapping between down and up.
    if (!capturing()) mac_key_positions_ = mac_key_positions;
    if (ready() && mac_key_positions_ && !keyboard_grabbed_) {
        // F8 releases the keyboard, including when fullscreen.
        SDL_SetHint(SDL_HINT_ALLOW_ALT_TAB_WHILE_GRABBED, "0");
        SDL_SetWindowKeyboardGrab(window_, SDL_TRUE);
        keyboard_grabbed_ = true;
    }
}

void VideoInput::presented(SDL_Rect pixels, int angle, int w, int h) {
    video_ = pixels;
    angle_ = angle;
    output_w_ = w;
    output_h_ = h;
}

void VideoInput::request_pair() {
    if (session_.empty() || peer_.empty()) return;
    if (paired_ && activate(address_.data(), secret_.data())) return;
    if (!address_[0]) {
        const auto candidate = private_address(peer_) ? peer_ : net::cached_peer_ipv4(peer_);
        if (private_address(candidate))
            std::snprintf(address_.data(), address_.size(), "%s", candidate.c_str());
    }
    message_.clear();
    popup_ = true;
    pairing_ = true;
}

bool VideoInput::activate(const char* address, const char* hex) {
    if (session_.empty() || peer_.empty() || (private_address(peer_) && peer_ != address) ||
        !channel_.start(address, hex)) return false;
    if (address != address_.data()) std::snprintf(address_.data(), address_.size(), "%s", address);
    if (hex != secret_.data()) std::snprintf(secret_.data(), secret_.size(), "%s", hex);
    paired_ = true;
    video_ = {};
    return true;
}

bool VideoInput::event(const SDL_Event& e) {
    if (!window_) return false;
    const auto id = SDL_GetWindowID(window_);
    if (e.type == SDL_QUIT || (e.type == SDL_WINDOWEVENT && e.window.windowID == id &&
        (e.window.event == SDL_WINDOWEVENT_FOCUS_LOST || e.window.event == SDL_WINDOWEVENT_HIDDEN ||
         e.window.event == SDL_WINDOWEVENT_MINIMIZED || e.window.event == SDL_WINDOWEVENT_CLOSE))) {
        stop();
        return false;
    }
    if (e.type == SDL_WINDOWEVENT && e.window.windowID == id && e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED)
        video_ = {};
    const bool keyboard = e.type == SDL_KEYDOWN || e.type == SDL_KEYUP;
    if (keyboard && e.key.windowID == id && e.key.keysym.scancode == SDL_SCANCODE_F8 && !session_.empty()) {
        if (e.type == SDL_KEYDOWN && !e.key.repeat) {
            if (capturing()) stop();
            else if (!pairing_ && video_.w > 1 && !ImGui::GetIO().WantTextInput) request_pair();
        }
        return true;
    }
    if (!capturing()) return false;
    if (keyboard && e.key.windowID == id) {
        auto code = e.key.keysym.scancode;
        if (mac_key_positions_) code = mac_position_code(code);
        if (code == SDL_SCANCODE_F9) code = SDL_SCANCODE_LANG1;
        if (code > 0 && code < 256)
            channel_.send({key, uint8_t(code), uint8_t(e.type == SDL_KEYUP ? 0 : e.key.repeat ? 2 : 1)});
        return true;
    }
    if (e.type == SDL_TEXTINPUT || e.type == SDL_TEXTEDITING) return true;
    Packet p{};
    int x, y;
    unsigned bit = 0;
    if (e.type == SDL_MOUSEMOTION && e.motion.windowID == id) {
        p[0] = move; x = e.motion.x; y = e.motion.y;
    } else if ((e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEBUTTONUP) && e.button.windowID == id) {
        if (e.button.button < 1 || e.button.button > 3) return true;
        bit = SDL_BUTTON(e.button.button);
        p = {button, e.button.button, uint8_t(e.type == SDL_MOUSEBUTTONDOWN), e.button.clicks};
        if (!p[2] && !(buttons_ & bit)) return true;
        x = e.button.x; y = e.button.y;
    } else if (e.type == SDL_MOUSEWHEEL && e.wheel.windowID == id) {
        const int direction = e.wheel.direction == SDL_MOUSEWHEEL_FLIPPED ? -1 : 1;
        p = {scroll, uint8_t(direction * std::clamp(e.wheel.x, -127, 127)),
                     uint8_t(direction * std::clamp(e.wheel.y, -127, 127))};
        SDL_GetMouseState(&x, &y);
    } else return false;

    int w, h;
    SDL_GetWindowSize(window_, &w, &h);
    if (w <= 0 || h <= 0 || !put_point(p, int(int64_t(x)*output_w_/w),
                                        int(int64_t(y)*output_h_/h),
                                        video_, angle_, buttons_ != 0)) {
        if (bit && !p[2] && (buttons_ & bit)) stop();
        return true;
    }
    if (!ready()) return true;
    if (bit) {
        if (p[2]) buttons_ |= bit;
        else buttons_ &= ~bit;
        SDL_CaptureMouse(buttons_ ? SDL_TRUE : SDL_FALSE);
    }
    channel_.send(p);
    return true;
}

void VideoInput::draw() {
    if (popup_) { ImGui::OpenPopup("Mac input"); popup_ = false; }
    if (ImGui::BeginPopupModal("Mac input", nullptr, ImGuiWindowFlags_AlwaysAutoResize)) {
        ImGui::Text("Mirroring peer: %s", peer_.c_str());
        ImGui::BeginDisabled(private_address(peer_));
        ImGui::InputText("Mac LAN IPv4", address_.data(), address_.size());
        ImGui::EndDisabled();
        ImGui::InputText("Pairing key", secret_.data(), secret_.size(), ImGuiInputTextFlags_Password);
        if (!message_.empty()) ImGui::TextUnformatted(message_.c_str());
        bool close = !pairing_ || session_.empty();
        if (!close && ImGui::Button("Enable input")) {
            if (activate(address_.data(), secret_.data())) {
                close = true;
            } else message_ = "Enter the Mac's private IPv4 and its 32-digit hex key.";
        }
        ImGui::SameLine();
        if (ImGui::Button("Cancel")) close = true;
        if (close) {
            pairing_ = false;
            if (!paired_) OPENSSL_cleanse(secret_.data(), secret_.size());
            ImGui::CloseCurrentPopup();
        }
        ImGui::EndPopup();
    }
    if (capturing()) {
        auto* draw = ImGui::GetForegroundDrawList();
        const char* text = ready() ?
            "Mac input on   |   F8 to release" : "Connecting to Mac   |   F8 to cancel";
        auto size = ImGui::CalcTextSize(text);
        draw->AddRectFilled({6,6}, {22+size.x,18+size.y}, IM_COL32(20,25,29,205), 5);
        draw->AddText({14,12}, IM_COL32_WHITE, text);
    }
}
} // namespace ap::input
