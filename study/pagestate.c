// DynamoRIO client: replays the page-state protocol of docs/NOTES.md section 2 on every memory access of an x86-64
// program and counts how many accesses could stay plain (unordered) on Arm.
//
// Page states: untouched, private to one thread, shared read-only, shared read-write.
//   untouched            -> private(T)        on the first access by T
//   private(O), T != O   -> shared read-only  on a read by T, shared read-write on a write by T
//   shared read-only     -> shared read-write on any write
// An access may be plain if, after the transition, its page is private to the accessing thread, or shared
// read-only and the access is a read. Otherwise the translator retranslates the instruction in the ordered form,
// and it stays ordered (sticky per instruction).
//
// Three numbers per access class:
//   sticky   plain under the mechanism (instruction not yet escalated and access allowed)
//   dynamic  plain if every access could be decided on its own (upper bound for any per-access scheme)
//   page     plain by final page state (pages touched by one thread only; read-only shared pages for loads)
//   fex      plain under FEX's default settings: accesses based on rsp, vector accesses and string
//            instructions (rep movs/stos) are not ordered, everything else is (not sound, for comparison)
//
// Two ways to give ordered instructions their own view of guest memory (-mode):
//   views   one ordered view per thread: a thread's own private pages are accessible in it (default)
//   global  one ordered view for all threads, in which private pages are inaccessible: an ordered access by the
//           owner to its own private page shares the page as if another thread had touched it
// Atomic (locked) instructions are always ordered and are treated like ordered accesses.
//
// Fault accounting for the cost model (each is a fault plus mprotect calls in the real mechanism):
//   first    first touch of a page by the thread that mapped it: free (shown for information only)
//   share    private -> shared read-only / read-write, including the first touch by a thread that did not map it
//   upgrade  shared read-only -> shared read-write; 'revokes' counts the plain views that lose the page
//   lazy     a thread's first plain read of a shared read-only page (mapped into its plain view on demand)
//   lazy-o   (views mode) a thread's first ordered access to a shared page (mapped into its ordered view)
//   escal.   instructions retranslated in the ordered form
//
// Options: -out PREFIX    results go to PREFIX.APP.PID.txt (default stderr)
//          -list PREFIX   also write PREFIX.APP.PID.plain: addresses of the executed instructions of the main
//                         module that never had to be ordered (input for the oracle experiment in FEX)
//          -page_shift N  page size 2^N (default 12)
//          -mode views|global

#include "dr_api.h"
#include "drmgr.h"
#include "drreg.h"
#include "drutil.h"
#include "hashtable.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { ST_NONE = 0, ST_PRIV = 1, ST_SRO = 2, ST_SRW = 3 };
enum { C_LOAD = 0, C_VLOAD = 1, C_STORE = 2, C_VSTORE = 3, NCLASS = 4 };
static const char *const class_name[NCLASS] = {"load", "vector load", "store", "vector store"};

#define INFO_WRITE (1u << 16)
#define INFO_VEC (1u << 17)
#define INFO_ATOMIC (1u << 18)
#define INFO_NT (1u << 19)
#define INFO_RSP (1u << 20)
#define INFO_STR (1u << 21)

typedef struct {
    uint32_t word;  // state in bits 0-1, owner thread index + 1 above
    uint32_t pad;
    uint64_t ro_mask;  // threads whose plain view maps this shared read-only page
    uint64_t o_mask;   // (views mode) threads whose ordered view maps this shared page
    uint64_t n[NCLASS];
} page_t;

enum { TR_NONE, TR_FIRST, TR_SHARE, TR_UPGRADE };
enum { MODE_VIEWS, MODE_GLOBAL, MODE_CHECK };
static const char *const mode_name[] = {"views", "global", "check"};
static int mode;

#define L2_BITS 16
#define L1_BITS 20
static page_t *l1[1u << L1_BITS];
static int page_shift = 12;

// One record per x86 instruction: if any of its memory operands needs ordering, all of it is ordered, as a
// translator decides per guest instruction.
typedef struct {
    uint32_t ordered;
    uint32_t executed;
    app_pc pc;
} insn_t;

typedef struct {
    uint32_t idx;
    uint64_t total[NCLASS], sticky[NCLASS], dynamic[NCLASS], fex[NCLASS];
    uint64_t atomics, nontemporal, transitions, escalations;
    uint64_t f_first, f_share, f_upgrade, f_lazy, f_lazy_o, revokes, checked;
    int sc;           // system call in flight and its parameters (saved before the call)
    uintptr_t p[5];
} tls_t;

