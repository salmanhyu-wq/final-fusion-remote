#import <Foundation/Foundation.h>
#include <Security/Security.h>
#include <arpa/inet.h>
#include <libproc.h>
#include <netinet/tcp_fsm.h>
#include <sys/proc_info.h>
#include <unistd.h>

#include "ReceiverEvents.h"

static bool processInfo(pid_t pid, struct proc_bsdinfo *info) {
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, sizeof(*info)) == sizeof(*info) &&
           info->pbi_pid == (uint32_t)pid && info->pbi_uid == geteuid() && info->pbi_ruid == getuid();
}

static bool isIPv4Loopback(const struct in_sockinfo *ip, int family) {
    if (family == AF_INET6) {
        // macOS also reports IPv4 TCP sockets created by this client as
        // IPv4-compatible or IPv4-mapped IPv6 in the process descriptor table.
        if (!(IN6_IS_ADDR_V4COMPAT(&ip->insi_laddr.ina_6) || IN6_IS_ADDR_V4MAPPED(&ip->insi_laddr.ina_6)) ||
            !(IN6_IS_ADDR_V4COMPAT(&ip->insi_faddr.ina_6) || IN6_IS_ADDR_V4MAPPED(&ip->insi_faddr.ina_6))) return false;
    } else if (family != AF_INET) {
        return false;
    }
    return ntohl(ip->insi_laddr.ina_46.i46a_addr4.s_addr) == INADDR_LOOPBACK &&
           ntohl(ip->insi_faddr.ina_46.i46a_addr4.s_addr) == INADDR_LOOPBACK;
}

bool StudioIsScreenSharingPeer(pid_t pid, uint16_t clientPort, uint16_t serverPort) {
    struct proc_bsdinfo before, after;
    if (pid <= 0 || !clientPort || !serverPort || !processInfo(pid, &before)) return false;

    // Inspect the exact client side of the accepted IPv4 connection. A listening
    // socket, a different connection of the same process, or another UID is insufficient.
    struct proc_fdinfo descriptors[512];
    int length = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, descriptors, sizeof(descriptors));
    if (length <= 0 || length >= sizeof(descriptors)) return false;
    bool matches = false;
    for (int i = 0; i < length / sizeof(descriptors[0]); ++i) {
        if (descriptors[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo socket;
        if (proc_pidfdinfo(pid, descriptors[i].proc_fd, PROC_PIDFDSOCKETINFO, &socket, sizeof(socket)) != sizeof(socket) ||
            socket.psi.soi_kind != SOCKINFO_TCP) continue;
        const struct tcp_sockinfo *tcp = &socket.psi.soi_proto.pri_tcp;
        const struct in_sockinfo *ip = &tcp->tcpsi_ini;
        if (tcp->tcpsi_state == TCPS_ESTABLISHED &&
            ntohs((uint16_t)ip->insi_lport) == clientPort && ntohs((uint16_t)ip->insi_fport) == serverPort &&
            isIPv4Loopback(ip, socket.psi.soi_family)) {
            matches = true;
            break;
        }
    }
    if (!matches) return false;

    SecCodeRef peer = NULL;
    SecRequirementRef requirement = NULL;
    matches = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)@{(__bridge NSString *)kSecGuestAttributePid: @(pid)},
                                            kSecCSDefaultFlags, &peer) == errSecSuccess &&
              SecRequirementCreateWithString(CFSTR("identifier \"com.apple.ScreenSharing\" and anchor apple"),
                                             kSecCSDefaultFlags, &requirement) == errSecSuccess &&
              SecCodeCheckValidity(peer, kSecCSDefaultFlags, requirement) == errSecSuccess &&
              processInfo(pid, &after) && before.pbi_start_tvsec == after.pbi_start_tvsec &&
              before.pbi_start_tvusec == after.pbi_start_tvusec;
    if (requirement) CFRelease(requirement);
    if (peer) CFRelease(peer);
    return matches;
}
