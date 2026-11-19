#pragma once
#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

namespace ap::input {

enum Kind : uint8_t { heartbeat, move, button, scroll, key };
using Packet = std::array<uint8_t, 8>;
using Secret = std::array<uint8_t, 16>;
bool decode_secret(const char* hex, Secret& secret);
bool private_address(const std::string& ip);

class Channel {
public:
    enum class State { off, connecting, ready, failed };
    ~Channel();
    bool start(const std::string& ip, const char* hex);
    void stop();
    void send(Packet packet);
    State state() const { return state_.load(); }
private:
    void run(std::string ip, Secret secret);
    std::atomic<State> state_{State::off};
    std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<Packet> queue_;
    std::thread worker_;
};

} // namespace ap::input