static int tls_idx;
static uint32_t nthreads;
static hashtable_t insns;
static void *merge_lock;
static tls_t sum;
static uint32_t max_threads_seen;
static file_t out = INVALID_FILE;
static file_t list = INVALID_FILE;
static app_pc main_start, main_end;

// ---- Memory regions and who created them. Pages of a region start private to the thread that mapped it (mmap,
// brk), so that its own first touch costs no fault; a thread's stack belongs to the thread from its start. munmap
// returns pages to the untouched state. Unknown memory (the binary's data, the first stack) belongs to the first
// thread.
typedef struct {
    uintptr_t start, end;
    uint32_t creator;
} region_t;
#define MAX_REGIONS 65536
static region_t *regions;
static int nregions;
static void *region_lock;
static uintptr_t cur_brk;

static void carve(uintptr_t s, uintptr_t e) {
    for (int i = 0; i < nregions; i++) {
        region_t *r = &regions[i];
        if (r->end <= s || r->start >= e) continue;
        if (r->start < s && r->end > e) {
            if (nregions < MAX_REGIONS) regions[nregions++] = (region_t){e, r->end, r->creator};
            r->end = s;
        } else if (r->start < s) {
            r->end = s;
        } else if (r->end > e) {
            r->start = e;
        } else {
            regions[i] = regions[--nregions];
            i--;
        }
    }
}

static void add_region(uintptr_t s, uintptr_t e, uint32_t creator) {
    dr_mutex_lock(region_lock);
    carve(s, e);
    if (nregions < MAX_REGIONS) regions[nregions++] = (region_t){s, e, creator};
    dr_mutex_unlock(region_lock);
}

static uint32_t creator_of(uintptr_t a, uintptr_t *s, uintptr_t *e) {
    uint32_t c = 1;
    dr_mutex_lock(region_lock);
    for (int i = 0; i < nregions; i++)
        if (a >= regions[i].start && a < regions[i].end) {
            c = regions[i].creator;
            if (s) *s = regions[i].start;
            if (e) *e = regions[i].end;
            break;
        }
    dr_mutex_unlock(region_lock);
    return c;
}

static page_t *page_of(uintptr_t pn);

// Sets the pages of [s, e) back to untouched; only_private: only pages that are private to some thread.
static void reset_pages(uintptr_t s, uintptr_t e, int only_private) {
    if (e <= s) return;
    for (uintptr_t pn = s >> page_shift; pn <= (e - 1) >> page_shift; pn++) {
        size_t i1 = (pn >> 16) & ((1u << 20) - 1);
        if (__atomic_load_n(&l1[i1], __ATOMIC_ACQUIRE) == NULL) {
            pn |= (1u << 16) - 1;  // whole chunk untouched
            continue;
        }
        page_t *pg = page_of(pn);
        uint32_t w = __atomic_load_n(&pg->word, __ATOMIC_ACQUIRE);
        if (only_private && (w & 3) != ST_PRIV) continue;
        __atomic_store_n(&pg->word, 0, __ATOMIC_RELEASE);
        pg->ro_mask = pg->o_mask = 0;
    }
}

