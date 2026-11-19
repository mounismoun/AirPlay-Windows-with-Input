#include "net/socket.h"
#define SDL_MAIN_HANDLED
#include "input/video_input.h"
#include <openssl/ssl.h>
#include <chrono>
#include <cstring>
#include <iostream>
#include <thread>
#include <stdexcept>
#ifndef _WIN32
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

static void capture_test(socket_t listener, SSL_CTX* ctx) {
    SDL_SetMainReady();
    SDL_setenv("SDL_VIDEODRIVER","dummy",1);
    check(SDL_Init(SDL_INIT_VIDEO)==0,"dummy video");
    SDL_Window* window = SDL_CreateWindow("input test",0,0,400,240,SDL_WINDOW_HIDDEN);
    check(window != nullptr,"event window");
    VideoInput video;
    video.update(window,"","");
    check(!video.activate("127.0.0.1",test_key),"armed outside mirroring");
    video.update(window,"127.0.0.1","session A");
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
    e = {}; e.type=SDL_KEYDOWN; e.key.windowID=id; e.key.keysym.scancode=SDL_SCANCODE_LCTRL;
    video.event(e); expect({key,224,1});
    e.key.keysym.scancode=SDL_SCANCODE_F9;
    video.event(e); expect({key,144,1});
    e = {}; e.type=SDL_WINDOWEVENT; e.window.windowID=id; e.window.event=SDL_WINDOWEVENT_FOCUS_LOST;
    video.event(e);
    check(!video.capturing(),"focus loss left capture on");
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
        } else check(until(client,Channel::State::failed), "bad key accepted");
        SSL_free(ssl);
        ap::net::close_socket(fd);
    }
    capture_test(listener,ctx);
    SSL_CTX_free(ctx);
    ap::net::close_socket(listener);
}

int main() {
#ifndef _WIN32
    signal(SIGPIPE,SIG_IGN);
#endif
    check(ap::net::global_init(),"socket init");
    Secret secret{};
    check(decode_secret(test_key,secret) && secret[15]==15, "key decode");
    check(!decode_secret("123",secret) && !decode_secret("z00102030405060708090a0b0c0d0e0f",secret),"invalid key");
    check(private_address("172.31.255.255") && !private_address("172.32.0.1") &&
          !private_address("0.0.0.0") && !private_address("8.8.8.8"), "address policy");
    geometry();
    channel_test();
    ap::net::global_shutdown();
    std::cout << "Geometry, address bounds, PSK acceptance/rejection, packet, heartbeat and release passed\n";
}
