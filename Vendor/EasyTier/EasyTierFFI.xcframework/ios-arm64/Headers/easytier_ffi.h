#ifndef EASYTIER_FFI_H
#define EASYTIER_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 基础 ABI（设计 6.2，人工维护；scripts/verify-easytier-ffi-symbols.sh 与 XCFramework 比对） */
typedef struct ETKeyValuePair {
    const char *key;
    const char *value;
} ETKeyValuePair;

int32_t parse_config(const char *cfg_str);
int32_t run_network_instance(const char *cfg_str);
int32_t set_tun_fd(const char *inst_name, int32_t fd);
int32_t retain_network_instance(const char *const *inst_names, size_t length);
int32_t collect_network_infos(ETKeyValuePair *infos, size_t max_length);
void get_error_msg(const char **out);
void free_string(const char *value);

/* public packetFlow bridge ABI（设计 6.2.1，App Store 轨） */
enum {
    ET_IO_OK = 0,
    ET_IO_EAGAIN = -11,
    ET_IO_EINVAL = -22,
    ET_IO_ENOENT = -2
};

typedef int32_t (*ETPacketOutputCallback)(
    const uint8_t *bytes, size_t length, uint32_t ip_version, void *context);

int32_t set_packet_flow_io(const char *inst_name,
                           ETPacketOutputCallback output,
                           void *context);
int32_t push_packet_flow_packet(const char *inst_name,
                                const uint8_t *bytes, size_t length,
                                uint32_t ip_version);
int32_t close_packet_flow_io(const char *inst_name);

#ifdef __cplusplus
}
#endif

#endif /* EASYTIER_FFI_H */
