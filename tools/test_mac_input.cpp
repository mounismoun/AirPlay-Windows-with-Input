#include "net/socket.h"
#define SDL_MAIN_HANDLED
#include "input/video_input.h"
#include <openssl/ssl.h>
#include <chrono>
#include <cstring>
#include <iostream>
#include <thread>
#include <stdexcept>
#ifdef _WIN32
#include <windows.h>
#include <wincred.h>
#else
#include <csignal>
#endif

using namespace ap::input;
using namespace std::chrono_literals;
static void check(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}

static void geometry() {
    const SDL_Rect rect{20, 50, 201, 101};
    Packet p{};
    auto point = [&](int x, int y, int angle, bool clip, int u, int v) {
        check(put_point(p,x,y,rect,angle,clip), "point rejected");
        check(p[4]*256+p[5] == u && p[6]*256+p[7] == v, "coordinate mismatch");
    };
    check(!put_point(p,19,50,rect,0,false), "letterbox forwarded");
    check(!put_point(p,220,151,rect,0,false), "bottom letterbox forwarded");
    check(!put_point(p,20,50,{0,0,0,0},0,true), "empty viewport");
    point(20,50,0,false,0,0);
    point(220,150,0,false,65535,65535);
    point(120,100,0,false,32768,32768);
    point(20,50,90,false,0,65535);
    point(20,50,180,false,65535,65535);
    point(20,50,270,false,65535,0);
    point(-10,400,0,true,0,65535);
}

static constexpr char test_key[] = "000102030405060708090a0b0c0d0e0f";
static unsigned int server_key(SSL*, const char* identity, unsigned char* psk, unsigned int cap) {
    if (!identity || std::strcmp(identity, "airplay-input-v1") || cap < 16) return 0;
    for (int i=0; i<16; ++i) psk[i]=static_cast<unsigned char>(i);
    return 16;
}

static bool until(Channel& client, Channel::State state) {
    auto end = std::chrono::steady_clock::now()+5s;
    while (client.state()!=state && std::chrono::steady_clock::now()<end)
        std::this_thread::sleep_for(2ms);
    return client.state()==state;
}

#ifdef _WIN32
static void remembered_pairing_test(socket_t listener, SSL_CTX* ctx) {
    const std::string device = "test-" + std::to_string(GetCurrentProcessId()) + "-" +
                               std::to_string(GetTickCount64());
    const auto target = pairing_target(device, "Test Mac", "127.0.0.1");
    struct Cleanup {
        const std::string& target;
        ~Cleanup() { CredDeleteA(target.c_str(), CRED_TYPE_GENERIC, 0); }
    } cleanup{target};
    check(target == pairing_target(device, "Renamed", "192.168.1.4"), "IP or name changed credential");
    check(target != pairing_target(device + "B", "Test Mac", "127.0.0.1"), "device credentials collided");
    PairingKey key{};
    check(!read_pairing(target, key), "unexpected test credential");
    for (const std::string session : {"first", "remembered", "rotated"}) {
        VideoInput video;
        video.update(nullptr, "127.0.0.1", session, false, device, "Test Mac");
        if (session == "first") {
            check(video.activate("127.0.0.1", test_key, true), "first pairing");
            check(!read_pairing(target, key), "stored key before authentication");
        } else {
            if (session == "rotated") {
                key[0] = 'f'; // The saved key predates the Mac's current key.
                check(write_pairing(target, key), "could not seed a stale pairing");
            }
            video.request_pair();
            check(video.capturing() && !video.pairing(), "remembered pairing prompted again");
        }
        if (session == "rotated") {
            socket_t stale = accept(listener, nullptr, nullptr);
            SSL* rejected = SSL_new(ctx);
            check(stale != INVALID_SOCK && rejected && SSL_set_fd(rejected, static_cast<int>(stale)) &&
                  SSL_accept(rejected) != 1, "stale pairing accepted");
            SSL_free(rejected);
            ap::net::close_socket(stale);
            auto until_prompt = std::chrono::steady_clock::now() + 3s;
            while (!video.pairing() && std::chrono::steady_clock::now() < until_prompt) {
                video.update(nullptr, "127.0.0.1", session, false, device, "Test Mac");
                std::this_thread::sleep_for(2ms);
            }
            check(video.pairing() && !video.capturing(), "no recovery after key rotation");
            check(video.activate("127.0.0.1", test_key, true), "could not replace stale key");
        }
        socket_t fd = accept(listener, nullptr, nullptr);
        SSL* ssl = SSL_new(ctx);
        check(fd != INVALID_SOCK && ssl && SSL_set_fd(ssl, static_cast<int>(fd)) &&
              SSL_accept(ssl) == 1 && SSL_write(ssl, "\1", 1) == 1, "remembered handshake");
        auto end = std::chrono::steady_clock::now() + 3s;
        while (!video.ready() && std::chrono::steady_clock::now() < end)
            std::this_thread::sleep_for(2ms);
        check(video.ready(), "remembered connection not ready");
        video.update(nullptr, "127.0.0.1", session, false, device, "Test Mac");
        check(read_pairing(target, key) && std::strcmp(key.data(), test_key) == 0,
              "verified key not in Windows Credential Manager");
        video.update(nullptr, "", "");
        SSL_free(ssl);
        ap::net::close_socket(fd);
    }
}
#endif