static page_t *page_of(uintptr_t pn) {
    size_t i1 = (pn >> L2_BITS) & ((1u << L1_BITS) - 1);
    page_t *chunk = __atomic_load_n(&l1[i1], __ATOMIC_ACQUIRE);
    if (chunk == NULL) {
        size_t bytes = sizeof(page_t) << L2_BITS;
        page_t *fresh = dr_raw_mem_alloc(bytes, DR_MEMPROT_READ | DR_MEMPROT_WRITE, NULL);
        DR_ASSERT(fresh != NULL);
        if (__atomic_compare_exchange_n(&l1[i1], &chunk, fresh, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
            chunk = fresh;
        else
            dr_raw_mem_free(fresh, bytes);
    }
    return &chunk[pn & ((1u << L2_BITS) - 1)];
}

// Applies the transition for an access by thread 'me' (index + 1); returns the page word after it and the kind of
// transition in *kind. 'as_foreign': the access cannot reach the thread's own private pages (global ordered view).
static uint32_t touch(page_t *pg, uintptr_t pn, uint32_t me, int write, int as_foreign, int *kind) {
    uint32_t w = __atomic_load_n(&pg->word, __ATOMIC_ACQUIRE);
    for (;;) {
        uint32_t st = w & 3, nw;
        int k;
        if (st == ST_NONE) {
            // the page was assigned to its region's creator when it was mapped
            uint32_t c = creator_of(pn << page_shift, NULL, NULL);
            if (c == me && !as_foreign) {
                nw = (me << 2) | ST_PRIV;
                k = TR_FIRST;  // free: mapped for this thread from the start
            } else {
                nw = write ? ST_SRW : ST_SRO;
                k = TR_SHARE;
                if (nw == ST_SRO) __atomic_fetch_or(&pg->ro_mask, 1ull << ((c - 1) & 63), __ATOMIC_RELAXED);
            }
            if (__atomic_compare_exchange_n(&pg->word, &w, nw, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
                *kind = k;
                return nw;
            }
            continue;
        } else if (st == ST_PRIV) {
            if ((w >> 2) == me && !as_foreign) return w;
            nw = write ? ST_SRW : ST_SRO;
            k = TR_SHARE;
        } else if (st == ST_SRO) {
            if (!write) return w;
            nw = ST_SRW;
            k = TR_UPGRADE;
        } else
            return w;
        if (__atomic_compare_exchange_n(&pg->word, &w, nw, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            *kind = k;
            if (k == TR_SHARE && nw == ST_SRO) {
                // the owner keeps read access in its plain view
                __atomic_fetch_or(&pg->ro_mask, 1ull << (((w >> 2) - 1) & 63), __ATOMIC_RELAXED);
            }
            return nw;
        }
    }
}

static void on_access(insn_t *in, uintptr_t addr, uint32_t info) {
    tls_t *tl = drmgr_get_tls_field(dr_get_current_drcontext(), tls_idx);
    uint32_t me = tl->idx + 1;
    uint32_t size = info & 0xffff;
    int write = (info & INFO_WRITE) != 0;
    int c = (write ? 2 : 0) + ((info & INFO_VEC) ? 1 : 0);
    uintptr_t first = addr >> page_shift, last = (addr + (size ? size - 1 : 0)) >> page_shift;
    uint64_t bit = 1ull << ((me - 1) & 63);
    int via_ordered = __atomic_load_n(&in->ordered, __ATOMIC_RELAXED) || (info & INFO_ATOMIC);
    int ok = 1, own = 1;
    for (uintptr_t pn = first; pn <= last && pn - first < 64; pn++) {
        page_t *pg = page_of(pn);
        int kind = TR_NONE;
        uint32_t w = touch(pg, pn, me, write, mode == MODE_GLOBAL && via_ordered, &kind);
        uint32_t st = w & 3;
        switch (kind) {
        case TR_FIRST: tl->f_first++; break;
        case TR_SHARE: tl->f_share++; break;
        case TR_UPGRADE: {
            uint64_t m = __atomic_exchange_n(&pg->ro_mask, 0, __ATOMIC_RELAXED);
            tl->f_upgrade++;
            tl->revokes += __builtin_popcountll(m);
            break;
        }
        }
        if (kind != TR_NONE && kind != TR_FIRST) tl->transitions++;
        if (!((st == ST_PRIV && (w >> 2) == me) || (st == ST_SRO && !write))) ok = 0;
        if (!(st == ST_PRIV && (w >> 2) == me)) own = 0;
        if (st == ST_SRO && !write && !via_ordered && !(__atomic_load_n(&pg->ro_mask, __ATOMIC_RELAXED) & bit)) {
            __atomic_fetch_or(&pg->ro_mask, bit, __ATOMIC_RELAXED);
            tl->f_lazy++;
        }
        if (mode == MODE_VIEWS && via_ordered && st >= ST_SRO &&
            !(__atomic_load_n(&pg->o_mask, __ATOMIC_RELAXED) & bit)) {
            __atomic_fetch_or(&pg->o_mask, bit, __ATOMIC_RELAXED);
            tl->f_lazy_o++;
        }
        if (pn == first && !(info & (INFO_ATOMIC | INFO_NT))) __atomic_fetch_add(&pg->n[c], 1, __ATOMIC_RELAXED);
    }
    if (info & INFO_ATOMIC) {
        tl->atomics++;
        return;
    }
    if (info & INFO_NT) {
        tl->nontemporal++;
        return;
    }
    if (!in->executed) in->executed = 1;
    tl->total[c]++;
    if (ok) tl->dynamic[c]++;
    if ((info & (INFO_VEC | INFO_RSP | INFO_STR)) != 0) tl->fex[c]++;
    uint32_t ord = __atomic_load_n(&in->ordered, __ATOMIC_RELAXED);
    if (!ord && !ok) {
        __atomic_store_n(&in->ordered, 1, __ATOMIC_RELAXED);
        tl->escalations++;
        ord = 1;
    }
    if (!ord) {
        tl->sticky[c]++;
    } else if (mode == MODE_CHECK && own) {
        // escalated, but the owner check sends accesses to the thread's own private pages down the plain path
        tl->sticky[c]++;
        tl->checked++;
    }
}

static bool has_simd_reg(instr_t *instr) {
    for (int i = 0; i < instr_num_srcs(instr); i++) {
        opnd_t o = instr_get_src(instr, i);
        if (opnd_is_reg(o) && (reg_is_xmm(opnd_get_reg(o)) || reg_is_mmx(opnd_get_reg(o)))) return true;
    }
    for (int i = 0; i < instr_num_dsts(instr); i++) {
        opnd_t o = instr_get_dst(instr, i);
        if (opnd_is_reg(o) && (reg_is_xmm(opnd_get_reg(o)) || reg_is_mmx(opnd_get_reg(o)))) return true;
    }
    return false;
}

static bool is_nontemporal(int op) {
    switch (op) {
    case OP_movntdq: case OP_movntps: case OP_movntpd: case OP_movnti: case OP_movntq:
    case OP_vmovntdq: case OP_vmovntps: case OP_vmovntpd: case OP_maskmovdqu: case OP_maskmovq:
        return true;
    default:
        return false;
    }
}

static insn_t *insn_record(app_pc pc) {
    void *key = (void *)pc;
    hashtable_lock(&insns);
    insn_t *rec = hashtable_lookup(&insns, key);
    if (rec == NULL) {
        rec = dr_global_alloc(sizeof *rec);
        rec->ordered = 0;
        rec->executed = 0;
        rec->pc = pc;
        hashtable_add(&insns, key, rec);
    }
    hashtable_unlock(&insns);
    return rec;
}

static void instrument_ref(void *dc, instrlist_t *bb, instr_t *where, opnd_t ref, uint32_t flags) {
    if (opnd_is_vsib(ref)) return;  // gathers/scatters: rare, not handled
    reg_id_t reg_addr, reg_tmp;
    if (drreg_reserve_register(dc, bb, where, NULL, &reg_addr) != DRREG_SUCCESS ||
        drreg_reserve_register(dc, bb, where, NULL, &reg_tmp) != DRREG_SUCCESS) {
        DR_ASSERT(false);
        return;
    }
    if (drutil_insert_get_mem_addr(dc, bb, where, ref, reg_addr, reg_tmp)) {
        uint32_t size = drutil_opnd_mem_size_in_bytes(ref, where);
        if (size > 0xffff) size = 0xffff;
        if (opnd_is_base_disp(ref) && opnd_get_base(ref) == DR_REG_RSP) flags |= INFO_RSP;
        insn_t *rec = insn_record(instr_get_app_pc(where));
        dr_insert_clean_call(dc, bb, where, (void *)on_access, false, 3, OPND_CREATE_INTPTR(rec),
                             opnd_create_reg(reg_addr), OPND_CREATE_INT32(size | flags));
    }
    drreg_unreserve_register(dc, bb, where, reg_tmp);
    drreg_unreserve_register(dc, bb, where, reg_addr);
}

static dr_emit_flags_t event_app2app(void *dc, void *tag, instrlist_t *bb, bool for_trace, bool translating) {
    if (!drutil_expand_rep_string(dc, bb)) DR_ASSERT(false);
    return DR_EMIT_DEFAULT;
}

static dr_emit_flags_t event_insert(void *dc, void *tag, instrlist_t *bb, instr_t *instr, bool for_trace,
                                    bool translating, void *user_data) {
    if (!instr_is_app(instr) || instr_get_app_pc(instr) == NULL) return DR_EMIT_DEFAULT;
    if (!instr_reads_memory(instr) && !instr_writes_memory(instr)) return DR_EMIT_DEFAULT;
    int op = instr_get_opcode(instr);
    if (instr_is_prefetch(instr) || op == OP_nop_modrm || op == OP_clflush || op == OP_clflushopt)
        return DR_EMIT_DEFAULT;
    uint32_t common = 0;
    if (has_simd_reg(instr)) common |= INFO_VEC;
    if (instr_get_prefix_flag(instr, PREFIX_LOCK) || (op == OP_xchg && instr_writes_memory(instr)))
        common |= INFO_ATOMIC;
    if (is_nontemporal(op)) common |= INFO_NT;
    if (op == OP_movs || op == OP_stos) common |= INFO_STR;
    int slot = 0;
    for (int i = 0; i < instr_num_srcs(instr) && slot < 15; i++) {
        opnd_t o = instr_get_src(instr, i);
        if (!opnd_is_memory_reference(o)) continue;
        uint32_t f = common;
        if (drutil_opnd_mem_size_in_bytes(o, instr) >= 16) f |= INFO_VEC;
        instrument_ref(dc, bb, instr, o, f);
        slot++;
    }
    for (int i = 0; i < instr_num_dsts(instr) && slot < 15; i++) {
        opnd_t o = instr_get_dst(instr, i);
        if (!opnd_is_memory_reference(o)) continue;
        uint32_t f = common | INFO_WRITE;
        if (drutil_opnd_mem_size_in_bytes(o, instr) >= 16) f |= INFO_VEC;
        instrument_ref(dc, bb, instr, o, f);
        slot++;
    }
    return DR_EMIT_DEFAULT;
}

static void event_thread_init(void *dc) {
    tls_t *tl = dr_thread_alloc(dc, sizeof *tl);
    memset(tl, 0, sizeof *tl);
    tl->idx = __atomic_fetch_add(&nthreads, 1, __ATOMIC_RELAXED);
    drmgr_set_tls_field(dc, tls_idx, tl);
    // A new thread's stack was mapped by its parent; it belongs to the new thread from its first instruction
    // (the clone call orders the parent's writes, e.g. glibc's thread descriptor at the top, before it).
    dr_mcontext_t mc;
    mc.size = sizeof mc;
    mc.flags = DR_MC_CONTROL;
    if (tl->idx > 0 && dr_get_mcontext(dc, &mc)) {
        uintptr_t s = 0, e = 0;
        creator_of((uintptr_t)mc.xsp, &s, &e);
        if (e > s) {
            reset_pages(s, e, 1);
            add_region(s, e, tl->idx + 1);
        }
    }
}

static bool event_filter_syscall(void *dc, int sysnum) {
    (void)dc;
    return sysnum == 9 || sysnum == 11 || sysnum == 12 || sysnum == 25;  // mmap munmap brk mremap
}

static bool event_pre_syscall(void *dc, int sysnum) {
    tls_t *tl = drmgr_get_tls_field(dc, tls_idx);
    tl->sc = sysnum;
    for (int i = 0; i < 5; i++) tl->p[i] = (uintptr_t)dr_syscall_get_param(dc, i);
    return true;
}

static void event_post_syscall(void *dc, int sysnum) {
    tls_t *tl = drmgr_get_tls_field(dc, tls_idx);
    if (tl->sc != sysnum) return;
    tl->sc = -1;
    ptr_int_t res = (ptr_int_t)dr_syscall_get_result(dc);
    if (res < 0 && res > -4096) return;
    uint32_t me = tl->idx + 1;
    uintptr_t pg = (uintptr_t)1 << page_shift, r = (uintptr_t)res;
#define PAGE_UP(x) (((x) + pg - 1) & ~(pg - 1))
    switch (sysnum) {
    case 9:  // mmap(addr, len, ...)
        reset_pages(r, r + PAGE_UP(tl->p[1]), 0);
        add_region(r, r + PAGE_UP(tl->p[1]), me);
        break;
    case 11:  // munmap(addr, len)
        reset_pages(tl->p[0], tl->p[0] + PAGE_UP(tl->p[1]), 0);
        dr_mutex_lock(region_lock);
        carve(tl->p[0], tl->p[0] + PAGE_UP(tl->p[1]));
        dr_mutex_unlock(region_lock);
        break;
    case 25:  // mremap(old, old_size, new_size, flags, new)
        reset_pages(tl->p[0], tl->p[0] + PAGE_UP(tl->p[1]), 0);
        dr_mutex_lock(region_lock);
        carve(tl->p[0], tl->p[0] + PAGE_UP(tl->p[1]));
        dr_mutex_unlock(region_lock);
        reset_pages(r, r + PAGE_UP(tl->p[2]), 0);
        add_region(r, r + PAGE_UP(tl->p[2]), me);
        break;
    case 12:  // brk
        if (cur_brk == 0) {
            cur_brk = r;
        } else if (r > cur_brk) {
            add_region(PAGE_UP(cur_brk), PAGE_UP(r), me);
            cur_brk = r;
        } else if (r < cur_brk) {
            reset_pages(PAGE_UP(r), PAGE_UP(cur_brk), 0);
            dr_mutex_lock(region_lock);
            carve(PAGE_UP(r), PAGE_UP(cur_brk));
            dr_mutex_unlock(region_lock);
            cur_brk = r;
        }
        break;
    }
#undef PAGE_UP
}

static void event_thread_exit(void *dc) {
    tls_t *tl = drmgr_get_tls_field(dc, tls_idx);
    dr_mutex_lock(merge_lock);
    for (int c = 0; c < NCLASS; c++) {
        sum.total[c] += tl->total[c];
        sum.sticky[c] += tl->sticky[c];
        sum.dynamic[c] += tl->dynamic[c];
        sum.fex[c] += tl->fex[c];
    }
    sum.atomics += tl->atomics;
    sum.nontemporal += tl->nontemporal;
    sum.transitions += tl->transitions;
    sum.escalations += tl->escalations;
    sum.f_first += tl->f_first;
    sum.f_share += tl->f_share;
    sum.f_upgrade += tl->f_upgrade;
    sum.f_lazy += tl->f_lazy;
    sum.f_lazy_o += tl->f_lazy_o;
    sum.revokes += tl->revokes;
    sum.checked += tl->checked;
    if (tl->idx + 1 > max_threads_seen) max_threads_seen = tl->idx + 1;
    dr_mutex_unlock(merge_lock);
    dr_thread_free(dc, tl, sizeof *tl);
}

static double pct(uint64_t a, uint64_t b) { return b ? 100.0 * (double)a / (double)b : 0.0; }

static uint64_t listed_plain, listed_ordered;

static void list_one(void *payload, void *user_data) {
    insn_t *in = payload;
    (void)user_data;
    if (!in->executed || in->pc < main_start || in->pc >= main_end) return;
    if (in->ordered) {
        listed_ordered++;
        return;
    }
    listed_plain++;
    if (list != INVALID_FILE) dr_fprintf(list, "%p\n", in->pc);
}

static file_t open_named(const char *prefix, const char *suffix) {
    char path[512];
    dr_snprintf(path, sizeof path, "%s.%s.%d.%s", prefix, dr_get_application_name(), (int)dr_get_process_id(),
                suffix);
    path[sizeof path - 1] = 0;
    return dr_open_file(path, DR_FILE_WRITE_OVERWRITE);
}

static void event_exit(void) {
    uint64_t page_plain[NCLASS] = {0}, page_total[NCLASS] = {0}, pages[4] = {0};
    for (size_t i1 = 0; i1 < (1u << L1_BITS); i1++) {
        page_t *chunk = l1[i1];
        if (chunk == NULL) continue;
        for (size_t i2 = 0; i2 < (1u << L2_BITS); i2++) {
            page_t *pg = &chunk[i2];
            uint32_t st = pg->word & 3;
            if (st == ST_NONE) continue;
            pages[st]++;
            for (int c = 0; c < NCLASS; c++) {
                page_total[c] += pg->n[c];
                int plain = st == ST_PRIV || (st == ST_SRO && (c == C_LOAD || c == C_VLOAD));
                if (plain) page_plain[c] += pg->n[c];
            }
        }
        dr_raw_mem_free(chunk, sizeof(page_t) << L2_BITS);
    }
    hashtable_apply_to_all_payloads_user_data(&insns, list_one, NULL);
    if (list != INVALID_FILE) dr_close_file(list);
    file_t f = out != INVALID_FILE ? out : STDERR;
    dr_fprintf(f, "process %s   main module instructions with memory accesses: plain %llu, ordered %llu\n",
               dr_get_application_name(), (unsigned long long)listed_plain, (unsigned long long)listed_ordered);
    dr_fprintf(f, "threads %u   page size %d   pages: private %llu, shared read-only %llu, shared read-write %llu\n",
               nthreads, 1 << page_shift, (unsigned long long)pages[ST_PRIV], (unsigned long long)pages[ST_SRO],
               (unsigned long long)pages[ST_SRW]);
    dr_fprintf(f, "mode %s   transitions %llu   escalated instructions %llu   locked/xchg %llu   non-temporal %llu\n",
               mode_name[mode], (unsigned long long)sum.transitions,
               (unsigned long long)sum.escalations, (unsigned long long)sum.atomics,
               (unsigned long long)sum.nontemporal);
    dr_fprintf(f, "faults: (free first touches %llu)  share %llu  upgrade %llu (revokes %llu)  lazy %llu  lazy-o %llu  "
                  "escal. %llu\n",
               (unsigned long long)sum.f_first, (unsigned long long)sum.f_share,
               (unsigned long long)sum.f_upgrade, (unsigned long long)sum.revokes,
               (unsigned long long)sum.f_lazy, (unsigned long long)sum.f_lazy_o,
               (unsigned long long)sum.escalations);
    if (mode == MODE_CHECK)
        dr_fprintf(f, "accesses of escalated instructions sent down the plain path by the owner check: %llu\n",
                   (unsigned long long)sum.checked);
    dr_fprintf(f, "plain accesses:\n");
    dr_fprintf(f, "%-13s %15s %9s %9s %9s %9s\n", "class", "accesses", "sticky", "dynamic", "page", "fex");
    for (int c = 0; c < NCLASS; c++)
        dr_fprintf(f, "%-13s %15llu %8.2f%% %8.2f%% %8.2f%% %8.2f%%\n", class_name[c],
                   (unsigned long long)sum.total[c], pct(sum.sticky[c], sum.total[c]),
                   pct(sum.dynamic[c], sum.total[c]), pct(page_plain[c], page_total[c]),
                   pct(sum.fex[c], sum.total[c]));
    if (out != INVALID_FILE) dr_close_file(out);
    hashtable_delete(&insns);
    dr_mutex_destroy(merge_lock);
    drmgr_unregister_tls_field(tls_idx);
    drutil_exit();
    drreg_exit();
    drmgr_exit();
}

DR_EXPORT void dr_client_main(client_id_t id, int argc, const char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-out") == 0 && i + 1 < argc)
            out = open_named(argv[++i], "txt");
        else if (strcmp(argv[i], "-list") == 0 && i + 1 < argc)
            list = open_named(argv[++i], "plain");
        else if (strcmp(argv[i], "-page_shift") == 0 && i + 1 < argc)
            page_shift = atoi(argv[++i]);
        else if (strcmp(argv[i], "-mode") == 0 && i + 1 < argc)
        {
            i++;
            mode = strcmp(argv[i], "global") == 0 ? MODE_GLOBAL : strcmp(argv[i], "check") == 0 ? MODE_CHECK : MODE_VIEWS;
        }
    }
    module_data_t *m = dr_get_main_module();
    if (m != NULL) {
        main_start = m->start;
        main_end = m->end;
        dr_free_module_data(m);
    }
    drreg_options_t ops = {sizeof(ops), 3, false};
    if (!drmgr_init() || drreg_init(&ops) != DRREG_SUCCESS || !drutil_init()) DR_ASSERT(false);
    // not synchronized internally: insn_record() holds the table lock across lookup and add
    hashtable_init_ex(&insns, 16, HASH_INTPTR, false, false, NULL, NULL, NULL);
    merge_lock = dr_mutex_create();
    region_lock = dr_mutex_create();
    regions = dr_global_alloc(MAX_REGIONS * sizeof(region_t));
    drmgr_register_filter_syscall_event(event_filter_syscall);
    drmgr_register_pre_syscall_event(event_pre_syscall);
    drmgr_register_post_syscall_event(event_post_syscall);
    tls_idx = drmgr_register_tls_field();
    drmgr_register_thread_init_event(event_thread_init);
    drmgr_register_thread_exit_event(event_thread_exit);
    drmgr_register_bb_app2app_event(event_app2app, NULL);
    drmgr_register_bb_instrumentation_event(NULL, event_insert, NULL);
    drmgr_register_exit_event(event_exit);
}
