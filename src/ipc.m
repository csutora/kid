#import "ipc.h"

#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static const size_t max_message = 4096;

NSString *ipc_socket_path(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"pinky.sock"];
}

static bool socket_address(struct sockaddr_un *addr) {
    const char *path = ipc_socket_path().fileSystemRepresentation;
    memset(addr, 0, sizeof *addr);
    addr->sun_family = AF_UNIX;
    if (strlen(path) >= sizeof addr->sun_path) return false;
    strcpy(addr->sun_path, path);
    return true;
}

static void configure(int fd) {
    int on = 1;
    struct timeval timeout = {.tv_sec = 2};
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
}

static NSString *read_message(int fd) {
    NSMutableData *data = [NSMutableData data];
    char buf[512];
    while (data.length < max_message) {
        ssize_t n = read(fd, buf, sizeof buf);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        [data appendBytes:buf length:n];
        if (memchr(buf, '\n', n)) break;
    }
    NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static void write_message(int fd, NSString *message) {
    NSData *data = [[message stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    const char *bytes = data.bytes;
    size_t left = data.length;
    while (left) {
        ssize_t n = write(fd, bytes, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        bytes += n;
        left -= n;
    }
}

bool ipc_serve(NSString *(^handler)(NSString *request)) {
    static dispatch_source_t source;
    struct sockaddr_un addr;
    if (!socket_address(&addr)) return false;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return false;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    unlink(addr.sun_path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0 || listen(fd, 8) < 0) {
        close(fd);
        return false;
    }

    dispatch_queue_t queue = dispatch_queue_create("pinky.ipc", DISPATCH_QUEUE_SERIAL);
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, queue);
    dispatch_source_set_event_handler(source, ^{
        int client = accept(fd, NULL, NULL);
        if (client < 0) return;
        fcntl(client, F_SETFD, FD_CLOEXEC);
        uid_t uid;
        gid_t gid;
        if (getpeereid(client, &uid, &gid) < 0 || uid != getuid()) {
            close(client);
            return;
        }
        configure(client);
        NSString *request = read_message(client);
        __block NSString *response;
        dispatch_sync(dispatch_get_main_queue(), ^{
            response = handler(request);
        });
        write_message(client, response);
        close(client);
    });
    dispatch_resume(source);
    return true;
}

NSString *ipc_request(NSString *request) {
    struct sockaddr_un addr;
    if (!socket_address(&addr)) return nil;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    configure(fd);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        close(fd);
        return nil;
    }
    write_message(fd, request);
    shutdown(fd, SHUT_WR);
    NSString *response = read_message(fd);
    close(fd);
    return response.length ? response : nil;
}