static void capture_test(socket_t listener, SSL_CTX* ctx, bool mac_positions) {
    SDL_SetMainReady();
    SDL_setenv("SDL_VIDEODRIVER","dummy",1);
    check(SDL_Init(SDL_INIT_VIDEO)==0,"dummy video");
    SDL_Window* window = SDL_CreateWindow("input test",0,0,400,240,SDL_WINDOW_HIDDEN);
    check(window != nullptr,"event window");
    VideoInput video;
    video.update(window,"","");
    check(!video.activate("127.0.0.1",test_key),"armed outside mirroring");
    video.update(window,"127.0.0.1","session A",mac_positions);
    check(!video.activate("192.168.1.2",test_key),"accepted a different IPv4 mirror peer");
    check(video.activate("127.0.0.1",test_key),"pair input");
    socket_t fd = accept(listener,nullptr,nullptr);
    SSL* ssl = SSL_new(ctx);
    check(fd != INVALID_SOCK && ssl && SSL_set_fd(ssl,static_cast<int>(fd)) &&
          SSL_accept(ssl)==1 && SSL_write(ssl,"\1",1)==1,"test agent handshake");
    auto deadline = std::chrono::steady_clock::now()+3s;
    while (!video.ready() && std::chrono::steady_clock::now()<deadline)
        std::this_thread::sleep_for(2ms);
    check(video.ready(),"paired window not ready");
    auto expect = [&](Packet wanted) {
        Packet actual{};
        // Heartbeats may precede input on a busy CI machine.
        do { check(SSL_read(ssl,actual.data(),8)==8,"missing event"); } while (!actual[0]);
        check(actual==wanted,"unexpected SDL input on wire");
    };
    video.presented({100,40,601,401},0,800,480);
    SDL_Event e{};
    const auto id = SDL_GetWindowID(window);
    e.type=SDL_MOUSEMOTION; e.motion.windowID=id; e.motion.x=1; e.motion.y=1;
    check(video.event(e),"letterbox escaped to local shortcuts");
    e.type=SDL_MOUSEBUTTONDOWN; e.button.windowID=id; e.button.button=SDL_BUTTON_LEFT;
    e.button.clicks=2; e.button.x=50; e.button.y=20;
    check(video.event(e),"double-click escaped");
    expect({button,1,1,2,0,0,0,0});
    e.type=SDL_MOUSEMOTION; e.motion.windowID=id; e.motion.x=399; e.motion.y=239;
    video.event(e);
    expect({move,0,0,0,255,255,255,255});
    e.type=SDL_MOUSEBUTTONUP; e.button.windowID=id; e.button.button=SDL_BUTTON_LEFT;
    e.button.clicks=2; e.button.x=399; e.button.y=239;
    video.event(e);
    expect({button,1,0,2,255,255,255,255});
    const auto press = [&](SDL_Scancode physical, uint8_t wire, bool down) {
        SDL_Event k{};
        k.type = down ? SDL_KEYDOWN : SDL_KEYUP;
        k.key.windowID = id;
        k.key.keysym.scancode = physical;
        check(video.event(k), "modifier chord escaped to receiver");
        expect({key, wire, uint8_t(down)});
    };
    struct Binding { SDL_Scancode physical; uint8_t position_code; };
    for (Binding b : {Binding{SDL_SCANCODE_LCTRL,231}, {SDL_SCANCODE_LGUI,226},
                      {SDL_SCANCODE_LALT,224}, {SDL_SCANCODE_RALT,227},
                      {SDL_SCANCODE_RGUI,230}, {SDL_SCANCODE_RCTRL,228}}) {
        uint8_t wire = mac_positions ? b.position_code : uint8_t(b.physical);
        press(b.physical,wire,true);
        press(SDL_SCANCODE_C,6,true);
        press(SDL_SCANCODE_C,6,false);
        press(b.physical,wire,false);
    }
    press(SDL_SCANCODE_CAPSLOCK,57,true);
    press(SDL_SCANCODE_CAPSLOCK,57,false);
#ifdef _WIN32
    // Exercise native Korean make-only input and the 101-key shared positions
    // through the SDL queue, renderer input path and authenticated wire.
    const auto native = [&](UINT vk, Uint32 scan, bool down, int events) {
        check(queue_windows_language_key(id, vk, scan, down), "unhandled Korean virtual key");
        SDL_Event pending{};
        int count = 0;
        while (SDL_PeepEvents(&pending, 1, SDL_GETEVENT, SDL_KEYDOWN, SDL_KEYUP) == 1) {
            check(video.event(pending), "Korean key escaped input capture");
            ++count;
        }
        check(count == events, "unexpected Korean key event count");
    };
    native(VK_HANGUL, 0xf2u << 16, true, 2);
    expect({key,144,1}); expect({key,144,0});
    native(VK_HANGUL, (0xf2u << 16) | (1u << 30), true, 0);
    native(VK_HANGUL, 0xf2u << 16, false, 0);
    const Uint32 right_alt_scan = (1u << 24) | (0x38u << 16);
    const uint8_t alt_wire = mac_positions ? 227 : 230;
    native(VK_HANGUL, right_alt_scan, true, 1); expect({key,alt_wire,1});
    native(VK_HANGUL, right_alt_scan, false, 1); expect({key,alt_wire,0});
    if (!mac_positions) { expect({key,144,1}); expect({key,144,0}); }
    // A physical Command tap must not add a language pulse before this key.
    press(SDL_SCANCODE_A,4,true); press(SDL_SCANCODE_A,4,false);
    native(VK_HANGUL, right_alt_scan, true, 1); expect({key,alt_wire,1});
    press(SDL_SCANCODE_C,6,true); press(SDL_SCANCODE_C,6,false);
    native(VK_HANGUL, right_alt_scan, false, 1); expect({key,alt_wire,0});
    const Uint32 right_ctrl_scan = (1u << 24) | (0x1du << 16);
    native(VK_HANJA, right_ctrl_scan, true, 1); expect({key,228,1});
    native(VK_HANJA, right_ctrl_scan, false, 1); expect({key,228,0});
    check(!queue_windows_language_key(id, VK_HANJA, 0xf1u << 16, true),
          "dedicated Hanja key confused with right Ctrl");
    native(VK_F4, 0, true, 1); expect({key,SDL_SCANCODE_F4,1});
    native(VK_F4, 0, false, 1); expect({key,SDL_SCANCODE_F4,0});
    native(VK_ESCAPE, 0, true, 1); expect({key,SDL_SCANCODE_ESCAPE,1});
    native(VK_ESCAPE, 0, false, 1); expect({key,SDL_SCANCODE_ESCAPE,0});
    check(!queue_windows_language_key(id, VK_F4, 0x3eu << 16, true),
          "hardware F4 should follow SDL's normal path");
#endif
    if (mac_positions) {
        for (int f = SDL_SCANCODE_F1; f <= SDL_SCANCODE_F12; ++f) {
            press(static_cast<SDL_Scancode>(f), uint8_t(f), true);
            press(static_cast<SDL_Scancode>(f), uint8_t(f), false);
        }
        for (Binding b : {Binding{SDL_SCANCODE_BRIGHTNESSDOWN,240}, {SDL_SCANCODE_BRIGHTNESSUP,241},
                          {SDL_SCANCODE_AUDIOPREV,246}, {SDL_SCANCODE_AUDIOPLAY,247},
                          {SDL_SCANCODE_AUDIONEXT,248}, {SDL_SCANCODE_AUDIOMUTE,249},
                          {SDL_SCANCODE_VOLUMEDOWN,250}, {SDL_SCANCODE_VOLUMEUP,251}}) {
            press(b.physical,b.position_code,true);
            press(b.physical,b.position_code,false);
        }
        e = {}; e.type=SDL_KEYDOWN; e.key.windowID=id; e.key.keysym.mod=KMOD_LSHIFT;
        e.key.keysym.scancode=SDL_SCANCODE_F9;
        video.event(e); expect({key,144,1});
        e.type=SDL_KEYUP; e.key.keysym.mod=KMOD_NONE;
        video.event(e); expect({key,144,0});
        e.type=SDL_KEYDOWN; e.key.keysym.mod=KMOD_RSHIFT; e.key.keysym.scancode=SDL_SCANCODE_F8;
        check(video.event(e) && !video.capturing(), "Shift+F8 did not release capture");
    } else {
        press(SDL_SCANCODE_F9,144,true); press(SDL_SCANCODE_F9,144,false);
        e = {}; e.type=SDL_WINDOWEVENT; e.window.windowID=id; e.window.event=SDL_WINDOWEVENT_FOCUS_LOST;
        video.event(e);
        check(!video.capturing(),"focus loss left capture on");
    }
    Packet last{};
    int count;
    do { count=SSL_read(ssl,last.data(),8); } while (count==8 && last[0]==heartbeat);
    check(count<=0,"connection survived focus loss");
    video.update(window,"","");
    SSL_free(ssl);
    ap::net::close_socket(fd);
    SDL_DestroyWindow(window);
    SDL_Quit();
}

