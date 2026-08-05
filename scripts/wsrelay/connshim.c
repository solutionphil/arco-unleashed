/* connshim.c — LD_PRELOAD hook: redirect ONLY voronFDM's connect() to 127.0.0.1:7125 -> 127.0.0.1:7126
 * (the relay).  voronFDM is a native aarch64 binary, so this builds with the native gcc:
 *     gcc -shared -fPIC -O2 -o connshim.so connshim.c -ldl
 *
 * Injected via a KlipperScreen.service.d Environment=LD_PRELOAD drop-in, which the start script's other
 * children (ota_control, PhrozenGo/phrozen-go-release, frpc, ...) ALSO inherit. The process-name guard
 * (program_invocation_short_name == "voronFDM") makes sure only voronFDM is redirected; every sibling
 * reaches Moonraker on 7125 unchanged, and the relay is a WebSocket relay that would otherwise reject
 * their plain-HTTP requests. moonraker itself is never touched.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

extern char *program_invocation_short_name;
static int (*real_connect)(int, const struct sockaddr *, socklen_t) = 0;

int connect(int fd, const struct sockaddr *addr, socklen_t len)
{
    if (!real_connect)
        real_connect = (int (*)(int, const struct sockaddr *, socklen_t))dlsym(RTLD_NEXT, "connect");
    if (addr && addr->sa_family == AF_INET &&
        program_invocation_short_name &&
        strcmp(program_invocation_short_name, "voronFDM") == 0) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
        if (in->sin_port == htons(7125) &&
            in->sin_addr.s_addr == htonl(INADDR_LOOPBACK)) {
            struct sockaddr_in red = *in;
            red.sin_port = htons(7126);
            return real_connect(fd, (const struct sockaddr *)&red, sizeof(red));
        }
    }
    return real_connect(fd, addr, len);
}
