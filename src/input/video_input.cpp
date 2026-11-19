#include "input/video_input.h"
#include "log.h"
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

// The 240..251 wire usages request the system action at F1..F12 even
// when the Mac is configured to use numbered function keys by default.
static int mac_wire_code(SDL_Scancode code) {
    switch (code) {
    case SDL_SCANCODE_BRIGHTNESSDOWN: return 240;
    case SDL_SCANCODE_BRIGHTNESSUP:   return 241;
    case SDL_SCANCODE_AUDIOPREV:      return 246;
    case SDL_SCANCODE_AUDIOPLAY:      return 247;
    case SDL_SCANCODE_AUDIONEXT:      return 248;
    case SDL_SCANCODE_MUTE:
    case SDL_SCANCODE_AUDIOMUTE:      return 249;
    case SDL_SCANCODE_VOLUMEDOWN:     return 250;
    case SDL_SCANCODE_VOLUMEUP:       return 251;
    default: return mac_position_code(code);
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
#ifdef _WIN32
    windows_keyboard_.detach();
#endif
    held_keys_.reset();
    hangul_tap_ = false;
    language_f9_ = false;
    local_f8_ = false;
    write_pending_ = false;
    if (keyboard_grabbed_) {
        SDL_SetWindowKeyboardGrab(window_, SDL_FALSE);
        keyboard_grabbed_ = false;
    }
    if (buttons_) SDL_CaptureMouse(SDL_FALSE);
    buttons_ = 0;
}

void VideoInput::update(SDL_Window* window, const std::string& peer, const std::string& session,
                        bool mac_key_positions, const std::string& device_id, const std::string& device_name) {
    window_ = window;
    if (peer != peer_ || session != session_ || device_id != device_id_ || device_name != device_name_) {
        stop();
        peer_ = peer;
        session_ = session;
        device_id_ = device_id;
        device_name_ = device_name;
        target_ = pairing_target(device_id, device_name, peer);
        address_.fill(0);
        paired_ = pairing_ = popup_ = false;
        OPENSSL_cleanse(secret_.data(), secret_.size());
        video_ = {};
    }
    if (channel_.state() == Channel::State::failed) {
        const auto failure = channel_.failure_message();
        stop();
        paired_ = false;
        // Keep the attempted key in this modal for retry. Cancel and session
        // changes clear it; only a successful handshake can persist it.
        popup_ = pairing_ = true;
        message_ = failure;
    }
    if (ready()) paired_ = true;
    if (write_pending_ && ready()) {
        if (!write_pairing(target_, secret_)) LOG_WARN << "Windows could not save the key for Mac input.";
        write_pending_ = false;
    }
    if (capturing() && SDL_GetKeyboardFocus() != window_) stop();
    // Never switch a held key's mapping between down and up.
    if (!capturing()) mac_key_positions_ = mac_key_positions;
#ifdef _WIN32
    if (ready()) windows_keyboard_.attach(window_);
#endif
    if (ready() && mac_key_positions_ && !keyboard_grabbed_) {
        // Shift+F8 releases the keyboard, including when fullscreen.
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
    if (!address_[0]) {
        const auto candidate = private_address(peer_) ? peer_ : net::cached_peer_ipv4(peer_);
        if (private_address(candidate))
            std::snprintf(address_.data(), address_.size(), "%s", candidate.c_str());
    }
    if (address_[0] && (paired_ || read_pairing(target_, secret_)) &&
        activate(address_.data(), secret_.data())) return;
    message_.clear();
    popup_ = true;
    pairing_ = true;
}

bool VideoInput::activate(const char* address, const char* hex, bool remember) {
    const bool fixed_v4 = peer_.find(':') == std::string::npos && private_address(peer_);
    if (session_.empty() || peer_.empty() || (fixed_v4 && peer_ != address) ||
        !channel_.start(address, hex)) return false;
    if (address != address_.data()) std::snprintf(address_.data(), address_.size(), "%s", address);
    if (hex != secret_.data()) std::snprintf(secret_.data(), secret_.size(), "%s", hex);
    write_pending_ = remember;
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
            const bool local = !ready() || !mac_key_positions_ || (e.key.keysym.mod & KMOD_SHIFT);
            if (local) {
                if (capturing()) stop();
                else if (!pairing_ && video_.w > 1 && !ImGui::GetIO().WantTextInput) request_pair();
            }
            local_f8_ = local;
        }
        if (local_f8_ || !capturing()) {
            if (e.type == SDL_KEYUP) local_f8_ = false;
            return true;
        }
    }
    if (!capturing()) return false;
    if (keyboard && e.key.windowID == id) {
        const auto physical = e.key.keysym.scancode;
        int code = mac_key_positions_ ? mac_wire_code(physical) : static_cast<int>(physical);
        const bool down = e.type == SDL_KEYDOWN;
        const bool right_alt = physical == SDL_SCANCODE_RALT;
        if (!right_alt) hangul_tap_ = false;
        // In MacBook layout this physical key is always right Command,
        // including on Korean 101-key layouts where Windows calls it Hangul.
        if (!mac_key_positions_ && right_alt && down && !e.key.repeat) {
            bool shared = e.key.keysym.sym == SDL_SCANCODE_TO_KEYCODE(SDL_SCANCODE_LANG1);
#ifdef _WIN32
            shared = shared || windows_keyboard_.shared_right_alt();
#endif
            hangul_tap_ = shared && !buttons_ && held_keys_.none();
        }
        if (physical == SDL_SCANCODE_F9) {
            if (down && !e.key.repeat) language_f9_ = !mac_key_positions_ || (e.key.keysym.mod & KMOD_SHIFT);
            if (language_f9_) code = SDL_SCANCODE_LANG1;
            if (!down) language_f9_ = false;
        }
        if (code > 0 && code < 256) {
            held_keys_.set(code, down);
            channel_.send({key, uint8_t(code), uint8_t(down ? (e.key.repeat ? 2 : 1) : 0)});
        }
        if (right_alt && !down && hangul_tap_) {
            channel_.send({key, SDL_SCANCODE_LANG1, 1});
            channel_.send({key, SDL_SCANCODE_LANG1, 0});
            hangul_tap_ = false;
        }
        return true;
    }
    if (e.type == SDL_TEXTINPUT || e.type == SDL_TEXTEDITING) return true;
    Packet p{};
    int x, y;
    unsigned bit = 0;
    if (e.type == SDL_MOUSEMOTION && e.motion.windowID == id) {
        p[0] = move; x = e.motion.x; y = e.motion.y;
    } else if ((e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEBUTTONUP) && e.button.windowID == id) {
        hangul_tap_ = false;
        if (e.button.button < 1 || e.button.button > 3) return true;
        bit = SDL_BUTTON(e.button.button);
        p = {button, e.button.button, uint8_t(e.type == SDL_MOUSEBUTTONDOWN), e.button.clicks};
        if (!p[2] && !(buttons_ & bit)) return true;
        x = e.button.x; y = e.button.y;
    } else if (e.type == SDL_MOUSEWHEEL && e.wheel.windowID == id) {
        hangul_tap_ = false;
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
        ImGui::Text("Mac: %s", device_name_.empty() ? peer_.c_str() : device_name_.c_str());
        ImGui::TextUnformatted("Copy the pairing key from the Mac app. Windows remembers it after connecting.");
        if (mac_key_positions_) ImGui::TextUnformatted("Press Shift+F8 to release Mac input.");
        if (peer_.find(':') != std::string::npos &&
            ImGui::CollapsingHeader("Connection address", address_[0] ? 0 : ImGuiTreeNodeFlags_DefaultOpen))
            ImGui::InputText("Mac LAN address", address_.data(), address_.size());
        ImGui::InputText("Pairing key", secret_.data(), secret_.size(), ImGuiInputTextFlags_Password);
        if (!message_.empty()) ImGui::TextUnformatted(message_.c_str());
        bool close = !pairing_ || session_.empty();
        if (!close && ImGui::Button("Enable input")) {
            if (confirm_pairing()) {
                close = true;
            } else message_ = "Check the local Mac address and its 32-digit hexadecimal pairing key.";
        }
        ImGui::SameLine();
        if (ImGui::Button("Cancel")) close = true;
        if (close) {
            pairing_ = false;
            if (!paired_ && !capturing()) OPENSSL_cleanse(secret_.data(), secret_.size());
            ImGui::CloseCurrentPopup();
        }
        ImGui::EndPopup();
    }
}
} // namespace ap::input