static void channel_test() {
    socket_t listener = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(49721);
#ifndef _WIN32
    int yes = 1;
    setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
#endif
    check(bind(listener,reinterpret_cast<sockaddr*>(&addr),sizeof(addr))==0 &&
          listen(listener,1)==0, "test needs loopback port 49721");
    SSL_CTX* ctx = SSL_CTX_new(TLS_server_method());
    check(ctx && SSL_CTX_set_max_proto_version(ctx,TLS1_2_VERSION) &&
          SSL_CTX_set_cipher_list(ctx,"PSK-AES128-GCM-SHA256"), "TLS context");
    SSL_CTX_set_psk_server_callback(ctx,server_key);
    Channel client;
    Packet sent{button,3,1,2,0xff,0,0,1};
    for (bool valid : {false,true}) {
        check(client.start("127.0.0.1",valid ? test_key : "ffffffffffffffffffffffffffffffff"), "start");
        socket_t fd = accept(listener,nullptr,nullptr);
        check(fd != INVALID_SOCK,"accept");
        SSL* ssl = SSL_new(ctx);
        check(ssl && SSL_set_fd(ssl,static_cast<int>(fd)), "TLS socket");
        bool accepted = SSL_accept(ssl)==1;
        check(accepted==valid, "PSK authentication");
        if (valid) {
            check(SSL_write(ssl,"\1",1)==1 && until(client,Channel::State::ready), "ready acknowledgement");
            client.send(sent);
            Packet received{};
            check(SSL_read(ssl,received.data(),8)==8 && received==sent,"input frame");
            check(SSL_read(ssl,received.data(),8)==8 && received==Packet{}, "idle heartbeat");
            client.stop();
            check(SSL_read(ssl,received.data(),8)<=0, "socket still active after release");
        } else {
            check(until(client,Channel::State::failed), "bad key accepted");
            check(client.failure_message().find("TLS pairing failed") != std::string::npos,
                  "bad key was not identified as a TLS-stage failure");
        }
        SSL_free(ssl);
        ap::net::close_socket(fd);
    }
    capture_test(listener,ctx,true);
    capture_test(listener,ctx,false);
#ifdef _WIN32
    remembered_pairing_test(listener,ctx);
#endif
    check(client.start("127.0.0.1",test_key), "ack test start");
    socket_t fd = accept(listener,nullptr,nullptr);
    SSL* ssl = SSL_new(ctx);
    check(fd != INVALID_SOCK && ssl && SSL_set_fd(ssl,static_cast<int>(fd)) && SSL_accept(ssl)==1,
          "ack test TLS");
    SSL_shutdown(ssl);
    SSL_free(ssl);
    ap::net::close_socket(fd);
    check(until(client,Channel::State::failed) && client.failure_message().find("input readiness") != std::string::npos,
          "lost ready acknowledgement was not identified");
    SSL_CTX_free(ctx);
    ap::net::close_socket(listener);
    check(client.start("127.0.0.1",test_key) && until(client,Channel::State::failed) &&
          client.failure_message().find("TCP connection to 127.0.0.1:49721 failed") != std::string::npos,
          "connection refusal was not identified");
    VideoInput retry;
    retry.update(nullptr, "127.0.0.1", "retry", false);
    check(retry.activate("127.0.0.1", test_key), "start refused session");
    auto end = std::chrono::steady_clock::now() + 5s;
    while (!retry.pairing() && std::chrono::steady_clock::now() < end) {
        retry.update(nullptr, "127.0.0.1", "retry", false);
        std::this_thread::sleep_for(2ms);
    }
    check(retry.confirm_pairing(), "TCP refusal discarded the entered pairing key");
}

int main() {
#ifndef _WIN32
    signal(SIGPIPE,SIG_IGN);
#endif
    check(ap::net::global_init(),"socket init");
    Secret secret{};
    check(decode_secret(test_key,secret) && secret[15]==15, "key decode");
    check(!decode_secret("123",secret) && !decode_secret("z00102030405060708090a0b0c0d0e0f",secret),"invalid key");
    check(private_address("fe80::1%12") && private_address("fd12::2") &&
          !private_address("fe80::1") && !private_address("fe80::1%0") &&
          !private_address("fe80::1%3x") && !private_address("2001:db8::1") &&
          !private_address("ff02::1%12"), "IPv6 LAN address policy");
    check(private_address("172.31.255.255") && !private_address("172.32.0.1") &&
          !private_address("0.0.0.0") && !private_address("8.8.8.8"), "address policy");
    geometry();
    channel_test();
    ap::net::global_shutdown();
    std::cout << "Geometry, address bounds, PSK acceptance/rejection, packet, heartbeat and release passed\n";
}
