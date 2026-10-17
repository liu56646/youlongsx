#ifndef VM_FRAME_SHM_H
#define VM_FRAME_SHM_H

/*
 * B1 子进程模式的帧回传 —— 共享内存版（替代 frame.rgba 文件握手）。
 *
 * 为什么：文件回传每帧要走 open/write/rename（写端）与 open/read（读端）
 * 四条系统调用，外加文件页缓存与该目录的 dentry 抖动；1080p 一帧就是几 MB，
 * 这些与 CPU 快慢无关的开销直接吃掉"跟手感"。改成 mmap 同一块文件后，
 * 两端都只剩一次 memcpy。
 *
 * 两个进程共用本头描述的同一块映射（<frame_dir>/frame.shm）：
 *   写端：QEMU 子进程  engine/scripts/qemu_patches/vmhost_gfx_glue.cpp
 *   读端：App 进程     engine/src/main/cpp/src/vm_frame_relay.c
 *
 * 同步协议（单写者、多读者，seqlock 风格 + 多缓冲轮转）：
 *   写者：把新帧 memcpy 进 (seq+1)%NBUFS 号缓冲 → 写 slot/width/height →
 *         release 递增 seq。
 *   读者：acquire 读 seq；与上次不同即认为有新帧，从 slot 缓冲拷出。
 *   NBUFS>=3 保证写者当前写的槽不会正好等于读者正在读的槽（读者拷一帧的
 *   时间远小于 3 帧间隔），因此无需加锁，也无需读者持有跨帧的指针。
 *
 * 字节序：小端（仅在本机自用，不跨机器）。
 */

#include <stddef.h>
#include <stdint.h>

#define VM_FRAME_SHM_MAGIC   0x564D4652u   /* 'VMFR' */
#define VM_FRAME_SHM_VERSION 1u
#define VM_FRAME_SHM_NBUFS   3u

/* 固定头，恰好 64 字节；缓冲紧接其后。magic 由写者“最后”写入，作为“已就绪”
   标志 —— 读者只有在 magic 正确时才接受，避免读到半初始化或上一轮的残留。 */
typedef struct {
    uint32_t magic;       /* = VM_FRAME_SHM_MAGIC（就绪标志） */
    uint32_t version;     /* = VM_FRAME_SHM_VERSION */
    uint32_t nbufs;       /* = VM_FRAME_SHM_NBUFS */
    uint32_t stride_cap;  /* 单个缓冲容量（字节），各缓冲共用 */
    uint32_t disp_w;      /* 配置的显示宽（诊断用） */
    uint32_t disp_h;      /* 配置的显示高（诊断用） */
    uint32_t seq;         /* 发布计数：0=尚无帧；写者 release 递增 */
    uint32_t slot;        /* 最新帧所在缓冲下标 [0, nbufs) */
    uint32_t width;       /* 最新帧宽 */
    uint32_t height;      /* 最新帧高 */
    uint32_t format;      /* 保留：0 = RGBA8888 */
    uint32_t reserved0;
    uint32_t reserved1;
    uint32_t reserved2;
    uint32_t reserved3;
} VmFrameShmHeader;

#define VM_FRAME_SHM_HDR_SIZE 64u   /* 固定头长；缓冲从该偏移开始 */

/* 第 slot 号缓冲的首地址。 */
static inline uint8_t* vm_frame_shm_buf(VmFrameShmHeader* h, uint32_t slot) {
    return (uint8_t*)h + VM_FRAME_SHM_HDR_SIZE +
           (size_t)slot * (size_t)h->stride_cap;
}

/* 整块共享内存应占的字节数。 */
static inline size_t vm_frame_shm_total(uint32_t stride_cap) {
    return (size_t)VM_FRAME_SHM_HDR_SIZE +
           (size_t)VM_FRAME_SHM_NBUFS * (size_t)stride_cap;
}

#endif /* VM_FRAME_SHM_H */
