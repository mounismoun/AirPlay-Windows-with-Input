#include "input/channel.h"
#include "net/socket.h"
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <algorithm>
#include <chrono>
#include <charconv>
#include <cstring>
#include <memory>
#ifndef _WIN32
#include <csignal>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <pthread.h>
#endif

namespace ap::input {
using namespace std::chrono_literals;
using Clock = std::chrono::steady_clock;

static int local_endpoint(const std::string& ip, sockaddr_storage& endpoint) {
    if (ip.find('\0') != std::string::npos) return 0;
    sockaddr_in v4{};
    if (inet_pton(AF_INET, ip.c_str(), &v4.sin_addr) == 1) {
        const uint32_t n = ntohl(v4.sin_addr.s_addr);
        if (!(n == 0x7f000001 || (n >> 24) == 10 || (n >> 20) == 0xac1 ||
              (n >> 16) == 0xc0a8 || (n >> 16) == 0xa9fe)) return 0;
        v4.sin_family = AF_INET;
        v4.sin_port = htons(49721);
        std::memcpy(&endpoint, &v4, sizeof(v4));
        return sizeof(v4);
    }
    sockaddr_in6 v6{};
    const auto zone = ip.find('%');
    if (inet_pton(AF_INET6, ip.substr(0, zone).c_str(), &v6.sin6_addr) != 1) return 0;
    if (zone != std::string::npos) {
        auto end = ip.data() + ip.size();
        uint32_t index = 0;
        auto parsed = std::from_chars(ip.data() + zone + 1, end, index);
        if (parsed.ec != std::errc{} || parsed.ptr != end || index == 0) return 0;
        v6.sin6_scope_id = index;
    }
    const bool link_local = IN6_IS_ADDR_LINKLOCAL(&v6.sin6_addr) && v6.sin6_scope_id;
    if (!link_local && (v6.sin6_addr.s6_addr[0] & 0xfe) != 0xfc) return 0;
    v6.sin6_family = AF_INET6;
    v6.sin6_port = htons(49721);
    std::memcpy(&endpoint, &v6, sizeof(v6));
    return sizeof(v6);
}

bool private_address(const std::string& ip) {
    sockaddr_storage endpoint{};
    return local_endpoint(ip, endpoint) != 0;
}

bool decode_secret(const char* hex, Secret& secret) {
    if (std::strlen(hex) != 2 * secret.size()) return false;
    auto digit = [](char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    for (size_t i = 0; i < secret.size(); ++i) {
        int a = digit(hex[2*i]), b = digit(hex[2*i+1]);
        if (a < 0 || b < 0) return false;
        secret[i] = static_cast<uint8_t>(a * 16 + b);
    }
    return true;
}

Channel::~Channel() { stop(); if (worker_.joinable()) worker_.join(); }

bool Channel::start(const std::string& ip, const char* hex) {
    Secret secret{};
    if (!private_address(ip) || !decode_secret(hex, secret)) return false;
    stop();
    if (worker_.joinable()) worker_.join();
    state_ = State::connecting;
    worker_ = std::thread(&Channel::run, this, ip, secret);
    OPENSSL_cleanse(secret.data(), secret.size());
    return true;
}

void Channel::stop() {
    std::lock_guard<std::mutex> guard(mutex_);
    state_ = State::off;
    queue_.clear();
    wake_.notify_one();
}

std::string Channel::failure_message() {
    std::lock_guard<std::mutex> guard(mutex_);
    return failure_;
}

void Channel::send(Packet p) {
    std::lock_guard<std::mutex> guard(mutex_);
    if (state_ != State::ready) return;
    if (p[0] == move && !queue_.empty() && queue_.back()[0] == move)
        queue_.back() = p;
    else if (queue_.size() < 128)
        queue_.push_back(p);
    else {
        failure_ = "Input queue filled while sending. Reconnect to resume.";
        state_ = State::failed;
        queue_.clear();
    }
    wake_.notify_one();
}

namespace {
unsigned int supply_key(SSL* ssl, const char*, char* identity, unsigned int cap,
                        unsigned char* out, unsigned int size) {
    constexpr char id[] = "airplay-input-v1";
    auto* secret = static_cast<const Secret*>(SSL_get_app_data(ssl));
    if (!secret || cap < sizeof(id) || size < secret->size()) return 0;
    std::memcpy(identity, id, sizeof(id));
    std::memcpy(out, secret->data(), secret->size());
    return static_cast<unsigned>(secret->size());
}
struct Socket {
    socket_t fd;
    ~Socket() { if (fd != INVALID_SOCK) net::close_socket(fd); }
};
}

void Channel::run(std::string ip, Secret secret) {
#ifndef _WIN32
    sigset_t blocked;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &blocked, nullptr);
#endif
    std::string failure;
    bool tcp_connected = false;
    auto connect_and_send = [&]() {
        const std::string endpoint = (ip.find(':') == std::string::npos ? ip : "[" + ip + "]") + ":49721";
        failure = "Could not open a TCP socket for " + endpoint;
        sockaddr_storage peer{};
        int length = local_endpoint(ip, peer);
        if (!length) return;
        Socket sock{::socket(peer.ss_family, SOCK_STREAM, IPPROTO_TCP)};
        if (sock.fd == INVALID_SOCK) return;
#ifdef _WIN32
        u_long mode = 1;
        if (ioctlsocket(sock.fd, FIONBIO, &mode)) return;
#else
        if (fcntl(sock.fd, F_SETFL, O_NONBLOCK) < 0 || sock.fd >= FD_SETSIZE) return;
#endif
        int enabled = 1;
        setsockopt(sock.fd, IPPROTO_TCP, TCP_NODELAY,
                   reinterpret_cast<const char*>(&enabled), sizeof(enabled));
        auto wait_io = [&](bool writing, Clock::time_point deadline) {
            while (state_ != State::off && state_ != State::failed && Clock::now() < deadline) {
                fd_set ready, errors;
                FD_ZERO(&ready); FD_SET(sock.fd, &ready);
                FD_ZERO(&errors); FD_SET(sock.fd, &errors);
                timeval timeout{0, 50000};
                int rc = select(static_cast<int>(sock.fd + 1), writing ? nullptr : &ready,
                                writing ? &ready : nullptr, &errors, &timeout);
                // A nonblocking Winsock connect reports refusal in exceptfds.
                // Let the caller read SO_ERROR (or retry the TLS operation).
                if (rc != 0) return rc > 0;
            }
            return false;
        };
        auto deadline = Clock::now() + 4s;
        failure = "TCP connection to " + endpoint;
        if (connect(sock.fd, reinterpret_cast<sockaddr*>(&peer), length) != 0) {
            const int initial = net::last_error();
#ifdef _WIN32
            const bool pending = initial == WSAEWOULDBLOCK || initial == WSAEINPROGRESS;
#else
            const bool pending = initial == EINPROGRESS;
#endif
            if (!pending) {
                failure += " failed (socket " + std::to_string(initial) + ").";
                return;
            }
            if (!wait_io(true, deadline)) {
                failure += Clock::now() >= deadline ? " timed out." : " interrupted.";
                return;
            }
            int error = 0;
#ifdef _WIN32
            int len = sizeof(error);
#else
            socklen_t len = sizeof(error);
#endif
            if (getsockopt(sock.fd, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&error), &len))
                error = net::last_error();
            if (error) {
                failure += " failed (socket " + std::to_string(error) + ").";
                return;
            }
        }
        tcp_connected = true;
        failure = "TCP connected. Windows could not initialize TLS-PSK.";
        std::unique_ptr<SSL_CTX, decltype(&SSL_CTX_free)> ctx(SSL_CTX_new(TLS_client_method()), SSL_CTX_free);
        if (!ctx || !SSL_CTX_set_min_proto_version(ctx.get(), TLS1_2_VERSION) ||
            !SSL_CTX_set_max_proto_version(ctx.get(), TLS1_2_VERSION) ||
            !SSL_CTX_set_cipher_list(ctx.get(), "PSK-AES128-GCM-SHA256")) return;
        SSL_CTX_set_psk_client_callback(ctx.get(), supply_key);
        std::unique_ptr<SSL, decltype(&SSL_free)> tls(SSL_new(ctx.get()), SSL_free);
        if (!tls || !SSL_set_fd(tls.get(), static_cast<int>(sock.fd))) return;
        SSL_set_app_data(tls.get(), &secret);
        auto transfer = [&](auto operation, Clock::time_point until) {
            while (state_ != State::off && state_ != State::failed) {
                ERR_clear_error();
                int result = operation();
                if (result > 0) return result;
                int error = SSL_get_error(tls.get(), result);
                if (error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE) {
                    const char* reason = ERR_reason_error_string(ERR_peek_last_error());
                    if (reason) failure += std::string(" (") + reason + ")";
                    else if (error == SSL_ERROR_ZERO_RETURN) failure += " (peer closed TLS)";
                    else failure += " (TLS I/O " + std::to_string(error) + ")";
                    break;
                }
                if (!wait_io(error == SSL_ERROR_WANT_WRITE, until)) {
                    if (Clock::now() >= until) failure += " (timed out)";
                    break;
                }
            }
            return 0;
        };
        failure = "TCP connected to " + ip + ". TLS pairing failed";
        if (!transfer([&] { return SSL_connect(tls.get()); }, Clock::now() + 5s)) return;
        uint8_t ack = 0;
        failure = "TLS paired. The Mac agent did not confirm input readiness";
        if (!transfer([&] { return SSL_read(tls.get(), &ack, 1); }, Clock::now() + 4s)) return;
        if (ack != 1) {
            failure = "TLS paired. Unexpected Mac agent protocol version.";
            return;
        }
        State expected = State::connecting;
        if (!state_.compare_exchange_strong(expected, State::ready)) return;
        failure = "The paired Mac input session disconnected";
        while (state_ == State::ready) {
            Packet packet{};
            {
                std::unique_lock<std::mutex> lock(mutex_);
                wake_.wait_for(lock, 500ms, [&] { return state_ != State::ready || !queue_.empty(); });
                if (state_ != State::ready) break;
                if (!queue_.empty()) {
                    packet = queue_.front();
                    queue_.pop_front();
                }
            }
            if (transfer([&] { return SSL_write(tls.get(), packet.data(), static_cast<int>(packet.size())); },
                         Clock::now() + 1s) != static_cast<int>(packet.size())) break;
        }
        SSL_shutdown(tls.get());
    };
    connect_and_send();
    if (!tcp_connected && state_ == State::connecting && ip.find(':') != std::string::npos) {
        auto other = net::cached_peer_ipv4(ip);
        if (private_address(other) && state_ == State::connecting) {
            const auto first_failure = failure;
            ip = std::move(other);
            connect_and_send();
            if (!tcp_connected) failure = first_failure + "\n" + failure;
        }
    }
    if (!tcp_connected)
        failure += "\nOpen AirPlay Input on the Mac and check that it is waiting for Windows.";
    OPENSSL_cleanse(secret.data(), secret.size());
    std::lock_guard<std::mutex> guard(mutex_);
    if (state_ == State::connecting || state_ == State::ready) {
        failure_ = std::move(failure);
        state_ = State::failed;
    }
    queue_.clear();
}
} // namespace ap::input
